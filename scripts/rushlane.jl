#!/usr/bin/env julia
# One-command entry point:
#   julia --project=. scripts/rushlane.jl [config.toml] [--out DIR]
# Defaults to config/kantin_default.toml and out/.

using Rushlane

function main(args::Vector{String})
    config_path = length(args) >= 1 && !startswith(args[1], "--") ? args[1] :
        joinpath(@__DIR__, "..", "config", "kantin_default.toml")
    out_dir = "out"
    i = 1
    while i <= length(args)
        if args[i] == "--out" && i < length(args)
            out_dir = args[i+1]
            i += 2
        else
            i += 1
        end
    end

    println("Rushlane: loading $(config_path)")
    cfg = load_config(config_path)
    println("Generating report in $(out_dir)/ ...")
    path = write_report(cfg; out_dir = out_dir, config_name = basename(config_path))
    println("Done. Report: $(path)")
    return 0
end

exit(main(ARGS))
