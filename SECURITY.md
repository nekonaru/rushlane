# Security Policy

## Reporting a vulnerability

Please report security issues privately by opening a GitHub Security Advisory
on the repository (Security tab, "Report a vulnerability"). Do not open a
public issue for an undisclosed vulnerability.

You can expect an acknowledgement within 7 days. Rushlane is a simulation
library; it has no network services, no accounts and stores no personal data.
The most relevant risks are crashes or excessive resource use when parsing
untrusted configuration files.

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |

## Scope

- Input validation of TOML configuration files
- Resource usage during simulation runs
- Dependency integrity (registered Julia packages only, committed Manifest.toml)
