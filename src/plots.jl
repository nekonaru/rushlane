# Plots (CairoMakie): queue length over time, wait histogram, metrics vs servers.

using CairoMakie

const BRAND_GREEN = "#2E9E57"
const BRAND_INK = "#1B1B1A"

"""
    generate_queue_plot(series_t, series_len, cfg; path="out/queue_length.png") -> String

Line plot of the time-weighted average number of customers waiting, averaged
over 15-minute buckets, x axis in hours since open.
"""
function generate_queue_plot(series_t::AbstractVector, series_len::AbstractVector, cfg::SimConfig;
                             path::AbstractString="out/queue_length.png")::String
    mkpath(dirname(path))
    day_seconds = cfg.close_seconds - cfg.open_seconds
    bucket = 15 * 60
    n_buckets = ceil(Int, day_seconds / bucket)
    sums = zeros(Float64, n_buckets)
    counts = zeros(Float64, n_buckets)
    # series is a step function: value series_len[i] holds over (series_t[i], series_t[i+1]]
    # walk it and distribute each segment over the buckets it overlaps
    for i in eachindex(series_t)
        t0 = series_t[i]
        v = series_len[i]
        t1 = i < length(series_t) ? series_t[i + 1] : cfg.close_seconds
        t1 = min(t1, cfg.close_seconds)
        t1 <= t0 && continue
        b0 = clamp(floor(Int, (t0 - cfg.open_seconds) / bucket) + 1, 1, n_buckets)
        b1 = clamp(floor(Int, (t1 - cfg.open_seconds) / bucket) + 1, 1, n_buckets)
        for b in b0:b1
            seg_start = max(t0, cfg.open_seconds + (b - 1) * bucket)
            seg_end = min(t1, cfg.open_seconds + b * bucket)
            seg = seg_end - seg_start
            if seg > 0
                sums[b] += v * seg
                counts[b] += seg
            end
        end
    end
    avg = sums ./ max.(counts, 1e-9)
    x = ((1:n_buckets) .- 0.5) .* (bucket / 3600)
    fig = Figure(size = (900, 380), fontsize = 13)
    ax = Axis(fig[1, 1], xlabel = "Hours since open ($(format_clock(cfg.open_seconds)))",
              ylabel = "Customers waiting", title = "Queue length over the day (15-minute average)")
    lines!(ax, x, avg, color = BRAND_GREEN, linewidth = 2.2)
    save(path, fig)
    return path
end

"""
    generate_wait_histogram(waits_seconds; path="out/wait_histogram.png", bins=40) -> String

Histogram of queueing delay (seconds) for served customers.
"""
function generate_wait_histogram(waits_seconds::AbstractVector;
                                 path::AbstractString="out/wait_histogram.png", bins::Int=40)::String
    mkpath(dirname(path))
    fig = Figure(size = (900, 380), fontsize = 13)
    ax = Axis(fig[1, 1], xlabel = "Waiting time (seconds)", ylabel = "Customers",
              title = "Waiting time distribution")
    hist!(ax, waits_seconds, bins = bins, color = BRAND_GREEN, strokewidth = 0)
    save(path, fig)
    return path
end

"""
    generate_metrics_vs_servers(table::DataFrame; path="out/metrics_vs_servers.png") -> String

Two panels: mean wait (min) with 95% CI error bars, and abandon percent with
CI error bars, both against the number of cashiers.
"""
function generate_metrics_vs_servers(table::DataFrame;
                                     path::AbstractString="out/metrics_vs_servers.png")::String
    mkpath(dirname(path))
    servers = table.servers
    wait_min = table.wait_mean_seconds ./ 60
    wait_ci = table.wait_mean_seconds_ci ./ 60
    abandon = table.abandon_percent
    abandon_ci = table.abandon_percent_ci

    fig = Figure(size = (900, 380), fontsize = 13)
    ax1 = Axis(fig[1, 1], xlabel = "Cashiers", ylabel = "Average wait (min)",
               title = "Wait vs cashiers", xticks = servers)
    errorbars!(ax1, servers, wait_min, wait_ci, color = :gray50)
    lines!(ax1, servers, wait_min, color = BRAND_GREEN, linewidth = 2)
    scatter!(ax1, servers, wait_min, color = BRAND_GREEN, markersize = 10)

    ax2 = Axis(fig[1, 2], xlabel = "Cashiers", ylabel = "Abandoned (%)",
               title = "Abandon vs cashiers", xticks = servers)
    errorbars!(ax2, servers, abandon, abandon_ci, color = :gray50)
    lines!(ax2, servers, abandon, color = BRAND_INK, linewidth = 2)
    scatter!(ax2, servers, abandon, color = BRAND_INK, markersize = 10)

    save(path, fig)
    return path
end
