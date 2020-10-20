module PProf

export pprof, @pprof

using Profile
using ProtoBuf
using OrderedCollections
import pprof_jll

using Profile: clear

"""
    PProf.clear()

Alias for `Profile.clear()`
"""
clear

include(joinpath("..", "lib", "perftools.jl"))

import .perftools.profiles: ValueType, Sample, Function,
                            Location, Line
const PProfile = perftools.profiles.Profile

const proc = Ref{Union{Base.Process, Nothing}}(nothing)

"""
    _enter!(dict::OrderedDict{T, Int64}, key::T) where T

Resolves from `key` to the index (zero-based) in the dict.
Useful for the Strings table

NOTE: We must use Int64 throughout this package (regardless of system word-size) b/c the
proto file specifies 64-bit integers.
"""
function _enter!(dict::OrderedDict{T, Int64}, key::T) where T
    if haskey(dict, key)
        return dict[key]
    else
        l = Int64(length(dict))
        dict[key] = l
        return l
    end
end

using Base.StackTraces: StackFrame

# TODO:
# - Mappings

"""
    pprof([data, [lidict]];
            web = true, webhost = "localhost", webport = 57599,
            out = "profile.pb.gz", from_c = true, drop_frames = "", keep_frames = "",
            ui_relative_percentages = true, sampling_delay = nothing,
         )

Fetches the collected `Profile` data, exports to the `pprof` format, and (optionally) opens
a `pprof` web-server for interactively viewing the results.

If `web=true`, the web-server is opened in the background. Re-running `pprof()` will refresh
the web-server to use the new output.

If you manually edit the output file, `PProf.refresh()` will refresh the server without
overwriting the output file. `PProf.kill()` will kill the server.

You can also use `PProf.refresh(file="...")` to open a new file in the server.

# Arguments:
- `data::Vector{UInt}`: The data provided by `Profile.retrieve()` [optional].
- `lidict::Dict`: The lookup dictionary provided by `Profile.retrieve()` [optional].
    - Note that you need both the `data` and the `lidict` returned from
      `Profile.retrieve()` in order to export profiling data between julia processes.

# Keyword Arguments
- `sampling_delay::UInt64`: The period between samples in nanoseconds [optional].
- `web::Bool`: Whether to launch the `go tool pprof` interactive webserver for viewing results.
- `webhost::AbstractString`: If using `web`, which host to launch the webserver on.
- `webport::Integer`: If using `web`, which port to launch the webserver on.
- `out::String`: Filename for output.
- `from_c::Bool`: If `false`, exclude frames that come from from_c. Defaults to `true`.
- `drop_frames`: frames with function_name fully matching regexp string will be dropped from the samples,
                 along with their successors.
- `keep_frames`: frames with function_name fully matching regexp string will be kept, even if it matches drop_functions.
- `ui_relative_percentages`: Passes `-relative_percentages` to pprof. Causes nodes
  ignored/hidden through the web UI to be ignored from totals when computing percentages.
"""
function pprof(data::Union{Nothing, Vector{UInt}} = nothing,
               lidict::Union{Nothing, Dict} = nothing;
               sampling_delay::Union{Nothing, UInt64} = nothing,
               web::Bool = true,
               webhost::AbstractString = "localhost",
               webport::Integer = 57599,
               out::AbstractString = "profile.pb.gz",
               from_c::Bool = true,
               drop_frames::Union{Nothing, AbstractString} = nothing,
               keep_frames::Union{Nothing, AbstractString} = nothing,
               ui_relative_percentages::Bool = true,
            )
    if data === nothing
        data = copy(Profile.fetch())
    end
    lookup = lidict
    if lookup === nothing
        lookup = Profile.getdict(data)
    end
    if sampling_delay === nothing
        sampling_delay = ccall(:jl_profile_delay_nsec, UInt64, ())
    end
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
    # Functions need a uid, we'll use the pointer for the method instance
    seen_funcs = Set{UInt64}()
    funcs = Dict{UInt64, Function}()

    seen_locs = Set{UInt64}()
    locs  = Dict{UInt64, Location}()
    locs_from_c  = Dict{UInt64, Bool}()

    sample_type = [
        ValueType!("events",      "count"), # Mandatory
        ValueType!("stack_depth", "count")
    ]

    prof = PProfile(
        sample = [], location = [], _function = [],
        mapping = [], string_table = [],
        sample_type = sample_type, default_sample_type = 1, # events
        period = sampling_delay, period_type = ValueType!("cpu", "nanoseconds")
    )

    if drop_frames !== nothing
        prof.drop_frames = enter!(drop_frames)
    end
    if keep_frames !== nothing
        prof.keep_frames = enter!(keep_frames)
    end

    # start decoding backtraces
    location_id = Vector{eltype(data)}()
    lastwaszero = true

    for ip in data
        # ip == 0x0 is the sentinel value for finishing a backtrace, therefore finising a sample
        if ip == 0
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

        # A backtrace consists of a set of IP (Instruction Pointers), each IP points
        # a single line of code and `litrace` has the necessary information to decode
        # that IP to a specific frame (or set of frames, if inlining occured).

        # if we have already seen this IP avoid decoding it again
        if ip in seen_locs
            # Only keep C frames if from_c=true
            if (from_c || !locs_from_c[ip])
                push!(location_id, ip)
            end
            continue
        end
        push!(seen_locs, ip)

        # Decode the IP into information about this stack frame (or frames given inlining)
        location = Location(;id = ip, address = ip, line=[])
        location_from_c = true
        # Will have multiple frames if frames were inlined (the last frame is the "real
        # function", the inlinee)
        for frame in lookup[ip]
            # ip 0 is reserved
            frame.pointer == 0 && continue

            # if any of the frames is not from_c the entire location is not from_c
            location_from_c &= frame.from_c

            # `func_id` - Uniquely identifies this function (a method instance in julia, and
            # a function in C/C++).
            # Note that this should be unique even for several different functions all
            # inlined into the same frame.
            func_id = if frame.linfo !== nothing
                hash(frame.linfo)
            else
                hash((frame.func, frame.file, frame.line))
            end
            push!(location.line, Line(function_id = func_id, line = frame.line))

            # Known function
            func_id in seen_funcs && continue
            push!(seen_funcs, func_id)

            # Store the function in our functions dict
            funcProto = Function()
            funcProto.id = func_id
            file = nothing
            if frame.linfo !== nothing && frame.linfo isa Core.MethodInstance
                linfo = frame.linfo::Core.MethodInstance
                meth = linfo.def
                file = string(meth.file)
                funcProto.name       = enter!(string(meth.module, ".", meth.name))
                funcProto.start_line = convert(Int64, meth.line)
            else
                # frame.linfo either nothing or CodeInfo, either way fallback
                file = string(frame.file)
                funcProto.name = enter!(string(frame.func))
                funcProto.start_line = convert(Int64, frame.line) # TODO: Get start_line properly
            end
            file = Base.find_source_file(file)
            funcProto.filename   = enter!(file)
            funcProto.system_name = funcProto.name
            # Only keep C functions if from_c=true
            if (from_c || !frame.from_c)
                funcs[func_id] = funcProto
            end
        end
        locs_from_c[ip] = location_from_c
        # Only keep C frames if from_c=true
        if (from_c || !location_from_c)
            locs[ip] = location
            push!(location_id, ip)
        end
    end

    # Build Profile
    prof.string_table = collect(keys(string_table))
    # If from_c=false funcs and locs should NOT contain C functions
    prof._function = collect(values(funcs))
    prof.location  = collect(values(locs))

    # Write to disk
    open(out, "w") do io
        writeproto(io, prof)
    end

    if web
        refresh(webhost = webhost, webport = webport, file = out,
            ui_relative_percentages = ui_relative_percentages)
    end

    out
end

"""
    refresh(; webhost = "localhost", webport = 57599, file = "profile.pb.gz",
            ui_relative_percentages = true)

Start or restart the go pprof webserver.

- `webhost::AbstractString`: Which host to launch the webserver on.
- `webport::Integer`: Which port to launch the webserver on.
- `file::String`: Profile file to open.
- `ui_relative_percentages::Bool`: Passes `-relative_percentages` to pprof. Causes nodes
  ignored/hidden through the web UI to be ignored from totals when computing percentages.
"""
function refresh(; webhost::AbstractString = "localhost",
                   webport::Integer = 57599,
                   file::AbstractString = "profile.pb.gz",
                   ui_relative_percentages::Bool = true,
                )

    if proc[] === nothing
        # The first time, register an atexit hook to kill the web server.
        atexit(PProf.kill)
    else
        # On subsequent calls, restart the pprof web server.
        Base.kill(proc[])
    end

    relative_percentages_flag = ui_relative_percentages ? "-relative_percentages" : ""

    proc[] = pprof_jll.pprof() do pprof_path
        open(pipeline(`$pprof_path -http=$webhost:$webport $relative_percentages_flag $file`))
    end
end

"""
    pprof_kill()

Kills the pprof server if running.
"""
function kill()
    if proc[] !== nothing
        Base.kill(proc[])
        proc[] = nothing
    end
end


"""
    @pprof ex

Profiles the expression using `@profile` and starts or restarts the `pprof()` web UI with
default arguments.
"""
macro pprof(ex)
    esc(quote
        $Profile.@profile $ex
        $(@__MODULE__).pprof()
    end)
end

include("flamegraphs.jl")

end # module
