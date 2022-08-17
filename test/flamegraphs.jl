module PProfFlameGraphsTest

using PProf

using Test
using Profile
using ProtoBuf

# Test interactions with FlameGraphs package
using FlameGraphs

const out = tempname() * ".pb.gz"

function foo(n, a, out=[])
    # make this expensive to ensure it's sampled
    for i in 1:n
        push!(out, i*a)
    end
end

@testset "empty output" begin
    Profile.clear()
    # Function doesn't error if no Profile recorded
    fg = flamegraph()
    rm(out, force=true)
    @test (pprof(fg, out=out, web=false); true)
    @test ispath(out)
end

@testset "export basic profile" begin
    Profile.clear()

    let x = 1
        @profile for _ in 1:1000000; x += 1; end
        sleep(2)
    end

    # Collect the profile via FlameGraphs
    fg = flamegraph()

    # Write the profile
    outf = pprof(fg, out=out, web=false)

    # Read the exported profile
    fg_prof = open(io->decode(ProtoDecoder(io), PProf.perftools.profiles.Profile), outf, "r")

    # Verify that we exported stack trace samples:
    @test length(fg_prof.sample) > 0
    # Verify that we exported frame information
    @test length(fg_prof.location) > 0
    @test length(fg_prof.var"#function") > 0

end

function load_prof_proto(file)
    @show file
    open(io->decode(ProtoDecoder(io), PProf.perftools.profiles.Profile), file, "r")
end

@testset "with_c" begin
    Profile.clear()

    let arr = []
        @profile foo(1000000, 5, arr)
        sleep(2)
    end

    fg = flamegraph(C=true)

    # Write a profile that includes C function frames
    with_c = load_prof_proto(pprof(fg, out=tempname(), web=false, from_c = true))

    # Write a profile that excludes C function frames
    without_c = load_prof_proto(pprof(fg, out=tempname(), web=false, from_c = false))

    # Test that C frames were excluded
    @test length(with_c.sample) == length(without_c.sample)
    @test length(with_c.location) > length(without_c.location)
    @test length(with_c.var"#function") > length(without_c.var"#function")
end

@testset "drop_frames/keep_frames" begin
    fg = flamegraph()
    @test load_prof_proto(pprof(fg, out=tempname(), web=false, drop_frames = "foo")).drop_frames != 0
    @test load_prof_proto(pprof(fg, out=tempname(), web=false, keep_frames = "foo")).keep_frames != 0
end

end # module