# Operations

## Daily

- Review open `[upstream]`, `[freshness]`, `[cache-usage]`, and `[CI]` issues.
- Confirm the latest upstream and published versions are consistent.
- Investigate unresolved dependency reports instead of treating them as stale.

## Updating a Package

1. Run manifest/static checks.
2. Update `PKGBUILD` and `.SRCINFO` together.
3. For AUR mirrors, use `sync-aur-packages.sh` or the sync workflow.
4. For vendored dependencies, update the owner package and preserve its pin.
5. Build and run ELF/runtime verification.
6. Publish only through the repository gates.

## Recovering a Failed Publish

Preserve the old `repo` release assets and database. Re-run build verification,
restore only the last valid snapshot when a transaction is not publishable, and
record the rollback reason before retrying.
