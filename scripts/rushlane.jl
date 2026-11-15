#!/usr/bin/env julia
# One-command entry point:
#   julia --project=. scripts/rushlane.jl [config.toml] [--out DIR]
# Defaults to config/kantin_default.toml and out/.

using Rushlane

const USAGE = """
Usage:
  julia --project=. scripts/rushlane.jl [config.toml] [--out DIR]

Arguments:
  config.toml   Path to a TOML configuration file (default: config/kantin_default.toml)
  --out DIR     Output directory for the report, figures and CSVs (default: out)
  --help, -h    Show this message
"""

function main(args::Vector{String})
    config_path = nothing
    out_dir = "out"
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--help" || a == "-h"
            print(USAGE)
            return 0
        elseif a == "--out"
            i += 1
            i > length(args) && (println(stderr, "Error: --out requires a directory argument\n", USAGE); return 1)
            out_dir = args[i]
        elseif startswith(a, "-")
            println(stderr, "Error: unknown option '$a'\n", USAGE)
            return 1
        elseif config_path === nothing
            config_path = a
        else
            println(stderr, "Error: unexpected extra argument '$a'\n", USAGE)
            return 1
        end
        i += 1
    end

    if config_path === nothing
        config_path = joinpath(@__DIR__, "..", "config", "kantin_default.toml")
    end

    try
        println("Rushlane: loading $(config_path)")
        cfg = load_config(config_path)
        println("Generating report in $(out_dir)/ ...")
        path = write_report(cfg; out_dir = out_dir, config_name = basename(config_path))
        println("Done. Report: $(path)")
        return 0
    catch e
        println(stderr, "Error: ", sprint(showerror, e))
        return 1
    end
end

exit(main(ARGS))
