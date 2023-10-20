# This file will test that your changes produce the same profiles as it did on main.
# It can be a bit hard to tell if a change is going to affect the profiles or not, so this
# file can act as a sanity test.
# It requires you to have committed your changes before running.

# Here is an example of what a failure looks like, where I purposefully reintroduced the bug
# fixed in #70. You can see that the bug is that some method instances have been incorrectly
# replaced with other methods of the same function:
#=
Main binary filename not available.
Alloc Profiles golden testing: Test Failed at /Users/nathandaly/.julia/dev/PProf/test/golden/regression_test.jl:25
  Expression: nodiff
Stacktrace:
 [1] macro expansion
   @ ~/builds/julia-1.8/usr/share/julia/stdlib/v1.8/Test/src/Test.jl:464 [inlined]
 [2] compare_profiles(name::String)
   @ Main ~/.julia/dev/PProf/test/golden/regression_test.jl:25
┌ Info: Got diff!:
│ Type: allocs
│ Showing nodes accounting for 0, 0% of 1355 total
│       flat  flat%   sum%        cum   cum%
│          0     0%     0%          1 0.074%  Core.Compiler.IdDict{Int64, Int64}(::Core.Compiler.Generator{Core.Compiler.Iterators.Filter{Core.Compiler.var\"#375#382\", Core.Compiler.Pairs{Int64, Int64, Core.Compiler.LinearIndices{1, Tuple{Core.Compiler.OneTo{Int64}}}, Vector{Int64}}}, Core.Compiler.var\"#374#381\"})
│          0     0%     0%         -1 0.074%  Core.Compiler.IdDict{Union{Core.Compiler.NewSSAValue, Core.Compiler.OldSSAValue, Core.SSAValue}, Int64}(::Core.Compiler.Generator{Core.Compiler.Iterators.Enumerate{Vector{Union{Core.Compiler.NewSSAValue, Core.Compiler.OldSSAValue, Core.SSAValue}}}, Core.Compiler.var\"#419#421\"})
│          0     0%     0%         -1 0.074%  _collect(::Type{Int64}, ::Core.Compiler.Generator{Core.Compiler.Iterators.Filter{Core.Compiler.var\"#377#384\"{Core.Compiler.IdDict{Int64, Int64}}, Vector{Int64}}, Core.Compiler.var\"#376#383\"{Int64, Core.Compiler.IdDict{Int64, Int64}, Vector{Int64}}}, ::Core.Compiler.SizeUnknown)
│          0     0%     0%          1 0.074%  _collect(::Type{Int64}, ::Core.Compiler.Generator{Core.Compiler.Iterators.Filter{Core.Compiler.var\"#379#386\"{Core.Compiler.IdDict{Int64, Int64}}, Vector{Int64}}, Core.Compiler.var\"#378#385\"{Int64, Core.Compiler.IdDict{Int64, Int64}, Vector{Int64}}}, ::Core.Compiler.SizeUnknown)
│          0     0%     0%          1 0.074%  anymap(::Core.Compiler.var\"#261#262\", ::Vector{Any})
│          0     0%     0%         -1 0.074%  anymap(::typeof(Core.Compiler.widenconditional), ::Vector{Any})
│          0     0%     0%         -1 0.074%  append!(::Vector{Any}, ::Vector{Any})
│          0     0%     0%          1 0.074%  append!(::Vector{Core.Compiler.BasicBlock}, ::Vector{Core.Compiler.BasicBlock})
│          0     0%     0%         11  0.81%  argextype(::Any, ::Core.Compiler.IRCode, ::Vector{Any}, ::Vector{Any})
│          0     0%     0%        -11  0.81%  argextype(::Any, ::Core.Compiler.IncrementalCompact, ::Vector{Any}, ::Vector{Any})
│          0     0%     0%          8  0.59%  copy!(::Vector{Core.Compiler.DomTreeNode}, ::Vector{Core.Compiler.DomTreeNode})
│          0     0%     0%         -8  0.59%  copy!(::Vector{Int64}, ::Vector{Int64})
│          0     0%     0%         -1 0.074%  setindex!(::Core.Compiler.IdDict{Any, Union{Nothing, Core.Compiler.LiftedValue}}, ::Any, ::Any)
│          0     0%     0%          6  0.44%  setindex!(::Core.Compiler.IdDict{Core.Compiler.MethodMatchKey, Union{Core.Compiler.Missing, Core.Compiler.MethodMatchResult}}, ::Any, ::Any)
│          0     0%     0%         -3  0.22%  setindex!(::Core.Compiler.IdDict{Int64, Int64}, ::Any, ::Any)
│          0     0%     0%         -1 0.074%  setindex!(::Core.Compiler.IdDict{Union{Core.Compiler.NewSSAValue, Core.Compiler.OldSSAValue, Core.SSAValue}, Any}, ::Any, ::Any)
│          0     0%     0%         -1 0.074%  setindex!(::Core.Compiler.IdDict{Union{Core.Compiler.NewSSAValue, Core.Compiler.OldSSAValue, Core.SSAValue}, Int64}, ::Any, ::Any)
│          0     0%     0%          3  0.22%  sort
└          0     0%     0%         -3  0.22%  sort##kw
Test Summary:                 | Pass  Fail  Total   Time
Alloc Profiles golden testing |    1     2      3  19.8s
ERROR: LoadError: Some tests did not pass: 1 passed, 2 failed, 0 errored, 0 broken.
in expression starting at /Users/nathandaly/.julia/dev/PProf/test/golden/regression_test.jl:32
=#

using Profile, PProf
using Test, Revise
using InteractiveUtils: peakflops

# Make sure that there's no local diffs (grep returns -1 if empty)
@assert !success(pipeline(`git status --porcelain=v1`,`grep -v '^??'`))

dir1 = mktempdir()
dir2 = mktempdir()

function compare_profiles(name)
    run(`git checkout main`)
    Revise.revise()
    @time @eval PProf.Allocs.pprof(web=false, out="$dir1/$($name).pb.gz")
    run(`git checkout -`)
    Revise.revise()
    @time @eval PProf.Allocs.pprof(web=false, out="$dir2/$($name).pb.gz")
    # Assert that there's no diff:
    lines = readlines(`$(PProf.pprof_jll.pprof()) -top -diff_base=$dir1/$name.pb.gz $dir2/$name.pb.gz`)
    nodiff = (lines[end] === "      flat  flat%   sum%        cum   cum%")
    @test nodiff
    if !nodiff
        @info "Got diff!: \n$(join(lines, "\n"))"
    end
    #@assert success(`diff $dir1/$name.pb.gz $dir2/$name.pb.gz`) "DIFF: $name"
end

@testset "Alloc Profiles golden testing" begin

    Profile.Allocs.clear(); peakflops(); Profile.Allocs.@profile sample_rate=1 begin
        for _ in 1:10 peakflops() end
    end
    compare_profiles("1")


    my_function() = length(collect(Iterators.flatten(Any[1:500 for _ in 1:1000])))

    Profile.Allocs.clear(); my_function(); Profile.Allocs.@profile sample_rate=0.0001 begin
        my_function()
    end

    compare_profiles("2")

    # Compilation
    @eval my_function2() = length(collect(Iterators.flatten(Any[1:5 for _ in 1:10])))
    @eval Profile.Allocs.clear(); Profile.Allocs.@profile sample_rate=0.1 begin
        @eval (while false end; my_function2())
    end

    compare_profiles("3")

end
