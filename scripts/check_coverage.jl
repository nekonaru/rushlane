# Coverage gate: fail if line coverage over src/ falls below the threshold.
# Usage: julia scripts/check_coverage.jl [threshold_percent]
# Run after `julia --project=. -e 'using Pkg; Pkg.test(coverage=true)'`.

function main()
    threshold = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 60.0

    src_dir = joinpath(@__DIR__, "..", "src")
    cov_files = filter(f -> endswith(f, ".cov"), readdir(src_dir; join = true))

    total_lines = 0
    covered_lines = 0
    for cov_file in cov_files
        for line in eachline(cov_file)
            m = match(r"^\s*(-|\d+)(?:\s|$)", line)
            m === nothing && continue
            marker = strip(m.captures[1])
            marker == "-" && continue  # non-coverable line
            total_lines += 1
            n = tryparse(Int, marker)
            if n !== nothing && n > 0
                covered_lines += 1
            end
        end
    end

    total_lines == 0 && (println("No coverage data found (expected .cov files next to src/)."); return 1)

    pct = 100 * covered_lines / total_lines
    println("Coverage: $(round(pct, digits = 1))% of $(total_lines) coverable lines")

    for cov_file in cov_files
        rm(cov_file)
    end

    if pct < threshold
        println("Coverage $(round(pct, digits = 1))% is below the $(threshold)% threshold.")
        return 1
    end
    println("Coverage gate passed.")
    return 0
end

exit(main())
