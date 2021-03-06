using CSV, DataFrames, MLDataUtils, KernelFunctions, MVDA, StableRNGs
using LinearAlgebra, Statistics

# using MKL
BLAS.set_num_threads(8)

run = function(dir, example, data, sparse2dense::Bool=false; at::Real=0.8, nfolds::Int=5, kwargs...)
    # Create MVDAProblem instance w/o kernel and construct grids.
    @info "Creating MVDAProblem for $(example)"
    problem = MVDAProblem(data..., intercept=true, kernel=nothing)
    n, p, c = MVDA.probdims(problem)
    n_train = round(Int, n * at * (nfolds-1)/nfolds)
    n_validate = round(Int, n * at * 1/nfolds)
    n_test = round(Int, n * (1-at))
    fill!(problem.coeff.all, 1/(p+1))
    fill!(problem.coeff_prev.all, 1/(p+1))
    ϵ_grid = [MVDA.maximal_deadzone(problem)]
    s_grid = sort!([1-k/p for k in p:-1:0], rev=sparse2dense)
    grids = (ϵ_grid, s_grid)

    # Collect data for cross-validation replicates.
    @info "CV split: $(n_train) Train / $(n_validate) Validate / $(n_test) Test"
    subsets = (n_train, n_validate, n_test)
    rng = StableRNG(1903)
    replicates = MVDA.cv_estimation(MMSVD(), problem, grids;
        at=at,                  # propagate CV / Test split
        nfolds=nfolds,          # propagate number of folds
        rng=rng,                # random number generator for reproducibility
        nouter=10^2,            # outer iterations
        ninner=10^6,            # inner iterations
        gtol=1e-3,              # tolerance on gradient for convergence of inner problem
        dtol=1e-3,              # tolerance on distance for convergence of outer problem
        rtol=0.0,               # use strict distance criteria
        lambda=1e-3,            # regularization level
        tol=1e-6,               # convergence tolerance in initialization
        maxiter=10^4,           # maximum iterations in initialization
        nesterov_threshold=100, # delay on Nesterov acceleration
        show_progress=true,     # display progress over replicates
        kwargs...               # propagate other keywords
    )

    # Write results to disk.
    @info "Writing to disk"
    traversal = sparse2dense ? "S2D" : "D2S"
    filename = joinpath(dir, "$(example)-L-path=$(traversal).dat")
    kernel = "none"
    problem_info = (example, subsets, p, c, sparse2dense, kernel)
    MVDA.save_cv_results(filename, problem_info, replicates, grids)

    return nothing
end

# Examples ordered from easiest to hardest
examples = (
    ("colon", 3, 0.8),
    ("srbctA", 3, 0.8),
    ("leukemiaA", 3, 0.8),
    ("lymphomaA", 3, 0.8),
    ("brain", 3, 0.8),
    ("prostate", 3, 0.8),
)

dir = ARGS[1]
@info "Output directory: $(dir)"

for (example, nfolds, split) in examples
    tmp = CSV.read("/home/alanderos/Desktop/data/$(example).DAT", DataFrame, header=false)
    df = shuffleobs(tmp, rng=StableRNG(1234))
    data = (Vector(df[!,end]), Matrix{Float64}(df[!,1:end-1]))
    run(dir, example, data, false;
        at=split,           # CV set / Test set split
        nfolds=nfolds,      # number of folds
        nreplicates=50,     # number of CV replicates
    )
end
