using CSV, DataFrames, MLDataUtils, KernelFunctions, MVDA, Plots, StableRNGs
using LinearAlgebra, Statistics

BLAS.set_num_threads(8)

add_model_size_guide = function(fig, N)
    # Compute ticks based on maximum model size N.
    if N > 16
        xticks = collect(N .* range(0, 1, length=11))
    else
        xticks = collect(0:N)
    end
    sort!(xticks, rev=true)

    # Register figure inside main subplot and append extra x-axis.
    model_size_guide = plot(yticks=nothing, xticks=xticks, xlim=(0,N), xlabel="Model Size", xflip=true)
    full_figure = plot(fig, model_size_guide, layout=@layout [a{1.0h}; b{1e-8h}])

    return full_figure
end

run = function(dir, example, data, sparse2dense::Bool=false; at::Real=0.8, nfolds::Int=5, kwargs...)
    # Create MVDAProblem instance w/ RBFKernel and construct grids.
    @info "Creating MVDAProblem for $(example)"
    dist = Float64[]
    @views for j in axes(data[2], 1), i in axes(data[2], 1)
        yᵢ, xᵢ = data[1][i], data[2][i, :]
        yⱼ, xⱼ = data[1][j], data[2][j, :]
        if yᵢ != yⱼ
            push!(dist, sqrt(dot(xᵢ, xᵢ) - 2*dot(xᵢ, xⱼ) + dot(xⱼ, xⱼ)))
        end
    end
    σ = 13/10 * median(dist)
    problem = MVDAProblem(data..., intercept=true, kernel=σ*RBFKernel())
    n, p, c = MVDA.probdims(problem)
    n_train = round(Int, n * at * (nfolds-1)/nfolds)
    n_validate = round(Int, n * at * 1/nfolds)
    n_test = round(Int, n * (1-at))
    fill!(problem.coeff.all, 1/(n_train+1))
    ϵ_grid = [MVDA.maximal_deadzone(problem)]
    s_grid = sort!([1-k/n_train for k in n_train:-1:0], rev=sparse2dense)
    grids = (ϵ_grid, s_grid)

    @info "CV split: $(n_train) Train / $(n_validate) Validate / $(n_test) Test"
    data_subsets = (n_train, n_validate, n_test)
    titles = ["$(example) / $(_n) samples / $(p) features / $(c) classes" for _n in data_subsets]
    metrics = (:train, :validation, :test)

    # Collect data for cross-validation replicates.
    rng = StableRNG(1903)
    replicates = MVDA.cv_estimation(MMSVD(), problem, grids;
        at=at,                  # propagate CV / Test split
        nfolds=nfolds,          # propagate number of folds
        rng=rng,                # random number generator for reproducibility
        nouter=10^2,            # outer iterations
        ninner=10^6,            # inner iterations
        gtol=1e-6,              # tolerance on gradient for convergence of inner problem
        dtol=1e-6,              # tolerance on distance for convergence of outer problem
        rtol=0.0,               # use strict distance criteria
        nesterov_threshold=100, # delay on Nesterov acceleration
        show_progress=true,     # display progress over replicates
        kwargs...               # propagate other keywords
    )

    # Write results to disk.
    @info "Writing to disk"
    traversal = sparse2dense ? "S2D" : "D2S"
    partial_filename = joinpath(dir, "$(example)-NL-path=$(traversal)")
    MVDA.save_cv_results(partial_filename*".dat", replicates, grids)

    # Default plot options.
    w, h = default(:size)
    options = (; left_margin=5Plots.mm, size=(1.5*w, 1.5*h),)

    # Summarize CV results over folds + make plot.
    @info "Summarizing over folds"
    cv_results = CSV.read(partial_filename*".dat", DataFrame, header=true)
    cv_paths = MVDA.cv_error(cv_results)
    for (title, metric) in zip(titles, metrics)
        fig = MVDA.plot_cv_paths(cv_paths, metric)
        plot!(fig; title=title, options...)
        fig = add_model_size_guide(fig, n_train)
        savefig(fig, partial_filename*"-replicates=$(metric).png")
    end

    # Construct credible intervals for detailed summary plot.
    @info "Constructing credible intervals"
    cv_intervals = MVDA.credible_intervals(cv_paths)
    for (title, metric) in zip(titles, metrics)
        fig = MVDA.plot_credible_intervals(cv_intervals, metric)
        plot!(fig; title=title, options...)
        fig = add_model_size_guide(fig, n_train)
        savefig(fig, partial_filename*"-summary=$(metric).png")
    end
    println()

    return nothing
end

# Nested Circles
n_cv, n_test = 250, 10^3
nsamples = n_cv + n_test
nclasses = 3
data = MVDA.generate_nested_circle(nsamples, nclasses; p=8//10, rng=StableRNG(1903))
run("/home/alanderos/Desktop/VDA/", "circles", data, false;
    at=n_cv/nsamples,   # CV set / Test set split
    nfolds=5,           # number of folds
    nreplicates=50,     # number of CV replicates
)

# Waveform
n_cv, n_test = 375, 10^3
nsamples = n_cv + n_test
nfeatures = 21
data = MVDA.generate_waveform(nsamples, nfeatures; rng=StableRNG(1903))
run("/home/alanderos/Desktop/VDA/", "waveform", data, false;
    at=n_cv/nsamples,   # CV set / Test set split
    nfolds=5,           # number of folds
    nreplicates=50,     # number of CV replicates
)

# Zoo
df = MVDA.dataset("zoo")
data = (Vector(df[!,1]), Matrix{Float64}(df[!,2:end]))
run("/home/alanderos/Desktop/VDA/", "zoo", data, false;
    at=0.9,             # CV set / Test set split
    nfolds=3,           # number of folds
    nreplicates=50,     # number of CV replicates
)

# Vowel
df = MVDA.dataset("vowel")
data = (Vector(df[!,1]), Matrix{Float64}(df[!,2:end]))
run("/home/alanderos/Desktop/VDA/", "vowel", data, false;
    at=0.533333,        # CV set / Test set split
    nfolds=5,           # number of folds
    nreplicates=50,     # number of CV replicates
)
