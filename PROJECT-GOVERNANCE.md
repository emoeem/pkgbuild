# Project Governance

## Scope

This repository is governed by one release principle:
**discover, route, build, verify, publish, and record**.

## Source of Truth

- Package metadata: `packages/<name>/PKGBUILD` and `.SRCINFO`
- Update source: `.aur-url`/`.aur-commit`, `config/package-updates.txt`, or a vendored pin
- Rebuild triggers: `packages/<name>/`.rebuild-on
- Build strategy: `packages/<name>/`.build-strategy
- Published state: the `repo` GitHub Release

## Update States

`UP_TO_DATE`, `UPDATE_AVAILABLE`, `UPDATE_DETECTED`, `UPDATE_PROCESSING`,
`UPDATE_FAILED`, `BUILD_PENDING`, `BUILD_FAILED`, `PUBLISHED`, and
`MANUAL_REVIEW` must be distinguishable in issue and workflow output.

## Change Rules

1. Tests and manifest validation precede automation changes.
2. Unknown package sources fail closed.
3. pkgrel-only dependency changes do not trigger rebuilds.
4. Real SONAME breaks remain rebuild triggers.
5. External provider lookup failures remain `UNRESOLVED`, never `STALE`.
6. Failed publication never substitutes a partial repository for the old snapshot.
7. Commits and pushes require authorization; this governance document does not authorize them.
