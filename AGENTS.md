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
- `Manifest.toml` is committed, pinned for Julia 1.10 LTS (the oldest supported
  version). It cannot be used on Julia 1.12+ (StyledStrings became a stdlib
  with a different constructor), so newer Julia deletes it and resolves from
  the compat bounds in `Project.toml`. CI runs 1.10 with the lockfile and
  1.x with it removed.
- Security gate: `security-general.md` toolkit applies (kind = general).
