# Security Policy

## Supply Chain

- Third-party GitHub Actions must be pinned to immutable commit SHAs.
- Dependabot tracks GitHub Actions and builder Docker dependencies.
- Builder and package sources are checksum- or digest-validated.
- Live configuration files preserve ownership and permissions.
- GPG operations must not expose passphrases in process arguments.

## Automation

- Shell inputs use environment variables instead of workflow expression interpolation.
- Workflow permissions are job-scoped and least-privilege.
- Unknown update routes fail closed.
- Failure notifications do not allow a failed scan to look clean.
- Pull requests and push workflows use concurrency cancellation where appropriate.

## Audit

Security scan history is retained under `docs/archive/`. A separate green scan
does not replace an existing change review; it is evidence for the exact commit
and scanner configuration under which it ran.
