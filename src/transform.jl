"""
Normalization (unit norm transformation)
"""
struct NormalizationTransform{T<:Real} <: StatsBase.AbstractDataTransform
    len::Int
    dims::Int
    norms::Vector{T}

    function NormalizationTransform(l::Int, dims::Int, n::Vector{T}) where T
        len = length(n)
        len == l || len == 0 || throw(DimensionMismatch("Inconsistent dimensions."))
        new{T}(l, dims, n)
    end
end

function Base.getproperty(t::NormalizationTransform, p::Symbol)
    if p === :indim || p === :outdim
        return t.len
    else
        return getfield(t, p)
    end
end

"""
    fit(NormalizationTransform, X; dims=nothing, center=true, scale=true)
"""
function StatsBase.fit(::Type{NormalizationTransform}, X::AbstractMatrix{<:Real};
        dims::Union{Integer,Nothing}=nothing)
    if dims === nothing
        Base.depwarn("fit(t, x) is deprecated: use fit(t, x, dims=2) instead", :fit)
        dims = 2
    end
    if dims == 1
        n, l = size(X)
        n >= 1 || error("X must contain at least one row.")
        norms = [norm(xi) for xi in eachcol(X)]
    elseif dims == 2
        l, n = size(X)
        n >= 1 || error("X must contain at least one column.")
        norms = [norm(xi) for xi in eachrow(X)]
    else
        throw(DomainError(dims, "fit only accept dims to be 1 or 2."))
    end
    T = eltype(X)
    return NormalizationTransform(l, dims, vec(norms))
end

function StatsBase.fit(::Type{NormalizationTransform}, X::AbstractVector{<:Real};
        dims::Integer=1)
    if dims != 1
        throw(DomainError(dims, "fit only accepts dims=1 over a vector. Try fit(t, x, dims=1)."))
    end

    T = eltype(X)
    norms = [norm(X)]
    return NormalizationTransform(1, dims, norms)
end

function StatsBase.transform!(y::AbstractMatrix{<:Real}, t::NormalizationTransform, x::AbstractMatrix{<:Real})
    if t.dims == 1
        l = t.len
        size(x,2) == size(y,2) == l || throw(DimensionMismatch("Inconsistent dimensions."))
        n = size(y,1)
        size(x,1) == n || throw(DimensionMismatch("Inconsistent dimensions."))

        norms = t.norms

        if isempty(norms)
            copyto!(y, x)
        else
            broadcast!(/, y, x, norms')
        end
    elseif t.dims == 2
        t_ = NormalizationTransform(t.len, 1, t.norms)
        transform!(y', t_, x')
    end
    return y
end

function StatsBase.reconstruct!(x::AbstractMatrix{<:Real}, t::NormalizationTransform, y::AbstractMatrix{<:Real})
    if t.dims == 1
        l = t.len
        size(x,2) == size(y,2) == l || throw(DimensionMismatch("Inconsistent dimensions."))
        n = size(y,1)
        size(x,1) == n || throw(DimensionMismatch("Inconsistent dimensions."))

        norms = t.norms

        if isempty(norms)
            copyto!(x, y)
        else
            broadcast!(*, x, y, norms')
        end
    elseif t.dims == 2
        t_ = NormalizationTransform(t.len, 1, t.norms)
        reconstruct!(x', t_, y')
    end
    return x
end

"""
NoTransformation
"""
struct NoTransformation{T<:Real} <: StatsBase.AbstractDataTransform end

"""
    fit(NoTransformation, X; dims=nothing)
"""
function StatsBase.fit(::Type{NoTransformation}, X::AbstractMatrix{<:Real};
        dims::Union{Integer,Nothing}=nothing)
    if dims === nothing
        Base.depwarn("fit(t, x) is deprecated: use fit(t, x, dims=2) instead", :fit)
    end
    T = eltype(X)
    return NoTransformation{T}()
end

function StatsBase.fit(::Type{NoTransformation}, X::AbstractVector{<:Real};
        dims::Integer=1)
    if dims != 1
        throw(DomainError(dims, "fit only accepts dims=1 over a vector. Try fit(t, x, dims=1)."))
    end
    T = eltype(X)
    return NoTransformation{T}()
end

function StatsBase.transform!(y::AbstractMatrix{<:Real}, t::NoTransformation, x::AbstractMatrix{<:Real})
    copyto!(y, x)
    return y
end

function StatsBase.reconstruct!(x::AbstractMatrix{<:Real}, t::NoTransformation, y::AbstractMatrix{<:Real})
    copyto!(x, y)
    return x
end

##### adjusting the transform object #####

function __adjust_transform__(F::ZScoreTransform)
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
    return F
end

function __adjust_transform__(F::NormalizationTransform)
    has_nan = any(isnan, F.norms)
    has_inf = any(isinf, F.norms)
    has_zero = any(iszero, F.norms)
    if has_nan
        error("Detected NaN in norms.")
    elseif has_inf
        error("Detected Inf in norms.")
    elseif has_zero
        for idx in eachindex(F.norms)
            x = F.norms[idx]
            F.norms[idx] = ifelse(iszero(x), one(x), x)
        end
    end
    return F
end

__adjust_transform__(F::NoTransformation) = F
