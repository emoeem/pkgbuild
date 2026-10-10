# Build platform P1–P5 validation record — 2026-10-10

## Container boundary

- Base: existing `ghcr.io/emoeem/pkgbuild-builder:latest`, derived from `docker.io/cachyos/cachyos-v3:latest`.
- Local validation image: the same builder image with `devtools`, `nvchecker`, and `actionlint` installed in a disposable Podman container and committed to a local-only validation tag. No host package was installed.
- Rootless Podman / crun was confirmed. No `--privileged`, host pacman configuration, host sysctl, or sing-box setting was changed.

## Test results

- `./tests/run-all.sh --fast`: **74 passed, 0 failed, 2 skipped**.
- `./scripts/run-static-checks.sh`: **5 check groups passed** (Bash syntax, ShellCheck, actionlint, Python compile, `git diff --check`).
- `actionlint .github/workflows/*.yml`: passed.
- New Python tests cover clean-chroot workflow policy and all five upstream version definitions.

## Local clean-chroot limitation

A minimal `hello-clean-chroot` PKGBUILD was used to probe the actual clean-chroot path. With `--cap-add SYS_ADMIN --security-opt seccomp=unconfined`, a basic `unshare --mount` and simple bind mount worked, but `mkarchroot`'s nested `pacstrap` failed while mounting `/dev` inside its own mount namespace:

```text
mount: .../root/dev: permission denied.
==> ERROR: failed to setup chroot .../root
==> ERROR: Failed to install all packages
```

The authorized rootful Podman path was not available non-interactively: `sudo -n podman ...` returned `sudo: a password is required`. The proot fallback was attempted inside the builder-derived container, but the AUR source checkout failed before proot could be installed:

```text
fatal: unable to access 'https://github.com/cedric-vincent/proot.git/':
Failed to connect to github.com:443
```

Therefore local clean-chroot E2E is **not verified**. CI uses rootful GitHub Docker with `SYS_ADMIN` and `seccomp=unconfined` only on the clean-chroot build/upgrade containers, which is the intended `makechrootpkg` path. The first CI run must confirm that path. Static and unit validation remains green; no claim of a locally successful package chroot build is made.
