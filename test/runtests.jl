using Test
using Rushlane
using StableRNGs
using Statistics
using DataFrames

const DEFAULT_CFG = joinpath(@__DIR__, "..", "config", "kantin_default.toml")

function tiny_cfg(; replications=20, seed=2026, mode="single", balk=15, patience=8)
    path = joinpath(mktempdir(), "test.toml")
    open(path, "w") do io
        print(io, """
        [sim]
        open = "08:00"
        close = "16:00"
        replications = $replications
        seed = $seed

        [arrivals]
        bin_minutes = 60
        rates_per_hour = [30, 30, 30, 30, 120, 120, 30, 30]

        [service.std]
        share = 1.0
        dist = "exponential"
        mean_seconds = 60

        [queue]
        mode = "$mode"

        [behavior]
        balk_queue_length = $balk
        patience_mean_minutes = $patience

        [servers]
        count = 2

        [sla]
        p90_wait_minutes = 5
        max_abandon_percent = 2

        [cost]
        cashier_per_hour = 15000
        lost_customer_cost = 12000
        """)
    end
    return load_config(path)
end

@testset "config parsing and validation" begin
    cfg = load_config(DEFAULT_CFG)
    @test cfg.bin_minutes == 15
    @test length(cfg.rates_per_hour) == 36
    @test cfg.queue_mode === :single
    @test cfg.replications == 200

    @test_throws ArgumentError load_config("nonexistent.toml")

    bad = joinpath(mktempdir(), "bad.toml")
    open(bad, "w") do io
        print(io, """
        [sim]
        open = "08:00"
        close = "16:00"
        replications = 10
        seed = 1
        [arrivals]
        bin_minutes = 15
        rates_per_hour = [1, 2, 3]
        [service.std]
        share = 1.0
        dist = "exponential"
        mean_seconds = 60
        """)
    end
    @test_throws ArgumentError load_config(bad)  # 36 bins required, got 3
end

@testset "arrival generator statistics" begin
    cfg = load_config(DEFAULT_CFG)
    rng = StableRNG(42)
    # average arrivals per day should be near the configured expectation
    n_days = 300
    counts = Float64[]
    for _ in 1:n_days
        push!(counts, length(Rushlane.generate_arrivals(cfg, rng)))
    end
    @test abs(mean(counts) - Rushlane.expected_arrivals(cfg)) / Rushlane.expected_arrivals(cfg) < 0.05

    # scale doubles the expected count
    cfg2 = load_config(DEFAULT_CFG)
    times = Rushlane.generate_arrivals(cfg2, StableRNG(7))
    @test issorted(times)
end

@testset "engine invariants" begin
    cfg = tiny_cfg(replications = 1)
    cfg = load_config(DEFAULT_CFG, check_invariants = true)
    r = simulate(cfg, rng = StableRNG(2026), servers_override = 4)
    @test all(w -> w >= 0, r.waits)
    @test all(s -> s > 0, r.sojourns)
    @test r.done + r.balked + r.reneged <= r.arrivals
    @test 0.0 <= r.utilization <= 1.0
    @test r.avg_queue_length >= 0
    @test r.max_queue_length >= 0
end

@testset "determinism" begin
    cfg = tiny_cfg(replications = 1, seed = 99)
    r1 = simulate(cfg, rng = StableRNG(99), servers_override = 2)
    r2 = simulate(cfg, rng = StableRNG(99), servers_override = 2)
    @test r1.waits == r2.waits
    @test r1.sojourns == r2.sojourns
end

@testset "more cashiers never increase mean wait" begin
    cfg = tiny_cfg(replications = 1, seed = 1234)
    r_few = simulate(cfg, rng = StableRNG(1234), servers_override = 1)
    r_many = simulate(cfg, rng = StableRNG(1234), servers_override = 4)
    @test mean(r_many.waits) <= mean(r_few.waits)
end

@testset "balking behavior direction" begin
    cfg_free = tiny_cfg(replications = 1, seed = 5, balk = 0)
    cfg_strict = tiny_cfg(replications = 1, seed = 5, balk = 1)
    r_free = simulate(cfg_free, rng = StableRNG(5), servers_override = 2)
    r_strict = simulate(cfg_strict, rng = StableRNG(5), servers_override = 2)
    @test r_strict.balked > r_free.balked
end

@testset "reneging behavior direction" begin
    cfg_no = tiny_cfg(replications = 1, seed = 5, patience = 0)
    cfg_impatient = tiny_cfg(replications = 1, seed = 5, patience = 0.001)
    r_no = simulate(cfg_no, rng = StableRNG(5), servers_override = 1)
    r_imp = simulate(cfg_impatient, rng = StableRNG(5), servers_override = 1)
    @test r_no.reneged == 0
    @test r_imp.reneged > 0
end

@testset "per_server mode runs" begin
    cfg = tiny_cfg(replications = 1, mode = "per_server")
    r = simulate(cfg, rng = StableRNG(11), servers_override = 3)
    @test r.done > 0
    @test all(w -> w >= 0, r.waits)
end

@testset "shifts parse and run" begin
    path = joinpath(mktempdir(), "shift.toml")
    open(path, "w") do io
        print(io, """
        [sim]
        open = "08:00"
        close = "12:00"
        replications = 1
        seed = 77
        [arrivals]
        bin_minutes = 60
        rates_per_hour = [120, 120, 30, 30]
        [service.std]
        share = 1.0
        dist = "exponential"
        mean_seconds = 60
        [queue]
        mode = "single"
        [behavior]
        balk_queue_length = 0
        patience_mean_minutes = 0
        [servers]
        count = 1
        [[shifts]]
        from = "09:00"
        to = "11:00"
        count = 3
        [sla]
        p90_wait_minutes = 5
        max_abandon_percent = 2
        [cost]
        cashier_per_hour = 15000
        lost_customer_cost = 12000
        """)
    end
    cfg = load_config(path)
    @test length(cfg.shifts) == 1
    @test Rushlane.servers_at(cfg, Rushlane.parse_clock("08:30")) == 1
    @test Rushlane.servers_at(cfg, Rushlane.parse_clock("10:00")) == 3
    @test Rushlane.servers_at(cfg, Rushlane.parse_clock("11:30")) == 1
    r = simulate(cfg, rng = StableRNG(77))
    @test r.done > 0
end

@testset "Erlang C formula" begin
    # M/M/1 sanity: Wq = rho / (mu - lambda)
    λ, μ = 0.5, 1.0
    res = erlang_c(λ, μ, 1)
    @test isapprox(res.wq, (λ / μ) / (μ - λ), atol = 1e-10)
    @test isapprox(res.rho, λ / (1 * μ), atol = 1e-10)
    # stability guard
    @test_throws ArgumentError erlang_c(2.0, 1.0, 1)
end

@testset "simulation matches Erlang C (M/M/c steady state)" begin
    # constant rate all day, exponential service, no balking/reneging: M/M/c
    path = joinpath(mktempdir(), "mm_c.toml")
    open(path, "w") do io
        print(io, """
        [sim]
        open = "00:00"
        close = "09:00"
        replications = 60
        seed = 31337
        [arrivals]
        bin_minutes = 60
        rates_per_hour = [120, 120, 120, 120, 120, 120, 120, 120, 120]
        [service.std]
        share = 1.0
        dist = "exponential"
        mean_seconds = 60
        [queue]
        mode = "single"
        [behavior]
        balk_queue_length = 0
        patience_mean_minutes = 0
        [servers]
        count = 3
        [sla]
        p90_wait_minutes = 5
        max_abandon_percent = 2
        [cost]
        cashier_per_hour = 15000
        lost_customer_cost = 12000
        """)
    end
    cfg = load_config(path)
    λ = 120 / 3600
    μ = 1 / 60
    expected = erlang_c(λ, μ, 3).wq
    df = run_replications(cfg, 3; n = 200, seed = 31337)
    sim_wq = mean(df.wait_mean)
    @test abs(sim_wq - expected) / expected < 0.03
end

@testset "replication statistics and CI" begin
    cfg = tiny_cfg(replications = 20, seed = 777)
    df = run_replications(cfg, 2; n = 20, seed = 777)
    @test nrow(df) == 20
    s = Rushlane.summarize(df)
    @test s.mean_values["wait_mean"] == mean(df.wait_mean)
    @test s.ci95["wait_mean"] > 0
    @test 0.0 <= s.mean_values["utilization"] <= 1.0
end

@testset "optimizer" begin
    cfg = tiny_cfg(replications = 8, seed = 2026)
    opt = Rushlane.optimize(cfg; max_servers = 4, n = 8, seed = 2026)
    @test first(opt.table.servers) == 1
    @test length(opt.table.servers) == 4
    @test opt.recommended === nothing || 1 <= opt.recommended <= 4
    @test opt.cost_optimal in 1:4
    @test all(opt.table.sla_met .== (opt.table.wait_p90 .<= cfg.sla_p90_wait_seconds .&&
                                     opt.table.abandon_percent .<= cfg.sla_max_abandon_percent))
end

@testset "report generation" begin
    cfg = tiny_cfg(replications = 2, seed = 2026)
    out = mktempdir()
    path = write_report(cfg; out_dir = out)
    @test isfile(path)
    @test isfile(joinpath(out, "queue_length.png"))
    @test isfile(joinpath(out, "wait_histogram.png"))
    @test isfile(joinpath(out, "metrics_vs_servers.png"))
    @test isfile(joinpath(out, "metrics_by_cashiers.csv"))
    content = read(path, String)
    @test occursin("Rushlane report", content)
    @test occursin("Recommendation", content)
end
