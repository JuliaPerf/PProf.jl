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
    ValueType!(_type, unit) = ValueType(_type = enter!(_type), unit = enter!(unit))

    function _register_function(funcs, id, linfo, frame)
        # Known function
        haskey(funcs, id) && return

        # Store the function in our functions dict
        funcProto = Function()
        funcProto.id = id
        file = nothing
        if linfo !== nothing && linfo isa Core.MethodInstance
            meth = linfo.def
            file = string(meth.file)
            # HACK: Apparently proto doesn't escape func names with `"` in them ... >.<
            funcProto.name       = enter!(repr(string(meth.module, ".", meth.name))[2:end-1])
            funcProto.start_line = convert(Int64, meth.line)
        else
            # frame.linfo either nothing or CodeInfo, either way fallback
            # (This could be because we are `from_c`)
            file = string(frame.file)
            # HACK: Apparently proto doesn't escape func names with `"` in them ... >.<
            funcProto.name = enter!(repr(string(frame.func))[2:end-1])
            funcProto.start_line = convert(Int64, frame.line) # TODO: Get start_line properly
        end
        file = Base.find_source_file(file)
        funcProto.filename   = enter!(file)
        funcProto.system_name = funcProto.name
        # Only keep C functions if from_c=true
        if (from_c || !frame.from_c)
            funcs[id] = funcProto
        end
    end

    # Setup:
    enter!("")  # NOTE: pprof requires first entry to be ""
    # Functions need a uid, we'll use the pointer for the method instance
    seen_funcs = Set{UInt64}()
    funcs = Dict{UInt64, Function}()

    seen_locs = Set{UInt64}()
    locs  = Dict{UInt64, Location}()
    locs_from_c  = Dict{UInt64, Bool}()

    sample_type = [
        ValueType!("cpu",      "nanoseconds"), # Mandatory
    ]

    prof = PProfile(
        sample = [], location = [], _function = [],
        mapping = [], string_table = [],
        sample_type = sample_type, default_sample_type = 1, # events
        period = period, period_type = ValueType!("cpu", "nanoseconds")
    )

    if drop_frames !== nothing
        prof.drop_frames = enter!(drop_frames)
    end
    if keep_frames !== nothing
        prof.keep_frames = enter!(keep_frames)
    end

    # start decoding backtraces
    lastwaszero = true

    for leaf in AbstractTrees.Leaves(fg)

        location_id = Vector{Any}()

        node = leaf
        while node.parent != node
            data = node.data

            if !from_c && data.sf.from_c
                node = node.parent
                continue
            end

            frame = data.sf
            id = if frame.pointer !== UInt64(0x0)
                frame.pointer
            else
                hash(frame)
            end

            location = Location(;id = id, address = id, line=[])
            push!(location_id, id)
            locs[id] = location
            linfo = data.sf.linfo

            func_id = if frame.linfo !== nothing
                hash(frame.linfo)
            else
                hash((frame.func, frame.file, frame.line))
            end

            _register_function(funcs, func_id, linfo, frame)
            push!(location.line, Line(function_id = func_id, line = frame.line))

            node = node.parent
        end

        value = [
            length(leaf.data.span), # time duration (nanoseconds?)
        ]
        push!(prof.sample, Sample(;location_id = location_id, value = value))

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


