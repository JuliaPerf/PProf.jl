import AbstractTrees
using FlameGraphs

using FlameGraphs: Node, NodeData
using Base.StackTraces: StackFrame
using Profile: StackFrameTree

function pprof(fg::Node{NodeData},
    period::Union{Nothing, UInt64} = nothing;
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
    if period === nothing
        period = ccall(:jl_profile_delay_nsec, UInt64, ())
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

    function _register_function(funcs, id, linfo, frame)
        # Known function
        haskey(funcs, id) && return

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
        # WEIRD TRICK: By entering a *different value* for the name and system_name, pprof
        # will use the supplied `name` *verbatim*, without pruning off the arguments. So
        # even when full_signatures == false, we want to generate two `enter!` ids. So we
        # achieve that by entering an _empty_ name for the system_name, so that pprof will
        # use the `name` as provided.
        system_name = enter!("")
        if full_signatures
            name = enter!(full_name_with_args)
        else
            name = enter!(simple_name)
        end
        file = Base.find_source_file(file)
        filename = enter!(file)

        # Only keep C functions if from_c=true
        if (from_c || !frame.from_c)
            funcs[id] = Function(id, name, system_name, filename, start_line)
        end
    end

    # Setup:
    enter!("")  # NOTE: pprof requires first entry to be ""
    # Functions need a uid, we'll use the pointer for the method instance
    seen_funcs = Set{UInt64}()
    funcs = Dict{UInt64, Function}()

    seen_locs = Set{UInt64}()
    locs = Dict{UInt64, Location}()
    locs_from_c = Dict{UInt64, Bool}()

    sample_type = [
        ValueType!("events", "count"), # Mandatory
        ValueType!("cpu", "nanoseconds"),
    ]

    period_type = ValueType!("cpu", "nanoseconds")
    drop_frames = isnothing(drop_frames) ? 0 : enter!(drop_frames)
    keep_frames = isnothing(keep_frames) ? 0 : enter!(keep_frames)
    samples = Vector{Sample}()

    # start decoding backtraces
    lastwaszero = true

    # Do a top-down walk of the flame graph from root to leaves.
    # At each node, we enter a "sample" to flame graph if there is any time not covered by
    # its children. That is, if the exclusive time of any node is non-zero.
    # AND, we want to enter each "section" of exclusive time as a separate sample, in case
    # that allows PProf to do any ordering in its display.
    # So, the algorithm is that we enter a sample for every gap between the spans of the
    # children.
    function emit_tree(node)
        span = node.data.span
        start = span.start
        stop = span.stop
        child = node.child
        if child === node
            # We're a leaf node, so just emit this node directly, and then we're done.
            emit_stack_sample(child, start:stop)
            return
        end
        while true  # break when we've exhausted the children
            cspan = child.data.span
            if cspan.start > start
                # We know there's a gap before the next child starts
                # So we emit a frame for `node`
                emit_stack_sample(node, start:cspan.start-1)
            end
            # Now emit the child node
            emit_tree(child)

            start = cspan.stop + 1

            if child.sibling === child break end
            child = child.sibling
        end
        # If there was still time after the last child, that's another gap that we can emit.
        cspan = child.data.span
        if stop > cspan.stop
            # We know there's a gap before the next child starts
            # So we emit a frame for `node`
            emit_stack_sample(node, start:stop)
        end
    end

    function emit_stack_sample(leaf, span)
        location_id = Vector{Any}()

        # Walk back up the callstack, collecting all stack traces along the way, building
        # up a stack trace for this span.
        node = leaf
        while true  # do-while node.parent === node    -- this makes sure we get the top node.
            data = node.data

            if from_c || !data.sf.from_c
                frame = data.sf
                # Don't use the ip pointer, because this data is provided by the user and isn't
                # guaranteed to be unique.
                id = hash(frame)

                location = Location(;id = id, address = frame.pointer)
                push!(location_id, id)
                locs[id] = location
                linfo = data.sf.linfo

                # If the function comes with a `linfo` (meaning the profile was generated
                # in this process), we include it in the hash. If not, it's will be
                # `nothing`, which is okay to hash.
                # We include all of these in the hash though because in some contexts (such
                # as `@snoopi_deep` profiles), two frames with the same `linfo` might have
                # different func name.
                func_id = hash((frame.func, frame.file, frame.line, frame.linfo))

                _register_function(funcs, func_id, linfo, frame)
                push!(location.line, Line(function_id = func_id, line = frame.line))
            end

            if node.parent === node
                break
            end

            node = node.parent
        end

        value = [
            1, # Number of samples in this frame.
            60000000, # CPU ns (TODO: real number)
        ]
        push!(samples, Sample(;location_id, value))

    end

    emit_tree(fg)

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
        period = period,
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

