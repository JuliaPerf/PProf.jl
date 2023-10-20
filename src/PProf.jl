module PProf

export pprof, @pprof

using Profile
using ProtoBuf
using OrderedCollections
using CodecZlib
import pprof_jll

using Profile: clear

"""
    PProf.clear()

Alias for `Profile.clear()`
"""
clear

include(joinpath("..", "lib", "perftools", "perftools.jl"))

import .perftools.profiles: ValueType, Sample, Function,
                            Location, Line, Label
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
    return get!(dict, key, Int64(length(dict)))
end

using Base.StackTraces: StackFrame

# TODO:
# - Mappings

"""
    pprof([data, [lidict]];
            web = true, webhost = "localhost", webport = 57599,
            out = "profile.pb.gz", from_c = true, full_signatures = true, drop_frames = "",
            keep_frames = "", ui_relative_percentages = true, sampling_delay = nothing,
         )
    pprof(FlameGraphs.flamegraph(); kwargs...)

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
- `flamegraph`: PProf also accepts profile data passed as a `FlameGraphs.jl` graph object.

# Keyword Arguments
- `sampling_delay::UInt64`: The period between samples in nanoseconds [optional].
- `web::Bool`: Whether to launch the `go tool pprof` interactive webserver for viewing results.
- `webhost::AbstractString`: If using `web`, which host to launch the webserver on.
- `webport::Integer`: If using `web`, which port to launch the webserver on.
- `out::String`: Filename for output.
- `from_c::Bool`: If `false`, exclude frames that come from from_c. Defaults to `true`.
- `full_signatures::Bool`: If `true`, methods are printed as signatures with full argument
                           types. If `false`, as only names. E.g. `eval(::Module, ::Any)` vs `eval`.
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
               full_signatures::Bool = true,
               drop_frames::Union{Nothing, AbstractString} = nothing,
               keep_frames::Union{Nothing, AbstractString} = nothing,
               ui_relative_percentages::Bool = true,
            )
    has_meta = false
    if data === nothing
        data = if isdefined(Profile, :has_meta)
            copy(Profile.fetch(include_meta = true))
            has_meta = true
        else
            copy(Profile.fetch())
        end
    elseif isdefined(Profile, :has_meta)
        has_meta = Profile.has_meta(data)
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
    ValueType!(_type, unit) = ValueType(enter!(_type), enter!(unit))
    Label!(key, value, unit) = Label(key = enter!(key), num = value, num_unit = enter!(unit))
    Label!(key, value) = Label(key = enter!(key), str = enter!(string(value)))

    # Setup:
    enter!("")  # NOTE: pprof requires first entry to be ""
    # Functions need a uid, we'll use the pointer for the method instance
    seen_funcs = Set{UInt64}()
    funcs = Dict{UInt64, Function}()

    seen_locs = Set{UInt64}()
    locs  = Dict{UInt64, Location}()
    locs_from_c  = Dict{UInt64, Bool}()
    samples = Vector{Sample}()

    sample_type = [
        ValueType!("events",      "count"), # Mandatory
    ]

    period_type = ValueType!("cpu", "nanoseconds")
    drop_frames = isnothing(drop_frames) ? 0 : enter!(drop_frames)
    keep_frames = isnothing(keep_frames) ? 0 : enter!(keep_frames)
    # start decoding backtraces
    location_id = Vector{eltype(data)}()

    # All samples get the same value for the CPU profile.
    value = [
        1,      # events
    ]

    idx = length(data)
    meta = nothing
    while idx > 0
        if has_meta && Profile.is_block_end(data, idx)
            if meta !== nothing
                # Finish last block
                push!(samples, Sample(;location_id = reverse!(location_id), value = value, label = meta))
                location_id = Vector{eltype(data)}()
            end

            # Consume all of the metadata entries in the buffer, and then position the IP
            # at the idx for the actual ip.
            thread_sleeping = data[idx - Profile.META_OFFSET_SLEEPSTATE] - 1  # "Sleeping" is recorded as 1 or 2, to avoid 0s, which indicate end-of-block.
            cpu_cycle_clock = data[idx - Profile.META_OFFSET_CPUCYCLECLOCK]
            taskid = data[idx - Profile.META_OFFSET_TASKID]
            threadid = data[idx - Profile.META_OFFSET_THREADID]

            meta = Label[
                Label!("thread_sleeping", thread_sleeping != 0),
                Label!("cycle_clock", cpu_cycle_clock, "nanoseconds"),
                Label!("taskid", taskid),
                Label!("threadid", threadid),
            ]
            idx -= (Profile.nmeta + 2)  # skip all the metas, plus the 2 nulls that end a block.
            continue
        elseif !has_meta && data[idx] == 0
            # ip == 0x0 is the sentinel value for finishing a backtrace (when meta is disabled), therefore finising a sample
            # On some platforms, we sometimes get two 0s in a row for some reason...
            if idx > 1 && data[idx-1] == 0
                idx -= 1
            end
            # Finish last block
            push!(samples, Sample(;location_id = reverse!(location_id), value = value, label = meta))
            location_id = Vector{eltype(data)}()
        end
        ip = data[idx]
        idx -= 1

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
        location = Location(;id = ip, address = ip)
        location_from_c = true
        # Will have multiple frames if frames were inlined (the last frame is the "real
        # function", the inlinee)
        for frame in lookup[ip]
            # ip 0 is reserved
            frame.pointer == 0 && continue

            # if any of the frames is not from_c the entire location is not from_c
            location_from_c &= frame.from_c

            # Use a unique function id for the frame:
            func_id = method_instance_id(frame)
            push!(location.line, Line(function_id = func_id, line = frame.line))

            # Known function
            func_id in seen_funcs && continue
            push!(seen_funcs, func_id)

            # Store the function in our functions dict
            file = nothing
            simple_name = _escape_name_for_pprof(frame.func)
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
            file = Base.find_source_file(file)
            filename = enter!(file)
            # Only keep C functions if from_c=true
            if (from_c || !frame.from_c)
                funcs[func_id] = Function(func_id, name, system_name, filename, start_line)
            end
        end
        locs_from_c[ip] = location_from_c
        # Only keep C frames if from_c=true
        if (from_c || !location_from_c)
            locs[ip] = location
            push!(location_id, ip)
        end
    end

    # If from_c=false funcs and locs should NOT contain C functions
    prof = PProfile(
        sample_type = sample_type,
        sample = samples,
        location =  collect(values(locs)),
        var"#function" = collect(values(funcs)),
        string_table = collect(keys(string_table)),
        drop_frames = drop_frames,
        keep_frames = keep_frames,
        period_type = period_type,
        period = sampling_delay,
        default_sample_type = 1, # events
    )

    # Write to disk
    io = GzipCompressorStream(open(out, "w"))
    try
        ProtoBuf.encode(ProtoBuf.ProtoEncoder(io), prof)
    finally
        close(io)
    end

    if web
        refresh(webhost = webhost, webport = webport, file = out,
            ui_relative_percentages = ui_relative_percentages)
    end

    out
end

function _escape_name_for_pprof(name)
    # HACK: Apparently proto doesn't escape func names with `"` in them ... >.<
    # TODO: Remove this hack after https://github.com/google/pprof/pull/564
    quoted = repr(string(name))
    quoted = quoted[2:thisind(quoted, end-1)]
    return quoted
end
function method_instance_id(frame)
    # `func_id` - Uniquely identifies this function (a method instance in julia, and
    # a function in C/C++).
    # Note that this should be unique even for several different functions all
    # inlined into the same frame.
    func_id = if frame.linfo !== nothing
        hash(frame.linfo)
    else
        hash((frame.func, frame.file, frame.line, frame.inlined))
    end
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
    PProf.kill()

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

if isdefined(Profile, :Allocs)  # PR https://github.com/JuliaLang/julia/pull/42768
    include("Allocs.jl")
end


# Precompile as much as possible, so that profiling doesn't end up measuring our own
# compilation.
function __init__()
    precompile(pprof, ()) || error("precompilation of package functions is not supposed to fail")
    precompile(kill, ()) || error("precompilation of package functions is not supposed to fail")
    precompile(refresh, ()) || error("precompilation of package functions is not supposed to fail")
end
end # module
