# Configuration parsing and validation (TOML).

struct ServiceType
    name::String
    share::Float64
    dist::Symbol
    mean_seconds::Float64
    cv::Float64
end

struct SimConfig
    open_seconds::Float64
    close_seconds::Float64
    replications::Int
    seed::Int
    bin_minutes::Int
    rates_per_hour::Vector{Float64}
    arrival_scale::Float64
    services::Vector{ServiceType}
    queue_mode::Symbol              # :single | :per_server
    balk_queue_length::Int          # balk when waiting count >= this; <= 0 disables
    patience_mean_seconds::Float64  # exponential patience; <= 0 disables reneging
    default_servers::Int
    shifts::Vector{Tuple{Float64,Float64,Int}}  # (from, to, servers), seconds since midnight
    sla_p90_wait_seconds::Float64
    sla_max_abandon_percent::Float64
    cashier_per_hour::Float64
    lost_customer_cost::Float64
    max_servers::Int
    check_invariants::Bool
end

const SUPPORTED_DISTS = (:lognormal, :gamma, :exponential, :normal, :constant)

"""
    parse_clock(s::AbstractString) -> Float64

Parse "HH:MM" into seconds since midnight. Throws `ArgumentError` on bad input.
"""
function parse_clock(s::AbstractString)::Float64
    m = match(r"^(\d{1,2}):(\d{2})$", strip(s))
    m === nothing && throw(ArgumentError("invalid time \"$s\", expected HH:MM"))
    h = parse(Int, m.captures[1])
    min = parse(Int, m.captures[2])
    (h > 23 || min > 59) && throw(ArgumentError("invalid time \"$s\", hour 0-23 and minute 0-59 expected"))
    return Float64(h * 3600 + min * 60)
end

"""
    format_clock(seconds) -> String

Format seconds since midnight as "HH:MM".
"""
function format_clock(seconds::Real)::String
    total = floor(Int, seconds)
    h = div(total, 3600)
    m = rem(div(total, 60), 60)
    return string(lpad(h, 2, '0'), ":", lpad(m, 2, '0'))
end

"""
    servers_at(cfg::SimConfig, t::Float64) -> Int

Number of active cashiers at simulated time `t` (seconds since midnight).
Shifts, when present, override `default_servers` inside their windows.
"""
function servers_at(cfg::SimConfig, t::Float64)::Int
    isempty(cfg.shifts) && return cfg.default_servers
    n = cfg.default_servers
    for (from, to, c) in cfg.shifts
        if from <= t < to
            n = c
        end
    end
    return n
end

"""
    load_config(path::AbstractString; check_invariants=false) -> SimConfig

Read and validate a TOML configuration file. Raises `ArgumentError` with a
human-readable message on any validation failure.
"""
function load_config(path::AbstractString; check_invariants::Bool=false)::SimConfig
    isfile(path) || throw(ArgumentError("config file not found: $path"))
    raw = TOML.parsefile(path)

    sim = get(raw, "sim", Dict{String,Any}())
    open_s = parse_clock(get(sim, "open", "07:00"))
    close_s = parse_clock(get(sim, "close", "16:00"))
    close_s > open_s || throw(ArgumentError("sim.close must be after sim.open"))
    replications = Int(get(sim, "replications", 200))
    1 <= replications <= 10000 || throw(ArgumentError("sim.replications must be between 1 and 10000"))
    seed = Int(get(sim, "seed", 2026))

    arr = get(raw, "arrivals", Dict{String,Any}())
    bin_minutes = Int(get(arr, "bin_minutes", 15))
    1 <= bin_minutes <= 1440 || throw(ArgumentError("arrivals.bin_minutes must be between 1 and 1440"))
    rates = Float64.(get(arr, "rates_per_hour", Float64[]))
    all(r -> isfinite(r) && 0 <= r <= 100000, rates) ||
        throw(ArgumentError("arrivals.rates_per_hour entries must be finite numbers between 0 and 100000"))
    n_bins = ceil(Int, (close_s - open_s) / (bin_minutes * 60))
    length(rates) == n_bins || throw(ArgumentError(
        "arrivals.rates_per_hour has $(length(rates)) entries but the day needs $n_bins bins of $(bin_minutes) minutes"))
    arrival_scale = Float64(get(arr, "scale", 1.0))
    arrival_scale > 0 || throw(ArgumentError("arrivals.scale must be > 0"))

    services_raw = get(raw, "service", Dict{String,Any}())
    isempty(services_raw) && throw(ArgumentError("at least one [service.<name>] table is required"))
    services = ServiceType[]
    for (name, spec) in services_raw
        spec isa AbstractDict || throw(ArgumentError("service.$name must be a table"))
        share = Float64(get(spec, "share", NaN))
        mean_s = Float64(get(spec, "mean_seconds", NaN))
        dist = Symbol(get(spec, "dist", "lognormal"))
        cv = Float64(get(spec, "cv", dist == :exponential ? 1.0 : 0.5))
        isfinite(share) && share > 0 || throw(ArgumentError("service.$name.share must be a positive number"))
        isfinite(mean_s) && mean_s > 0 || throw(ArgumentError("service.$name.mean_seconds must be a positive number"))
        dist in SUPPORTED_DISTS || throw(ArgumentError("service.$name.dist must be one of $(SUPPORTED_DISTS)"))
        cv > 0 || throw(ArgumentError("service.$name.cv must be > 0"))
        push!(services, ServiceType(name, share, dist, mean_s, cv))
    end
    sort!(services, by = s -> s.name)
    total_share = sum(s.share for s in services)
    abs(total_share - 1.0) > 1e-6 && throw(ArgumentError(
        "service shares must add up to 1.0, got $total_share"))

    queue = get(raw, "queue", Dict{String,Any}())
    mode_str = String(get(queue, "mode", "single"))
    mode = mode_str == "single" ? :single : mode_str == "per_server" ? :per_server :
        throw(ArgumentError("queue.mode must be \"single\" or \"per_server\""))

    behavior = get(raw, "behavior", Dict{String,Any}())
    balk = Int(get(behavior, "balk_queue_length", 0))
    patience_min = Float64(get(behavior, "patience_mean_minutes", 0.0))
    patience_min >= 0 || throw(ArgumentError("behavior.patience_mean_minutes must be >= 0"))

    servers_tbl = get(raw, "servers", Dict{String,Any}())
    default_servers = Int(get(servers_tbl, "count", get(sim, "servers", 2)))
    1 <= default_servers <= 100 || throw(ArgumentError("servers.count must be between 1 and 100"))

    shifts = Tuple{Float64,Float64,Int}[]
    for (i, sh) in enumerate(get(raw, "shifts", []))
        sh isa AbstractDict || throw(ArgumentError("shifts entry #$i must be a table"))
        from = parse_clock(String(get(sh, "from", "")))
        to = parse_clock(String(get(sh, "to", "")))
        c = Int(get(sh, "count", -1))
        to > from || throw(ArgumentError("shifts entry #$i: to must be after from"))
        c >= 1 || throw(ArgumentError("shifts entry #$i: count must be >= 1"))
        push!(shifts, (from, to, c))
    end
    sort!(shifts, by = s -> s[1])

    sla = get(raw, "sla", Dict{String,Any}())
    sla_p90 = Float64(get(sla, "p90_wait_minutes", 5.0)) * 60
    sla_abandon = Float64(get(sla, "max_abandon_percent", 2.0))
    sla_p90 >= 0 || throw(ArgumentError("sla.p90_wait_minutes must be >= 0"))
    0 <= sla_abandon <= 100 || throw(ArgumentError("sla.max_abandon_percent must be between 0 and 100"))

    cost = get(raw, "cost", Dict{String,Any}())
    cashier_per_hour = Float64(get(cost, "cashier_per_hour", 0.0))
    lost_customer_cost = Float64(get(cost, "lost_customer_cost", 0.0))
    cashier_per_hour >= 0 || throw(ArgumentError("cost.cashier_per_hour must be >= 0"))
    lost_customer_cost >= 0 || throw(ArgumentError("cost.lost_customer_cost must be >= 0"))

    report_tbl = get(raw, "report", Dict{String,Any}())
    max_servers = Int(get(report_tbl, "max_servers", 8))
    1 <= max_servers <= 50 || throw(ArgumentError("report.max_servers must be between 1 and 50"))

    return SimConfig(open_s, close_s, replications, seed, bin_minutes, rates,
                     arrival_scale, services, mode, balk, patience_min * 60,
                     default_servers, shifts, sla_p90, sla_abandon,
                     cashier_per_hour, lost_customer_cost, max_servers, check_invariants)
end
