using Test

@testset "PProf.jl" begin
    include("PProf.jl")
end

@testset "flamegraphs.jl" begin
    include("flamegraphs.jl")
end

if VERSION >= v"1.8.0-DEV.1346"  # PR https://github.com/JuliaLang/julia/pull/42768
@testset "Allocs.jl" begin
    include("Allocs.jl")
end
end

