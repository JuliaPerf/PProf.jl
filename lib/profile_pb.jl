# syntax: proto3
using ProtoBuf
import ProtoBuf.meta

mutable struct ValueType <: ProtoType
    _type::Int64
    unit::Int64
    ValueType(; kwargs...) = (o=new(); fillunset(o); isempty(kwargs) || ProtoBuf._protobuild(o, kwargs); o)
end #mutable struct ValueType

mutable struct Label <: ProtoType
    key::Int64
    str::Int64
    num::Int64
    num_unit::Int64
    Label(; kwargs...) = (o=new(); fillunset(o); isempty(kwargs) || ProtoBuf._protobuild(o, kwargs); o)
end #mutable struct Label

mutable struct Sample <: ProtoType
    location_id::Base.Vector{UInt64}
    value::Base.Vector{Int64}
    label::Base.Vector{Label}
    Sample(; kwargs...) = (o=new(); fillunset(o); isempty(kwargs) || ProtoBuf._protobuild(o, kwargs); o)
end #mutable struct Sample
const __pack_Sample = Symbol[:location_id,:value]
meta(t::Type{Sample}) = meta(t, ProtoBuf.DEF_REQ, ProtoBuf.DEF_FNUM, ProtoBuf.DEF_VAL, true, __pack_Sample, ProtoBuf.DEF_WTYPES, ProtoBuf.DEF_ONEOFS, ProtoBuf.DEF_ONEOF_NAMES, ProtoBuf.DEF_FIELD_TYPES)

mutable struct Mapping <: ProtoType
    id::UInt64
    memory_start::UInt64
    memory_limit::UInt64
    file_offset::UInt64
    filename::Int64
    build_id::Int64
    has_functions::Bool
    has_filenames::Bool
    has_line_numbers::Bool
    has_inline_frames::Bool
    Mapping(; kwargs...) = (o=new(); fillunset(o); isempty(kwargs) || ProtoBuf._protobuild(o, kwargs); o)
end #mutable struct Mapping

mutable struct Line <: ProtoType
    function_id::UInt64
    line::Int64
    Line(; kwargs...) = (o=new(); fillunset(o); isempty(kwargs) || ProtoBuf._protobuild(o, kwargs); o)
end #mutable struct Line

mutable struct Location <: ProtoType
    id::UInt64
    mapping_id::UInt64
    address::UInt64
    line::Base.Vector{Line}
    is_folded::Bool
    Location(; kwargs...) = (o=new(); fillunset(o); isempty(kwargs) || ProtoBuf._protobuild(o, kwargs); o)
end #mutable struct Location

mutable struct Function <: ProtoType
    id::UInt64
    name::Int64
    system_name::Int64
    filename::Int64
    start_line::Int64
    Function(; kwargs...) = (o=new(); fillunset(o); isempty(kwargs) || ProtoBuf._protobuild(o, kwargs); o)
end #mutable struct Function

mutable struct Profile <: ProtoType
    sample_type::Base.Vector{ValueType}
    sample::Base.Vector{Sample}
    mapping::Base.Vector{Mapping}
    location::Base.Vector{Location}
    _function::Base.Vector{Function}
    string_table::Base.Vector{AbstractString}
    drop_frames::Int64
    keep_frames::Int64
    time_nanos::Int64
    duration_nanos::Int64
    period_type::ValueType
    period::Int64
    comment::Base.Vector{Int64}
    default_sample_type::Int64
    Profile(; kwargs...) = (o=new(); fillunset(o); isempty(kwargs) || ProtoBuf._protobuild(o, kwargs); o)
end #mutable struct Profile
const __pack_Profile = Symbol[:comment]
meta(t::Type{Profile}) = meta(t, ProtoBuf.DEF_REQ, ProtoBuf.DEF_FNUM, ProtoBuf.DEF_VAL, true, __pack_Profile, ProtoBuf.DEF_WTYPES, ProtoBuf.DEF_ONEOFS, ProtoBuf.DEF_ONEOF_NAMES, ProtoBuf.DEF_FIELD_TYPES)

export Profile, ValueType, Sample, Label, Mapping, Location, Line, Function
