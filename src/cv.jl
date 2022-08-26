#
#   ROADMAP
#
#   Priority
#
#   X 1. cv: This function should select an optimal pair (s,λ) for model selection.
#   X 2. cv_deadzone: This function should tune the deadzone parameter, ϵ.
#   X 3. cv_rbfkernel: This function should tune the scaling parameter in RBFKenrel.
#   X 4. cv_pipeline: Runs cv_rbfkernel -> cv_deadzone -> cv in order to tune hyperparameters.
#   X 5. Write a flexible repeated_cv subroutine that composes with any of (1)-(4).
#
#   Useful subroutines
#
#   X 1. Write a flexible CVCallback to help record CV metrics.
#   X 2. Write a function to record data from CV results.
#   X 3. Write a function to deliver a classification report.
#   X 4. Write a function to search for an optimal combination of hyperparameters.
#
#       - X Accuracy
#       - X Confusion matrix (classes)
#       - X Confusion matrix (coefficients, where possible)
#       - X risk, loss, objective + other convergence metrics
#
#   4. X Write a function to save/load a model. 
#
#   Visuals
#
#   1. Plot solution path (replicates)
#   2. Plot solution path (aggregate)
#   3. Plot score and hyperparameter distributions
#

# https://discourse.julialang.org/t/how-to-read-only-the-last-line-of-a-file-txt/68005/10
function read_last(file)
    open(file) do io
        seekend(io)
        seek(io, position(io) - 2)
        while Char(peek(io)) != '\n'
            seek(io, position(io) - 1)
        end
        Base.read(io, Char)
        Base.read(io, String)
    end
end

function get_dataset_split(problem::MVDAProblem, at)
    @unpack X = problem
    L = original_labels(problem)
    cv_set, test_set = splitobs((L, X), at=at, obsdim=1)
    return cv_set, test_set
end

number_of_param_vals(grid::AbstractVector) = length(grid) 
number_of_param_vals(grid::NTuple{N,<:Real}) where N = length(grid)
number_of_param_vals(grids::NTuple) = prod(map(length, grids))

"""
    cv_path(algorithm, problem, grids; [at], [kwargs...])

Split data in `problem` into cross-validation and a test sets, then run CV over the `grids`.

# Keyword Arguments

- `at`: A value between `0` and `1` indicating the proportion of samples/instances used for
  cross-validation, with remaining samples used for a test set (default=`0.8`).
- `nfolds`: The number of folds to run in cross-validation.
- `scoref`: A function that evaluates a classifier over training, validation, and testing sets 
  (default uses misclassification error).
- `show_progress`: Toggles progress bar.
  
  Additional arguments are propagated to `fit!` and `anneal!`. See also [`MVDA.fit`](@ref) and [`MVDA.anneal`](@ref).
"""
function cv_path(algorithm::AbstractMMAlg, problem::MVDAProblem, epsilon::Real, lambda::Real, s_grid::G; at::Real=0.8, kwargs...) where G
    # Split data into cross-validation and test sets.
    data = get_dataset_split(problem, at)
    cv_path(algorithm, problem, epsilon, lambda, s_grid, data; kwargs...)
end

function cv_path(
    algorithm::AbstractMMAlg,
    problem::MVDAProblem,
    epsilon::Real,
    lambda::Real,
    s_grid::G,
    data::D;
    nfolds::Int=5,
    scoref::S=DEFAULT_SCORE_FUNCTION,
    callback::C=DEFAULT_CALLBACK,
    show_progress::Bool=true,
    progress_bar::Progress=Progress(nfolds * length(grids[1]) * length(grids[2]); desc="Running CV w/ $(algorithm)... ", enabled=show_progress),
    data_transform::Type{T}=ZScoreTransform,
    rho_init=DEFAULT_RHO_INIT,
    kwargs...,
    ) where {C,D,G,S,T}
    # Sanity checks.
    if any(x -> x < 0 || x > 1, s_grid)
        error("Values in sparsity grid should be in [0,1].")
    end

    # Get cross-validation and test sets.
    cv_set, test_set = data

    # Initialize the output.
    ns = length(s_grid)
    alloc_score_arrays(a, b) = Array{Float64,2}(undef, a, b)
    result = (;
        train=alloc_score_arrays(ns, nfolds),
        validation=alloc_score_arrays(ns, nfolds),
        test=alloc_score_arrays(ns, nfolds),
        time=alloc_score_arrays(ns, nfolds),
    )

    # Run cross-validation.
    for (k, fold) in enumerate(kfolds(cv_set, k=nfolds, obsdim=1))
        # Retrieve the training set and validation set.
        train_set, validation_set = fold
        train_L, train_X = getobs(train_set, obsdim=1)
        val_L, val_X = getobs(validation_set, obsdim=1)
        test_L, test_X = getobs(test_set, obsdim=1)
        
        # Standardize ALL data based on the training set.
        # Adjustment of transformation is to detect NaNs, Infs, and zeros in transform parameters that will corrupt data, and handle them gracefully if possible.
        F = StatsBase.fit(data_transform, train_X, dims=1)
        __adjust_transform__(F)
        foreach(Base.Fix1(StatsBase.transform!, F), (train_X, val_X, test_X))
        
        # Create a problem object for the training set.
        train_problem = MVDAProblem(train_L, train_X, problem)
        extras = __mm_init__(algorithm, train_problem, nothing)
        param_sets = (train_problem.coeff, train_problem.coeff_prev, train_problem.coeff_proj)
        
        # Set initial model parameters.
        for coeff_nt in param_sets
            foreach(Base.Fix2(fill!, 0), coeff_nt)
        end

        # Set initial value for rho.
        rho = rho_init

        for (i, s) in enumerate(s_grid)
            # Fit model.
            if iszero(s)
                timed_result = @timed MVDA.fit!(
                    algorithm, train_problem, epsilon, lambda, extras; kwargs...
                )
            else
                timed_result = @timed MVDA.fit!(
                    algorithm, train_problem, epsilon, lambda, s, extras; rho_init=rho, kwargs...
                )
            end
            
            hyperparams = (;sparsity=s,)
            indices = (;sparsity=i, fold=k,)
            measured_time = timed_result.time # seconds
            result.time[i,k] = measured_time
            statistics, new_rho = timed_result.value
            callback(statistics, train_problem, hyperparams, indices)

            # Check if we can use new rho value in the next step of the solution path.
            rho = ifelse(new_rho > 0, new_rho, rho)

            # Evaluate the solution.
            r = scoref(train_problem, (train_L, train_X), (val_L, val_X), (test_L, test_X))
            for (arr, val) in zip(result, r) # only touches first three arrays
                arr[i,k] = val
            end

            # Update the progress bar.
            spercent = string(round(100*s, digits=4), '%')
            next!(progress_bar, showvalues=[(:fold, k), (:sparsity, spercent)])
        end
    end

    return result
end

function init_cv_tune_progbar(algorithm, problem, nfolds, grids::Tuple{G1,G2,G3}, show_progress) where {G1,G2,G3}
    #
    if problem.kernel isa Nothing
        nvals = number_of_param_vals((grids[1], grids[2]))
    else # isa Kernel
        nvals = number_of_param_vals(grids)
    end
    Progress(nfolds * nvals; desc="Running CV w/ $(algorithm)... ", enabled=show_progress)
end

function cv_tune(algorithm::AbstractMMAlg, problem::MVDAProblem, grids::G; at::Real=0.8, kwargs...) where G
    # Split data into cross-validation and test sets.
    data = get_dataset_split(problem, at)
    cv_tune(algorithm, problem, grids, data; kwargs...)
end

function cv_tune(algorithm::AbstractMMAlg, problem::MVDAProblem, grids::G, data::D;
    nfolds::Int=5,
    scoref::S=DEFAULT_SCORE_FUNCTION,
    callback::C=DEFAULT_CALLBACK,
    show_progress::Bool=true,
    progress_bar::Progress=init_cv_tune_progbar(algorithm, problem, nfolds, grids, show_progress),
    data_transform::Type{T}=ZScoreTransform,
    kwargs...,
    ) where {C,D,G,S,T}
    #
    e_grid, l_grid, g_grid = grids
    # Sanity checks.
    if any(x -> x < 0 || x > 1, e_grid)
        error("Deadzone values should lie in [0,1].")
    end
    if any(<=(0), l_grid)
        error("Lambda values must be positive.")
    end
    if any(<(0), g_grid)
        error("Gamma values must be nonnegative.")
    end

    # Get cross-validation and test sets.
    cv_set, test_set = data

    # Initialize the output.
    if problem.kernel isa Nothing
        dims = (length(e_grid), length(l_grid), 1, nfolds)
    else # isa Kernel
        dims = (length(e_grid), length(l_grid), length(g_grid), nfolds)
    end
    alloc_score_arrays(dims) = Array{Float64,4}(undef, dims)
    result = (;
        train=alloc_score_arrays(dims),
        validation=alloc_score_arrays(dims),
        test=alloc_score_arrays(dims),
        time=alloc_score_arrays(dims),
    )

    # Run cross-validation.
    for (k, fold) in enumerate(kfolds(cv_set, k=nfolds, obsdim=1))
        # Retrieve the training set and validation set.
        train_set, validation_set = fold
        train_L, train_X = getobs(train_set, obsdim=1)
        val_L, val_X = getobs(validation_set, obsdim=1)
        test_L, test_X = getobs(test_set, obsdim=1)
        
        # Standardize ALL data based on the training set.
        # Adjustment of transformation is to detect NaNs, Infs, and zeros in transform parameters that will corrupt data, and handle them gracefully if possible.
        F = StatsBase.fit(data_transform, train_X, dims=1)
        __adjust_transform__(F)
        foreach(Base.Fix1(StatsBase.transform!, F), (train_X, val_X, test_X))
        
        fit_args = (algorithm, problem, scoref, kwargs)
        data_subsets = (train_L, train_X), (val_L, val_X), (test_L, test_X)
        mutables = (result, callback, progress_bar)
        __cv_tune_loop__(problem.kernel, fit_args, grids, data_subsets, mutables, k)
    end

    return result
end

function __cv_tune_loop__(::Kernel, fit_args::T1, grids::T2, data_subsets::T3, mutables::T4, k::Integer) where {T1,T2,T3,T4}
    #
    (algorithm, problem, scoref, kwargs) = fit_args
    (e_grid, l_grid, g_grid) = grids
    (train_L, train_X), (val_L, val_X), (test_L, test_X) = data_subsets
    (result, callback, progress_bar) = mutables

    for (l, gamma) in enumerate(g_grid)
        # Create a problem object for the training set.
        new_kernel = ScaledKernel(problem.kernel, gamma)
        train_problem = MVDAProblem(train_L, train_X, problem, new_kernel)
        extras = __mm_init__(algorithm, train_problem, nothing)
        param_sets = (train_problem.coeff, train_problem.coeff_prev, train_problem.coeff_proj)

        # Set initial model parameters.
        for coeff_nt in param_sets
            foreach(Base.Fix2(fill!, 0), coeff_nt)
        end

        for (i, epsilon) in enumerate(e_grid), (j, lambda) in enumerate(l_grid)
            # Fit model.
            timed_result = @timed MVDA.fit!(
                algorithm, train_problem, epsilon, lambda, extras; kwargs...
            )
                
            hyperparams = (;epsilon=epsilon, lambda=lambda, gamma=gamma)
            indices = (;epsilon=i, lambda=j, gamma=l, fold=k,)
            measured_time = timed_result.time # seconds
            result.time[i,j,l,k] = measured_time
            statistics, _ = timed_result.value
            callback(statistics, train_problem, hyperparams, indices)

            # Evaluate the solution.
            r = scoref(train_problem, (train_L, train_X), (val_L, val_X), (test_L, test_X))
            for (arr, val) in zip(result, r) # only touches first three arrays
                arr[i,j,l,k] = val
            end

            # Update the progress bar.
            next!(progress_bar, showvalues=[(:fold, k), (:epsilon, epsilon), (:lambda, lambda), (:gamma, gamma)])
        end
    end
end

function __cv_tune_loop__(::Nothing, fit_args::T1, grids::T2, data_subsets::T3, mutables::T4, k::Integer) where {T1,T2,T3,T4}
    #
    algorithm, problem, scoref, kwargs = fit_args
    e_grid, l_grid, _ = grids
    (train_L, train_X), (val_L, val_X), (test_L, test_X) = data_subsets
    result, callback, progress_bar = mutables

    # Create a problem object for the training set.
    train_problem = MVDAProblem(train_L, train_X, problem)
    extras = __mm_init__(algorithm, train_problem, nothing)
    param_sets = (train_problem.coeff, train_problem.coeff_prev, train_problem.coeff_proj)

    gamma = 0.0
    l = 1

    # Set initial model parameters.
    for coeff_nt in param_sets
        foreach(Base.Fix2(fill!, 0), coeff_nt)
    end

    for (i, epsilon) in enumerate(e_grid), (j, lambda) in enumerate(l_grid)
        # Fit model.
        timed_result = @timed MVDA.fit!(
            algorithm, train_problem, epsilon, lambda, extras; kwargs...
        )
            
        hyperparams = (;epsilon=epsilon, lambda=lambda, gamma=gamma)
        indices = (;epsilon=i, lambda=j, gamma=l, fold=k,)
        measured_time = timed_result.time # seconds
        result.time[i,j,l,k] = measured_time
        statistics, _ = timed_result.value
        callback(statistics, train_problem, hyperparams, indices)

        # Evaluate the solution.
        r = scoref(train_problem, (train_L, train_X), (val_L, val_X), (test_L, test_X))
        for (arr, val) in zip(result, r) # only touches first three arrays
            arr[i,j,l,k] = val
        end

        # Update the progress bar.
        next!(progress_bar, showvalues=[(:fold, k), (:epsilon, epsilon), (:lambda, lambda), (:gamma, gamma)])
    end
end

function repeated_cv(f::Function, algorithm::AbstractMMAlg, problem::MVDAProblem, grids::T, args...;
    at::Real=0.8,
    nfolds::Int=5,
    nreplicates::Int=10,
    show_progress::Bool=true,
    rng::RNG=StableRNG(1903),
    callback::C=DEFAULT_CALLBACK,
    filename::String=joinpath(pwd(), "cv-results.out"),
    title::String="Example",
    overwrite::Bool=false,
    kwargs...) where {C,RNG,T}
    # Split data into cross-validation and test sets.
    cv_set, test_set = get_dataset_split(problem, at)
    
    nvals = number_of_param_vals(grids)
    progress_bar = Progress(nreplicates * nfolds * nvals; desc="Repeated CV... ", enabled=show_progress)

    # Replicate CV procedure several times.

    # Shuffle cross-validation data.
    cv_shuffled = shuffleobs(cv_set, obsdim=1, rng=rng)

    # Run k-fold cross-validation and store results.
    result = f(algorithm, problem, args..., grids, (cv_shuffled, test_set);
        nfolds=nfolds,
        show_progress=show_progress,
        progress_bar=progress_bar,
        callback=callback,
        kwargs...,
    )

    save_cv_results(f, filename, title, algorithm, grids, result; overwrite=overwrite)

    for _ in 2:nreplicates
        # Shuffle cross-validation data.
        cv_shuffled = shuffleobs(cv_set, obsdim=1, rng=rng)

        # Run k-fold cross-validation and store results.
        result = f(algorithm, problem, args..., grids, (cv_shuffled, test_set);
            nfolds=nfolds,
            show_progress=show_progress,
            progress_bar=progress_bar,
            callback=callback,
            kwargs...,
        )

        save_cv_results(f, filename, title, algorithm, grids, result; overwrite=false)
    end

    @info "Saved CV results to disk" title=title file=filename overwrite=overwrite

    return nothing
end

function save_cv_results(::typeof(cv_path),
        filename::String,
        title::String,
        algorithm::AbstractMMAlg,
        grid::G,
        result::NT;
        overwrite=false,
    ) where {G,NT}
    #
    header = ("title", "algorithm", "replicate", "fold", "sparsity", "time", "train", "validation", "test")
    delim = ','
    if overwrite || !isfile(filename)
        open(filename, "w") do io
            write(io, join(header, delim), '\n')
        end
        replicate = 1
    else
        line = read_last(filename)
        value = split(line, delim)[3]
        replicate = parse(Int, value) + 1
    end
    alg = string(typeof(algorithm))
    open(filename, "a") do io
        is, ks = axes(result.time)
        for k in ks, i in is
            cv_data = (title, alg, replicate, k, grid[i],
                result.time[i,k],
                result.train[i,k],
                result.validation[i,k],
                result.test[i,k],
            )
            write(io, join(cv_data, delim), '\n')
        end
        flush(io)
    end

    return nothing
end

function save_cv_results(::typeof(cv_tune),
        filename::String,
        title::String,
        algorithm::AbstractMMAlg,
        grids::G,
        result::NT;
        overwrite=false,
    ) where {G,NT}
    #
    e_grid, l_grid, g_grid = grids
    #
    header = ("title", "algorithm", "replicate", "fold", "epsilon", "lambda", "gamma", "time", "train", "validation", "test")
    delim = ','
    if overwrite || !isfile(filename)
        open(filename, "w") do io
            write(io, join(header, delim), '\n')
        end
        replicate = 1
    else
        line = read_last(filename)
        value = split(line, delim)[3]
        replicate = parse(Int, value) + 1
    end
    alg = string(typeof(algorithm))

    open(filename, "a") do io
        is, js, ls, ks = axes(result.time)
        for k in ks, l in ls, j in js, i in is
            cv_data = (title, alg, replicate, k, e_grid[i], l_grid[j], g_grid[l],
                result.time[i,j,l,k],
                result.train[i,j,l,k],
                result.validation[i,j,l,k],
                result.test[i,j,l,k],
            )
            write(io, join(cv_data, delim), '\n')
        end
        flush(io)
    end

    return nothing
end

function search_hyperparameters(grids::Tuple{G1,G2,G3}, result::NamedTuple;
    by::Symbol=:validation,
    minimize::Bool=false,
    is_average::Bool=false,
) where {G1,G2,G3}
    # Extract score data.
    if is_average
        data = getindex(result, by)
    else
        avg_scores = mean(getindex(result, by), dims=4)
        data = dropdims(avg_scores, dims=4)
    end

    # Sanity checks.
    e_grid, l_grid, g_grid = grids
    ne, nl, ng = length(e_grid), length(l_grid), length(g_grid)
    if size(data) != (ne, nl, ng)
        error("Data in NamedTuple is incompatible with ($ne,$nl,$ng) grid.")
    end

    if minimize
        (best_i, best_j, best_l), best_quad = (0, 0, 0,), (Inf, Inf, Inf, Inf)
    else
        (best_i, best_j, best_l), best_quad = (0, 0, 0,), (-Inf, -Inf, -Inf, -Inf)
    end

    epsilons, lambdas, gammas = enumerate(e_grid), enumerate(l_grid), enumerate(g_grid)
    for (l, gamma) in gammas, (j, lambda) in lambdas, (i, epsilon) in epsilons
        quad_score = data[i,j,l]
        proposal = (quad_score, epsilon, lambda, gamma)

        # Check if this is the best pair. Rank by pair_score -> sparsity -> lambda.
        if minimize
            #
            #   quad_score: We want to minimize the CV score; e.g. minimum prediction error.
            #
            t = (quad_score, 1/epsilon, 1/lambda, gamma)
            r = (best_quad[1], 1/best_quad[2], 1/best_quad[3], best_quad[4])
            if t < r
                (best_i, best_j, best_l,), best_quad = (i, j, l,), proposal
            end
        else
            #
            #   quad_score: We want to maximize the CV score; e.g. maximum prediction accuracy.
            #
            t = (quad_score, epsilon, lambda, 1/gamma)
            r = (best_quad[1], best_quad[2], best_quad[3], 1/best_quad[4])
            if t > r
                (best_i, best_j, best_l,), best_quad = (i, j, l,), proposal
            end
        end
    end

    return ((best_i, best_j, best_l,), best_quad)
end

function search_hyperparameters(grids::Tuple{G1,G2}, result::NamedTuple;
    by::Symbol=:validation,
    minimize::Bool=false,
    is_average::Bool=false,
) where {G1,G2}
    # Extract score data.
    if is_average
        data = getindex(result, by)
    else
        avg_scores = mean(getindex(result, by), dims=3)
        data = dropdims(avg_scores, dims=3)
    end

    # Sanity checks.
    s_grid, l_grid = grids
    ns, nl = length(s_grid), length(l_grid)
    if size(data) != (ns, nl)
        error("Data in NamedTuple is incompatible with ($ns,$nl) grid.")
    end

    if minimize
        best_i, best_j, best_triple = 0, 0, (Inf, Inf, Inf)
    else
        best_i, best_j, best_triple = 0, 0, (-Inf, -Inf, -Inf)
    end

    for (j, lambda) in enumerate(l_grid), (i, sparsity) in enumerate(s_grid)
        pair_score = data[i,j]

        # Check if this is the best pair. Rank by pair_score -> sparsity -> lambda.
        if minimize
            #
            #   pair_score: We want to minimize the CV score; e.g. minimum prediction error.
            #   1-sparsity: higher sparsity => smaller model
            #   1/lambda: larger lambda => wider margin
            #
            proposal = (pair_score, 1-sparsity, 1/lambda)
            if proposal < best_triple
                best_i, best_j, best_triple = i, j, proposal
            end
        else
            #
            #   pair_score: We want to maximize the CV score; e.g. maximum prediction accuracy.
            #   sparsity: higher sparsity => smaller model
            #   lambda: larger lambda => wider margin
            #
            proposal = (pair_score, sparsity, lambda)
            if proposal > best_triple
                best_i, best_j, best_triple = i, j, proposal
            end
        end
    end

    return ((best_i, best_j,), best_triple)
end

function search_hyperparameters(grid::AbstractVector, result::NamedTuple;
    by::Symbol=:validation,
    minimize::Bool=false,
    is_average::Bool=false,
)
    # Extract score data.
    if is_average
        data = getindex(result, by)
    else
        avg_scores = mean(getindex(result, by), dims=2)
        data = dropdims(avg_scores, dims=2)
    end

    # Sanity checks.
    if size(data) != size(grid)
        error("Data in NamedTuple is incompatible with ($(length(grid)) × 1) grid.")
    end

    if minimize
        best_i, best_pair = 0, (Inf, Inf)
    else
        best_i, best_pair = 0, (-Inf, -Inf)
    end

    for (i, v) in enumerate(grid)
        score = data[i]

        # Check if this is the best value. Rank by score -> hyperparameter value.
        if minimize
            proposal = (score, v)
            if proposal < best_pair
                best_i, best_pair = i, proposal
            end
        else
            proposal = (score, v)
            if proposal > best_pair
                best_i, best_pair = i, proposal
            end
        end
    end

    return (best_i, best_pair)
end

function cv_pipeline(algorithm::AbstractMMAlg, input_problem::MVDAProblem;
    e_grid::G1=[maximum_deadzone(input_problem)],
    g_grid::G2=[1.0],
    s_grid::G3=[0.0],
    l_grid::G4=[1.0],
    nreplicates::Int=10,
    by::Symbol=:validation,
    minimize::Bool=false,
    dir::String,
    title::String,
    overwrite=false,
    kwargs...
) where {G1,G2,G3,G4}
    # Extract data from input problem. This will be used to remake the problem, if needed.
    L, X = original_labels(input_problem), input_problem.X

    # Filenames
    fname_tune = joinpath(dir, "cv-tune.out")
    fname_result = joinpath(dir, "cv-result.out")
    fname_hyperparams = joinpath(dir, "hyperparameters.out")

    # Tune epsilon, lambda, and gamma jointly.
    grids = (e_grid, l_grid, g_grid)
    tune_result = cv_tune(algorithm, input_problem, grids; kwargs...)
    (_, (score, epsilon, lambda, gamma)) = search_hyperparameters(grids, tune_result, by=by, minimize=minimize)
    save_cv_results(cv_tune, fname_tune, title, algorithm, grids, tune_result; overwrite=overwrite)

    if input_problem.kernel isa Kernel
        new_kernel = ScaledKernel(input_problem.kernel, gamma)
        problem = MVDAProblem(L, X, input_problem, new_kernel)
    else
        problem = input_problem
        gamma = zero(gamma)
    end
    @info "Finished tuning hyperparameters." filename=fname_tune score epsilon lambda gamma

    save_hyperparameters(fname_hyperparams, (epsilon, lambda, gamma))
    @info "Saved tuned hyperparameters" filename=fname_hyperparams epsilon lambda gamma

    # Run model selection while tuning the penalty coefficient, lambda.
    repeated_cv(cv_path, algorithm, problem, s_grid, epsilon, lambda;
        nreplicates=nreplicates,
        filename=fname_result,
        title=title,
        overwrite=overwrite,
        kwargs...
    )

    return nothing
end

function save_hyperparameters(filename, (epsilon, lambda, gamma))
    open(filename, "w") do io
        write(io, "epsilon=", string(epsilon), '\n')
        write(io, "lambda=", string(lambda), '\n')
        write(io, "gamma=", string(gamma), '\n')
    end
    return nothing
end

function load_hyperparameters(filename)
    epsilon, lambda, gamma = NaN, NaN, NaN
    open(filename, "r") do io
        epsilon = parse(Float64, last(split(readline(io), '=')))::Float64
        lambda = parse(Float64, last(split(readline(io), '=')))::Float64
        gamma = parse(Float64, last(split(readline(io), '=')))::Float64
    end
    return epsilon, lambda, gamma
end

# function cv_error(df::DataFrame)
#     # Group replicates based on hyperparameter pairs (ϵ, s).
#     gdf = groupby(df, [:replicate, :epsilon, :sparsity])

#     # Aggregate over folds.
#     f(a,b,c,d) = (time=sum(a), train=mean(b), validation=mean(c), test=mean(d))
#     out = combine(gdf, [:time, :train, :validation, :test] => f => AsTable)

#     return out
# end

# function plot_cv_paths(df::DataFrame, col::Symbol)
#     # Group by replicate and initialize figure based on selected column.
#     gdf = groupby(df, :replicate)
#     n = length(gdf)
#     fig = plot(
#         xlabel="Sparsity (%)",
#         ylabel=col == :time ? "Time (s)" : "Error (%)",
#         ylim=col == :time ? nothing : (-1,101),
#         xlim=(-1,101),
#         xticks=0:10:100,
#         yticks=col == :time ? nothing : 0:10:100,
#     )

#     # Plot paths from each replicate.
#     foreach(path -> plot!(path[!,:sparsity], path[!,col], lw=3, color=:black, alpha=1/n, label=nothing), gdf)

#     # Highlight the mean and median paths.
#     f(a) = (; median=median(a), mean=mean(a))
#     tmp = combine(groupby(df, [:epsilon, :sparsity]), [col] => f => AsTable)
#     plot!(tmp.sparsity, tmp.mean, lw=3, color=:red, ls=:dash, label=nothing)   # mean
#     plot!(tmp.sparsity, tmp.median, lw=3, color=:blue, ls=:dot, label=nothing) # median
    
#     return fig
# end

# """
# Returns the row index `j` corresponding to the optimal model.

# The input `df` must contain cross-validation errors (see [`MVDA.cv_error`](@ref)).
# Optimality is determined by the following:

# - Robustness: maximal deadzone radius, `epsilon`.
# - Parsimony: maximal `sparsity`.
# - Predictive: minimal classification error in `validation`.
# """
# function optimal_model(df::AbstractDataFrame)
#     itr = zip(df.validation, df.sparsity, df.epsilon)
#     adjusted_score = [(error, 100-s, 1/ϵ) for (error, s, ϵ) in itr]
#     j = argmin(adjusted_score)
# end

# function credible_intervals(df::DataFrame, credibility=19/20)
#     # Identify the optimal point in each replicate.
#     gdf = groupby(df, :replicate)
#     s_opt = zeros(length(gdf))
#     for (r, replicate) in enumerate(gdf)
#         j = optimal_model(replicate)
#         s_opt[r] = replicate.sparsity[j]
#     end

#     # Compute parameter for equal-tailed interval and define functions to aggregate along path.
#     α = (1 - credibility) / 2
#     estimate_interval(data, _α) = median(data), quantile(data, _α), quantile(data, 1-_α)
#     f = function (a, b, c, d)
#         time_md, time_lo, time_hi = estimate_interval(a, α)
#         train_md, train_lo, train_hi = estimate_interval(b, α)
#         validation_md, validation_lo, validation_hi = estimate_interval(c, α)
#         test_md, test_lo, test_hi = estimate_interval(d, α)
#         return (;
#             time_md=time_md, time_lo=time_lo, time_hi=time_hi,
#             train_md=train_md, train_lo=train_lo, train_hi=train_hi,
#             validation_md=validation_md, validation_lo=validation_lo, validation_hi=validation_hi,
#             test_md=test_md, test_lo=test_lo, test_hi=test_hi,
#         )
#     end

#     # Group by hyperparameter pairs (ϵ, s) and aggregate over replicates.
#     out = combine(groupby(df, [:epsilon, :sparsity]), [:time, :train, :validation, :test] => f => AsTable)

#     # Add optimal point credible interval to DataFrame.
#     model_md, model_lo, model_hi = estimate_interval(s_opt, α)
#     out[!, :model_md] .= model_md
#     out[!, :model_lo] .= model_lo
#     out[!, :model_hi] .= model_hi

#     return out
# end

# function plot_credible_intervals(df::DataFrame, col::Symbol)
#     # Plot the credible interval for the selected metric.
#     ys, lo, hi = df[!,Symbol(col, :_md)], df[!,Symbol(col, :_lo)], df[!,Symbol(col, :_hi)]
#     xs = df.sparsity
#     lower, upper = ys - lo, hi - ys

#     fig = plot(
#         xlabel="Sparsity (%)",
#         ylabel=col == :time ? "Time (s)" : "Error (%)",
#         ylim=col == :time ? nothing : (-1,101),
#         xlim=(-1,101),
#         xticks=0:10:100,
#     )

#     # Add a point highlighting the optimal point + its credible interval.
#     s_opt, s_lo, s_hi = df[1, [:model_md, :model_lo, :model_hi]]
#     j = findlast(≤(s_opt), xs)
#     error_bars = [(s_opt - s_lo, s_hi - s_opt)]
#     scatter!((s_opt, ys[j]), xerr=error_bars, color=:black, markersize=6, markerstrokewidth=3, label="optimal model")

#     annotate!([ (0.0, 90.0, ("Sparsity: $(round(s_opt, digits=4))%", 10, :left)) ])
#     annotate!([ (0.0, 80.0, ("Error: $(round(ys[j], digits=4))%", 10, :left)) ])

#     plot!(xs, ys, lw=3, ribbon=(lower, upper), label="95% credible interval", ls=:dash)

#     return fig
# end
