module PProfAllocsTest

import PProf
import Profile
using ProtoBuf

using Test

const out = tempname()

@testset "basic profiling" begin
    Profile.Allocs.clear()
    Profile.Allocs.@profile sample_rate=1.0 begin
        # Profile compilation
        @eval foo(x,y) = x * y + y / x
        @eval foo(2, 3)
    end

    # Write the profile
    outf = PProf.Allocs.pprof(out=out, web=false)

    # Read the exported profile
    prof = open(io->decode(ProtoDecoder(io), PProf.perftools.profiles.Profile), outf, "r")

    # Verify that we exported stack trace samples:
    @test length(prof.sample) > 0
    # Verify that we exported frame information
    @test length(prof.location) > 0
    @test length(prof.var"#function") > 0
    @test length(prof.sample_type) >= 2  # allocs and size

end

end  # module PProfAllocsTest
