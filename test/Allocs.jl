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

@noinline foo(x) = [x+x]

@testset "Multiple method specializations" begin
    # Warmup
    foo(1); foo(1.0)

    Profile.Allocs.clear(); @time Profile.Allocs.@profile sample_rate=1 (foo(1), foo(1.0))

    # Write the profile
    outf = PProf.Allocs.pprof(out=out, web=false)

    # Read the exported profile
    prof = open(io->decode(ProtoDecoder(io), PProf.perftools.profiles.Profile), outf, "r")

    # Test for both functions:
    @test in("foo(::Float64)", prof.string_table)
    @test in("foo(::Int64)", prof.string_table)

    # Test that they are both present in the locations table:
    int_str_idx = findfirst(==("foo(::Int64)"), prof.string_table) - 1
    float_str_idx = findfirst(==("foo(::Float64)"), prof.string_table) - 1

    int_func = findfirst(f->f.name == int_str_idx, prof.var"#function")
    float_func = findfirst(f->f.name == float_str_idx, prof.var"#function")

    int_loc = findfirst(l->l.line[1].function_id == int_func, prof.location)
    float_loc = findfirst(l->l.line[1].function_id == float_func, prof.location)

    @test int_loc !== nothing
    @test float_loc !== nothing
end

function load_prof_proto(file)
    @show file
    open(io->decode(ProtoDecoder(io), PProf.perftools.profiles.Profile), file, "r")
end

@testset "skip_julia_dispatch_frames" begin
    Profile.Allocs.clear();
    Profile.Allocs.@profile sample_rate=1 Base.inferencebarrier(foo)(1)
    args = (; out=tempname(), web=false)
    matches(r, proto) = any(s->occursin(r, s), proto.string_table)
    @test matches(r"jl_apply_generic", load_prof_proto(PProf.Allocs.pprof(;args..., skip_julia_dispatch_frames=false)))
    @test !matches(r"jl_apply_generic", load_prof_proto(PProf.Allocs.pprof(;args..., skip_julia_dispatch_frames=true)))
end
@testset "skip_gc_internal_frames" begin
    Profile.Allocs.clear();
    Profile.Allocs.@profile sample_rate=1 Base.inferencebarrier(foo)(1)
    args = (; out=tempname(), web=false)
    matches(r, proto) = any(s->occursin(r, s), proto.string_table)
    @test matches(r"maybe_record_alloc_to_profile", load_prof_proto(PProf.Allocs.pprof(;args..., skip_gc_internal_frames=false)))
    @test !matches(r"maybe_record_alloc_to_profile", load_prof_proto(PProf.Allocs.pprof(;args..., skip_gc_internal_frames=true)))
end



end  # module PProfAllocsTest
