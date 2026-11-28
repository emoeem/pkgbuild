# Final Acceptance

## Automated Update

- Every nvchecker source resolves to an owned route.
- Vendored dependencies are not sent to AUR sync.
- Dedicated and manual packages have explicit registry entries.
- AUR and network failures are visible and retryable.

## ABI and Dependencies

- SONAME declarations are package-local.
- Stale declarations fail manifest validation or artifact validation.
- Provider lookup failures remain unresolved.
- pkgrel-only changes do not rebuild routinely.
- Successful rebuild cooldown does not suppress real SONAME breaks.

## Build and Quality

- Static checks run independently of package selection.
- Bash syntax, ShellCheck, Python compilation and package manifests are gates.
- `.SRCINFO`, checksum, namcap, ELF, runtime and smoke checks remain in place.
- A failed package wave does not publish its partial repository.

## Release

- Publishing uses verification of all incoming assets and repository databases.
- Repository and package content are verified before publication.
- Rollback retains the previously valid repository snapshot.
- GitHub Release assets are kept consistent with the published database.
