module PProfTest

using PProf

using Test
using Profile
using ProtoBuf
using CodecZlib

const out = tempname() * ".pb.gz"

@noinline function foo(n, a, out=[])
    # make this expensive to ensure it's sampled
    for i in 1:n
        push!(out, i*a)
    end
end

@testset "empty output" begin
    Profile.clear()
    # Function doesn't error if no Profile recorded
    rm(out, force=true)
    @test (pprof(out=out, web=false); true)
    @test ispath(out)
end

@testset "export basic profile" begin
    Profile.clear()

    while Profile.len_data() == 0
        @profile for i in 1:10000
            # Profile compilation
            foo_sym = Symbol("foo$i)")
            @eval $foo_sym(x,y) = x * y + x / y
            @eval $foo_sym($i,3)
        end
    end

    # Cache profile output to test that it isn't changed
    _prior_profile_output = Profile.retrieve()

    # Write the profile
    outf = pprof(out=out, web=false)

    # Read the exported profile
    io = GzipDecompressorStream(open(outf, "r"))
    prof = try
        decode(ProtoDecoder(io), PProf.perftools.profiles.Profile)
    finally
        close(io)
    end

    # Verify that we exported stack trace samples:
    @test length(prof.sample) > 0
    # Verify that we exported frame information
    @test length(prof.location) > 0
    @test length(prof.var"#function") > 0

    # Test that we didn't modify the Profile output
    Profile.retrieve() == _prior_profile_output
end

function load_prof_proto(file)
    @show file
    open(io->decode(ProtoDecoder(GzipDecompressorStream(io)), PProf.perftools.profiles.Profile), file, "r")
end

@testset "with_c" begin
    Profile.clear()

    let arr = []
        while Profile.len_data() == 0
            @profile foo(1000000, 5, arr)
        end
        sleep(2)
    end
    for i in 1:2
        if i == 1
            data = Profile.fetch(include_meta = true)
            args = (data,)
        else
            data,lidict = Profile.retrieve(include_meta = true)
            args = (data, lidict)
        end

        # Write a profile that includes C function frames
        with_c = load_prof_proto(pprof(args..., out=tempname(), web=false, from_c = true))

        # Write a profile that excludes C function frames
        without_c = load_prof_proto(pprof(args..., out=tempname(), web=false, from_c = false))

        # Test that C frames were excluded
        @test length(with_c.sample) == length(without_c.sample)
        @test length(with_c.location) > length(without_c.location)
        @test length(with_c.var"#function") > length(without_c.var"#function")
    end
end

@testset "full_signatures" begin
    Profile.clear()
    while Profile.len_data() == 0
        # Use @eval and @time to make sure we don't interpret foo, and thus break the full-signature test
        @profile @eval @time foo(1000000, 5, [])
    end
    @test "foo" in load_prof_proto(pprof(out=tempname(), web=false, full_signatures = false)).string_table

    string_data = load_prof_proto(pprof(out=tempname(), web=false, full_signatures = true)).string_table
    found_full_sig = any(occursin.(Regex("^foo\\(::$Int, ::$Int, ::(Vector|Array)"), string_data))
    @test found_full_sig
    # Log what we got instead
    if !found_full_sig
        println("expected foo(...), but got:")
        @show string_data
    end
end

@testset "drop_frames/keep_frames" begin
    @test load_prof_proto(pprof(out=tempname(), web=false, drop_frames = "foo")).drop_frames != 0
    @test load_prof_proto(pprof(out=tempname(), web=false, keep_frames = "foo")).keep_frames != 0
end

@testset "@pprof macro" begin

    @pprof foo(10000, 5, [])

    @test PProf.proc[] !== nothing
    @test process_running(PProf.proc[])

    PProf.kill()
    @test PProf.proc[] === nothing

    @test isfile("profile.pb.gz")
    rm("profile.pb.gz")
end

@testset "subprocess refresh" begin

    @pprof foo(10000, 5, [])

    current_proc = PProf.proc[]
    @test process_running(current_proc)

    PProf.refresh()
    sleep(1)

    @test process_running(PProf.proc[])
    @test process_exited(current_proc)
end

@testset "subprocess kill" begin

    @pprof foo(10000, 5, [])

    current_proc = PProf.proc[]
    @test process_running(current_proc)

    PProf.kill()
    sleep(1)

    @test process_exited(current_proc)
    @test PProf.proc[] === nothing
    @test isfile("profile.pb.gz")
    rm("profile.pb.gz")
end

@testset "enforce correct output file extension (.pb.gz)" begin
    dir = mktempdir()
    @test basename(pprof(out="$dir/test")) == "test.pb.gz"
    @test basename(pprof(out="$dir/test.pb.gz")) == "test.pb.gz"

    @test_throws AssertionError pprof(out="$dir/")  # directory path with no file throws err
end

end # module
