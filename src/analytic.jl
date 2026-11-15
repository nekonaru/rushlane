# Erlang C (M/M/c) formulas, used to validate the simulation in steady state.

"""
    erlang_c(lambda, mu, c) -> NamedTuple

M/M/c steady-state results with `lambda` arrival rate (per second), per-server
rate `mu` (per second), and `c` identical servers.

Returns `p_wait` (P(wait > 0)), `wq` (mean queueing delay in seconds, over all
arrivals), `lq` (mean number waiting) and `rho` (utilization). Requires
`lambda < c * mu`. Ratios are built iteratively so moderate offered loads
(a < 300) are safe in Float64.
"""
function erlang_c(lambda::Real, mu::Real, c::Int)
    lambda > 0 || throw(ArgumentError("lambda must be > 0"))
    mu > 0 || throw(ArgumentError("mu must be > 0"))
    c >= 1 || throw(ArgumentError("c must be >= 1"))
    a = lambda / mu
    rho = a / c
    rho < 1 || throw(ArgumentError("unstable: offered load a=$a must be < c=$c"))

    # S = sum_{k=0..c-1} a^k / k!, built with the recurrence term *= a / k
    s = 1.0
    term = 1.0
    for k in 1:(c - 1)
        term *= a / k
        s += term
    end
    # t = a^c / c!
    t = 1.0
    for k in 1:c
        t *= a / k
    end
    tail = t * c / (c - a)
    p_wait = tail / (s + tail)
    wq = p_wait / (c * mu - lambda)
    lq = lambda * wq
    return (p_wait = p_wait, wq = wq, lq = lq, rho = rho, a = a)
end
