# Metrics: per-run summaries and replication statistics with 95% confidence intervals.

using Statistics: mean, std, median
using Distributions: TDist, quantile
using DataFrames: DataFrame
using StableRNGs: StableRNG

"""
    percentile_sorted(sorted::AbstractVector, q::Real) -> Float64

Linear-interpolation percentile, q in [0, 100]. Assumes data may be unsorted; sorts a copy.
"""
function percentile_sorted(v::AbstractVector, q::Real)::Float64
    isempty(v) && return NaN
    s = sort(v)
    n = length(s)
    n == 1 && return s[1]
    rank = (q / 100) * (n - 1) + 1
    lo = floor(Int, rank)
    hi = ceil(Int, rank)
    if lo == hi
        return s[lo]
    end
    frac = rank - lo
    return s[lo] * (1 - frac) + s[hi] * frac
end

struct RunMetrics
    wait_mean::Float64
    wait_median::Float64
    wait_p90::Float64
    wait_p95::Float64
    sojourn_mean::Float64
    max_queue::Int
    avg_queue::Float64
    utilization::Float64
    abandon_percent::Float64
    throughput_per_hour::Float64
    done::Int
    balked::Int
    reneged::Int
    arrivals::Int
end

function metrics_of(r::SimResult)::RunMetrics
    served = length(r.waits)
    wait_mean = served > 0 ? mean(r.waits) : 0.0
    wait_median = served > 0 ? median(r.waits) : 0.0
    wait_p90 = served > 0 ? percentile_sorted(r.waits, 90) : 0.0
    wait_p95 = served > 0 ? percentile_sorted(r.waits, 95) : 0.0
    sojourn_mean = served > 0 ? mean(r.sojourns) : 0.0
    abandon = r.arrivals > 0 ? (r.balked + r.reneged) / r.arrivals * 100 : 0.0
    RunMetrics(wait_mean, wait_median, wait_p90, wait_p95, sojourn_mean,
               r.max_queue_length, r.avg_queue_length, r.utilization,
               abandon, r.throughput_per_hour, r.done, r.balked, r.reneged, r.arrivals)
end

struct StatSummary
    name::String
    mean::Float64
    ci95::Float64           # half-width of the 95% t-based confidence interval
    n::Int
end

summarize_col(v::Vector{Float64}, name::String) = StatSummary(name, mean(v), ci95_halfwidth(v), length(v))

function ci95_halfwidth(v::Vector{Float64})::Float64
    n = length(v)
    n < 2 && return NaN
    sd = std(v)
    sd == 0 && return 0.0
    tcrit = quantile(TDist(n - 1), 0.975)
    return tcrit * sd / sqrt(n)
end

"""
    run_replications(cfg::SimConfig, c::Int; n=nothing, seed=nothing) -> DataFrame

Run the scenario with `c` servers `n` times (default `cfg.replications`).
Replication `i` uses `StableRNG(seed + i)` with `seed = cfg.seed` by default, so
scenarios compared at the same `i` share the arrival and service streams
(common random numbers).
"""
function run_replications(cfg::SimConfig, c::Int; n::Union{Int,Nothing}=nothing,
                          seed::Union{Int,Nothing}=nothing)::DataFrame
    n = n === nothing ? cfg.replications : n
    seed = seed === nothing ? cfg.seed : seed
    rows = []
    for i in 0:(n - 1)
        rng = StableRNG(seed + i)
        r = simulate(cfg, rng = rng, servers_override = c)
        m = metrics_of(r)
        push!(rows, (replication = i, servers = c,
                     wait_mean = m.wait_mean, wait_median = m.wait_median,
                     wait_p90 = m.wait_p90, wait_p95 = m.wait_p95,
                     sojourn_mean = m.sojourn_mean,
                     max_queue = m.max_queue, avg_queue = m.avg_queue,
                     utilization = m.utilization, abandon_percent = m.abandon_percent,
                     throughput_per_hour = m.throughput_per_hour,
                     done = m.done, balked = m.balked, reneged = m.reneged,
                     arrivals = m.arrivals))
    end
    return DataFrame(rows)
end

struct ScenarioSummary
    servers::Int
    stats::Vector{StatSummary}
    mean_values::Dict{String,Float64}
    ci95::Dict{String,Float64}
end

"""
    summarize(df::DataFrame) -> ScenarioSummary

Mean and 95% CI half-width for every numeric column except replication/servers.
"""
function summarize(df::DataFrame)::ScenarioSummary
    cols = names(df)
    stats = StatSummary[]
    means = Dict{String,Float64}()
    cis = Dict{String,Float64}()
    for col in cols
        col in ("replication", "servers") && continue
        v = Float64.(df[!, col])
        s = summarize_col(v, col)
        push!(stats, s)
        means[col] = s.mean
        cis[col] = s.ci95
    end
    return ScenarioSummary(Int(df.servers[1]), stats, means, cis)
end

"""
    scenario_table(cfg::SimConfig; max_servers=cfg.max_servers, n=nothing, seed=nothing) -> DataFrame

One summary row per server count 1..max_servers, columns mean and CI.
"""
function scenario_table(cfg::SimConfig; max_servers::Int=cfg.max_servers,
                        n::Union{Int,Nothing}=nothing, seed::Union{Int,Nothing}=nothing)::DataFrame
    rows = []
    for c in 1:max_servers
        df = run_replications(cfg, c, n = n, seed = seed)
        s = summarize(df)
        push!(rows, (servers = c,
                     wait_mean = s.mean_values["wait_mean"], wait_mean_ci = s.ci95["wait_mean"],
                     wait_p90 = s.mean_values["wait_p90"], wait_p90_ci = s.ci95["wait_p90"],
                     wait_p95 = s.mean_values["wait_p95"], wait_p95_ci = s.ci95["wait_p95"],
                     avg_queue = s.mean_values["avg_queue"], avg_queue_ci = s.ci95["avg_queue"],
                     max_queue = s.mean_values["max_queue"], max_queue_ci = s.ci95["max_queue"],
                     utilization = s.mean_values["utilization"], utilization_ci = s.ci95["utilization"],
                     abandon_percent = s.mean_values["abandon_percent"], abandon_percent_ci = s.ci95["abandon_percent"],
                     throughput_per_hour = s.mean_values["throughput_per_hour"], throughput_per_hour_ci = s.ci95["throughput_per_hour"]))
    end
    return DataFrame(rows)
end
