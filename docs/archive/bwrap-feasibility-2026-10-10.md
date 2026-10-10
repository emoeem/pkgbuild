# bubblewrap feasibility probe — 2026-10-10

## Result

The host already had `bwrap`; no package was installed and no host configuration was changed. A namespace/bind sanity probe succeeded:

```bash
bwrap --ro-bind / / --proc /proc --dev /dev /usr/bin/true
```

This confirms basic bubblewrap namespace setup is available in the current environment. It does **not** prove that a complete devtools clean-chroot build works: `makechrootpkg` / `pacstrap` needs nested mount operations, a writable package root, pacman cache/repository bind mounts, and package installation semantics that `fakeroot` does not itself provide. A complete bwrap + fakeroot build was not attempted because the request only called for a feasibility conclusion and the established rootless `makechrootpkg` failure is already known.

## Minimal next probe (disposable test root only)

```bash
bwrap --unshare-user --unshare-pid --ro-bind / / --proc /proc --dev /dev \
  --tmpfs /tmp --chdir / /usr/bin/true
```

Do not treat this as a replacement for the rootful GitHub Actions chroot acceptance path unless a real minimal PKGBUILD passes end-to-end with pacman DB, cache, and bind mounts.
