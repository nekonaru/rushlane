# Optimizer: find the minimum number of cashiers that meets the SLA, and the
# cost curve (cashier wages vs expected lost sales).

using DataFrames: DataFrame, eachrow

"""
    optimize(cfg::SimConfig; max_servers=cfg.max_servers, n=nothing, seed=nothing) -> NamedTuple

Evaluate scenarios for 1..max_servers cashiers and return a NamedTuple with:
`table` (scenario summary plus SLA flags and per-day cost columns),
`recommended` (minimum servers meeting the SLA, or `nothing`),
`cost_optimal` (servers with the lowest total daily cost).

Expected lost customers per day use `expected_arrivals(cfg)` (the configured,
scale-adjusted arrival rate), so the cost comparison is consistent across
scenarios. Common random numbers (same per-replication seeds) are used via
`scenario_table`.
"""
function optimize(cfg::SimConfig; max_servers::Int=cfg.max_servers,
                  n::Union{Int,Nothing}=nothing, seed::Union{Int,Nothing}=nothing)
    table = scenario_table(cfg; max_servers=max_servers, n=n, seed=seed)
    day_hours = (cfg.close_seconds - cfg.open_seconds) / 3600
    expected = expected_arrivals(cfg)

    sla_ok = [row.wait_p90_seconds <= cfg.sla_p90_wait_seconds && row.abandon_percent <= cfg.sla_max_abandon_percent
              for row in eachrow(table)]
    idx = findfirst(sla_ok)
    recommended = idx === nothing ? nothing : Int(table.servers[idx])

    lost = [expected * row.abandon_percent / 100 for row in eachrow(table)]
    cashier_cost = [cfg.cashier_per_hour * Int(row.servers) * day_hours for row in eachrow(table)]
    lost_cost = [cfg.lost_customer_cost * l for l in lost]
    total_cost = cashier_cost .+ lost_cost
    cost_optimal = Int(table.servers[argmin(total_cost)])

    table.sla_met = sla_ok
    table.expected_lost_customers = lost
    table.cashier_cost_per_day = cashier_cost
    table.lost_sales_cost_per_day = lost_cost
    table.total_cost_per_day = total_cost

    return (table = table, recommended = recommended, cost_optimal = cost_optimal)
end
