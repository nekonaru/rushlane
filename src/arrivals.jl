# Arrival process: nonhomogeneous Poisson process (NHPP) with piecewise-constant
# rate, generated per bin. Independent increments make the statistics easy to test.

using Distributions: Poisson

"""
    generate_arrivals(cfg::SimConfig, rng) -> Vector{Float64}

Generate sorted arrival times (seconds since midnight) for one simulated day.
Each bin of `bin_minutes` minutes contributes Poisson(lambda_bin * bin_hours)
arrivals, uniform inside the bin. Counts and times are driven solely by `rng`.
"""
function generate_arrivals(cfg::SimConfig, rng)::Vector{Float64}
    bin_seconds = cfg.bin_minutes * 60
    times = Float64[]
    t = cfg.open_seconds
    for rate_per_hour in cfg.rates_per_hour
        lambda = rate_per_hour * cfg.arrival_scale / 3600  # per second
        if lambda > 0
            n = rand(rng, Poisson(lambda * bin_seconds))
            for _ in 1:n
                push!(times, t + rand(rng) * bin_seconds)
            end
        end
        t += bin_seconds
    end
    sort!(times)
    return times
end

"""
    expected_arrivals(cfg::SimConfig) -> Float64

Expected number of customers per day (sum of bin rates times bin length).
"""
expected_arrivals(cfg::SimConfig)::Float64 =
    sum(cfg.rates_per_hour) * (cfg.bin_minutes / 60) * cfg.arrival_scale
