using BART
using Distributions
using MCMCChains
using Test

@testset "BART.jl" begin
    # Example from the thesis.
    #using StatsPlots
    g(x) = 10sin.(pi * x[1] .* x[2]) + 20(x[3] .- 0.5).^2 + 10x[4] + 5x[5]
    n = 250
    p = 10
    σ = sqrt(1)
    X = rand(n, p)
    y = vec(mapslices(g, X, dims = 2)) + rand(Normal(0, σ), n)
    post = fit(BartModel, X, y)
    monitor = Chains(post)
    gelmandiag(monitor)
    #plot(monitor)
end
