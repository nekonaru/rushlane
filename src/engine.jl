# Discrete-event engine: hand-written min-heap event loop.
# Time is Float64 seconds since midnight and never moves backwards.

using Random: AbstractRNG
using DataStructures: BinaryMinHeap, Deque, push!, popfirst!, isempty
using Distributions: Exponential, LogNormal, Gamma, Normal
import StableRNGs: StableRNG

# ---------- service time sampling ----------

function sample_service(s::ServiceType, rng::AbstractRNG)::Float64
    if s.dist === :exponential
        return rand(rng, Exponential(s.mean_seconds))
    elseif s.dist === :lognormal
        sigma2 = log(1 + s.cv^2)
        mu = log(s.mean_seconds) - sigma2 / 2
        return rand(rng, LogNormal(mu, sqrt(sigma2)))
    elseif s.dist === :gamma
        k = 1 / s.cv^2
        theta = s.mean_seconds * s.cv^2
        return rand(rng, Gamma(k, theta))
    elseif s.dist === :normal
        return max(rand(rng, Normal(s.mean_seconds, s.cv * s.mean_seconds)), 0.5)
    elseif s.dist === :constant
        return s.mean_seconds
    end
    error("unsupported distribution: $(s.dist)")
end

function sample_type(services::Vector{ServiceType}, rng::AbstractRNG)::Int
    u = rand(rng)
    acc = 0.0
    for (i, s) in enumerate(services)
        acc += s.share
        u <= acc && return i
    end
    return length(services)
end

# ---------- state ----------

mutable struct Customer
    id::Int
    arrival::Float64
    stype::Int
    service_time::Float64
    patience_deadline::Float64   # Inf when reneging is disabled
    state::Symbol                # :waiting | :in_service | :done | :balked | :reneged
    lane::Int                    # 1-based lane index; 1 for the shared queue in :single mode
    entered::Float64             # time service started (NaN until then)
    done_at::Float64
end
Customer(id::Int, arrival::Float64, stype::Int, service_time::Float64, patience_deadline::Float64, lane::Int) =
    Customer(id, arrival, stype, service_time, patience_deadline, :waiting, lane, NaN, NaN)

mutable struct Server
    id::Int
    on::Bool
    leaving::Bool                # finish current service, then turn off
    busy::Bool
    current_customer::Int        # customer id or -1
    busy_time::Float64           # cumulative seconds spent serving
end
Server(id::Int) = Server(id, false, false, false, -1, 0.0)

struct SimResult
    waits::Vector{Float64}               # queueing delay per served customer (seconds)
    sojourns::Vector{Float64}            # arrival to departure per served customer (seconds)
    arrivals::Int
    done::Int
    balked::Int
    reneged::Int
    throughput_per_hour::Float64
    avg_queue_length::Float64            # time-weighted average number waiting
    max_queue_length::Int
    utilization::Float64                  # busy seconds / scheduled server seconds
    queue_series_t::Vector{Float64}      # value of the queue at each tick (step series)
    queue_series_len::Vector{Float64}
end

mutable struct EngineState
    t::Float64
    heap::BinaryMinHeap{Tuple{Float64,Int,Symbol,Int}}
    seq::Int
    customers::Vector{Customer}
    servers::Vector{Server}
    lanes::Vector{Deque{Int}}
    lane_waiting::Vector{Int}            # exact count of :waiting customers per lane
    waiting_total::Int
    balked::Int
    reneged::Int
    done::Int
    waits::Vector{Float64}
    sojourns::Vector{Float64}
    series_t::Vector{Float64}
    series_len::Vector{Float64}
    max_queue::Int
    q_last_t::Float64                    # queue-integral cursor
    queue_integral::Float64
    cap_last_t::Float64                  # capacity-integral cursor
    capacity_integral::Float64
    last_capacity::Int
end

@inline function push_event!(st::EngineState, time::Float64, kind::Symbol, id::Int)
    st.seq += 1
    push!(st.heap, (time, st.seq, kind, id))
end

# Integrate the queue length over [q_last_t, t) using the value before the change.
# Must be called BEFORE mutating waiting_total.
@inline function tick!(st::EngineState, t::Float64)
    st.queue_integral += st.waiting_total * (t - st.q_last_t)
    st.q_last_t = t
    push!(st.series_t, t)
    push!(st.series_len, Float64(st.waiting_total))
end

function target_capacity(cfg::SimConfig, t::Float64)::Int
    servers_at(cfg, t)
end

function activate_servers!(st::EngineState, n::Int)
    for s in st.servers
        n == 0 && break
        if !s.on
            s.on = true
            s.leaving = false
            n -= 1
        end
    end
end

function gather_lane!(st::EngineState, lane_id::Int, into::Vector{Int})
    lane = st.lanes[lane_id]
    while !isempty(lane)
        cid = popfirst!(lane)
        c = st.customers[cid+1]
        if c.state === :waiting
            push!(into, cid)
        end
    end
    st.lane_waiting[lane_id] = 0
end

# Pick a lane whose server is on and not leaving, shortest first.
function shortest_lane(st::EngineState)::Int
    best = 0
    best_n = typemax(Int)
    for i in eachindex(st.lanes)
        s = st.servers[min(i, length(st.servers))]
        if length(st.lanes) > 1 && (!s.on || s.leaving)
            continue
        end
        n = st.lane_waiting[i]
        if n < best_n
            best = i
            best_n = n
        end
    end
    return best == 0 ? 1 : best
end

# Remove n servers: idle ones first, then mark busy ones as leaving.
# Waiting customers in affected lanes are redistributed to the remaining lanes.
function deactivate_servers!(st::EngineState, n::Int, cfg::SimConfig)
    removed = Int[]
    for s in st.servers
        n == 0 && break
        if s.on && !s.busy && !s.leaving
            s.on = false
            if cfg.queue_mode === :per_server
                gather_lane!(st, s.id, removed)
            end
            n -= 1
        end
    end
    for s in st.servers
        n == 0 && break
        if s.on && s.busy && !s.leaving
            s.leaving = true
            if cfg.queue_mode === :per_server
                gather_lane!(st, s.id, removed)
            end
            n -= 1
        end
    end
    for cid in removed
        lane = shortest_lane(st)
        st.customers[cid+1].lane = lane
        push!(st.lanes[lane], cid)
        st.lane_waiting[lane] += 1
    end
end

function apply_capacity!(st::EngineState, cfg::SimConfig, t::Float64)
    # integrate capacity over the elapsed interval with the old capacity
    st.capacity_integral += st.last_capacity * (t - st.cap_last_t)
    st.cap_last_t = t

    target = target_capacity(cfg, t)
    current = count(s -> s.on, st.servers)
    if target > current
        activate_servers!(st, target - current)
    elseif target < current
        deactivate_servers!(st, current - target, cfg)
    end
    st.last_capacity = target
    dispatch!(st, cfg)
end

function dispatch!(st::EngineState, cfg::SimConfig)
    for s in st.servers
        if !s.on || s.leaving || s.busy
            continue
        end
        lane_idx = cfg.queue_mode === :single ? 1 : s.id
        lane = st.lanes[lane_idx]
        while !isempty(lane)
            cid = popfirst!(lane)
            c = st.customers[cid+1]
            if c.state !== :waiting
                continue  # stale entry; its count was already adjusted at renege time
            end
            tick!(st, st.t)
            c.state = :in_service
            c.entered = st.t
            c.lane = lane_idx
            s.busy = true
            s.current_customer = cid
            st.waiting_total -= 1
            st.lane_waiting[lane_idx] -= 1
            push!(st.waits, c.entered - c.arrival)
            push!(st.series_t, st.t)
            push!(st.series_len, Float64(st.waiting_total))
            push_event!(st, st.t + c.service_time, :service_done, s.id)
            if cfg.check_invariants && st.waiting_total < 0
                error("queue length went negative")
            end
            break
        end
    end
end

"""
    simulate(cfg::SimConfig; rng=nothing, servers_override=nothing) -> SimResult

Run one simulated day. `rng` defaults to `StableRNG(cfg.seed)`. When
`servers_override` is given, the day uses that constant server count (shifts
ignored) so scenarios can be compared with common random numbers.
"""
function simulate(cfg::SimConfig; rng::Union{AbstractRNG,Nothing}=nothing,
                  servers_override::Union{Int,Nothing}=nothing)::SimResult
    rng = rng === nothing ? StableRNG(cfg.seed) : rng

    if servers_override !== nothing
        cfg = SimConfig(cfg.open_seconds, cfg.close_seconds, cfg.replications, cfg.seed,
                        cfg.bin_minutes, cfg.rates_per_hour, cfg.arrival_scale, cfg.services,
                        cfg.queue_mode, cfg.balk_queue_length, cfg.patience_mean_seconds,
                        servers_override, Tuple{Float64,Float64,Int}[],
                        cfg.sla_p90_wait_seconds, cfg.sla_max_abandon_percent,
                        cfg.cashier_per_hour, cfg.lost_customer_cost, cfg.max_servers,
                        cfg.check_invariants)
    end

    arrivals = generate_arrivals(cfg, rng)

    max_shift = isempty(cfg.shifts) ? 0 : maximum(s -> s[3], cfg.shifts)
    n_server_slots = max(cfg.default_servers, max_shift)
    n_lanes = cfg.queue_mode === :single ? 1 : n_server_slots

    st = EngineState(cfg.open_seconds, BinaryMinHeap{Tuple{Float64,Int,Symbol,Int}}(), 0,
                     Customer[], [Server(i) for i in 1:n_server_slots],
                     [Deque{Int}() for _ in 1:n_lanes], zeros(Int, n_lanes),
                     0, 0, 0, 0, Float64[], Float64[],
                     [cfg.open_seconds], [0.0], 0,
                     cfg.open_seconds, 0.0, cfg.open_seconds, 0.0,
                     target_capacity(cfg, cfg.open_seconds))

    # schedule arrivals (stream of draws happens here, once, in arrival order)
    for (i, ta) in enumerate(arrivals)
        service_idx = sample_type(cfg.services, rng)
        svc = sample_service(cfg.services[service_idx], rng)
        patience = cfg.patience_mean_seconds > 0 ? rand(rng, Exponential(cfg.patience_mean_seconds)) : Inf
        push!(st.customers, Customer(i - 1, ta, service_idx, svc, ta + patience, 1))
        push_event!(st, ta, :arrival, i - 1)
    end

    # shift boundary events
    boundaries = sort!(unique(vcat(Float64[], [s[1] for s in cfg.shifts], [s[2] for s in cfg.shifts])))
    for b in boundaries
        if b >= cfg.open_seconds && b < cfg.close_seconds
            push_event!(st, b, :shift, 0)
        end
    end

    # initial capacity
    initial = target_capacity(cfg, cfg.open_seconds)
    activate_servers!(st, initial)
    st.last_capacity = initial

    last_event_t = cfg.open_seconds
    while !isempty(st.heap)
        (t, _, kind, id) = pop!(st.heap)
        if cfg.check_invariants && t < last_event_t
            error("event time went backwards: $t < $last_event_t")
        end
        last_event_t = t
        st.t = t

        if kind === :arrival
            c = st.customers[id+1]
            lane = cfg.queue_mode === :single ? 1 : shortest_lane(st)
            if cfg.balk_queue_length > 0 && st.lane_waiting[lane] >= cfg.balk_queue_length
                c.state = :balked
                c.done_at = t
                st.balked += 1
            else
                tick!(st, t)
                c.lane = lane
                push!(st.lanes[lane], id)
                st.lane_waiting[lane] += 1
                st.waiting_total += 1
                st.max_queue = max(st.max_queue, st.waiting_total)
                push!(st.series_t, t)
                push!(st.series_len, Float64(st.waiting_total))
                if isfinite(c.patience_deadline)
                    push_event!(st, c.patience_deadline, :renege, id)
                end
            end
            dispatch!(st, cfg)

        elseif kind === :renege
            c = st.customers[id+1]
            if c.state === :waiting
                tick!(st, t)
                c.state = :reneged
                c.done_at = t
                st.reneged += 1
                st.waiting_total -= 1
                st.lane_waiting[c.lane] -= 1
                push!(st.series_t, t)
                push!(st.series_len, Float64(st.waiting_total))
                if cfg.check_invariants && (st.waiting_total < 0 || st.lane_waiting[c.lane] < 0)
                    error("waiting count went negative on renege")
                end
            end

        elseif kind === :service_done
            s = st.servers[id]
            cid = s.current_customer
            cfg.check_invariants && cid < 0 && error("service_done with no customer on server $id")
            c = st.customers[cid+1]
            cfg.check_invariants && c.state !== :in_service &&
                error("service_done for customer not in service")
            c.state = :done
            c.done_at = t
            s.busy = false
            s.current_customer = -1
            s.busy_time += c.service_time
            st.done += 1
            push!(st.sojourns, t - c.arrival)
            if s.leaving
                s.leaving = false
                s.on = false
                if cfg.queue_mode === :per_server
                    leftover = Int[]
                    gather_lane!(st, s.id, leftover)
                    for cid2 in leftover
                        lane = shortest_lane(st)
                        st.customers[cid2+1].lane = lane
                        push!(st.lanes[lane], cid2)
                        st.lane_waiting[lane] += 1
                    end
                end
            end
            dispatch!(st, cfg)

        elseif kind === :shift
            apply_capacity!(st, cfg, t)
        end
    end

    # close the integrals at end of day
    final_t = cfg.close_seconds
    st.queue_integral += st.waiting_total * (final_t - st.q_last_t)
    st.capacity_integral += st.last_capacity * (final_t - st.cap_last_t)

    day_seconds = cfg.close_seconds - cfg.open_seconds
    utilization = st.capacity_integral > 0 ?
        min(1.0, sum(s.busy_time for s in st.servers) / st.capacity_integral) : 0.0

    SimResult(st.waits, st.sojourns, length(arrivals), st.done, st.balked, st.reneged,
              st.done / (day_seconds / 3600),
              st.queue_integral / day_seconds,
              st.max_queue, utilization, st.series_t, st.series_len)
end
