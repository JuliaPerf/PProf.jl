module Allocs

# Most of this file was copied from the PProf.jl package, and then adapted to
# export a profile of the heap profile data from this package.
# This code is pretty hacky, and I could probably do a better job re-using
# logic from the PProf package, but :shrug:.


import Profile  # For Profile.Allocs structures

# Import the PProf generated protobuf types from the PProf package:
import PProf
using PProf.perftools.profiles: ValueType, Sample, Function, Location, Line, Label
using PProf: _enter!, _escape_name_for_pprof, method_instance_id
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
    ValueType!(_type, unit) = ValueType(enter!(_type), enter!(unit))

    # Setup:
    enter!("")  # NOTE: pprof requires first entry to be ""

    # A map from each _function specialization_ to its proto ID. We map julia function
    # specializations to PProf Functions. We use a hash of the function for the key.
    funcs_map  = Dict{UInt64, UInt64}()
    functions = Vector{Function}()

    # NOTE: It's a bug to use the actual StackFrame itself as a key in a dictionary, since
    # different StackFrames can compare the same sometimes! 🙀 So we use its string
    # representation as the key. See: https://github.com/JuliaPerf/PProf.jl/issues/69
    locs_map  = Dict{String, UInt64}()
    locations = Vector{Location}()
    samples = Vector{Sample}()

    sample_type = ValueType[
        ValueType!("allocs", "count"), # Mandatory
        ValueType!("size", "bytes")
    ]
    period_type = ValueType!("heap", "bytes")
    drop_frames = isnothing(drop_frames) ? 0 : enter!(drop_frames)
    keep_frames = isnothing(keep_frames) ? 0 : enter!(keep_frames)

    function maybe_add_location(frame::StackFrame)::UInt64
        # See: https://github.com/JuliaPerf/PProf.jl/issues/69
        frame_key = string(frame)
        return get!(locs_map, frame_key) do
            loc_id = UInt64(length(locations) + 1)

            # Extract info from the location frame
            (function_name, file_name, line_number) =
                string(frame.func), string(frame.file), frame.line

            # Use a unique function id for the frame:
            function_key = method_instance_id(frame)

            # Decode the IP into information about this stack frame
            function_id = get!(funcs_map, function_key) do
                func_id = UInt64(length(functions) + 1)

                # Store the function in our functions dict
                local file
                simple_name = _escape_name_for_pprof(function_name)
                local full_name_with_args
                if frame.linfo !== nothing && frame.linfo isa Core.MethodInstance
                    linfo = frame.linfo::Core.MethodInstance
                    meth = linfo.def
                    file = string(meth.file)
                    io = IOBuffer()
                    Base.show_tuple_as_call(io, meth.name, linfo.specTypes)
                    full_name_with_args = _escape_name_for_pprof(String(take!(io)))
                    start_line = convert(Int64, meth.line)
                else
                    # frame.linfo either nothing or CodeInfo, either way fallback
                    file = string(frame.file)
                    full_name_with_args = _escape_name_for_pprof(string(frame.func))
                    start_line = convert(Int64, frame.line) # TODO: Get start_line properly
                end
                isempty(simple_name) && (simple_name = "[unknown function]")
                isempty(full_name_with_args) && (full_name_with_args = "[unknown function]")
                # WEIRD TRICK: By entering a separate copy of the string (with a
                # different string id) for the name and system_name, pprof will use
                # the supplied `name` *verbatim*, without pruning off the arguments.
                # So even when full_signatures == false, we want to generate two `enter!` ids.
                system_name = enter!(simple_name)
                if full_signatures
                    name = enter!(full_name_with_args)
                else
                    name = enter!(simple_name)
                end
                file = Base.find_source_file(file_name)
                file = file !== nothing ? file : file_name
                filename   = enter!(file)
                push!(functions, Function(func_id, name, system_name, filename, start_line))

                return func_id
            end

            push!(
                locations,
                Location(;id = loc_id, line=[Line(function_id, line_number)])
            )

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
        push!(samples, Sample(;location_id = location_ids, value = value, label = labels))
    end

    # If from_c=false funcs and locs should NOT contain C functions
    prof = PProfile(
        sample_type = sample_type,
        sample = samples,
        location = locations,
        var"#function" = functions,
        string_table = collect(keys(string_table)),
        drop_frames = drop_frames,
        keep_frames = keep_frames,
        period_type = period_type,
        period = period,
        # We default to allocs, since the Profile.Allocs code currently uniformly samples
        # accross allocations, so allocs is a representative profile, while size is not.
        default_sample_type = 1, # allocs
    )

    # Write to disk
    open(out, "w") do io
        ProtoBuf.encode(ProtoBuf.ProtoEncoder(io), prof)
    end

    if web
        PProf.refresh(webhost = webhost, webport = webport, file = out,
                      ui_relative_percentages = ui_relative_percentages,
        )
    end

    out
end

"""
    Allocs.@pprof ex
    Allocs.@pprof ex pr = (sample_rate = 1,) pp = (from_c = false,)

Allocation profiles the expression using `Allocs.@profile` and starts or restarts the `Allocs.pprof()` web UI.
pr is for Allocs.@profile arguments.
pp is for @pprof keyword arguments.
"""
macro pprof(ex, pr=(), pp=())
    esc(quote
        $Profile.Allocs.@profile $pr... $ex
        $(@__MODULE__).pprof(; $pp...)
    end)
end


end  # module Allocs
