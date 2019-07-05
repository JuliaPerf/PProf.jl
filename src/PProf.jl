module PProf

export pprof

using Profile
using ProtoBuf
using OrderedCollections

include(joinpath("..", "lib", "perftools.jl"))

import .perftools.profiles: ValueType, Sample, Function,
                            Location, Line
const PProfile = perftools.profiles.Profile

"""
    _enter!(dict::OrderedDict{T, Int}, key::T) where T

Resolves from `key` to the index (zero-based) in the dict.
Useful for the Strings table
"""
function _enter!(dict::OrderedDict{T, Int}, key::T) where T
    if haskey(dict, key)
        return dict[key]
    else
        l = length(dict)
        dict[key] = l
        return l
    end
end

using Base.StackTraces: StackFrame

# TODO:
# - from_c, two possible solutions:
#   - Filter functions out during profile creation
#   - PProfile has a `drop_frames` field that could be used to implement a filter
# - Fill out PProfile various fields
# - Fill out Function various fields
# - Location: is_folded
# - Mappings
# - Understand what Sample.value[0] is supposed to be
# - Check that we add Locations in the right order.
# - Tests!


function pprof(data::Array{UInt,1} = UInt[],
               litrace::Dict{UInt,Array{StackFrame,1}} = Dict{UInt,Array{StackFrame,1}}();
               from_c = false,
               outfile = "profile.pb.gz")

    if length(data) == 0
        (data, litrace) = Profile.retrieve()
    end

    string_table = OrderedDict{AbstractString, Int}()
    enter!(string) = _enter!(string_table, string)
    ValueType!(_type, unit) = ValueType(_type = enter!(_type), unit = enter!(unit))

    # Setup:
    enter!("")  # NOTE: pprof requires first entry to be ""
    # Functions need a uid, we'll use the pointer for the method instance
    funcs = Dict{UInt64, Function}()
    locs  = Dict{UInt64, Location}()

    sample_type = [
        ValueType!("events", "count"), # Mandatory
        ValueType!("stack_depth", "count")
    ]

    prof = PProfile(
        sample = [], location = [], _function = [],
        mapping = [], string_table = [], sample_type = sample_type)

    location_id = Vector{eltype(data)}()
    lastwaszero = true

    for d in data
        # d == 0 is the sentinel value for finishing a sample
        if d == 0
            # Avoid creating empty samples
            if lastwaszero
                @assert length(location_id) == 0
                continue
            end

            # End of sample
            value = [
                1,                   # events
                length(location_id), # stack_depth
            ]
            push!(prof.sample, Sample(;location_id = location_id, value = value))
            location_id = Vector{eltype(data)}()
            lastwaszero = true
            continue
        end
        lastwaszero = false

        push!(location_id, d)
        # if we have already seen this location avoid entering it again
        haskey(locs, d) && continue

        location = Location(;id = d, address = d, line=[])
        frames = litrace[d]
        for frame in frames
            # ip 0 is reserved
            frame.pointer == 0 && continue

            push!(location.line, Line(function_id = frame.pointer, line = frame.line))
            # Known function
            haskey(funcs, frame.pointer) && continue

            # Store the function in our functions dict
            funcProto = Function()
            funcProto.id = frame.pointer
            if frame.linfo !== nothing
                linfo = frame.linfo::Core.MethodInstance
                meth = linfo.def
                file = Base.find_source_file(string(meth.file))
                funcProto.name       = enter!(string(meth.module, ".", meth.name))
                funcProto.filename   = enter!(file)
                funcProto.start_line = convert(Int64, meth.line)
            else
                file = Base.find_source_file(string(frame.file))
                file_repr = file == nothing ? "nothing" : file
                funcProto.name = enter!(string(frame.func))
                funcProto.filename = enter!(file_repr)
                funcProto.start_line = convert(Int64, frame.line) # TODO: Get start_line properly
            end
            funcProto.system_name = funcProto.name
            funcs[frame.pointer] = funcProto
        end
        locs[d] = location
    end

    # Build Profile
    prof.string_table = collect(keys(string_table))
    prof._function = collect(values(funcs))
    prof.location  = collect(values(locs))

    # Write to
    open(outfile, "w") do io
        writeproto(io, prof)
    end

    outfile
end

end # module
