using Test

@testset "PProf.jl" begin
    include("PProf.jl")
end

@testset "flamegraphs.jl" begin
    include("flamegraphs.jl")
end
