# Markdown report generation: one command produces the full analysis.

using DataFrames: DataFrame, eachrow
using StableRNGs: StableRNG
using CSV: CSV
using Statistics: mean
import Dates

const REPORT_VERSION = "0.1.0"

fmt_ci(v, ci) = string(round(v, digits = 2), " ± ", round(ci, digits = 2))
fmt_pct(v) = string(round(v, digits = 1), "%")
fmt_min(v_seconds) = string(round(v_seconds / 60, digits = 2))
fmt_min_ci(v, ci) = string(round(v / 60, digits = 2), " ± ", round(ci / 60, digits = 2))

function _config_section(io, cfg::SimConfig)
    println(io, "## Configuration")
    println(io)
    println(io, "| Setting | Value |")
    println(io, "|---------|-------|")
    println(io, "| Opening time | $(format_clock(cfg.open_seconds)) |")
    println(io, "| Closing time | $(format_clock(cfg.close_seconds)) |")
    println(io, "| Replications per scenario | $(cfg.replications) |")
    println(io, "| Base random seed | $(cfg.seed) |")
    println(io, "| Arrival bins | $(cfg.bin_minutes) minutes |")
    println(io, "| Arrival scale | x$(cfg.arrival_scale) |")
    println(io, "| Expected customers per day | $(round(expected_arrivals(cfg), digits = 1)) |")
    println(io, "| Queue mode | $(cfg.queue_mode === :single ? "single line, multiple cashiers" : "one line per cashier") |")
    balk_txt = cfg.balk_queue_length > 0 ? "balk when $(cfg.balk_queue_length)+ already waiting" : "disabled"
    println(io, "| Balking | $balk_txt |")
    pat_txt = cfg.patience_mean_seconds > 0 ? "exponential, mean $(round(cfg.patience_mean_seconds / 60, digits = 1)) min" : "disabled"
    println(io, "| Reneging patience | $pat_txt |")
    if isempty(cfg.shifts)
        println(io, "| Cashiers (constant) | $(cfg.default_servers) |")
    else
        shift_txt = join(["$(format_clock(f))-$(format_clock(t)): $c" for (f, t, c) in cfg.shifts], ", ")
        println(io, "| Cashier shifts | default $(cfg.default_servers); $(shift_txt) |")
    end
    println(io)
    println(io, "**Service mix**")
    println(io)
    for s in cfg.services
        println(io, "- $(s.name): $(round(s.share * 100, digits = 1))% share, dist $(s.dist), mean $(round(s.mean_seconds, digits = 1)) s, cv $(s.cv)")
    end
    println(io)
    println(io, "| SLA | P90 wait ≤ $(round(cfg.sla_p90_wait_seconds / 60, digits = 1)) min, abandon ≤ $(cfg.sla_max_abandon_percent)% |")
    println(io, "| Cost | cashier $(cfg.cashier_per_hour)/hour, lost customer $(cfg.lost_customer_cost) |")
    println(io)
end

function _results_table(io, table::DataFrame, cfg::SimConfig)
    println(io, "## Results by number of cashiers")
    println(io)
    println(io, "Mean over replications, ± 95% CI in parentheses.")
    println(io)
    println(io, "| Cashiers | Avg wait (min) | P90 wait (min) | P95 wait (min) | Avg queue | Max queue | Utilization | Abandoned | Throughput/h | SLA met |")
    println(io, "|---------|----------------|----------------|----------------|-----------|-----------|-------------|-----------|--------------|---------|")
    for row in eachrow(table)
        println(io, "| $(row.servers) | $(fmt_min_ci(row.wait_mean, row.wait_mean_ci)) | $(fmt_min_ci(row.wait_p90, row.wait_p90_ci)) | $(fmt_min(row.wait_p95)) | $(fmt_ci(row.avg_queue, row.avg_queue_ci)) | $(fmt_ci(row.max_queue, row.max_queue_ci)) | $(fmt_pct(row.utilization * 100)) | $(fmt_pct(row.abandon_percent)) | $(round(row.throughput_per_hour, digits = 1)) | $(row.sla_met ? "yes" : "no") |")
    end
    println(io)
end

function _cost_section(io, table::DataFrame, cfg::SimConfig)
    println(io, "## Cost analysis")
    println(io)
    println(io, "Expected lost customers per day use the configured arrival rate (scale-adjusted).")
    println(io)
    println(io, "| Cashiers | Lost customers/day | Cashier cost/day | Lost sales cost/day | Total cost/day |")
    println(io, "|---------|--------------------|------------------|---------------------|----------------|")
    for row in eachrow(table)
        println(io, "| $(row.servers) | $(round(row.expected_lost_customers, digits = 1)) | $(round(row.cashier_cost_per_day, digits = 0)) | $(round(row.lost_sales_cost_per_day, digits = 0)) | $(round(row.total_cost_per_day, digits = 0)) |")
    end
    println(io)
end

function _recommendation(io, opt, cfg::SimConfig)
    println(io, "## Recommendation")
    println(io)
    if opt.recommended === nothing
        println(io, "No scenario up to $(maximum(opt.table.servers)) cashiers meets the SLA ")
        println(io, "(P90 wait ≤ $(round(cfg.sla_p90_wait_seconds / 60, digits = 1)) min and abandon ≤ $(cfg.sla_max_abandon_percent)%). ")
        println(io, "Consider more cashiers, shorter service times, or relaxing the SLA.")
    else
        best = opt.recommended
        println(io, "Use **$(best) cashier$(best == 1 ? "" : "s")**. It is the smallest number that meets the SLA ")
        println(io, "(P90 wait ≤ $(round(cfg.sla_p90_wait_seconds / 60, digits = 1)) min, abandon ≤ $(cfg.sla_max_abandon_percent)%).")
        if opt.cost_optimal != best
            println(io)
            println(io, "The cheapest option overall is $(opt.cost_optimal) cashier$(opt.cost_optimal == 1 ? "" : "s") by total daily cost, ")
            println(io, "but that configuration does not meet the SLA. $(best) cashiers is the cheapest option that does.")
        else
            println(io)
            println(io, "It is also the cheapest option by total daily cost (cashier wages plus expected lost sales).")
        end
    end
    println(io)
end

const LIMITATIONS = [
    "Arrivals follow a nonhomogeneous Poisson process with a piecewise-constant rate (one rate per bin).",
    "Service times are sampled independently per customer from the configured distributions.",
    "The queue is FIFO. Jockeying (switching lanes) is not modeled.",
    "Reneging patience is exponential. Balking is based on the number already waiting in the chosen lane.",
    "Waiting-time statistics cover served customers only. Customers still in line at closing time are excluded.",
    "All figures are means over replications with 95% t-based confidence intervals.",
    "Scenarios for different cashier counts use common random numbers (same per-replication seeds), so comparisons are paired.",
]

"""
    write_report(cfg::SimConfig; out_dir="out", config_name=nothing) -> String

Run all cashier-count scenarios and write `report.md`, figures and CSV exports
into `out_dir`. Returns the path of the Markdown report.
"""
function write_report(cfg::SimConfig; out_dir::AbstractString="out", config_name::Union{AbstractString,Nothing}=nothing)::String
    mkpath(out_dir)
    opt = optimize(cfg)
    table = opt.table

    # detail run (single day) at the recommended staffing for figures and CSVs
    detail_c = opt.recommended === nothing ? cfg.default_servers : opt.recommended
    detail = simulate(cfg, rng = StableRNG(cfg.seed), servers_override = detail_c)
    detail_metrics = metrics_of(detail)

    queue_png = generate_queue_plot(detail.queue_series_t, detail.queue_series_len, cfg;
                                    path = joinpath(out_dir, "queue_length.png"))
    wait_png = generate_wait_histogram(detail.waits;
                                       path = joinpath(out_dir, "wait_histogram.png"))
    servers_png = generate_metrics_vs_servers(table;
                                              path = joinpath(out_dir, "metrics_vs_servers.png"))

    csv_scenarios = joinpath(out_dir, "metrics_by_cashiers.csv")
    CSV.write(csv_scenarios, table)
    csv_detail = joinpath(out_dir, "detail_single_run.csv")
    CSV.write(csv_detail, DataFrame(waits_seconds = detail.waits, sojourns_seconds = detail.sojourns))

    report_path = joinpath(out_dir, "report.md")
    open(report_path, "w") do io
        println(io, "# Rushlane report: how many cashiers does the canteen need?")
        println(io)
        println(io, "Generated by Rushlane v$(REPORT_VERSION) on $(Dates.format(Dates.today(), "yyyy-mm-dd")).")
        config_name === nothing || println(io, "Configuration: `$(config_name)`.")
        println(io, "Random seed: $(cfg.seed). All multi-scenario numbers are means over $(cfg.replications) replications with 95% confidence intervals.")
        println(io)

        println(io, "## Summary")
        println(io)
        println(io, "- Expected customers per day: $(round(expected_arrivals(cfg), digits = 1))")
        println(io, "- Mode: $(cfg.queue_mode === :single ? "single shared queue" : "one queue per cashier")")
        if opt.recommended === nothing
            println(io, "- **Recommendation: no cashier count up to $(maximum(table.servers)) meets the SLA**")
        else
            println(io, "- **Recommendation: $(opt.recommended) cashier$(opt.recommended == 1 ? "" : "s")** (cheapest option that meets the SLA)")
        end
        println(io, "- Cheapest option by total daily cost: $(opt.cost_optimal) cashier$(opt.cost_optimal == 1 ? "" : "s")")
        println(io)

        _config_section(io, cfg)
        _results_table(io, table, cfg)
        _cost_section(io, table, cfg)
        _recommendation(io, opt, cfg)

        println(io, "## Assumptions and limitations")
        println(io)
        for item in LIMITATIONS
            println(io, "- $item")
        end
        println(io, "- Costs use expected arrivals (configured rates, scale applied) and the configured wages and lost-sale cost.")
        println(io)

        println(io, "## Figures")
        println(io)
        println(io, "Queue length over the day (single run, seed $(cfg.seed), $(detail_c) cashier$(detail_c == 1 ? "" : "s")):")
        println(io)
        println(io, "![Queue length](queue_length.png)")
        println(io)
        println(io, "Waiting time distribution (served customers, same run):")
        println(io)
        println(io, "![Waiting time distribution](wait_histogram.png)")
        println(io)
        println(io, "Average wait and abandon rate vs number of cashiers (replicated means, 95% CI):")
        println(io)
        println(io, "![Metrics vs cashiers](metrics_vs_servers.png)")
        println(io)

        println(io, "## Data exports")
        println(io)
        println(io, "- Scenario summary (per cashier count): `metrics_by_cashiers.csv`")
        println(io, "- Single-run per-customer detail: `detail_single_run.csv`")
        println(io)
    end
    return report_path
end
