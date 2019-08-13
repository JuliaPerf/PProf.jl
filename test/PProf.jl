module PProfTest

using PProf

using Test
using Profile
using ProtoBuf

const out = tempname()

function foo(n, a, out=[])
    # make this expensive to ensure it's sampled
    for i in 1:n
        push!(out, i*a)
    end
end

@testset "empty output" begin
    Profile.clear()
    # Function doesn't error if no Profile recorded
    @test (pprof(out=out, web=false); true)
end

@testset "export basic profile" begin
    Profile.clear()

    let x = 1
        @profile for _ in 1:10000; x += 1; end
        sleep(2)
    end

    # Cache profile output to test that it isn't changed
    _prior_profile_output = Profile.retrieve()

    # Write the profile
    pprof(out=out, web=false)

    # Read the exported profile
    prof = open(io->readproto(io, PProf.perftools.profiles.Profile()), out, "r")

    # Verify that we exported stack trace samples:
    @test length(prof.sample) > 0
    # Verify that we exported frame information
    @test length(prof.location) > 0
    @test length(prof._function) > 0

    # Test that we didn't modify the Profile output
    Profile.retrieve() == _prior_profile_output
end

function load_prof_proto(file)
    @show file
    open(io->readproto(io, PProf.perftools.profiles.Profile()), file, "r")
end

@testset "with_c" begin
    Profile.clear()

    let arr = []
        @profile foo(1000000, 5, arr)
        sleep(2)
    end
    data = Profile.fetch()

    # Write a profile that includes C function frames
    with_c = load_prof_proto(pprof(data, out=tempname(), web=false, from_c = true))

    # Write a profile that excludes C function frames
    without_c = load_prof_proto(pprof(data, out=tempname(), web=false, from_c = false))

    # Test that C frames were excluded
    @test length(with_c.sample) == length(without_c.sample)
    @test length(with_c.location) > length(without_c.location)
    @test length(with_c._function) > length(without_c._function)
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

end # module
