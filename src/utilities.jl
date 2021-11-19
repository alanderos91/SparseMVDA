"""
Generic template for evaluating residuals.
This assumes that projections have been handled externally.
The following flags control how residuals are evaluated:

+ `need_main`: If `true`, evaluates regression residuals.
+ `need_dist`: If `true`, evaluates difference between parameters and their projection.

**Note**: The values for each flag should be known at compile-time!
"""
function __evaluate_residuals__(problem, ϵ, extras, need_main::Bool, need_dist::Bool, need_z::Bool)
    @unpack Y, coeff, proj, res = problem
    @unpack Z = extras
    T = floattype(problem)
    X = get_design_matrix(problem)

    if need_main
        # main residuals, √(1/n) * (Y - X*B)
        a = 1 / sqrt(size(Y, 1))
        mul!(res.main.all, X, coeff.all)
        need_z && copyto!(Z, res.main.all)
        axpby!(a, Y, -a, res.main.all)

        # weighted residuals, W^1/2 * (Y - X*B)
        for i in axes(Y, 1)
            yᵢ = view(Y, i, :)
            rᵢ = res.main.sample[i]
            wrᵢ = res.weighted.sample[i]
            normrᵢ = norm(rᵢ) / a
            wᵢ = ifelse(normrᵢ ≤ ϵ, zero(T), (normrᵢ-ϵ)/normrᵢ)
            @. wrᵢ = wᵢ * rᵢ
            if need_z
                # zᵢ = X*B if norm(rᵢ) ≤ ϵ
                # zᵢ = wᵢ*yᵢ + (1-wᵢ)*X*B otherwise
                zᵢ = view(Z, i, :)
                axpby!(wᵢ, yᵢ, 1-wᵢ, zᵢ)
            end
        end
    end

    if need_dist
        # res_dist = P(B) - B
        copyto!(res.dist.all, proj.all)
        axpby!(-one(T), coeff.all, one(T), res.dist.all)
    end

    return nothing
end

"""
Evaluate the gradiant of the regression problem. Assumes residuals have been evaluated.
"""
function __evaluate_gradient__(problem, ρ, extras)
    @unpack res, grad = problem
    n, _, _ = probdims(problem)
    X = get_design_matrix(problem)

    for j in eachindex(grad.dim)
        # ∇g_ρ(B ∣ Bₘ)ⱼ = -[aXᵀ bⱼI] * Rₘ,ⱼ
        a = 1 / sqrt(n)
        b = ρ
        mul!(grad.dim[j], X', res.weighted.dim[j])
        axpby!(-b, res.dist.dim[j], -a, grad.dim[j])
    end

    return nothing
end

# function __evaluate_gradient_reg__(problem, λ, extras)
#     @unpack res, grad = problem
#     n, _, _ = probdims(problem)
#     X = get_design_matrix(problem)

#     for j in eachindex(grad.dim)
#         # ∇g_ρ(B ∣ Bₘ)ⱼ = -[aXᵀ λI] * Rₘ,ⱼ
#         a = 1 / sqrt(n)
#         mul!(grad.dim[j], X', res.weighted.dim[j])
#         axpby!(λ, problem.coeff.dim[j], -a, grad.dim[j])
#     end

#     return nothing
# end

"""
Evaluate the penalized least squares criterion. Also updates the gradient.
This assumes that projections have been handled externally.
"""
function __evaluate_objective__(problem, ϵ, ρ, extras)
    @unpack res, grad = problem

    __evaluate_residuals__(problem, ϵ, extras, true, true, false)
    __evaluate_gradient__(problem, ρ, extras)

    loss = norm(res.weighted.all)^2 # 1/n * ∑ᵢ (Zᵢ - Bᵀxᵢ)²
    dist = norm(res.dist.all)^2     # ∑ⱼ (P(B)ⱼ - Bⱼ)²
    obj = 1//2 * (loss + ρ * dist)
    gradsq = norm(grad.all)^2

    return IterationResult(loss, obj, dist, gradsq)
end

# function __evaluate_objective_reg__(problem, ϵ, λ, extras)
#     @unpack res, grad = problem

#     __evaluate_residuals__(problem, ϵ, extras, true, false, false)
#     __evaluate_gradient_reg__(problem, λ, extras)

#     loss = norm(res.weighted.all)^2 # 1/n * ∑ᵢ (Zᵢ - Bᵀxᵢ)²
#     objective = 1//2 * (loss + λ * norm(problem.coeff.all))
#     gradsq = norm(grad.all)^2

#     return IterationResult(loss, objective, 0.0, gradsq)
# end

"""
Apply acceleration to the current iterate `x` based on the previous iterate `y`
according to Nesterov's method with parameter `r=3` (default).
"""
function __apply_nesterov__!(x, y, iter::Integer, needs_reset::Bool, r::Int=3)
    if needs_reset # Reset acceleration scheme
        copyto!(y, x)
        iter = 1
    else # Nesterov acceleration 
        γ = (iter - 1) / (iter + r - 1)
        for i in eachindex(x)
            xi, yi = x[i], y[i]
            zi = xi + γ * (xi - yi)
            x[i], y[i] = zi, xi
        end
        iter += 1
    end

    return iter
end

"""
Map a sparsity level `s` to an integer `k`, assuming `n` elements.
"""
sparsity_to_k(problem::MVDAProblem, s) = __sparsity_to_k__(problem.kernel, problem, s)
__sparsity_to_k__(::Nothing, problem::MVDAProblem, s) = round(Int, (1-s) * problem.p)
__sparsity_to_k__(::Kernel, problem::MVDAProblem, s) = round(Int, (1-s)*problem.n)

get_projection_indices(problem::MVDAProblem) = __get_projection_indices__(problem.kernel, problem)
__get_projection_indices__(::Nothing, problem::MVDAProblem) = 1:problem.p
__get_projection_indices__(::Kernel, problem::MVDAProblem) = 1:problem.n

"""
Apply a projection to model coefficients.
"""
function apply_projection(projection, problem, k)
    idx = get_projection_indices(problem)
    @unpack coeff, proj = problem
    @unpack scores = projection
    copyto!(proj.all, coeff.all)

    # projection step, might not be unique
    if problem.intercept
        projection(view(proj.all, idx, :), k)
    else
        projection(proj.all, k)
    end

    return proj.all
end

"""
Define a geometric progression recursively by the rule
```
    rho_new = min(rho_max, rho * multiplier)
```
The result is guaranteed to have type `typeof(rho)`.
"""
function geometric_progression(rho, iter, rho_max, multiplier::Real=1.2)
    return convert(typeof(rho), min(rho_max, rho * multiplier))
end

"""
Default error message for missing methods. For internal use only.
"""
not_implemented(alg, msg) = error(string(msg, " not implemented for ", alg, "."))

"""
Placeholder for callbacks in main functions.
"""
__do_nothing_callback__(iter, problem, lambda, rho, k, history) = nothing
__do_nothing_callback__(fold, problem, train_problem, data, lambda, sparsity, model_size, result) = nothing

__svd_wrapper__(A::StridedMatrix) = svd(A)
__svd_wrapper__(A::AbstractMatrix) = svd!(copy(A))

function prediction_error(model::MVDAProblem, train_set, validation_set, test_set)
    # Extract number of features to make predictions consistent.
    @unpack p = model

    # Extract data for each set.
    Tr_Y, Tr_X = train_set
    V_Y, V_X = validation_set
    T_Y, T_X = test_set

    Tr_label = map(yᵢ -> model.vertex2label[yᵢ], eachrow(Tr_Y))
    V_label = map(yᵢ -> model.vertex2label[yᵢ], eachrow(V_Y))
    T_label = map(yᵢ -> model.vertex2label[yᵢ], eachrow(T_Y))

    # Make predictions on each subset.
    Tr_call = classify(model, view(Tr_X, :, 1:p))
    V_call = classify(model, view(V_X, :, 1:p))
    T_call = classify(model, view(T_X, :, 1:p))

    # Evaluate errors on each subset.
    Tr = 100 * (1 - sum(Tr_call .== Tr_label) / length(Tr_label))
    V = 100 * (1 - sum(V_call .== V_label) / length(V_label))
    T = 100 * (1 - sum(T_call .== T_label) / length(T_label))

    return (Tr, V, T)
end

struct IterationResult
    loss::Float64
    objective::Float64
    distance::Float64
    gradient::Float64
end

# destructuring
Base.iterate(r::IterationResult) = (r.loss, Val(:objective))
Base.iterate(r::IterationResult, ::Val{:objective}) = (r.objective, Val(:distance))
Base.iterate(r::IterationResult, ::Val{:distance}) = (r.distance, Val(:gradient))
Base.iterate(r::IterationResult, ::Val{:gradient}) = (r.gradient, Val(:done))
Base.iterate(r::IterationResult, ::Val{:done}) = nothing

struct SubproblemResult
    iters::Int
    loss::Float64
    objective::Float64
    distance::Float64
    gradient::Float64
end

function SubproblemResult(iters, r::IterationResult)
    return SubproblemResult(iters, r.loss, r.objective, r.distance, r.gradient)
end

# destructuring
Base.iterate(r::SubproblemResult) = (r.iters, Val(:loss))
Base.iterate(r::SubproblemResult, ::Val{:loss}) = (r.loss, Val(:objective))
Base.iterate(r::SubproblemResult, ::Val{:objective}) = (r.objective, Val(:distance))
Base.iterate(r::SubproblemResult, ::Val{:distance}) = (r.distance, Val(:gradient))
Base.iterate(r::SubproblemResult, ::Val{:gradient}) = (r.gradient, Val(:done))
Base.iterate(r::SubproblemResult, ::Val{:done}) = nothing

function save_cv_results(filename, replicates, grids)
    ϵ_grid, s_grid = grids
    delim = ','
    open(filename, "w+") do io
        writedlm(io, ["replicate" "fold" "epsilon" "sparsity" "time" "train" "validation" "test"], delim)
        for (r, replicate) in enumerate(replicates)
            for k in eachindex(replicate[1]), j in eachindex(ϵ_grid), i in eachindex(s_grid)
                ϵ, s = ϵ_grid[j], 100*s_grid[i]
                Tr, V, T, t = [arr[k][i,j] for arr in replicate]
                writedlm(io, Any[r k ϵ s t Tr V T], delim)
            end
        end
    end
    return nothing
end

function cv_error(df::DataFrame)
    # Group replicates based on hyperparameter pairs (ϵ, s).
    gdf = groupby(df, [:replicate, :epsilon, :sparsity])

    # Aggregate over folds.
    f(a,b,c,d) = (time=sum(a), train=mean(b), validation=mean(c), test=mean(d))
    out = combine(gdf, [:time, :train, :validation, :test] => f => AsTable)

    return out
end

"""
Returns the row index `j` corresponding to the optimal model.

The input `df` must contain cross-validation errors (see [`MVDA.cv_error`](@ref)).
Optimality is determined by the following:

- Robustness: maximal deadzone radius, `epsilon`.
- Parsimony: maximal `sparsity`.
- Predictive: minimal classification error in `validation`.
"""
function optimal_model(df::AbstractDataFrame)
    itr = zip(df.validation, df.sparsity, df.epsilon)
    adjusted_score = [(error, 100-s, 1/ϵ) for (error, s, ϵ) in itr]
    j = argmin(adjusted_score)
end

function cv_credible_intervals(df::DataFrame, credibility=19/20)
    # Identify the optimal point in each replicate.
    gdf = groupby(df, :replicate)
    s_opt = zeros(length(gdf))
    for (r, replicate) in enumerate(gdf)
        j = optimal_model(replicate)
        s_opt[r] = replicate.sparsity[j]
    end

    # Compute parameter for equal-tailed interval and define functions to aggregate along path.
    α = (1 - credibility) / 2
    estimate_interval(data, _α) = median(data), quantile(data, _α), quantile(data, 1-_α)
    f = function (a, b, c, d)
        time_md, time_lo, time_hi = estimate_interval(a, α)
        train_md, train_lo, train_hi = estimate_interval(b, α)
        validation_md, validation_lo, validation_hi = estimate_interval(c, α)
        test_md, test_lo, test_hi = estimate_interval(d, α)
        return (;
            time_md=time_md, time_lo=time_lo, time_hi=time_hi,
            train_md=train_md, train_lo=train_lo, train_hi=train_hi,
            validation_md=validation_md, validation_lo=validation_lo, validation_hi=validation_hi,
            test_md=test_md, test_lo=test_lo, test_hi=test_hi,
        )
    end

    # Group by hyperparameter pairs (ϵ, s) and aggregate over replicates.
    out = combine(groupby(df, [:epsilon, :sparsity]), [:time, :train, :validation, :test] => f => AsTable)

    # Add optimal point credible interval to DataFrame.
    model_md, model_lo, model_hi = estimate_interval(s_opt, α)
    out[!, :model_md] .= model_md
    out[!, :model_lo] .= model_lo
    out[!, :model_hi] .= model_hi

    return out
end

function plot_credible_interval(df::DataFrame, col::Symbol)
    # Plot the credible interval for the selected metric.
    ys, lo, hi = df[!,Symbol(col, :_md)], df[!,Symbol(col, :_lo)], df[!,Symbol(col, :_hi)]
    xs = df.sparsity
    lower, upper = ys - lo, hi - ys

    fig = plot(
        xlabel="Sparsity (%)",
        ylabel=col == :time ? "Time (s)" : "Error (%)",
        ylim=col == :time ? nothing : (-1,101),
        xlim=(-1,101),
        xticks=0:10:100,
    )

    # Add a point highlighting the optimal point + its credible interval.
    s_opt, s_lo, s_hi = df[1, [:model_md, :model_lo, :model_hi]]
    j = findlast(≤(s_opt), xs)
    error_bars = [(s_opt - s_lo, s_hi - s_opt)]
    str = "($(s_opt), $(round(ys[j], digits=4)))"
    scatter!((s_opt, ys[j]), xerr=error_bars, color=:black, markersize=8, markerstrokewidth=3, label="optimal model")
    annotate!([ (s_opt, ys[j]+5, (str, 10, :left)) ])

    plot!(xs, ys, lw=3, ribbon=(lower, upper), label="95% credible interval", ls=:dash)

    return fig
end
