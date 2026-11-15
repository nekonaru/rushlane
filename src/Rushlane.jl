module Rushlane

# Rushlane: discrete-event simulation of campus canteen queues.
# Written by hand (no simulation library) with an explicit min-heap event queue.

using Statistics
import TOML

export load_config, simulate, run_replications, summarize,
       erlang_c, find_min_servers, optimize, expected_arrivals,
       write_report, generate_metrics_vs_servers, generate_queue_plot, generate_wait_histogram

include("config.jl")
include("arrivals.jl")
include("engine.jl")
include("metrics.jl")
include("analytic.jl")
include("optimize.jl")
include("plots.jl")
include("report.jl")

end # module
