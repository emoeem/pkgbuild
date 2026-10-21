# AUR package overlays

Put every local `PKGBUILD` customization in `scripts/overlays/<package-name>.sh`.
The AUR sync script replaces `packages/<name>/PKGBUILD` with the upstream version
before applying that package's overlay, so edits made directly to
`packages/*/PKGBUILD` will be overwritten by the next AUR synchronization.

Overlays receive the staged package directory as their first argument. Keep them
idempotent so a repeated application does not accumulate changes, and fail with a
non-zero status if the expected upstream structure is not present.

## Stamp every change with a marker

Write `# emoeem overlay: <what this changes and why>` next to each edit an
overlay makes. `check-package-manifests.py` refuses a PKGBUILD that carries a
marker no overlay emits, and CI's build-regression suite asserts that the
marker is still present in the committed package.

That is not ceremony. `scx-scheds-git`'s `/usr/bin/scxtui` exclusion was once
written straight into `packages/scx-scheds-git/PKGBUILD`; the next AUR sync
(`e38a21e`) restored upstream's `package()` verbatim, the exclusion disappeared
without a trace, and the build failed again on a file collision with
`scx-tools` (run 39571220772) with nothing in the diff to explain the
regression. A marker turns that silent loss into a failed check.
