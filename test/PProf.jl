module PProfTest

using PProf

using Test
using Profile
using ProtoBuf

const out = tempname()

@testset "empty output" begin
    Profile.clear()
    # Function doesn't error if no Profile recorded
    @test (pprof(out=out); true)
end

@testset "export basic profile" begin
    Profile.clear()

    let x = 1
        @profile for _ in 1:10000; x += 1; end
    end

    # Cache profile output to test that it isn't changed
    _prior_profile_output = Profile.retrieve()

    # Write the profile
    pprof(out=out)

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

    function foo(n, a, out=[])
        # make this expensive to ensure it's sampled
        for i in 1:n
            push!(out, i*a)
        end
    end
    let arr = []
        @profile foo(10000, 5, arr)
    end

    # Write a profile that includes C function frames
    with_c = load_prof_proto(pprof(out=tempname(), from_c = true))

    # Write a profile that excludes C function frames
    without_c = load_prof_proto(pprof(out=tempname(), from_c = false))

    # Test that C frames were excluded
    @test_broken length(with_c.sample) == length(without_c.sample)
    @test_broken length(with_c._function) > length(without_c._function)
    @test_broken length(with_c.location) > length(without_c.location)
end

@testset "drop_frames" begin
    Profile.clear()

    function foo(n, a, out=[])
        # make this expensive to ensure it's sampled
        for i in 1:n
            push!(out, i*a)
        end
    end
    let arr = []
        @profile foo(10000, 5, arr)
    end

    allframes = load_prof_proto(pprof(out=tempname()))

    # SANITY CHECK
    allframes2 = load_prof_proto(pprof(out=tempname()))

    @test_broken length(allframes.sample) == length(allframes2.sample)
    @test_broken length(allframes._function) == length(allframes2._function)
    @test_broken length(allframes.location) == length(allframes2.location)

    # Write a profile that dropped frames
    droppedfoo = load_prof_proto(pprof(out=tempname(), drop_frames = "foo"))

    # Test that C frames were excluded
    @test_broken length(allframes.sample) == length(droppedfoo.sample)
    @test_broken length(allframes._function) > length(droppedfoo._function)
    @test_broken length(allframes.location) > length(droppedfoo.location)
end

end
