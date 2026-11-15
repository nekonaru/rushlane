# Project

- PROJECT_NAME: Rushlane
- REPO: nekonaru/rushlane
- AUTHOR_NAME: Nicolas Dwi Dharma
- AUTHOR_GITHUB: nekonaru
- PROJECT_KIND: general
- STACK: Julia 1.10+
- PLATFORMS: Cross-platform (Windows, Linux, macOS)
- MIN_OS: n/a
- DEFAULT_BRANCH: main
- LICENSE: MIT
- UI_LANGUAGES: English, Bahasa Indonesia
- VERIFICATION: local-and-ci
- PIPELINE: pr

# Notes

- Package is a Julia library plus CLI scripts under `scripts/`.
- `Manifest.toml` is intentionally not committed. A single lockfile cannot span
  Julia 1.10 (no StyledStrings stdlib) and 1.12+ (StyledStrings is a stdlib with
  a different constructor), so each supported Julia resolves fresh from the
  compat bounds in `Project.toml`. CI tests on Julia 1.10 and 1.x confirm both.
- Security gate: `security-general.md` toolkit applies (kind = general).
