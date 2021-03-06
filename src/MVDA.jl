module MVDA

using DataFrames: copy, copyto!
using DataDeps, CSV, DataFrames, CodecZlib
using Parameters, Printf, MLDataUtils, ProgressMeter
using LinearAlgebra, Random, Statistics, StatsBase, StableRNGs
using KernelFunctions
using DelimitedFiles, Plots
using Polyester, MLDataUtils

import Base: show, iterate

##### DATA #####

#=
Uses DataDeps to download data as needed.
Inspired by UCIData.jl: https://github.com/JackDunnNZ/UCIData.jl
=#

const DATA_DIR = joinpath(@__DIR__, "data")

"""
`list_datasets()`

List available datasets in MVDA.
"""
list_datasets() = map(x -> splitext(x)[1], readdir(DATA_DIR))

function __init__()
    for dataset in list_datasets()
        include(joinpath(DATA_DIR, dataset * ".jl"))
    end
end

"""
`dataset(str)`

Load a dataset named `str`, if available. Returns data as a `DataFrame` where
the first column contains labels/targets and the remaining columns correspond to
distinct features.
"""
function dataset(str)
    # Locate dataset file.
    dataset_path = @datadep_str str
    file = readdir(dataset_path)
    index = findfirst(x -> occursin("data.", x), file)
    if index isa Int
        dataset_file = joinpath(dataset_path, file[index])
    else # is this unreachable?
        error("Failed to locate a data.* file in $(dataset_path)")
    end
    
    # Read dataset file as a DataFrame.
    df = if splitext(dataset_file)[2] == ".csv"
        CSV.read(dataset_file, DataFrame)
    else # assume .csv.gz
        open(GzipDecompressorStream, dataset_file, "r") do stream
            CSV.read(stream, DataFrame)
        end
    end
    return df
end

"""
Process the dataset located at the given `path`.

This is an extra step to give fine-grain control in generating files with DataDeps.jl.
"""
function process_dataset(path::AbstractString; header=false, missingstrings="", kwargs...)
    input_df = CSV.read(path, DataFrame, header=header, missingstrings=missingstrings)
    process_dataset(input_df; kwargs...)
    rm(path)
end

"""
Final step in processing the given dataset `input_df`.

This standardizes cached files that live in ~/.julia/datadeps so that labels/targets appear in first column
followed by features in the remaining columns.
We also check for uniqueness in features.
"""
function process_dataset(input_df::DataFrame;
    target_index=-1,
    feature_indices=1:0,
    ext=".csv")
    # Build output DataFrame.
    output_df = DataFrame()
    output_df.target = input_df[!, target_index]
    output_df = hcat(output_df, input_df[!, feature_indices], makeunique=true)
    output_cols = [ :target; [Symbol("x", n) for n in eachindex(feature_indices)] ]
    rename!(output_df, output_cols)
    dropmissing!(output_df)
    
    # Write to disk.
    output_path = "data" * ext
    if ext == ".csv"
        CSV.write(output_path, output_df, delim=',', writeheader=true)
    elseif ext == ".csv.gz"
        open(GzipCompressorStream, output_path, "w") do stream
            CSV.write(stream, output_df, delim=",", writeheader=true)
        end
    else
        error("Unknown file extension option '$(ext)'")
    end
end

##### IMPLEMENTATION #####

include("problem.jl")
include("utilities.jl")
include("projections.jl")
include("simulation.jl")

abstract type AbstractMMAlg end

include(joinpath("algorithms", "SD.jl"))
include(joinpath("algorithms", "MMSVD.jl"))
include(joinpath("algorithms", "CyclicVDA.jl"))

const DEFAULT_ANNEALING = geometric_progression
const DEFAULT_CALLBACK = __do_nothing_callback__
const DEFAULT_SCORE_FUNCTION = prediction_error

"""
    fit(algorithm, problem, ??, s; kwargs...)

Solve optimization problem at sparsity level `s` using a deadzone of size `??`.

The solution is obtained via a proximal distance `algorithm` that gradually anneals parameter estimates
toward the target sparsity set.
"""
function fit(algorithm::AbstractMMAlg, problem::MVDAProblem, ??::Real, s::Real; kwargs...)
    extras = __mm_init__(algorithm, problem, nothing) # initialize extra data structures
    MVDA.fit!(algorithm, problem, ??, s, extras, (true,false,); kwargs...)
end

"""
    fit!(algorithm, problem, ??, s, [extras], [update_extras]; kwargs...)

Same as `fit_MVDA(algorithm, problem, ??, s)`, but with preallocated data structures in `extras`.

!!! Note
    The caller should specify whether to update data structures depending on `s` and `??` using `update_extras[1]` and `update_extras[2]`, respectively.

    Convergence is determined based on the rule `dist < dtol || abs(dist - old) < rtol * (1 + old)`, where `dist` is the squared distance and `dtol` and `rtol` are tolerance parameters.

!!! Tip
    The `extras` argument can be constructed using `extras = __mm_init__(algorithm, problem, nothing)`.

# Keyword Arguments

- `nouter`: The number of outer iterations; i.e. the maximum number of `??` values to use in annealing (default=`100`).
- `dtol`: An absolute tolerance parameter for the squared distance (default=`1e-6`).
- `rtol`: A relative tolerance parameter for the squared distance (default=`1e-6`).
- `rho_init`: The initial value for `??` (default=1.0).
- `rho_max`: The maximum value for `??` (default=1e8).
- `rhof`: A function `rhof(??, iter, rho_max)` used to determine the next value for `??` in the annealing sequence. The default multiplies `??` by `1.2`.
- `verbose`: Print convergence information (default=`false`).
- `cb`: A callback function for extending functionality.

See also: [`MVDA.anneal!`](@ref) for additional keyword arguments applied at the annealing step.
"""
function fit!(algorithm::AbstractMMAlg, problem::MVDAProblem, ??::Real, s::Real,
    extras=nothing,
    update_extras::NTuple{2,Bool}=(true,false,);
    nouter::Int=100,
    dtol::Real=1e-6,
    rtol::Real=1e-6,
    rho_init::Real=1.0,
    rho_max::Real=1e8,
    rhof::Function=DEFAULT_ANNEALING,
    verbose::Bool=false,
    cb::Function=DEFAULT_CALLBACK,
    kwargs...)
    # Check for missing data structures.
    if extras isa Nothing
        error("Detected missing data structures for algorithm $(algorithm).")
    end

    # Get problem info and extra data structures.
    @unpack intercept, coeff, coeff_prev, proj = problem
    @unpack projection = extras
    
    # Fix model size(s).
    k = sparsity_to_k(problem, s)

    # Initialize ?? and iteration count.
    ??, iters = rho_init, 0

    # Update data structures due to hyperparameters.
    update_extras[1] && __mm_update_sparsity__(algorithm, problem, ??, ??, k, extras)
    update_extras[2] && __mm_update_rho__(algorithm, problem, ??, ??, k, extras)

    # Check initial values for loss, objective, distance, and norm of gradient.
    apply_projection(projection, problem, k)
    init_result = __evaluate_objective__(problem, ??, ??, extras)
    result = SubproblemResult(0, init_result)
    cb(0, problem, ??, ??, k, result)
    old = sqrt(result.distance)

    for iter in 1:nouter
        # Solve minimization problem for fixed rho.
        verbose && print("\n",iter,"  ?? = ",??)
        result = MVDA.anneal!(algorithm, problem, ??, ??, s, extras, (false,true,); verbose=verbose, cb=cb, kwargs...)

        # Update total iteration count.
        iters += result.iters

        cb(iter, problem, ??, ??, k, result)

        # Check for convergence to constrained solution.
        dist = sqrt(result.distance)
        if dist < dtol || abs(dist - old) < rtol * (1 + old)
            break
        else
          old = dist
        end
                
        # Update according to annealing schedule.
        ?? = ifelse(iter < nouter, rhof(??, iter, rho_max), ??)
    end
    
    # Project solution to the constraint set.
    apply_projection(projection, problem, k)
    loss, obj, dist, gradsq = __evaluate_objective__(problem, ??, ??, extras)

    if verbose
        print("\n\niters = ", iters)
        print("\n?????? max{0, |y???-B???x???|???-??}?? = ", loss)
        print("\nobjective  = ", obj)
        print("\ndistance   = ", sqrt(dist))
        println("\n|gradient| = ", sqrt(gradsq))
    end

    return SubproblemResult(iters, loss, obj, dist, gradsq)
end

"""
    anneal(algorithm, problem, ??, ??, s; kwargs...)

Solve the `??`-penalized optimization problem at sparsity level `s` with deadzone `??`.
"""
function anneal(algorithm::AbstractMMAlg, problem::MVDAProblem, ??::Real, ??::Real, s::Real; kwargs...)
    extras = __mm_init__(algorithm, problem, nothing)
    MVDA.anneal!(algorithm, problem, ??, ??, s, extras, (true,true,); kwargs...)
end

"""
    anneal!(algorithm, problem, ??, ??, s, [extras], [update_extras]; kwargs...)

Same as `anneal(algorithm, problem, ??, ??, s)`, but with preallocated data structures in `extras`.

!!! Note
    The caller should specify whether to update data structures depending on `s` and `??` using `update_extras[1]` and `update_extras[2]`, respectively.

    Convergence is determined based on the rule `gradsq < gtol`, where `gradsq` is squared Euclidean norm of the gradient and `gtol` is a tolerance parameter.

!!! Tip
    The `extras` argument can be constructed using `extras = __mm_init__(algorithm, problem, nothing)`.

# Keyword Arguments

- `ninner`: The maximum number of iterations (default=`10^4`).
- `gtol`: An absoluate tolerance parameter on the squared Euclidean norm of the gradient (default=`1e-6`).
- `nesterov_threshold`: The number of early iterations before applying Nesterov acceleration (default=`10`).
- `verbose`: Print convergence information (default=`false`).
- `cb`: A callback function for extending functionality.
"""
function anneal!(algorithm::AbstractMMAlg, problem::MVDAProblem, ??::Real, ??::Real, s::Real,
    extras=nothing,
    update_extras::NTuple{2,Bool}=(true,true);
    ninner::Int=10^4,
    gtol::Real=1e-6,
    nesterov_threshold::Int=10,
    verbose::Bool=false,
    cb::Function=DEFAULT_CALLBACK,
    kwargs...
    )
    # Check for missing data structures.
    if extras isa Nothing
        error("Detected missing data structures for algorithm $(algorithm).")
    end

    # Get problem info and extra data structures.
    @unpack intercept, coeff, coeff_prev, proj = problem
    @unpack projection = extras

    # Fix model size(s).
    k = sparsity_to_k(problem, s)

    # Update data structures due to hyperparameters.
    update_extras[1] && __mm_update_sparsity__(algorithm, problem, ??, ??, k, extras)
    update_extras[2] && __mm_update_rho__(algorithm, problem, ??, ??, k, extras)

    # Check initial values for loss, objective, distance, and norm of gradient.
    apply_projection(projection, problem, k)
    result = __evaluate_objective__(problem, ??, ??, extras)
    cb(0, problem, ??, ??, k, result)
    old = result.objective

    if sqrt(result.gradient) < gtol
        return SubproblemResult(0, result)
    end

    # Use previous estimates in case of warm start.
    copyto!(coeff.all, coeff_prev.all)

    # Initialize iteration counts.
    iters = 0
    nesterov_iter = 1
    verbose && @printf("\n%-5s\t%-8s\t%-8s\t%-8s\t%-8s", "iter.", "loss", "objective", "distance", "|gradient|")
    for iter in 1:ninner
        iters += 1

        # Apply the algorithm map to minimize the quadratic surrogate.
        __mm_iterate__(algorithm, problem, ??, ??, k, extras)

        # Update loss, objective, distance, and gradient.
        apply_projection(projection, problem, k)
        result = __evaluate_objective__(problem, ??, ??, extras)

        cb(iter, problem, ??, ??, k, result)

        if verbose
            @printf("\n%4d\t%4.3e\t%4.3e\t%4.3e\t%4.3e", iter, result.loss, result.objective, sqrt(result.distance), sqrt(result.gradient))
        end

        # Assess convergence.
        obj = result.objective
        gradsq = sqrt(result.gradient)
        if gradsq < gtol
            break
        elseif iter < ninner
            needs_reset = iter < nesterov_threshold || obj > old
            nesterov_iter = __apply_nesterov__!(coeff.all, coeff_prev.all, nesterov_iter, needs_reset)
            old = obj
        end
    end
    # Save parameter estimates in case of warm start.
    copyto!(coeff_prev.all, coeff.all)

    return SubproblemResult(iters, result)
end

"""
    cv(algorithm, problem, grids; [at], [kwargs...])

Split data in `problem` into cross-validation and a test sets, then run cross-validation over the `grids`.

# Keyword Arguments

- `at`: A value between `0` and `1` indicating the proportion of samples/instances used for cross-validation, with remaining samples used for a test set (default=`0.8`).

See also: [`MVDA.cv(algorithm::AbstractMMAlg, problem::MVDAProblem, grids::Tuple{E,S}, dataset_split::Tuple{Any,Any})`](@ref)
"""
function cv(algorithm::AbstractMMAlg, problem::MVDAProblem, grids::Tuple{E,S}; at::Real=0.8, kwargs...) where {E,S}
    # Split data into cross-validation and test sets.
    @unpack p, Y, X, intercept = problem
    dataset_split = splitobs((Y, view(X, :, 1:p)), at=at, obsdim=1)
    MVDA.cv(algorithm, problem, grids, dataset_split; kwargs...)
end

"""
    cv(algorithm, problem, grids, dataset_split; [kwargs...])

Run k-fold cross-validation over hyperparameters `(??, s)` for deadzone radius and sparsity level, respectively.

The given `problem` should enter with initial model parameters in `problem.coeff.all`.
Hyperparameters are specified in `grids = (??_grid, s_grid)`, and data subsets are given as `dataset_split = (cv_set, test_set)`.

# Keyword Arguments

- `nfolds`: The number of folds to run in cross-validation.
- `scoref`: A function that evaluates a classifier over training, validation, and testing sets (default uses misclassification error).
- `show_progress`: Toggles progress bar.

Additional arguments are propagated to `fit` and `anneal`. See also [`MVDA.fit`](@ref) and [`MVDA.anneal`](@ref).
"""
function cv(algorithm::AbstractMMAlg, problem::MVDAProblem, grids::Tuple{E,S}, dataset_split::Tuple{Any,Any};
    lambda::Real=1e-3,
    maxiter::Int=10^4,
    tol::Real=1e-4,
    nfolds::Int=5,
    scoref::Function=DEFAULT_SCORE_FUNCTION,
    cb::Function=DEFAULT_CALLBACK,
    show_progress::Bool=true,
    kwargs...) where {E,S}
    # Initialize the output.
    cv_set, test_set = dataset_split
    ??_grid, s_grid = grids
    n??, ns = length(??_grid), length(s_grid)
    alloc_score_arrays(a, b, c) = [Matrix{Float64}(undef, a, b) for _ in 1:c]
    result = (;
        train=alloc_score_arrays(ns, n??, nfolds),
        validation=alloc_score_arrays(ns, n??, nfolds),
        test=alloc_score_arrays(ns, n??, nfolds),
        time=alloc_score_arrays(ns, n??, nfolds),
    )

    # Run cross-validation.
    if show_progress
        progress_bar = Progress(nfolds * n?? * ns, 1, "Running CV w/ $(algorithm)... ")
    end

    for (k, fold) in enumerate(kfolds(cv_set, k=nfolds, obsdim=1))
        # Retrieve the training set and validation set.
        # TODO: Does this guarantee copies?
        train_set, validation_set = fold
        train_Y, train_X = getobs(train_set, obsdim=1)
        val_Y, val_X = getobs(validation_set, obsdim=1)
        test_Y, test_X = getobs(test_set, obsdim=1)
        
        # Standardize ALL data based on the training set.
        F = StatsBase.fit(ZScoreTransform, train_X, dims=1)
        has_nan = any(isnan, F.scale) || any(isnan, F.mean)
        has_inf = any(isinf, F.scale) || any(isinf, F.mean)
        has_zero = any(iszero, F.scale)
        if has_nan
            error("Detected NaN in z-score.")
        elseif has_inf
            error("Detected Inf in z-score.")
        elseif has_zero
            for idx in eachindex(F.scale)
                x = F.scale[idx]
                F.scale[idx] = ifelse(iszero(x), one(x), x)
            end
        end

        foreach(X -> StatsBase.transform!(F, X), (train_X, val_X, test_X))
        
        # Create a problem object for the training set.
        train_idx, _ = parentindices(train_set[1])
        train_problem = change_data(problem, train_Y, train_X)
        extras = __mm_init__(algorithm, train_problem, nothing)

        for (j, ??) in enumerate(??_grid)
            # Set initial model parameters.
            set_initial_coefficients!(train_problem, problem, train_idx)
            
            for (i, s) in enumerate(s_grid)
                # Obtain solution as function of (??, s).
                if s != 0.0
                    result.time[k][i,j] = @elapsed MVDA.fit!(algorithm, train_problem, ??, s, extras, (true, false,);
                        cb=cb, kwargs...
                    )
                else# s == 0
                    result.time[k][i,j] = @elapsed MVDA.init!(algorithm, train_problem, ??, lambda, extras;
                        maxiter=maxiter, gtol=tol, nesterov_threshold=0,
                    )
                end
                copyto!(train_problem.coeff.all, train_problem.proj.all)

                # Evaluate the solution.
                r = scoref(train_problem, (train_Y, train_X), (val_Y, val_X), (test_Y, test_X))
                for (arr, val) in zip(result, r)
                    arr[k][i,j] = val
                end

                # Update the progress bar.
                if show_progress
                    spercent = string(round(100*s, digits=6), '%')
                    next!(progress_bar, showvalues=[(:fold, k), (:sparsity, spercent), (:??, ??)])
                end
            end
        end
    end

    return result
end

function cv_estimation(algorithm::AbstractMMAlg, problem::MVDAProblem, grids::Tuple{E,S}; at::Real=0.8, kwargs...) where {E,S}
    # Split data into cross-validation and test sets.
    @unpack p, Y, X, intercept = problem
    dataset_split = splitobs((Y, view(X, :, 1:p)), at=at, obsdim=1)
    MVDA.cv_estimation(algorithm, problem, grids, dataset_split; kwargs...)
end

function cv_estimation(algorithm::AbstractMMAlg, problem::MVDAProblem, grids::Tuple{E,S}, dataset_split::Tuple{Any,Any};
    nreplicates::Int=10,
    show_progress::Bool=true,
    rng::AbstractRNG=StableRNG(1903),
    kwargs...) where {E,S}
    # Retrieve subsets and create index set into cross-validation set.
    cv_set, test_set = dataset_split

    if show_progress
        progress_bar = Progress(nreplicates, 1, "Running CV w/ $(algorithm)... ")
    end

    # Replicate CV procedure several times.
    replicate = NamedTuple[]
    for r in 1:nreplicates
        # Shuffle cross-validation data.
        cv_shuffled = shuffleobs(cv_set, obsdim=1, rng=rng)

        # Run k-fold cross-validation and store results.
        result = MVDA.cv(algorithm, problem, grids, (cv_shuffled, test_set); show_progress=false, kwargs...)
        push!(replicate, result)

        # Update the progress bar.
        if show_progress
            next!(progress_bar, showvalues=[(:replicate, r),])
        end
    end

    return replicate
end

"""
```init!(algorithm, problem, ??, ??, [_extras_]; [maxiter=10^3], [gtol=1e-6], [nesterov_threshold=10], [verbose=false])```

Initialize a `problem` with its `??`-regularized solution.
"""
function init!(algorithm::AbstractMMAlg, problem::MVDAProblem, ??, ??, _extras_=nothing;
    maxiter::Int=10^3,
    gtol::Real=1e-6,
    nesterov_threshold::Int=10,
    verbose::Bool=false,
    )
    # Check for missing data structures.
    extras = __mm_init__(algorithm, problem, _extras_)

    # Get problem info and extra data structures.
    @unpack coeff, coeff_prev, proj = problem

    # Update data structures due to hyperparameters.
    __mm_update_lambda__(algorithm, problem, ??, ??, extras)

    # Initialize coefficients.
    randn!(coeff.all)
    copyto!(coeff_prev.all, coeff.all)

    # Check initial values for loss, objective, distance, and norm of gradient.
    result = __evaluate_reg_objective__(problem, ??, ??, extras)
    old = result.objective

    if sqrt(result.gradient) < gtol
        return SubproblemResult(0, result)
    end

    # Initialize iteration counts.
    iters = 0
    nesterov_iter = 1
    verbose && @printf("\n%-5s\t%-8s\t%-8s\t%-8s", "iter.", "loss", "objective", "|gradient|")
    for iter in 1:maxiter
        iters += 1

        # Apply the algorithm map to minimize the quadratic surrogate.
        __reg_iterate__(algorithm, problem, ??, ??, extras)

        # Update loss, objective, and gradient.
        result = __evaluate_reg_objective__(problem, ??, ??, extras)

        if verbose
            @printf("\n%4d\t%4.3e\t%4.3e\t%4.3e", iter, result.loss, result.objective, sqrt(result.gradient))
        end

        # Assess convergence.
        obj = result.objective
        gradsq = sqrt(result.gradient)
        if gradsq < gtol
            break
        elseif iter < maxiter
            needs_reset = iter < nesterov_threshold || obj > old
            nesterov_iter = __apply_nesterov__!(coeff.all, coeff_prev.all, nesterov_iter, needs_reset)
            old = obj
        end
    end
    # Save parameter estimates in case of warm start.
    copyto!(coeff_prev.all, coeff.all)
    copyto!(proj.all, coeff.all)

    return SubproblemResult(iters, result)
end

# function fit_MVDA(algorithm::CyclicVDA, problem, ??, ??, ?????, ?????;
#         niter::Int=10^3,
#         atol=1e-4,
#     )
#     @unpack Y, X, res, coeff = problem
#     # ?? = 1 / 20
#     # ?? = 1//2 * sqrt(2*c/(c-1))
#     n, p, c = probdims(problem)
#     ????? = n * ?????
#     ????? = n * ?????

#     # initialize residuals
#     mul!(res.main.all, X, coeff.all)
#     axpby!(1.0, Y, -1.0, res.main.all)
#     extras = nothing

#     full_objective, _, _ = fetch_objective(problem, p+1, 1, ??, ??, ?????, ?????)
#     penalty1 = 0.0
#     penalty2 = 0.0
#     for j in 1:p # does not include intercept here
#         ?? = view(problem.coeff.all, j, :)
#         penalty1 = penalty1 + ????? * norm(??, 1)
#         penalty2 = penalty2 + ????? * norm(??, 2)
#     end
#     full_objective = full_objective + penalty2 + penalty1

#     iters = 0
#     for iter in 1:niter
#         iters += 1

#         __mm_iterate__(algorithm, problem, ??, ??, ?????, ?????, extras)
#         loss, _, _ = fetch_objective(problem, p+1, 1, ??, ??, ?????, ?????)
#         penalty1 = 0.0
#         penalty2 = 0.0
#         for j in 1:p # does not include intercept here
#             ?? = view(problem.coeff.all, j, :)
#             penalty1 = penalty1 + ????? * norm(??, 1)
#             penalty2 = penalty2 + ????? * norm(??, 2)
#         end
#         objective = loss + penalty2 + penalty1

#         if objective > full_objective error("Descent failure") end

#         if full_objective - objective < atol break end
#         full_objective = objective
#     end

#     copyto!(problem.proj.all, coeff.all)

#     return full_objective, penalty1, penalty2
# end

export IterationResult, SubproblemResult
export MVDAProblem, SD, MMSVD # CyclicVDA

end
