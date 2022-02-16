module Allocs

# Most of this file was copied from the PProf.jl package, and then adapted to
# export a profile of the heap profile data from this package.
# This code is pretty hacky, and I could probably do a better job re-using
# logic from the PProf package, but :shrug:.


import Profile  # For Profile.Allocs structures

# Import the PProf generated protobuf types from the PProf package:
import PProf
using PProf.perftools.profiles: ValueType, Sample, Function, Location, Line, Label
using PProf: _enter!, _escape_name_for_pprof
const PProfile = PProf.perftools.profiles.Profile
using Base.StackTraces: StackFrame

using PProf.ProtoBuf
using PProf.OrderedCollections

using ProgressMeter

"""
PProf.Allocs.pprof([alloc_profile]; kwargs...)

The `kwargs` are the same as [`PProf.pprof`](@ref), except:
- `frame_for_type = true`: If true, add a frame to the FlameGraph for the Type:
  of every allocation. Note that this tends to make the Graph view harder to
  read, because it's over-aggregated, so we recommend filtering out the `Type:`
  nodes in the PProf web UI.
"""
function pprof(alloc_profile::Profile.Allocs.AllocResults = Profile.Allocs.fetch()
               ;
               web::Bool = true,
               webhost::AbstractString = "localhost",
               webport::Integer = 62261,  # Use a different port than PProf (chosen via rand(33333:99999))
               out::AbstractString = "alloc-profile.pb.gz",
               from_c::Bool = true,
               drop_frames::Union{Nothing, AbstractString} = nothing,
               keep_frames::Union{Nothing, AbstractString} = nothing,
               ui_relative_percentages::Bool = true,
               full_signatures::Bool = true,
               # Allocs-specific arguments:
               frame_for_type::Bool = true,
            )
    period = UInt64(0x1)

    @assert !isempty(basename(out)) "`out=` must specify a file path to write to. Got unexpected: '$out'"
    if !endswith(out, ".pb.gz")
        out = "$out.pb.gz"
        @info "Writing output to $out"
    end

    string_table = OrderedDict{AbstractString, Int64}()
    enter!(string) = _enter!(string_table, string)
    enter!(::Nothing) = _enter!(string_table, "nothing")
    ValueType!(_type, unit) = ValueType(_type = enter!(_type), unit = enter!(unit))

    # Setup:
    enter!("")  # NOTE: pprof requires first entry to be ""

    funcs_map  = Dict{String, UInt64}()
    functions = Vector{Function}()

    locs_map  = Dict{StackFrame, UInt64}()
    locations = Vector{Location}()

    sample_type = [
        ValueType!("allocs", "count"), # Mandatory
        ValueType!("size", "bytes")
    ]

    prof = PProfile(
        sample = [], location = [], _function = [],
        mapping = [], string_table = [],
        sample_type = sample_type,
        # We default to allocs, since the Profile.Allocs code currently uniformly samples
        # accross allocations, so allocs is a representative profile, while size is not.
        default_sample_type = 1, # allocs
        period = period, period_type = ValueType!("heap", "bytes")
    )

    if drop_frames !== nothing
        prof.drop_frames = enter!(drop_frames)
    end
    if keep_frames !== nothing
        prof.keep_frames = enter!(keep_frames)
    end

    function maybe_add_location(frame::StackFrame)::UInt64
        return get!(locs_map, frame) do
            loc_id = UInt64(length(locations) + 1)

            # Extract info from the location frame
            (function_name, file_name, line_number) =
                string(frame.func), string(frame.file), frame.line

            # Decode the IP into information about this stack frame
            function_id = get!(funcs_map, function_name) do
                func_id = UInt64(length(functions) + 1)

                # Store the function in our functions dict
                funcProto = Function()
                funcProto.id = func_id
                file = function_name
                simple_name = _escape_name_for_pprof(function_name)
                local full_name_with_args
                if frame.linfo !== nothing && frame.linfo isa Core.MethodInstance
                    linfo = frame.linfo::Core.MethodInstance
                    meth = linfo.def
                    file = string(meth.file)
                    io = IOBuffer()
                    Base.show_tuple_as_call(io, meth.name, linfo.specTypes)
                    name = String(take!(io))
                    full_name_with_args = _escape_name_for_pprof(name)
                    funcProto.start_line = convert(Int64, meth.line)
                else
                    # frame.linfo either nothing or CodeInfo, either way fallback
                    file = string(frame.file)
                    full_name_with_args = _escape_name_for_pprof(string(frame.func))
                    funcProto.start_line = convert(Int64, frame.line) # TODO: Get start_line properly
                end
                # WEIRD TRICK: By entering a separate copy of the string (with a
                # different string id) for the name and system_name, pprof will use
                # the supplied `name` *verbatim*, without pruning off the arguments.
                # So even when full_signatures == false, we want to generate two `enter!` ids.
                funcProto.system_name = enter!(simple_name)
                if full_signatures
                    funcProto.name = enter!(full_name_with_args)
                else
                    funcProto.name = enter!(simple_name)
                end
                file = Base.find_source_file(file_name)
                file = file !== nothing ? file : file_name
                funcProto.filename   = enter!(file)
                push!(functions, funcProto)

                return func_id
            end

            locationProto = Location(;id = loc_id,
                                line=[Line(function_id = function_id, line = line_number)])
            push!(locations, locationProto)

            return loc_id
        end
    end

    type_name_cache = Dict{Any,String}()

    function get_type_name(type::Any)
        return get!(type_name_cache, type) do
            return "Alloc: $(type)"
        end
    end

    function construct_location_for_type(typename)
        # TODO: Lol something less hacky than this:
        return maybe_add_location(StackFrame(get_type_name(typename), "nothing", 0))
    end

    # convert the sample.stack to vector of location_ids
    @showprogress "Analyzing $(length(alloc_profile.allocs)) allocation samples..." for sample in alloc_profile.allocs
        # for each location in the sample.stack, if it's the first time seeing it,
        # we also enter that location into the locations table
        location_ids = UInt64[
            maybe_add_location(frame)
            for frame in sample.stacktrace if (!frame.from_c || from_c)
        ]

        if frame_for_type
            # Add location_id for the type:
            pushfirst!(location_ids, construct_location_for_type(sample.type))
        end

        # report the value: allocs = 1 (count)
        # report the value: size (bytes)
        value = [
            1,                   # allocs
            sample.size,         # bytes
        ]

        labels = Label[
            Label(key = enter!("bytes"), num = sample.size, num_unit = enter!("bytes")),
            Label(key = enter!("type"), str = enter!(_escape_name_for_pprof(string(sample.type))))
        ]

        push!(prof.sample, Sample(;location_id = location_ids, value = value, label = labels))
    end


    # Build Profile
    prof.string_table = collect(keys(string_table))
    # If from_c=false funcs and locs should NOT contain C functions
    prof._function = functions
    prof.location  = locations

    # Write to disk
    open(out, "w") do io
        writeproto(io, prof)
    end

    if web
        PProf.refresh(webhost = webhost, webport = webport, file = out,
                      ui_relative_percentages = ui_relative_percentages,
        )
    end

    out
end

end  # module Allocs
