"""
Project `x` onto sparsity set with `k` non-zero elements.
Assumes `idx` enters as a vector of indices into `x`.
"""
function project_l0_ball!(x, idx, k, buffer)
    n = length(x)
    # do nothing if k > length(x)
    if k ≥ n return x end
    
    # fill with zeros if k ≤ 0
    if k ≤ 0 return fill!(x, 0) end
    
    # otherwise, find the spliting element
    search_by_top_k = k < n-k+1
    if search_by_top_k
        _k = k
        pivot = l0_search_partialsort!(idx, x, _k, true)
    else
        _k = n-k+1
        pivot = l0_search_partialsort!(idx, x, _k, false)
    end
    
    # preserve the top k elements
    p = abs(pivot)
    nonzero_count = 0
    @inbounds for i in eachindex(x)
        if x[i] == 0 continue end
        if abs(x[i]) < p
            x[i] = 0
        else
            nonzero_count += 1
        end
    end

    # resolve ties
    if nonzero_count > k
        number_to_drop = nonzero_count - k
        _buffer_ = view(buffer, 1:number_to_drop)
        _indexes_ = findall(!iszero, x)
        sample!(_indexes_, _buffer_, replace=false)
        @inbounds for i in _buffer_
            x[i] = 0
        end
    end

    return x
end

function project_l0_ball!(X::AbstractMatrix, idx, scores, k, buffer; by::Union{Val{:row}, Val{:col}}=Val(:row))
    # determine structure of sparsity
    if by isa Val{:row}
        n = size(X, 1)
        itr = axes(X, 1)
        itr2 = eachrow(X)
        f = i -> norm(view(X, i, :))
    elseif by isa Val{:col}
        n = size(X, 2)
        itr = axes(X, 2)
        itr2 = eachcol(X)
        f = i -> norm(view(X, :, i))
    else
        error("uncrecognized option `by=$(by)`.")
    end

    # do nothing if k > length(x)
    if k ≥ n return X end

    # fill with zeros if k ≤ 0
    if k ≤ 0 return fill!(X, 0) end

    # otherwise, map rows to a score used in ranking and find the spliting element
    map!(f, scores, itr)
    search_by_top_k = k < n-k+1
    if search_by_top_k
        _k = k
        pivot = l0_search_partialsort!(idx, scores, _k, true)
    else
        _k = n-k+1
        pivot = l0_search_partialsort!(idx, scores, _k, false)
    end

    # preserve the top k elements
    p = abs(pivot)
    nonzero_count = 0
    @inbounds for (i, xᵢ) in enumerate(itr2)
        if scores[i] == 0 continue end

        # row is not in the top k
        if scores[i] < p
            fill!(xᵢ, 0)
            scores[i] = 0
        else # row is in the top k
            nonzero_count += 1
        end
    end

    # resolve ties
    if nonzero_count > k
        number_to_drop = nonzero_count - k
        _buffer_ = view(buffer, 1:number_to_drop)
        _indexes_ = findall(!iszero, scores)
        sample!(_indexes_, _buffer_, replace=false)
        @inbounds for i in _buffer_
            if by isa Val{:row}
                fill!(view(X, i, :), 0)
            elseif by isa Val{:col}
                fill!(view(X, :, i), 0)
            end
        end
    end

    return X
end

"""
Search `x` for the pivot that splits the vector into the `k`-largest elements in magnitude.

The search preserves signs and returns `x[k]` after partially sorting `x`.
"""
function l0_search_partialsort!(idx, x, k, rev::Bool)
    #
    # Based on https://github.com/JuliaLang/julia/blob/788b2c77c10c2160f4794a4d4b6b81a95a90940c/base/sort.jl#L863
    # This eliminates a mysterious allocation of ~48 bytes per call for
    #   sortperm!(idx, x, alg=algorithm, lt=isless, by=abs, rev=true, initialized=false)
    # where algorithm = PartialQuickSort(lo:hi)
    # Savings are small in terms of performance but add up for CV code.
    #
    lo = k
    hi = k+1

    # Order arguments
    lt  = isless
    by  = abs
    # rev = true
    o = Base.Order.Forward
    order = Base.Order.Perm(Base.Sort.ord(lt, by, rev, o), x)

    # sort!(idx, lo, hi, PartialQuickSort(k), order)
    Base.Sort.Float.fpsort!(idx, PartialQuickSort(lo:hi), order)

    return x[idx[k]]
end

struct L0Projection <: Function
    idx::Vector{Int}
    buffer::Vector{Int}

    function L0Projection(n::Int)
        new(collect(1:n), Vector{Int}(undef, n))
    end
end

function (P::L0Projection)(x, k)
    project_l0_ball!(x, P.idx, k, P.buffer)
end

struct StructuredL0Projection <: Function
    idx::Vector{Int}
    buffer::Vector{Int}
    scores::Vector{Float64}

    function StructuredL0Projection(n::Int)
        new(collect(1:n), Vector{Int}(undef, n), Vector{Float64}(undef, n))
    end
end

function (P::StructuredL0Projection)(X::AbstractMatrix, k)
    project_l0_ball!(X, P.idx, P.scores, k, P.buffer, by=Val(:row))
end
