module PProf

include(joinpath("..", "lib", "perftools.jl"))

using ProtoBuf
using OrderedCollections

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

using Profile
using Base.StackTraces: StackFrame

# =================
# NOTES
#
function pprof(data::Array{UInt,1} = UInt[],litrace::Dict{UInt,Array{StackFrame,1}} = Dict{UInt,Array{StackFrame,1}}();
                         from_c=false)


     string_table = OrderedDict{AbstractString, Int}()
     enter!(string_table, "")  # NOTE: Google requires first entry to be ""

     # Functions need a uid, we'll use the pointer for the method instance
     funcs = Dict{UInt64, perftools.profiles.Function}()

     prof = perftools.profiles.Profile(sample = [], location = [], _function = [],
                                       mapping = [], string_table = [])


    if length(data) == 0
        (data, litrace) = Profile.retrieve()
    end

    #data, litrace = Profile.flatten(data, litrace)

    sample = perftools.profiles.Sample()

    lastwaszero = true
    for d in data
        if d == 0
            # End of sample
            push!(prof.sample, sample)
            sample = perftools.profiles.Sample()

            #if !lastwaszero
            #    write(formatter, "\n")
            #end
            lastwaszero = true
            continue
        end
        frames = litrace[d]
        for frame in frames
            if !frame.from_c || from_c
                # Store the function in our functions dict
                if !(frame.pointer in keys(funcs))
                    funcProto = (funcs[frame.pointer] = perftools.profiles.Function())
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
                    funcProto.start_line = frame.line
                end

                lastwaszero = false
            end
        end
    end

    # Build Profile
    prof.string_table = collect(keys(string_table))
    prof._function = collect(values(funcs))

    # Write to
    f = "out.proto"
    open("out.proto", "w") do io
        writeproto(io, prof)
    end


    @show prof
    f
end



pprof()


end # module
