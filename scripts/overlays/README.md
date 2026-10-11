# AUR package overlays

Put every local `PKGBUILD` customization in `scripts/overlays/<package-name>.sh`.
The AUR sync script replaces `packages/<name>/PKGBUILD` with the upstream version
before applying that package's overlay, so edits made directly to
`packages/*/PKGBUILD` will be overwritten by the next AUR synchronization.

Overlays receive the staged package directory as their first argument. Keep them
idempotent so a repeated application does not accumulate changes, and fail with a
non-zero status if the expected upstream structure is not present.
