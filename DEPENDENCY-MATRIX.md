# Dependency Matrix

## Dependency Classes

- Official repository dependency
- Arch/CachyOS third-party repository dependency
- AUR dependency
- Vendored source or pinned commit
- Build dependency
- Runtime dependency
- Optional dependency

## Detection Rules

`check-dependency-drift.sh`:

- compares pkgver changes, not pkgrel-only rebuilds;
- queries pacman repositories first;
- queries the AUR RPC only for declared external providers;
- caches successful AUR lookups briefly;
- reports unresolved providers instead of converting lookup failure to stale.

`check-repository-sonames.sh`:

- validates ELF `DT_NEEDED`;
- derives providers from repository file databases, published assets and declared external SONAMEs;
- rejects incomplete provider databases;
- rejects stale `.rebuild-on` declarations that do not match the artifact.
