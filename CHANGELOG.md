# Changelog

## v0.1.0

First public release. Rushlane simulates a campus canteen queue and recommends the smallest cashier count that meets your service targets.

## New features

- **Discrete-event engine.** Hand-written min-heap event loop with arrival, service start, service done and renege events, no simulation library.
- **Non-uniform arrivals.** Nonhomogeneous Poisson process with per-bin rates and a global rush-day scale factor.
- **Two queue modes.** Single shared FIFO line or one line per cashier with shortest-line selection.
- **Balking and reneging.** Customers refuse to join a long line and leave after their patience runs out.
- **Replication with confidence intervals.** Configurable replications with 95% t-based intervals and common random numbers across scenarios.
- **Erlang C validation.** Simulation output matches M/M/c theory in steady state (within 3%).
- **Optimizer.** Finds the smallest cashier count meeting the SLA and compares daily cashier wages against expected lost sales.
- **One-command report.** `julia --project=. scripts/rushlane.jl` produces a Markdown report, figures and CSV exports.
- **Cashier shifts.** Optional per-window staffing levels, for example heavier staffing during lunch.

## Improvements

- **Pinned installs.** `Manifest.toml` is committed for Julia 1.10 LTS; newer Julia resolves fresh from the compat bounds in `Project.toml`.
- **Input validation.** Every TOML value is type- and range-checked at the boundary, with clear errors.
- **Logo assets.** Symbol masters rebuilt as pixel-accurate SVGs (light, dark, and single-colour versions) and the README header now uses the theme-aware mark.
