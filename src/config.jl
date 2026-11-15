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

# ---------- boundary type guards ----------

function _int_field(tbl::AbstractDict, key, default::Int, name::AbstractString)::Int
    v = get(tbl, key, default)
    if v isa Bool
        throw(ArgumentError("$name must be a number, not a boolean"))
    elseif v isa Integer
        return Int(v)
    elseif v isa Real && isfinite(v) && v == floor(v)
        return Int(v)
    end
    throw(ArgumentError("$name must be an integer, got: $(repr(v))"))
end

function _number_field(tbl::AbstractDict, key, default::Float64, name::AbstractString)::Float64
    v = get(tbl, key, default)
    if v isa Bool || !(v isa Real)
        throw(ArgumentError("$name must be a number, got: $(repr(v))"))
    end
    f = Float64(v)
    isfinite(f) || throw(ArgumentError("$name must be finite, got: $(repr(v))"))
    return f
end

function _string_field(tbl::AbstractDict, key, default::AbstractString, name::AbstractString)::String
    v = get(tbl, key, default)
    v isa AbstractString || throw(ArgumentError("$name must be a string, got: $(repr(v))"))
    return String(v)
end

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
    sim isa AbstractDict || throw(ArgumentError("sim must be a table"))
    open_s = parse_clock(_string_field(sim, "open", "07:00", "sim.open"))
    close_s = parse_clock(_string_field(sim, "close", "16:00", "sim.close"))
    close_s > open_s || throw(ArgumentError("sim.close must be after sim.open"))
    replications = _int_field(sim, "replications", 200, "sim.replications")
    1 <= replications <= 10000 || throw(ArgumentError("sim.replications must be between 1 and 10000"))
    seed = _int_field(sim, "seed", 2026, "sim.seed")
    seed >= 0 || throw(ArgumentError("sim.seed must be >= 0"))

    arr = get(raw, "arrivals", Dict{String,Any}())
    arr isa AbstractDict || throw(ArgumentError("arrivals must be a table"))
    bin_minutes = _int_field(arr, "bin_minutes", 15, "arrivals.bin_minutes")
    1 <= bin_minutes <= 1440 || throw(ArgumentError("arrivals.bin_minutes must be between 1 and 1440"))
    rates_raw = get(arr, "rates_per_hour", Float64[])
    rates_raw isa AbstractVector || throw(ArgumentError("arrivals.rates_per_hour must be a list of numbers"))
    rates = map(enumerate(rates_raw)) do (i, r)
        r isa Bool && throw(ArgumentError("arrivals.rates_per_hour[$i] must be a number, not a boolean"))
        r isa Real || throw(ArgumentError("arrivals.rates_per_hour[$i] must be a number, got: $(repr(r))"))
        f = Float64(r)
        isfinite(f) || throw(ArgumentError("arrivals.rates_per_hour[$i] must be finite, got: $(repr(r))"))
        f
    end
    all(r -> 0 <= r <= 100000, rates) ||
        throw(ArgumentError("arrivals.rates_per_hour entries must be between 0 and 100000"))
    n_bins = ceil(Int, (close_s - open_s) / (bin_minutes * 60))
    length(rates) == n_bins || throw(ArgumentError(
        "arrivals.rates_per_hour has $(length(rates)) entries but the day needs $n_bins bins of $(bin_minutes) minutes"))
    arrival_scale = _number_field(arr, "scale", 1.0, "arrivals.scale")
    arrival_scale > 0 || throw(ArgumentError("arrivals.scale must be > 0"))

    services_raw = get(raw, "service", Dict{String,Any}())
    services_raw isa AbstractDict || throw(ArgumentError("service must be a table of tables"))
    isempty(services_raw) && throw(ArgumentError("at least one [service.<name>] table is required"))
    services = ServiceType[]
    for (name, spec) in services_raw
        spec isa AbstractDict || throw(ArgumentError("service.$name must be a table"))
        share = _number_field(spec, "share", NaN, "service.$name.share")
        mean_s = _number_field(spec, "mean_seconds", NaN, "service.$name.mean_seconds")
        dist_str = _string_field(spec, "dist", "lognormal", "service.$name.dist")
        dist = Symbol(dist_str)
        cv = _number_field(spec, "cv", dist == :exponential ? 1.0 : 0.5, "service.$name.cv")
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
    queue isa AbstractDict || throw(ArgumentError("queue must be a table"))
    mode_str = _string_field(queue, "mode", "single", "queue.mode")
    mode = mode_str == "single" ? :single : mode_str == "per_server" ? :per_server :
        throw(ArgumentError("queue.mode must be \"single\" or \"per_server\""))

    behavior = get(raw, "behavior", Dict{String,Any}())
    behavior isa AbstractDict || throw(ArgumentError("behavior must be a table"))
    balk = _int_field(behavior, "balk_queue_length", 0, "behavior.balk_queue_length")
    0 <= balk <= 10000 || throw(ArgumentError("behavior.balk_queue_length must be between 0 and 10000 (0 disables balking)"))
    patience_min = _number_field(behavior, "patience_mean_minutes", 0.0, "behavior.patience_mean_minutes")
    patience_min >= 0 || throw(ArgumentError("behavior.patience_mean_minutes must be >= 0"))

    servers_tbl = get(raw, "servers", Dict{String,Any}())
    servers_tbl isa AbstractDict || throw(ArgumentError("servers must be a table"))
    sim_servers = _int_field(sim, "servers", 2, "sim.servers")
    default_servers = _int_field(servers_tbl, "count", sim_servers, "servers.count")
    1 <= default_servers <= 100 || throw(ArgumentError("servers.count must be between 1 and 100"))

    shifts = Tuple{Float64,Float64,Int}[]
    shifts_raw = get(raw, "shifts", [])
    shifts_raw isa AbstractVector || throw(ArgumentError("shifts must be a list of tables"))
    for (i, sh) in enumerate(shifts_raw)
        sh isa AbstractDict || throw(ArgumentError("shifts entry #$i must be a table"))
        from = parse_clock(_string_field(sh, "from", "", "shifts entry #$i.from"))
        to = parse_clock(_string_field(sh, "to", "", "shifts entry #$i.to"))
        c = _int_field(sh, "count", -1, "shifts entry #$i.count")
        to > from || throw(ArgumentError("shifts entry #$i: to must be after from"))
        c >= 1 || throw(ArgumentError("shifts entry #$i: count must be >= 1"))
        push!(shifts, (from, to, c))
    end
    sort!(shifts, by = s -> s[1])

    sla = get(raw, "sla", Dict{String,Any}())
    sla isa AbstractDict || throw(ArgumentError("sla must be a table"))
    sla_p90 = _number_field(sla, "p90_wait_minutes", 5.0, "sla.p90_wait_minutes") * 60
    sla_abandon = _number_field(sla, "max_abandon_percent", 2.0, "sla.max_abandon_percent")
    sla_p90 >= 0 || throw(ArgumentError("sla.p90_wait_minutes must be >= 0"))
    0 <= sla_abandon <= 100 || throw(ArgumentError("sla.max_abandon_percent must be between 0 and 100"))

    cost = get(raw, "cost", Dict{String,Any}())
    cost isa AbstractDict || throw(ArgumentError("cost must be a table"))
    cashier_per_hour = _number_field(cost, "cashier_per_hour", 0.0, "cost.cashier_per_hour")
    lost_customer_cost = _number_field(cost, "lost_customer_cost", 0.0, "cost.lost_customer_cost")
    cashier_per_hour >= 0 || throw(ArgumentError("cost.cashier_per_hour must be >= 0"))
    lost_customer_cost >= 0 || throw(ArgumentError("cost.lost_customer_cost must be >= 0"))

    report_tbl = get(raw, "report", Dict{String,Any}())
    report_tbl isa AbstractDict || throw(ArgumentError("report must be a table"))
    max_servers = _int_field(report_tbl, "max_servers", 8, "report.max_servers")
    1 <= max_servers <= 50 || throw(ArgumentError("report.max_servers must be between 1 and 50"))

    return SimConfig(open_s, close_s, replications, seed, bin_minutes, rates,
                     arrival_scale, services, mode, balk, patience_min * 60,
                     default_servers, shifts, sla_p90, sla_abandon,
                     cashier_per_hour, lost_customer_cost, max_servers, check_invariants)
end
