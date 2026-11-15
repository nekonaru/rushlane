# Coverage gate: fail if line coverage over src/ falls below the threshold.
# Usage: julia scripts/check_coverage.jl [threshold_percent]
# Run after `julia --project=. --code-coverage=user -e 'using Pkg; Pkg.test()'`.

threshold = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 60.0

src_files = filter(f -> endswith(f, ".jl"), readdir(joinpath(@__DIR__, "..", "src"); join = true))

total_lines = 0
covered_lines = 0
for file in src_files
    cov_file = file * ".cov"
    isfile(cov_file) || continue
    for line in eachline(cov_file)
        # coverage files prefix each line with a count or '-' for non-executable
        m = match(r"^(\s*-|\s*\d+)\s*(.*)$", line)
        m === nothing && continue
        marker = strip(m.captures[1])
        if marker == "-"
            continue
        end
        total_lines += 1
        inner = m.captures[2]
        # A counted line is executed if the leading number is not 0
        n = tryparse(Int, marker)
        if n !== nothing && n > 0
            covered_lines += 1
        end
    end
end

if total_lines == 0
    println("No coverage data found (expected .cov files next to src/).")
    exit(1)
end

pct = 100 * covered_lines / total_lines
println("Coverage: $(round(pct, digits = 1))% of $(total_lines) coverable lines")

# Clean up .cov files so they never show up in git status
for file in readdir(joinpath(@__DIR__, "..", "src"); join = true)
    endswith(file, ".cov") && rm(file)
end

if pct < threshold
    println("Coverage $(round(pct, digits = 1))% is below the $(threshold)% threshold.")
    exit(1)
end
println("Coverage gate passed.")
