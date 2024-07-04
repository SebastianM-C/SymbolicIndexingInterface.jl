function set_state!(sys, val, idx)
    state_values(sys)[idx] = val
end

"""
    getu(indp, sym)

Return a function that takes a value provider and returns the value of the symbolic
variable `sym`. If `sym` is not an observed quantity, the returned function can also
directly be called with an array of values representing the state vector. `sym` can be an
index into the state vector, a symbolic variable, a symbolic expression involving symbolic
variables in the index provider `indp`, a parameter symbol, the independent variable
symbol, or an array/tuple of the aforementioned. If the returned function is called with
a timeseries object, it can also be given a second argument representing the index at
which to return the value of `sym`.

At minimum, this requires that the value provider implement [`state_values`](@ref). To
support symbolic expressions, the value provider must implement [`observed`](@ref),
[`parameter_values`](@ref) and [`current_time`](@ref).

This function typically does not need to be implemented, and has a default implementation
relying on the above functions.

If the value provider is a parameter timeseries object, the same rules apply as
[`getp`](@ref). The difference here is that `sym` may also contain non-parameter symbols,
and the values are always returned corresponding to the state timeseries.
"""
function getu(sys, sym)
    symtype = symbolic_type(sym)
    elsymtype = symbolic_type(eltype(sym))
    _getu(sys, symtype, elsymtype, sym)
end

struct GetStateIndex{I} <: AbstractStateGetIndexer
    idx::I
end
function (gsi::GetStateIndex)(::Timeseries, prob)
    getindex.(state_values(prob), (gsi.idx,))
end
function (gsi::GetStateIndex)(::Timeseries, prob, i::Union{Int, CartesianIndex})
    getindex(state_values(prob, i), gsi.idx)
end
function (gsi::GetStateIndex)(::Timeseries, prob, i)
    getindex.(state_values(prob, i), gsi.idx)
end
function (gsi::GetStateIndex)(::NotTimeseries, prob)
    state_values(prob, gsi.idx)
end

function _getu(sys, ::NotSymbolic, ::NotSymbolic, sym)
    return GetStateIndex(sym)
end

struct GetIndepvar <: AbstractStateGetIndexer end

(::GetIndepvar)(::IsTimeseriesTrait, prob) = current_time(prob)
(::GetIndepvar)(::Timeseries, prob, i) = current_time(prob, i)

struct TimeDependentObservedFunction{I, F} <: AbstractStateGetIndexer
    ts_idxs::I
    obsfn::F
end

indexer_timeseries_index(t::TimeDependentObservedFunction) = t.ts_idxs
function is_indexer_timeseries(::Type{G}) where {G <:
                                                 TimeDependentObservedFunction{ContinuousTimeseries}}
    return IndexerBoth()
end
function is_indexer_timeseries(::Type{G}) where {G <:
                                                 TimeDependentObservedFunction{<:Vector}}
    return IndexerMixedTimeseries()
end
function (o::TimeDependentObservedFunction)(ts::IsTimeseriesTrait, prob, args...)
    return o(ts, is_indexer_timeseries(o), prob, args...)
end

function (o::TimeDependentObservedFunction)(ts::Timeseries, ::IndexerBoth, prob)
    return o.obsfn.(state_values(prob),
        (parameter_values(prob),),
        current_time(prob))
end
function (o::TimeDependentObservedFunction)(
        ::Timeseries, ::IndexerBoth, prob, i::Union{Int, CartesianIndex})
    return o.obsfn(state_values(prob, i), parameter_values(prob), current_time(prob, i))
end
function (o::TimeDependentObservedFunction)(ts::Timeseries, ::IndexerBoth, prob, ::Colon)
    return o(ts, prob)
end
function (o::TimeDependentObservedFunction)(
        ts::Timeseries, ::IndexerBoth, prob, i::AbstractArray{Bool})
    map(only(to_indices(current_time(prob), (i,)))) do idx
        o(ts, prob, idx)
    end
end
function (o::TimeDependentObservedFunction)(ts::Timeseries, ::IndexerBoth, prob, i)
    o.((ts,), (prob,), i)
end
function (o::TimeDependentObservedFunction)(::NotTimeseries, ::IndexerBoth, prob)
    return o.obsfn(state_values(prob), parameter_values(prob), current_time(prob))
end

function (o::TimeDependentObservedFunction)(
        ::Timeseries, ::IndexerMixedTimeseries, prob, args...)
    throw(MixedParameterTimeseriesIndexError(prob, indexer_timeseries_index(o)))
end
function (o::TimeDependentObservedFunction)(
        ::NotTimeseries, ::IndexerMixedTimeseries, prob, args...)
    return o.obsfn(state_values(prob), parameter_values(prob), current_time(prob))
end

struct TimeIndependentObservedFunction{F} <: AbstractStateGetIndexer
    obsfn::F
end

function (o::TimeIndependentObservedFunction)(::IsTimeseriesTrait, prob)
    return o.obsfn(state_values(prob), parameter_values(prob))
end

function _getu(sys, ::ScalarSymbolic, ::SymbolicTypeTrait, sym)
    if is_variable(sys, sym)
        idx = variable_index(sys, sym)
        return getu(sys, idx)
    elseif is_parameter(sys, sym)
        return getp(sys, sym)
    elseif is_independent_variable(sys, sym)
        return GetIndepvar()
    elseif is_observed(sys, sym)
        if !is_time_dependent(sys)
            return TimeIndependentObservedFunction(observed(sys, sym))
        end

        ts_idxs = get_all_timeseries_indexes(sys, sym)
        if ContinuousTimeseries() in ts_idxs
            if length(ts_idxs) == 1
                ts_idxs = only(ts_idxs)
            else
                ts_idxs = collect(ts_idxs)
            end
            fn = observed(sys, sym)
            return TimeDependentObservedFunction(ts_idxs, fn)
        else
            return getp(sys, sym)
        end
    end
    error("Invalid symbol $sym for `getu`")
end

struct MultipleGetters{I, G} <: AbstractStateGetIndexer
    ts_idxs::I
    getters::G
end

indexer_timeseries_index(mg::MultipleGetters) = mg.ts_idxs
function is_indexer_timeseries(::Type{G}) where {G <: MultipleGetters{ContinuousTimeseries}}
    return IndexerBoth()
end
function is_indexer_timeseries(::Type{G}) where {G <: MultipleGetters{<:Vector}}
    return IndexerMixedTimeseries()
end
function is_indexer_timeseries(::Type{G}) where {G <: MultipleGetters{Nothing}}
    return IndexerNotTimeseries()
end

function (mg::MultipleGetters)(ts::IsTimeseriesTrait, prob, args...)
    return mg(ts, is_indexer_timeseries(mg), prob, args...)
end

function (mg::MultipleGetters)(ts::Timeseries, ::IndexerBoth, prob)
    return mg.((ts,), (prob,), eachindex(current_time(prob)))
end
function (mg::MultipleGetters)(
        ::Timeseries, ::IndexerBoth, prob, i::Union{Int, CartesianIndex})
    return map(CallWith(prob, i), mg.getters)
end
function (mg::MultipleGetters)(ts::Timeseries, ::IndexerBoth, prob, ::Colon)
    return mg(ts, prob)
end
function (mg::MultipleGetters)(ts::Timeseries, ::IndexerBoth, prob, i::AbstractArray{Bool})
    return map(only(to_indices(current_time(prob), (i,)))) do idx
        mg(ts, prob, idx)
    end
end
function (mg::MultipleGetters)(ts::Timeseries, ::IndexerBoth, prob, i)
    mg.((ts,), (prob,), i)
end
function (mg::MultipleGetters)(
        ::NotTimeseries, ::Union{IndexerBoth, IndexerNotTimeseries}, prob)
    return map(g -> g(prob), mg.getters)
end

function (mg::MultipleGetters)(::Timeseries, ::IndexerMixedTimeseries, prob, args...)
    throw(MixedParameterTimeseriesIndexError(prob, indexer_timeseries_index(mg)))
end
function (mg::MultipleGetters)(::NotTimeseries, ::IndexerMixedTimeseries, prob, args...)
    return map(g -> g(prob), mg.getters)
end

struct AsTupleWrapper{N, G} <: AbstractStateGetIndexer
    getter::G
end

AsTupleWrapper{N}(getter::G) where {N, G} = AsTupleWrapper{N, G}(getter)

wrap_tuple(::AsTupleWrapper{N}, val) where {N} = ntuple(i -> val[i], Val(N))

function (atw::AsTupleWrapper)(::Timeseries, prob)
    return wrap_tuple.((atw,), atw.getter(prob))
end
function (atw::AsTupleWrapper)(::Timeseries, prob, i::Union{Int, CartesianIndex})
    return wrap_tuple(atw, atw.getter(prob, i))
end
function (atw::AsTupleWrapper)(::Timeseries, prob, i)
    return wrap_tuple.((atw,), atw.getter(prob, i))
end
function (atw::AsTupleWrapper)(::NotTimeseries, prob)
    wrap_tuple(atw, atw.getter(prob))
end

for (t1, t2) in [
    (ScalarSymbolic, Any),
    (ArraySymbolic, Any),
    (NotSymbolic, Union{<:Tuple, <:AbstractArray})
]
    @eval function _getu(sys, ::NotSymbolic, elt::$t1, sym::$t2)
        if isempty(sym)
            return MultipleGetters(ContinuousTimeseries(), sym)
        end
        sym_arr = sym isa Tuple ? collect(sym) : sym
        num_observed = count(x -> is_observed(sys, x), sym)
        if !is_time_dependent(sys)
            if num_observed == 0 || num_observed == 1 && sym isa Tuple
                return MultipleGetters(nothing, getu.((sys,), sym))
            else
                obs = observed(sys, sym_arr)
                getter = TimeIndependentObservedFunction(obs)
                if sym isa Tuple
                    getter = AsTupleWrapper{length(sym)}(getter)
                end
                return getter
            end
        end
        ts_idxs = get_all_timeseries_indexes(sys, sym_arr)
        if !(ContinuousTimeseries() in ts_idxs)
            return getp(sys, sym)
        end
        if length(ts_idxs) == 1
            ts_idxs = only(ts_idxs)
        else
            ts_idxs = collect(ts_idxs)
        end

        num_observed = count(x -> is_observed(sys, x), sym)
        if num_observed == 0 || num_observed == 1 && sym isa Tuple
            getters = getu.((sys,), sym)
            return MultipleGetters(ts_idxs, getters)
        else
            obs = observed(sys, sym_arr)
            getter = if is_time_dependent(sys)
                TimeDependentObservedFunction(ts_idxs, obs)
            else
                TimeIndependentObservedFunction(obs)
            end
            if sym isa Tuple
                getter = AsTupleWrapper{length(sym)}(getter)
            end
            return getter
        end
    end
end

function _getu(sys, ::ArraySymbolic, ::SymbolicTypeTrait, sym)
    if is_variable(sys, sym)
        idx = variable_index(sys, sym)
        return getu(sys, idx)
    elseif is_parameter(sys, sym)
        return getp(sys, sym)
    end
    return getu(sys, collect(sym))
end

# setu doesn't need the same `let` blocks to be inferred for some reason

"""
    setu(sys, sym)

Return a function that takes a value provider and a value, and sets the the state `sym` to
that value. Note that `sym` can be an index, a symbolic variable, or an array/tuple of the
aforementioned.

Requires that the value provider implement [`state_values`](@ref) and the returned
collection be a mutable reference to the state vector in the value provider. Alternatively,
if this is not possible or additional actions need to be performed when updating state,
[`set_state!`](@ref) can be defined. This function does not work on types for which
[`is_timeseries`](@ref) is [`Timeseries`](@ref).
"""
function setu(sys, sym)
    symtype = symbolic_type(sym)
    elsymtype = symbolic_type(eltype(sym))
    _setu(sys, symtype, elsymtype, sym)
end

struct SetStateIndex{I} <: AbstractSetIndexer
    idx::I
end

function (ssi::SetStateIndex)(prob, val)
    set_state!(prob, val, ssi.idx)
end

function _setu(sys, ::NotSymbolic, ::NotSymbolic, sym)
    return SetStateIndex(sym)
end

function _setu(sys, ::ScalarSymbolic, ::SymbolicTypeTrait, sym)
    if is_variable(sys, sym)
        idx = variable_index(sys, sym)
        return SetStateIndex(idx)
    elseif is_parameter(sys, sym)
        return setp(sys, sym)
    end
    error("Invalid symbol $sym for `setu`")
end

for (t1, t2) in [
    (ScalarSymbolic, Any),
    (ArraySymbolic, Any),
    (NotSymbolic, Union{<:Tuple, <:AbstractArray})
]
    @eval function _setu(sys, ::NotSymbolic, ::$t1, sym::$t2)
        setters = setu.((sys,), sym)
        return MultipleSetters(setters)
    end
end

function _setu(sys, ::ArraySymbolic, ::SymbolicTypeTrait, sym)
    if is_variable(sys, sym)
        idx = variable_index(sys, sym)
        if idx isa AbstractArray
            return MultipleSetters(SetStateIndex.(idx))
        else
            return SetStateIndex(idx)
        end
    elseif is_parameter(sys, sym)
        return setp(sys, sym)
    end
    return setu(sys, collect(sym))
end
