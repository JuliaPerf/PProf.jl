module PProf

using Profile
using ProtoBuf
using OrderedCollections

include(joinpath("..", "lib", "perftools.jl"))

import .perftools.profiles: ValueType, Sample, Function,
                            Location, Line
const PProfile = perftools.profiles.Profile

"""
    enter!(dict::OrderedDict{T, Int}, key::T) where T

Resolves from `key` to the index (zero-based) in the dict.
Useful for the Strings table
"""
function enter!(dict::OrderedDict{T, Int}, key::T) where T
    if haskey(dict, key)
        return dict[key]
    else
        l = length(dict)
        dict[key] = l
        return l
    end
end

using Base.StackTraces: StackFrame

function pprof(data::Array{UInt,1} = UInt[],
               litrace::Dict{UInt,Array{StackFrame,1}} = Dict{UInt,Array{StackFrame,1}}();
               from_c = false,
               outfile = "profile.pb.gz")

    if length(data) == 0
        (data, litrace) = Profile.retrieve()
    end

    string_table = OrderedDict{AbstractString, Int}()
    enter!(string_table, "")  # NOTE: pprof requires first entry to be ""

    # Functions need a uid, we'll use the pointer for the method instance
    funcs = Dict{UInt64, Function}()
    locs  = Dict{UInt64, Location}()

    prof = PProfile(
        sample_type = [ValueType(_type = enter!(string_table, "events"),
                                 unit  = enter!(string_table, "count"))],
        sample = [], location = [], _function = [],
        mapping = [], string_table = [])

    location_id = Vector{eltype(data)}()
    lastwaszero = true

    for d in data
        # d == 0 is the sentinel value for finishing a sample
        if d == 0
            lastwaszero && continue

            # End of sample
            push!(prof.sample, Sample(;location_id = location_id, value = [length(location_id)]))
            location_id = Vector{eltype(data)}()
            lastwaszero = true
            continue
        end
        lastwaszero = false

        push!(location_id, d)

        haskey(locs, d) && continue
        location = Location(;id = d, address = d, line=[]) # TODO address
        frames = litrace[d]
        for frame in frames
            if !frame.from_c || from_c
                # Store the function in our functions dict
                if !(frame.pointer in keys(funcs))
                    funcProto = Function()
                    funcProto.id = frame.pointer
                    funcProto.name = enter!(string_table, string(frame.func))
                    if frame.linfo !== nothing
                        # TODO
                        # ... get full method name w/ types
                    end
                    funcProto.system_name = funcProto.name
                    file = Base.find_source_file(string(frame.file))
                    file_repr = file == nothing ? "nothing" : file
                    funcProto.filename = enter!(string_table, file_repr)
                    funcProto.start_line = frame.line # is  this the right line?
                    funcs[frame.pointer] = funcProto
                    push!(location.line, Line(function_id = funcProto.id, line = frame.line))
                end
            end
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
