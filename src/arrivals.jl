# Arrival process: nonhomogeneous Poisson process (NHPP) with piecewise-constant
# rate, generated per bin. Independent increments make the statistics easy to test.

using Distributions: Poisson

"""
    generate_arrivals(cfg::SimConfig, rng) -> Vector{Float64}

Generate sorted arrival times (seconds since midnight) for one simulated day.
Each bin of `bin_minutes` contributes Poisson(lambda_bin * overlap_hours)
arrivals, uniform inside the overlap with the simulation window, so a final
partial bin never produces arrivals after closing. Counts and times are driven
solely by `rng`.
"""
function generate_arrivals(cfg::SimConfig, rng)::Vector{Float64}
    bin_seconds = cfg.bin_minutes * 60
    times = Float64[]
    t = cfg.open_seconds
    for rate_per_hour in cfg.rates_per_hour
        overlap = min(bin_seconds, cfg.close_seconds - t)
        lambda = rate_per_hour * cfg.arrival_scale / 3600  # per second
        if lambda > 0 && overlap > 0
            n = rand(rng, Poisson(lambda * overlap))
            for _ in 1:n
                push!(times, t + rand(rng) * overlap)
            end
        end
        t += bin_seconds
    end
    sort!(times)
    return times
end

"""
    expected_arrivals(cfg::SimConfig) -> Float64

Expected number of customers per day, with any partial final bin counted only
for its overlap with the simulation window.
"""
function expected_arrivals(cfg::SimConfig)::Float64
    bin_seconds = cfg.bin_minutes * 60
    t = cfg.open_seconds
    total = 0.0
    for rate_per_hour in cfg.rates_per_hour
        overlap = min(bin_seconds, cfg.close_seconds - t)
        total += rate_per_hour * cfg.arrival_scale * (max(overlap, 0.0) / 3600)
        t += bin_seconds
    end
    return total
end
