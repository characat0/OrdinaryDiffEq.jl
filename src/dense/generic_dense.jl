const DERIVATIVE_ORDER_NOT_POSSIBLE_MESSAGE = """
                                         Derivative order too high for interpolation order. An interpolation derivative is
                                         only accurate to a certain deriative. For example, a second order interpolation
                                         is a quadratic polynomial, and thus third derivatives cannot be computed (will be
                                         incorrectly zero). Thus use a solver with a higher order interpolation or compute
                                         the higher order derivative through other means.

                                         You can find the list of available ODE/DAE solvers with their documented interpolations at:

                                         * https://docs.sciml.ai/DiffEqDocs/stable/solvers/ode_solve/
                                         * https://docs.sciml.ai/DiffEqDocs/stable/solvers/dae_solve/
                                         """

struct DerivativeOrderNotPossibleError <: Exception end

function Base.showerror(io::IO, e::DerivativeOrderNotPossibleError)
    print(io, DERIVATIVE_ORDER_NOT_POSSIBLE_MESSAGE)
    println(io, TruncatedStacktraces.VERBOSE_MSG)
end

## Integrator Dispatches

# Can get rid of an allocation here with a function
# get_tmp_arr(integrator.cache) which gives a pointer to some
# cache array which can be modified.

@inline function _searchsortedfirst(v::AbstractVector, x, lo::Integer, forward::Bool)
    u = oftype(lo, 1)
    lo = lo - u
    hi = length(v) + u
    @inbounds while lo < hi - u
        m = (lo + hi) >>> 1
        @inbounds if (forward && v[m] < x) || (!forward && v[m] > x)
            lo = m
        else
            hi = m
        end
    end
    return hi
end

@inline function _searchsortedlast(v::AbstractVector, x, lo::Integer, forward::Bool)
    u = oftype(lo, 1)
    lo = lo - u
    hi = length(v) + u
    @inbounds while lo < hi - u
        m = (lo + hi) >>> 1
        @inbounds if (forward && v[m] > x) || (!forward && v[m] < x)
            hi = m
        else
            lo = m
        end
    end
    return lo
end

@inline function ode_addsteps!(integrator, f = integrator.f, always_calc_begin = false,
    allow_calc_end = true, force_calc_end = false)
    cache = integrator.cache
    if !(cache isa CompositeCache)
        _ode_addsteps!(integrator.k, integrator.tprev, integrator.uprev, integrator.u,
            integrator.dt, f, integrator.p, cache,
            always_calc_begin, allow_calc_end, force_calc_end)
    else
        cache_current = cache.current
        if length(integrator.cache.caches) == 2
            if cache_current == 1
                _ode_addsteps!(integrator.k, integrator.tprev, integrator.uprev,
                    integrator.u,
                    integrator.dt, f, integrator.p,
                    cache.caches[1],
                    always_calc_begin, allow_calc_end, force_calc_end)
            else
                @assert cache_current == 2
                _ode_addsteps!(integrator.k, integrator.tprev, integrator.uprev,
                    integrator.u,
                    integrator.dt, f, integrator.p,
                    cache.caches[2],
                    always_calc_begin, allow_calc_end, force_calc_end)
            end
        else
            if cache_current == 1
                _ode_addsteps!(integrator.k, integrator.tprev, integrator.uprev,
                    integrator.u,
                    integrator.dt, f, integrator.p,
                    cache.caches[1],
                    always_calc_begin, allow_calc_end, force_calc_end)
            elseif cache_current == 2
                _ode_addsteps!(integrator.k, integrator.tprev, integrator.uprev,
                    integrator.u,
                    integrator.dt, f, integrator.p,
                    cache.caches[2],
                    always_calc_begin, allow_calc_end, force_calc_end)
            else
                _ode_addsteps!(integrator.k, integrator.tprev, integrator.uprev,
                    integrator.u,
                    integrator.dt, f, integrator.p,
                    cache.caches[cache_current],
                    always_calc_begin, allow_calc_end, force_calc_end)
            end
        end
    end
    return nothing
end
@inline function DiffEqBase.addsteps!(integrator::ODEIntegrator, args...)
    ode_addsteps!(integrator, args...)
end

@inline function ode_interpolant(Θ, integrator::DiffEqBase.DEIntegrator, idxs, deriv)
    DiffEqBase.addsteps!(integrator)
    if !(integrator.cache isa CompositeCache)
        val = ode_interpolant(Θ, integrator.dt, integrator.uprev, integrator.u,
            integrator.k, integrator.cache, idxs, deriv, integrator.differential_vars)
    else
        val = composite_ode_interpolant(Θ, integrator, integrator.cache.caches,
            integrator.cache.current, idxs, deriv)
    end
    val
end

@generated function composite_ode_interpolant(Θ, integrator, caches::T, current, idxs,
    deriv) where {T <: Tuple}
    expr = Expr(:block)
    for i in 1:length(T.types)
        push!(expr.args,
            quote
                if $i == current
                    return ode_interpolant(Θ, integrator.dt, integrator.uprev,
                        integrator.u, integrator.k, caches[$i], idxs,
                        deriv, integrator.differential_vars)
                end
            end)
    end
    push!(expr.args,
        quote
            throw("Cache $current is not available. There are only $(length(caches)) caches.")
        end)
    return expr
end

@inline function ode_interpolant!(val, Θ, integrator::DiffEqBase.DEIntegrator, idxs, deriv)
    DiffEqBase.addsteps!(integrator)
    if !(integrator.cache isa CompositeCache)
        ode_interpolant!(val, Θ, integrator.dt, integrator.uprev, integrator.u,
            integrator.k, integrator.cache, idxs, deriv, integrator.differential_vars)
    else
        ode_interpolant!(val, Θ, integrator.dt, integrator.uprev, integrator.u,
            integrator.k, integrator.cache.caches[integrator.cache.current],
            idxs, deriv, integrator.differential_vars)
    end
end

@generated function composite_ode_interpolant!(val, Θ, integrator, caches::T, current, idxs,
    deriv) where {T <: Tuple}
    expr = Expr(:block)
    for i in 1:length(T.types)
        push!(expr.args,
            quote
                if $i == current
                    return ode_interpolant!(val, Θ, integrator.dt, integrator.uprev,
                        integrator.u, integrator.k, caches[$i], idxs,
                        deriv)
                end
            end)
    end
    push!(expr.args,
        quote
            throw("Cache $current is not available. There are only $(length(caches)) caches.")
        end)
    return expr
end

@inline function current_interpolant(t::Number, integrator::DiffEqBase.DEIntegrator, idxs,
    deriv)
    Θ = (t - integrator.tprev) / integrator.dt
    ode_interpolant(Θ, integrator, idxs, deriv)
end

@inline function current_interpolant(t, integrator::DiffEqBase.DEIntegrator, idxs, deriv)
    Θ = (t .- integrator.tprev) ./ integrator.dt
    [ode_interpolant(ϕ, integrator, idxs, deriv) for ϕ in Θ]
end

@inline function current_interpolant!(val, t::Number, integrator::DiffEqBase.DEIntegrator,
    idxs, deriv)
    Θ = (t - integrator.tprev) / integrator.dt
    ode_interpolant!(val, Θ, integrator, idxs, deriv)
end

@inline function current_interpolant!(val, t, integrator::DiffEqBase.DEIntegrator, idxs,
    deriv)
    Θ = (t .- integrator.tprev) ./ integrator.dt
    [ode_interpolant!(val, ϕ, integrator, idxs, deriv) for ϕ in Θ]
end

@inline function current_interpolant!(val, t::Array, integrator::DiffEqBase.DEIntegrator,
    idxs, deriv)
    Θ = similar(t)
    @inbounds @simd ivdep for i in eachindex(t)
        Θ[i] = (t[i] - integrator.tprev) / integrator.dt
    end
    [ode_interpolant!(val, ϕ, integrator, idxs, deriv) for ϕ in Θ]
end

@inline function current_extrapolant(t::Number, integrator::DiffEqBase.DEIntegrator,
    idxs = nothing, deriv = Val{0})
    Θ = (t - integrator.tprev) / (integrator.t - integrator.tprev)
    ode_extrapolant(Θ, integrator, idxs, deriv)
end

@inline function current_extrapolant!(val, t::Number, integrator::DiffEqBase.DEIntegrator,
    idxs = nothing, deriv = Val{0})
    Θ = (t - integrator.tprev) / (integrator.t - integrator.tprev)
    ode_extrapolant!(val, Θ, integrator, idxs, deriv)
end

@inline function current_extrapolant(t::AbstractArray, integrator::DiffEqBase.DEIntegrator,
    idxs = nothing, deriv = Val{0})
    Θ = (t .- integrator.tprev) ./ (integrator.t - integrator.tprev)
    [ode_extrapolant(ϕ, integrator, idxs, deriv) for ϕ in Θ]
end

@inline function current_extrapolant!(val, t, integrator::DiffEqBase.DEIntegrator,
    idxs = nothing, deriv = Val{0})
    Θ = (t .- integrator.tprev) ./ (integrator.t - integrator.tprev)
    [ode_extrapolant!(val, ϕ, integrator, idxs, deriv) for ϕ in Θ]
end

@inline function ode_extrapolant!(val, Θ, integrator::DiffEqBase.DEIntegrator, idxs, deriv)
    DiffEqBase.addsteps!(integrator)
    if !(integrator.cache isa CompositeCache)
        ode_interpolant!(val, Θ, integrator.t - integrator.tprev, integrator.uprev2,
            integrator.uprev, integrator.k, integrator.cache, idxs, deriv, integrator.differential_vars)
    else
        composite_ode_extrapolant!(val, Θ, integrator, integrator.cache.caches,
            integrator.cache.current, idxs, deriv)
    end
end

@generated function composite_ode_extrapolant!(val, Θ, integrator, caches::T, current, idxs,
    deriv) where {T <: Tuple}
    expr = Expr(:block)
    for i in 1:length(T.types)
        push!(expr.args,
            quote
                if $i == current
                    return ode_interpolant!(val, Θ, integrator.t - integrator.tprev,
                        integrator.uprev2, integrator.uprev,
                        integrator.k, caches[$i], idxs, deriv, integrator.differential_vars)
                end
            end)
    end
    push!(expr.args,
        quote
            throw("Cache $current is not available. There are only $(length(caches)) caches.")
        end)
    return expr
end

@inline function ode_extrapolant(Θ, integrator::DiffEqBase.DEIntegrator, idxs, deriv)
    DiffEqBase.addsteps!(integrator)
    if !(integrator.cache isa CompositeCache)
        ode_interpolant(Θ, integrator.t - integrator.tprev, integrator.uprev2,
            integrator.uprev, integrator.k, integrator.cache, idxs, deriv, integrator.differential_vars)
    else
        composite_ode_extrapolant(Θ, integrator, integrator.cache.caches,
            integrator.cache.current, idxs, deriv)
    end
end

@generated function composite_ode_extrapolant(Θ, integrator, caches::T, current, idxs,
    deriv) where {T <: Tuple}
    expr = Expr(:block)
    for i in 1:length(T.types)
        push!(expr.args,
            quote
                if $i == current
                    return ode_interpolant(Θ, integrator.t - integrator.tprev,
                        integrator.uprev2, integrator.uprev,
                        integrator.k, caches[$i], idxs, deriv, integrator.differential_vars)
                end
            end)
    end
    push!(expr.args,
        quote
            throw("Cache $current is not available. There are only $(length(caches)) caches.")
        end)
    return expr
end

function _evaluate_interpolant(f, Θ, dt, timeseries, i₋, i₊,
    cache, idxs,
    deriv, ks, ts, p, differential_vars)
    _ode_addsteps!(ks[i₊], ts[i₋], timeseries[i₋], timeseries[i₊], dt, f, p,
        cache) # update the kcurrent
    return ode_interpolant(Θ, dt, timeseries[i₋], timeseries[i₊], ks[i₊],
        cache, idxs, deriv, differential_vars)
end
function evaluate_composite_cache(f, Θ, dt, timeseries, i₋, i₊,
    caches::Tuple{C1, C2, Vararg}, idxs,
    deriv, ks, ts, p, cacheid, differential_vars) where {C1, C2}
    if (cacheid -= 1) != 0
        return evaluate_composite_cache(f, Θ, dt, timeseries, i₋, i₊, Base.tail(caches),
            idxs,
            deriv, ks, ts, p, cacheid, differential_vars)
    end
    _evaluate_interpolant(f, Θ, dt, timeseries, i₋, i₊,
        first(caches), idxs,
        deriv, ks, ts, p, differential_vars)
end
function evaluate_composite_cache(f, Θ, dt, timeseries, i₋, i₊,
    caches::Tuple{C}, idxs,
    deriv, ks, ts, p, _, differential_vars) where {C}
    _evaluate_interpolant(f, Θ, dt, timeseries, i₋, i₊,
        only(caches), idxs,
        deriv, ks, ts, p, differential_vars)
end

function evaluate_interpolant(f, Θ, dt, timeseries, i₋, i₊, cache, idxs,
    deriv, ks, ts, id, p, differential_vars)
    if cache isa (FunctionMapCache) || cache isa FunctionMapConstantCache
        return ode_interpolant(Θ, dt, timeseries[i₋], timeseries[i₊], 0, cache, idxs,
            deriv, differential_vars)
    elseif !id.dense
        return linear_interpolant(Θ, dt, timeseries[i₋], timeseries[i₊], idxs, deriv)
    elseif cache isa CompositeCache
        return evaluate_composite_cache(f, Θ, dt, timeseries, i₋, i₊, cache.caches, idxs,
            deriv, ks, ts, p, id.alg_choice[i₊], differential_vars)
    else
        return _evaluate_interpolant(f, Θ, dt, timeseries, i₋, i₊,
            cache, idxs,
            deriv, ks, ts, p, differential_vars)
    end
end

"""
ode_interpolation(tvals,ts,timeseries,ks)

Get the value at tvals where the solution is known at the
times ts (sorted), with values timeseries and derivatives ks
"""
function ode_interpolation(tvals, id::I, idxs, deriv::D, p,
    continuity::Symbol = :left) where {I, D}
    @unpack ts, timeseries, ks, f, cache, differential_vars = id
    @inbounds tdir = sign(ts[end] - ts[1])
    idx = sortperm(tvals, rev = tdir < 0)
    # start the search thinking it's ts[1]-ts[2]
    i₋₊ref = Ref((1, 2))
    vals = map(idx) do j
        t = tvals[j]
        (i₋, i₊) = i₋₊ref[]
        if continuity === :left
            # we have i₋ = i₊ = 1 if t = ts[1], i₊ = i₋ + 1 = lastindex(ts) if t > ts[end],
            # and otherwise i₋ and i₊ satisfy ts[i₋] < t ≤ ts[i₊]
            i₊ = min(lastindex(ts), _searchsortedfirst(ts, t, i₊, tdir > 0))
            i₋ = i₊ > 1 ? i₊ - 1 : i₊
        else
            # we have i₋ = i₊ - 1 = 1 if t < ts[1], i₊ = i₋ = lastindex(ts) if t = ts[end],
            # and otherwise i₋ and i₊ satisfy ts[i₋] ≤ t < ts[i₊]
            i₋ = max(1, _searchsortedlast(ts, t, i₋, tdir > 0))
            i₊ = i₋ < lastindex(ts) ? i₋ + 1 : i₋
        end
        i₋₊ref[] = (i₋, i₊)
        dt = ts[i₊] - ts[i₋]
        Θ = iszero(dt) ? oneunit(t) / oneunit(dt) : (t - ts[i₋]) / dt
        evaluate_interpolant(f, Θ, dt, timeseries, i₋, i₊, cache, idxs,
            deriv, ks, ts, id, p, differential_vars)
    end
    invpermute!(vals, idx)
    DiffEqArray(vals, tvals)
end

"""
ode_interpolation(tvals,ts,timeseries,ks)

Get the value at tvals where the solution is known at the
times ts (sorted), with values timeseries and derivatives ks
"""
function ode_interpolation!(vals, tvals, id::I, idxs, deriv::D, p,
    continuity::Symbol = :left) where {I, D}
    @unpack ts, timeseries, ks, f, cache, differential_vars = id
    @inbounds tdir = sign(ts[end] - ts[1])
    idx = sortperm(tvals, rev = tdir < 0)

    # start the search thinking it's in ts[1]-ts[2]
    i₋ = 1
    i₊ = 2
    # if CompositeCache, have an inplace cache for lower allocations
    # (expecting the same algorithms for large portions of ts)
    if cache isa OrdinaryDiffEq.CompositeCache
        current_alg = id.alg_choice[i₊]
        cache_i₊ = cache.caches[current_alg]
    end
    @inbounds for j in idx
        t = tvals[j]

        if continuity === :left
            # we have i₋ = i₊ = 1 if t = ts[1], i₊ = i₋ + 1 = lastindex(ts) if t > ts[end],
            # and otherwise i₋ and i₊ satisfy ts[i₋] < t ≤ ts[i₊]
            i₊ = min(lastindex(ts), _searchsortedfirst(ts, t, i₊, tdir > 0))
            i₋ = i₊ > 1 ? i₊ - 1 : i₊
        else
            # we have i₋ = i₊ - 1 = 1 if t < ts[1], i₊ = i₋ = lastindex(ts) if t = ts[end],
            # and otherwise i₋ and i₊ satisfy ts[i₋] ≤ t < ts[i₊]
            i₋ = max(1, _searchsortedlast(ts, t, i₋, tdir > 0))
            i₊ = i₋ < lastindex(ts) ? i₋ + 1 : i₋
        end

        dt = ts[i₊] - ts[i₋]
        Θ = iszero(dt) ? oneunit(t) / oneunit(dt) : (t - ts[i₋]) / dt

        if cache isa (FunctionMapCache) || cache isa FunctionMapConstantCache
            if eltype(vals) <: AbstractArray
                ode_interpolant!(vals[j], Θ, dt, timeseries[i₋], timeseries[i₊], 0, cache,
                    idxs, deriv, differential_vars)
            else
                vals[j] = ode_interpolant(Θ, dt, timeseries[i₋], timeseries[i₊], 0, cache,
                    idxs, deriv, differential_vars)
            end
        elseif !id.dense
            if eltype(vals) <: AbstractArray
                linear_interpolant!(vals[j], Θ, dt, timeseries[i₋], timeseries[i₊], idxs,
                    deriv)
            else
                vals[j] = linear_interpolant(Θ, dt, timeseries[i₋], timeseries[i₊], idxs,
                    deriv)
            end
        elseif cache isa CompositeCache
            if current_alg != id.alg_choice[i₊] # switched algorithm
                current_alg = id.alg_choice[i₊]
                @inbounds cache_i₊ = cache.caches[current_alg] # this alloc is costly
            end
            _ode_addsteps!(ks[i₊], ts[i₋], timeseries[i₋], timeseries[i₊], dt, f, p,
                cache_i₊) # update the kcurrent
            if eltype(vals) <: AbstractArray
                ode_interpolant!(vals[j], Θ, dt, timeseries[i₋], timeseries[i₊], ks[i₊],
                    cache_i₊, idxs, deriv, differential_vars)
            else
                vals[j] = ode_interpolant(Θ, dt, timeseries[i₋], timeseries[i₊], ks[i₊],
                    cache_i₊, idxs, deriv, differential_vars)
            end
        else
            _ode_addsteps!(ks[i₊], ts[i₋], timeseries[i₋], timeseries[i₊], dt, f, p,
                cache) # update the kcurrent
            if eltype(vals) <: AbstractArray
                ode_interpolant!(vals[j], Θ, dt, timeseries[i₋], timeseries[i₊], ks[i₊],
                    cache, idxs, deriv, differential_vars)
            else
                vals[j] = ode_interpolant(Θ, dt, timeseries[i₋], timeseries[i₊], ks[i₊],
                    cache, idxs, deriv, differential_vars)
            end
        end
    end

    vals
end

"""
ode_interpolation(tval::Number,ts,timeseries,ks)

Get the value at tval where the solution is known at the
times ts (sorted), with values timeseries and derivatives ks
"""
function ode_interpolation(tval::Number, id::I, idxs, deriv::D, p,
    continuity::Symbol = :left) where {I, D}
    @unpack ts, timeseries, ks, f, cache, differential_vars = id
    @inbounds tdir = sign(ts[end] - ts[1])

    if continuity === :left
        # we have i₋ = i₊ = 1 if tval = ts[1], i₊ = i₋ + 1 = lastindex(ts) if tval > ts[end],
        # and otherwise i₋ and i₊ satisfy ts[i₋] < tval ≤ ts[i₊]
        i₊ = min(lastindex(ts), _searchsortedfirst(ts, tval, 2, tdir > 0))
        i₋ = i₊ > 1 ? i₊ - 1 : i₊
    else
        # we have i₋ = i₊ - 1 = 1 if tval < ts[1], i₊ = i₋ = lastindex(ts) if tval = ts[end],
        # and otherwise i₋ and i₊ satisfy ts[i₋] ≤ tval < ts[i₊]
        i₋ = max(1, _searchsortedlast(ts, tval, 1, tdir > 0))
        i₊ = i₋ < lastindex(ts) ? i₋ + 1 : i₋
    end

    @inbounds begin
        dt = ts[i₊] - ts[i₋]
        Θ = iszero(dt) ? oneunit(tval) / oneunit(dt) : (tval - ts[i₋]) / dt

        if cache isa (FunctionMapCache) || cache isa FunctionMapConstantCache
            val = ode_interpolant(Θ, dt, timeseries[i₋], timeseries[i₊], 0, cache, idxs,
                deriv, differential_vars)
        elseif !id.dense
            val = linear_interpolant(Θ, dt, timeseries[i₋], timeseries[i₊], idxs, deriv)
        elseif cache isa CompositeCache
            _ode_addsteps!(ks[i₊], ts[i₋], timeseries[i₋], timeseries[i₊], dt, f, p,
                cache.caches[id.alg_choice[i₊]]) # update the kcurrent
            val = ode_interpolant(Θ, dt, timeseries[i₋], timeseries[i₊], ks[i₊],
                cache.caches[id.alg_choice[i₊]], idxs, deriv, differential_vars)
        else
            _ode_addsteps!(ks[i₊], ts[i₋], timeseries[i₋], timeseries[i₊], dt, f, p,
                cache) # update the kcurrent
            val = ode_interpolant(Θ, dt, timeseries[i₋], timeseries[i₊], ks[i₊], cache,
                idxs, deriv, differential_vars)
        end
    end

    val
end

"""
ode_interpolation!(out,tval::Number,ts,timeseries,ks)

Get the value at tval where the solution is known at the
times ts (sorted), with values timeseries and derivatives ks
"""
function ode_interpolation!(out, tval::Number, id::I, idxs, deriv::D, p,
    continuity::Symbol = :left) where {I, D}
    @unpack ts, timeseries, ks, f, cache, differential_vars = id
    @inbounds tdir = sign(ts[end] - ts[1])

    if continuity === :left
        # we have i₋ = i₊ = 1 if tval = ts[1], i₊ = i₋ + 1 = lastindex(ts) if tval > ts[end],
        # and otherwise i₋ and i₊ satisfy ts[i₋] < tval ≤ ts[i₊]
        i₊ = min(lastindex(ts), _searchsortedfirst(ts, tval, 2, tdir > 0))
        i₋ = i₊ > 1 ? i₊ - 1 : i₊
    else
        # we have i₋ = i₊ - 1 = 1 if tval < ts[1], i₊ = i₋ = lastindex(ts) if tval = ts[end],
        # and otherwise i₋ and i₊ satisfy ts[i₋] ≤ tval < ts[i₊]
        i₋ = max(1, _searchsortedlast(ts, tval, 1, tdir > 0))
        i₊ = i₋ < lastindex(ts) ? i₋ + 1 : i₋
    end

    @inbounds begin
        dt = ts[i₊] - ts[i₋]
        Θ = iszero(dt) ? oneunit(tval) / oneunit(dt) : (tval - ts[i₋]) / dt

        if cache isa (FunctionMapCache) || cache isa FunctionMapConstantCache
            ode_interpolant!(out, Θ, dt, timeseries[i₋], timeseries[i₊], 0, cache, idxs,
                deriv, differential_vars)
        elseif !id.dense
            linear_interpolant!(out, Θ, dt, timeseries[i₋], timeseries[i₊], idxs, deriv)
        elseif cache isa CompositeCache
            _ode_addsteps!(ks[i₊], ts[i₋], timeseries[i₋], timeseries[i₊], dt, f, p,
                cache.caches[id.alg_choice[i₊]]) # update the kcurrent
            ode_interpolant!(out, Θ, dt, timeseries[i₋], timeseries[i₊], ks[i₊],
                cache.caches[id.alg_choice[i₊]], idxs, deriv, differential_vars)
        else
            _ode_addsteps!(ks[i₊], ts[i₋], timeseries[i₋], timeseries[i₊], dt, f, p,
                cache) # update the kcurrent
            ode_interpolant!(out, Θ, dt, timeseries[i₋], timeseries[i₊], ks[i₊], cache,
                idxs, deriv, differential_vars)
        end
    end

    out
end

"""
By default, Hermite interpolant so update the derivative at the two ends
"""
function _ode_addsteps!(k, t, uprev, u, dt, f, p, cache, always_calc_begin = false,
    allow_calc_end = true, force_calc_end = false)
    if length(k) < 2 || always_calc_begin
        if cache isa OrdinaryDiffEqMutableCache
            rtmp = similar(u, eltype(eltype(k)))
            f(rtmp, uprev, p, t)
            copyat_or_push!(k, 1, rtmp)
            f(rtmp, u, p, t + dt)
            copyat_or_push!(k, 2, rtmp)
        else
            copyat_or_push!(k, 1, f(uprev, p, t))
            copyat_or_push!(k, 2, f(u, p, t + dt))
        end
    end
    nothing
end

"""
ode_interpolant and ode_interpolant! dispatch
"""
function ode_interpolant(Θ, dt, y₀, y₁, k, cache, idxs, T::Type{Val{TI}}, differential_vars) where {TI}
    _ode_interpolant(Θ, dt, y₀, y₁, k, cache, idxs, T, differential_vars)
end

function ode_interpolant(Θ, dt, y₀, y₁, k, cache::OrdinaryDiffEqMutableCache, idxs,
    T::Type{Val{TI}}, differential_vars) where {TI}
    if idxs isa Number || y₀ isa Union{Number, SArray}
        # typeof(y₀) can be these if saveidxs gives a single value
        _ode_interpolant(Θ, dt, y₀, y₁, k, cache, idxs, T, differential_vars)
    elseif idxs isa Nothing
        if y₁ isa Array{<:Number}
            out = similar(y₁, eltype(first(y₁) * oneunit(Θ)))
            copyto!(out, y₁)
        else
            out = oneunit(Θ) .* y₁
        end
        _ode_interpolant!(out, Θ, dt, y₀, y₁, k, cache, idxs, T, differential_vars)
    else
        if y₁ isa Array{<:Number}
            out = similar(y₁, eltype(first(y₁) * oneunit(Θ)), axes(idxs))
            for i in eachindex(idxs)
                out[i] = y₁[idxs[i]]
            end
        else
            out = oneunit(Θ) .* y₁[idxs]
        end
        _ode_interpolant!(out, Θ, dt, y₀, y₁, k, cache, idxs, T, differential_vars)
    end
end

function ode_interpolant!(out, Θ, dt, y₀, y₁, k, cache, idxs, T::Type{Val{TI}}, differential_vars) where {TI}
    _ode_interpolant!(out, Θ, dt, y₀, y₁, k, cache, idxs, T, differential_vars)
end

##################### Hermite Interpolants

const HERMITE_CASE_NOT_DEFINED_MESSAGE = """
                                         Hermite interpolation is not defined in this case. The Hermite interpolation
                                         fallback only supports diagonal mass matrices. If you have a DAE with a
                                         non-diagonal mass matrix, then the dense output is not supported with this
                                         ODE solver. Either use a method which has a specialized interpolation,
                                         such as Rodas5P, or use `dense=false`

                                         You can find the list of available DAE solvers with their documented interpolations at:
                                         https://docs.sciml.ai/DiffEqDocs/stable/solvers/dae_solve/
                                         """

struct HermiteInterpolationNonDiagonalError <: Exception end

function Base.showerror(io::IO, e::HermiteInterpolationNonDiagonalError)
    print(io, HERMITE_CASE_NOT_DEFINED_MESSAGE)
    println(io, TruncatedStacktraces.VERBOSE_MSG)
end

# If no dispatch found, assume Hermite
function _ode_interpolant(Θ, dt, y₀, y₁, k, cache, idxs, T::Type{Val{TI}}, differential_vars) where {TI}
    differential_vars isa DifferentialVarsUndefined && throw(HermiteInterpolationNonDiagonalError())
    TI > 3 && throw(DerivativeOrderNotPossibleError())

    differential_vars = if differential_vars === nothing
        if y₀ isa Number
            differential_vars = true
        elseif idxs === nothing
            differential_vars = Trues(size(y₀))
        elseif idxs isa Number
            differential_vars = true
        else
            differential_vars = Trues(size(idxs))
        end
    elseif idxs isa Number
        differential_vars[idxs]
    elseif idxs === nothing
        differential_vars
    else
        @view differential_vars[idxs]
    end

    hermite_interpolant(Θ, dt, y₀, y₁, k, Val{cache isa OrdinaryDiffEqMutableCache}, idxs, T, differential_vars)
end

function _ode_interpolant!(out, Θ, dt, y₀, y₁, k, cache, idxs, T::Type{Val{TI}}, differential_vars) where {TI}
    differential_vars isa DifferentialVarsUndefined && throw(HermiteInterpolationNonDiagonalError())
    TI > 3 && throw(DerivativeOrderNotPossibleError())

    differential_vars = if differential_vars === nothing
        if y₀ isa Number
            differential_vars = true
        elseif idxs === nothing
            differential_vars = Trues(size(out))
        elseif idxs isa Number
            differential_vars = true
        else
            differential_vars = Trues(size(idxs))
        end
    elseif idxs isa Number
        differential_vars[idxs]
    elseif idxs === nothing
        differential_vars
    else
        @view differential_vars[idxs]
    end

    hermite_interpolant!(out, Θ, dt, y₀, y₁, k, idxs, T, differential_vars)
end

"""
Hairer Norsett Wanner Solving Ordinary Differential Euations I - Nonstiff Problems Page 190

Herimte Interpolation, chosen if no other dispatch for ode_interpolant
"""
@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, ::Type{Val{false}}, idxs::Nothing,
    T::Type{Val{0}}, differential_vars) # Default interpolant is Hermite
    #@.. broadcast=false (1-Θ)*y₀+Θ*y₁+Θ*(Θ-1)*((1-2Θ)*(y₁-y₀)+(Θ-1)*dt*k[1] + Θ*dt*k[2])
    @inbounds (1 - Θ) * y₀ + Θ * y₁ +
              differential_vars .* (Θ * (Θ - 1) * ((1 - 2Θ) * (y₁ - y₀) + (Θ - 1) * dt * k[1] + Θ * dt * k[2]))
end

@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, ::Type{Val{true}}, idxs::Nothing,
    T::Type{Val{0}}, differential_vars) # Default interpolant is Hermite
    #@.. broadcast=false (1-Θ)*y₀+Θ*y₁+Θ*(Θ-1)*((1-2Θ)*(y₁-y₀)+(Θ-1)*dt*k[1] + Θ*dt*k[2])
    @inbounds @.. broadcast=false (1 - Θ)*y₀+Θ*y₁+
                                  differential_vars*Θ*(Θ-1)*((1 - 2Θ)*(y₁ - y₀)+(Θ-1)*dt*k[1]+Θ*dt*k[2])
end

@muladd function hermite_interpolant(Θ, dt, y₀::Array, y₁, k, ::Type{Val{true}},
    idxs::Nothing, T::Type{Val{0}}, differential_vars) # Default interpolant is Hermite
    out = similar(y₀)
    @inbounds @simd ivdep for i in eachindex(y₀)
        out[i] = (1 - Θ) * y₀[i] + Θ * y₁[i] +
                 differential_vars[i] * Θ * (Θ - 1) *
                 ((1 - 2Θ) * (y₁[i] - y₀[i]) + (Θ - 1) * dt * k[1][i] + Θ * dt * k[2][i])
    end
end

@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, cache, idxs, T::Type{Val{0}}, differential_vars) # Default interpolant is Hermite
    # return @.. broadcast=false (1-Θ)*y₀[idxs]+Θ*y₁[idxs]+Θ*(Θ-1)*((1-2Θ)*(y₁[idxs]-y₀[idxs])+(Θ-1)*dt*k[1][idxs] + Θ*dt*k[2][idxs])
    return (1 - Θ) * y₀[idxs] + Θ * y₁[idxs] +
           differential_vars .* (Θ * (Θ - 1) *
           ((1 - 2Θ) * (y₁[idxs] - y₀[idxs]) + (Θ - 1) * dt * k[1][idxs] +
            Θ * dt * k[2][idxs]))
end

@muladd function hermite_interpolant!(out, Θ, dt, y₀, y₁, k, idxs::Nothing, T::Type{Val{0}}, differential_vars) # Default interpolant is Hermite
    @inbounds @.. broadcast=false out=(1 - Θ) * y₀ + Θ * y₁ +
                                      differential_vars * Θ * (Θ - 1) *
                                      ((1 - 2Θ) * (y₁ - y₀) + (Θ - 1) * dt * k[1] +
                                       Θ * dt * k[2])
end

@muladd function hermite_interpolant!(out::Array, Θ, dt, y₀, y₁, k, idxs::Nothing,
    T::Type{Val{0}}, differential_vars) # Default interpolant is Hermite
    @inbounds @simd ivdep for i in eachindex(out)
        out[i] = (1 - Θ) * y₀[i] + Θ * y₁[i] +
                 differential_vars[i] * Θ * (Θ - 1) *
                 ((1 - 2Θ) * (y₁[i] - y₀[i]) + (Θ - 1) * dt * k[1][i] + Θ * dt * k[2][i])
    end
    out
end

@muladd function hermite_interpolant!(out, Θ, dt, y₀, y₁, k, idxs, T::Type{Val{0}}, differential_vars) # Default interpolant is Hermite
    @views @.. broadcast=false out=(1 - Θ) * y₀[idxs] + Θ * y₁[idxs] +
                                   differential_vars * Θ * (Θ - 1) *
                                   ((1 - 2Θ) * (y₁[idxs] - y₀[idxs]) +
                                    (Θ - 1) * dt * k[1][idxs] + Θ * dt * k[2][idxs])
end

@muladd function hermite_interpolant!(out::Array, Θ, dt, y₀, y₁, k, idxs, T::Type{Val{0}}, differential_vars) # Default interpolant is Hermite
    @inbounds for (j, i) in enumerate(idxs)
        out[j] = (1 - Θ) * y₀[i] + Θ * y₁[i] +
                 differential_vars[j] * Θ * (Θ - 1) *
                 ((1 - 2Θ) * (y₁[i] - y₀[i]) + (Θ - 1) * dt * k[1][i] + Θ * dt * k[2][i])
    end
    out
end

"""
Herimte Interpolation, chosen if no other dispatch for ode_interpolant
"""
@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, ::Type{Val{false}}, idxs::Nothing,
    T::Type{Val{1}}, differential_vars) # Default interpolant is Hermite
    #@.. broadcast=false k[1] + Θ*(-4*dt*k[1] - 2*dt*k[2] - 6*y₀ + Θ*(3*dt*k[1] + 3*dt*k[2] + 6*y₀ - 6*y₁) + 6*y₁)/dt
    @inbounds (.!differential_vars).*(y₁ - y₀)/dt + differential_vars .*(
              k[1] +
              Θ * (-4 * dt * k[1] - 2 * dt * k[2] - 6 * y₀ +
               Θ * (3 * dt * k[1] + 3 * dt * k[2] + 6 * y₀ - 6 * y₁) + 6 * y₁) / dt)
end

@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, ::Type{Val{true}}, idxs::Nothing,
    T::Type{Val{1}}, differential_vars) # Default interpolant is Hermite
    @inbounds @.. broadcast=false !differential_vars*((y₁ - y₀)/dt)+differential_vars*(
                                   k[1]+Θ * (-4 * dt * k[1] - 2 * dt * k[2] - 6 * y₀ +
                                        Θ *
                                        (3 * dt * k[1] + 3 * dt * k[2] + 6 * y₀ - 6 * y₁) +
                                        6 * y₁) / dt)
end

@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, cache, idxs, T::Type{Val{1}}, differential_vars) # Default interpolant is Hermite
    # return @.. broadcast=false k[1][idxs] + Θ*(-4*dt*k[1][idxs] - 2*dt*k[2][idxs] - 6*y₀[idxs] + Θ*(3*dt*k[1][idxs] + 3*dt*k[2][idxs] + 6*y₀[idxs] - 6*y₁[idxs]) + 6*y₁[idxs])/dt
    return (.!differential_vars).*((y₁[idxs] - y₀[idxs])/dt)+differential_vars.*(
           k[1][idxs] +
           Θ * (-4 * dt * k[1][idxs] - 2 * dt * k[2][idxs] - 6 * y₀[idxs] +
            Θ * (3 * dt * k[1][idxs] + 3 * dt * k[2][idxs] + 6 * y₀[idxs] - 6 * y₁[idxs]) +
            6 * y₁[idxs]) / dt)
end

@muladd function hermite_interpolant!(out, Θ, dt, y₀, y₁, k, idxs::Nothing, T::Type{Val{1}}, differential_vars) # Default interpolant is Hermite
    @inbounds @.. broadcast=false out=!differential_vars*((y₁ - y₀)/dt)+differential_vars*(
                                      k[1] +
                                      Θ * (-4 * dt * k[1] - 2 * dt * k[2] - 6 * y₀ +
                                       Θ *
                                       (3 * dt * k[1] + 3 * dt * k[2] + 6 * y₀ - 6 * y₁) +
                                       6 * y₁) / dt)
end

@muladd function hermite_interpolant!(out::Array, Θ, dt, y₀, y₁, k, idxs::Nothing,
    T::Type{Val{1}}, differential_vars) # Default interpolant is Hermite
    @inbounds @simd ivdep for i in eachindex(out)
        out[i] = !differential_vars[i]*((y₁[i] - y₀[i])/dt)+differential_vars[i]*(
                 k[1][i] +
                 Θ * (-4 * dt * k[1][i] - 2 * dt * k[2][i] - 6 * y₀[i] +
                  Θ * (3 * dt * k[1][i] + 3 * dt * k[2][i] + 6 * y₀[i] - 6 * y₁[i]) +
                  6 * y₁[i]) / dt)
    end
    out
end

@muladd function hermite_interpolant!(out, Θ, dt, y₀, y₁, k, idxs, T::Type{Val{1}}, differential_vars) # Default interpolant is Hermite
    @views @.. broadcast=false out=!differential_vars*((y₁ - y₀)/dt)+differential_vars*(
                                   k[1][idxs] +
                                   Θ * (-4 * dt * k[1][idxs] - 2 * dt * k[2][idxs] -
                                    6 * y₀[idxs] +
                                    Θ * (3 * dt * k[1][idxs] + 3 * dt * k[2][idxs] +
                                     6 * y₀[idxs] - 6 * y₁[idxs]) + 6 * y₁[idxs]) / dt)
end

@muladd function hermite_interpolant!(out::Array, Θ, dt, y₀, y₁, k, idxs, T::Type{Val{1}}, differential_vars) # Default interpolant is Hermite
    @inbounds for (j, i) in enumerate(idxs)
        out[j] = !differential_vars[j]*((y₁[i] - y₀[i])/dt)+differential_vars[j]*(
                 k[1][i] +
                 Θ * (-4 * dt * k[1][i] - 2 * dt * k[2][i] - 6 * y₀[i] +
                  Θ * (3 * dt * k[1][i] + 3 * dt * k[2][i] + 6 * y₀[i] - 6 * y₁[i]) +
                  6 * y₁[i]) / dt)
    end
    out
end

"""
Herimte Interpolation, chosen if no other dispatch for ode_interpolant
"""
@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, ::Type{Val{false}}, idxs::Nothing,
    T::Type{Val{2}}, differential_vars) # Default interpolant is Hermite
    #@.. broadcast=false (-4*dt*k[1] - 2*dt*k[2] - 6*y₀ + Θ*(6*dt*k[1] + 6*dt*k[2] + 12*y₀ - 12*y₁) + 6*y₁)/(dt*dt)
    @inbounds differential_vars .* (-4 * dt * k[1] - 2 * dt * k[2] - 6 * y₀ +
               Θ * (6 * dt * k[1] + 6 * dt * k[2] + 12 * y₀ - 12 * y₁) + 6 * y₁) / (dt * dt)
end

@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, ::Type{Val{true}}, idxs::Nothing,
    T::Type{Val{2}}, differential_vars) # Default interpolant is Hermite
    #@.. broadcast=false (-4*dt*k[1] - 2*dt*k[2] - 6*y₀ + Θ*(6*dt*k[1] + 6*dt*k[2] + 12*y₀ - 12*y₁) + 6*y₁)/(dt*dt)
    @inbounds @.. broadcast=false differential_vars * (-4 * dt * k[1] - 2 * dt * k[2] - 6 * y₀ +
                                   Θ * (6 * dt * k[1] + 6 * dt * k[2] + 12 * y₀ - 12 * y₁) +
                                   6 * y₁)/(dt * dt)
end

@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, cache, idxs, T::Type{Val{2}}, differential_vars) # Default interpolant is Hermite
    #out = similar(y₀,axes(idxs))
    #@views @.. broadcast=false out = (-4*dt*k[1][idxs] - 2*dt*k[2][idxs] - 6*y₀[idxs] + Θ*(6*dt*k[1][idxs] + 6*dt*k[2][idxs] + 12*y₀[idxs] - 12*y₁[idxs]) + 6*y₁[idxs])/(dt*dt)
    @views out = differential_vars .* (-4 * dt * k[1][idxs] - 2 * dt * k[2][idxs] - 6 * y₀[idxs] +
                  Θ * (6 * dt * k[1][idxs] + 6 * dt * k[2][idxs] + 12 * y₀[idxs] -
                   12 * y₁[idxs]) + 6 * y₁[idxs]) / (dt * dt)
    out
end

@muladd function hermite_interpolant!(out, Θ, dt, y₀, y₁, k, idxs::Nothing, T::Type{Val{2}}, differential_vars) # Default interpolant is Hermite
    @inbounds @.. broadcast=false out= differential_vars * (-4 * dt * k[1] - 2 * dt * k[2] - 6 * y₀ +
                                       Θ *
                                       (6 * dt * k[1] + 6 * dt * k[2] + 12 * y₀ - 12 * y₁) +
                                       6 * y₁) / (dt * dt)
end

@muladd function hermite_interpolant!(out::Array, Θ, dt, y₀, y₁, k, idxs::Nothing,
    T::Type{Val{2}}, differential_vars) # Default interpolant is Hermite
    @inbounds @simd ivdep for i in eachindex(out)
        out[i] = differential_vars[i] * (-4 * dt * k[1][i] - 2 * dt * k[2][i] - 6 * y₀[i] +
                  Θ * (6 * dt * k[1][i] + 6 * dt * k[2][i] + 12 * y₀[i] - 12 * y₁[i]) +
                  6 * y₁[i]) / (dt * dt)
    end
    out
end

@muladd function hermite_interpolant!(out, Θ, dt, y₀, y₁, k, idxs, T::Type{Val{2}}, differential_vars) # Default interpolant is Hermite
    @views @.. broadcast=false out=differential_vars * (-4 * dt * k[1][idxs] - 2 * dt * k[2][idxs] -
                                    6 * y₀[idxs] +
                                    Θ * (6 * dt * k[1][idxs] + 6 * dt * k[2][idxs] +
                                     12 * y₀[idxs] - 12 * y₁[idxs]) + 6 * y₁[idxs]) /
                                   (dt * dt)
end

@muladd function hermite_interpolant!(out::Array, Θ, dt, y₀, y₁, k, idxs, T::Type{Val{2}}, differential_vars) # Default interpolant is Hermite
    @inbounds for (j, i) in enumerate(idxs)
        out[j] = differential_vars[j] * (-4 * dt * k[1][i] - 2 * dt * k[2][i] - 6 * y₀[i] +
                  Θ * (6 * dt * k[1][i] + 6 * dt * k[2][i] + 12 * y₀[i] - 12 * y₁[i]) +
                  6 * y₁[i]) / (dt * dt)
    end
    out
end

"""
Herimte Interpolation, chosen if no other dispatch for ode_interpolant
"""
@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, ::Type{Val{false}}, idxs::Nothing,
    T::Type{Val{3}}, differential_vars) # Default interpolant is Hermite
    #@.. broadcast=false (6*dt*k[1] + 6*dt*k[2] + 12*y₀ - 12*y₁)/(dt*dt*dt)
    @inbounds differential_vars .* (6 * dt * k[1] + 6 * dt * k[2] + 12 * y₀ - 12 * y₁) / (dt * dt * dt)
end

@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, ::Type{Val{true}}, idxs::Nothing,
    T::Type{Val{3}}, differential_vars) # Default interpolant is Hermite
    #@.. broadcast=false (6*dt*k[1] + 6*dt*k[2] + 12*y₀ - 12*y₁)/(dt*dt*dt)
    @inbounds @.. broadcast=false differential_vars * (6 * dt * k[1] + 6 * dt * k[2] + 12 * y₀ -
                                   12 * y₁)/(dt *
                                             dt *
                                             dt)
end

@muladd function hermite_interpolant(Θ, dt, y₀, y₁, k, cache, idxs, T::Type{Val{3}}, differential_vars) # Default interpolant is Hermite
    #out = similar(y₀,axes(idxs))
    #@views @.. broadcast=false out = (6*dt*k[1][idxs] + 6*dt*k[2][idxs] + 12*y₀[idxs] - 12*y₁[idxs])/(dt*dt*dt)
    @views out = differential_vars .* (6 * dt * k[1][idxs] + 6 * dt * k[2][idxs] + 12 * y₀[idxs] -
                  12 * y₁[idxs]) /
                 (dt * dt * dt)
    out
end

@muladd function hermite_interpolant!(out, Θ, dt, y₀, y₁, k, idxs::Nothing, T::Type{Val{3}}, differential_vars) # Default interpolant is Hermite
    @inbounds @.. broadcast=false out=differential_vars * (6 * dt * k[1] + 6 * dt * k[2] + 12 * y₀ - 12 * y₁) /
                                      (dt * dt * dt)
    #for i in eachindex(out)
    #  out[i] = (6*dt*k[1][i] + 6*dt*k[2][i] + 12*y₀[i] - 12*y₁[i])/(dt*dt*dt)
    #end
    #out
end

@muladd function hermite_interpolant!(out::Array, Θ, dt, y₀, y₁, k, idxs::Nothing,
    T::Type{Val{3}}, differential_vars) # Default interpolant is Hermite
    @inbounds @simd ivdep for i in eachindex(out)
        out[i] = differential_vars[i] * (6 * dt * k[1][i] + 6 * dt * k[2][i] + 12 * y₀[i] - 12 * y₁[i]) /
                 (dt * dt * dt)
    end
    out
end

@muladd function hermite_interpolant!(out, Θ, dt, y₀, y₁, k, idxs, T::Type{Val{3}}, differential_vars) # Default interpolant is Hermite
    @views @.. broadcast=false out=(6 * dt * k[1][idxs] + 6 * dt * k[2][idxs] +
                                    12 * y₀[idxs] - 12 * y₁[idxs]) / (dt * dt * dt)
end

@muladd function hermite_interpolant!(out::Array, Θ, dt, y₀, y₁, k, idxs, T::Type{Val{3}}, differential_vars) # Default interpolant is Hermite
    @inbounds for (j, i) in enumerate(idxs)
        out[j] = differential_vars[j] * (6 * dt * k[1][i] + 6 * dt * k[2][i] + 12 * y₀[i] - 12 * y₁[i]) /
                 (dt * dt * dt)
    end
    out
end

######################## Linear Interpolants

@muladd @inline function linear_interpolant(Θ, dt, y₀, y₁, idxs::Nothing, T::Type{Val{0}})
    Θm1 = (1 - Θ)
    @.. broadcast=false Θm1 * y₀+Θ * y₁
end

@muladd @inline function linear_interpolant(Θ, dt, y₀, y₁, idxs, T::Type{Val{0}})
    Θm1 = (1 - Θ)
    @.. broadcast=false Θm1 * y₀[idxs]+Θ * y₁[idxs]
end

@muladd @inline function linear_interpolant!(out, Θ, dt, y₀, y₁, idxs::Nothing,
    T::Type{Val{0}})
    Θm1 = (1 - Θ)
    @.. broadcast=false out=Θm1 * y₀ + Θ * y₁
    out
end

@muladd @inline function linear_interpolant!(out, Θ, dt, y₀, y₁, idxs, T::Type{Val{0}})
    Θm1 = (1 - Θ)
    @views @.. broadcast=false out=Θm1 * y₀[idxs] + Θ * y₁[idxs]
    out
end

"""
Linear Interpolation
"""
@inline function linear_interpolant(Θ, dt, y₀, y₁, idxs::Nothing, T::Type{Val{1}})
    (y₁ - y₀) / dt
end

@inline function linear_interpolant(Θ, dt, y₀, y₁, idxs, T::Type{Val{1}})
    @.. broadcast=false (y₁[idxs] - y₀[idxs])/dt
end

@inline function linear_interpolant!(out, Θ, dt, y₀, y₁, idxs::Nothing, T::Type{Val{1}})
    @.. broadcast=false out=(y₁ - y₀) / dt
    out
end

@inline function linear_interpolant!(out, Θ, dt, y₀, y₁, idxs, T::Type{Val{1}})
    @views @.. broadcast=false out=(y₁[idxs] - y₀[idxs]) / dt
    out
end
