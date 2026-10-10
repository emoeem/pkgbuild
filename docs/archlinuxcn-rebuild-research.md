# How archlinuxcn decides to rebuild — primary-source research

Companion: [archlinuxcn-publish-research.md](archlinuxcn-publish-research.md) covers the publish half (worker → signature → repo dir → DB → mirror).

Sources: shallow clones of `github.com/archlinuxcn/lilac` @ `dccdb58b25e16a567faa2162573138c5f44cc14f` and `github.com/archlinuxcn/repo` + its wiki (`github.com/archlinuxcn/repo.wiki.git`); fetched pages https://build.archlinuxcn.org/ and https://archlinuxcn.github.io/lilac/. Retrieved 2026-10-10. No file name, function or number below is invented; paths are from the clones.

## Findings

**1. Rebuild decisions are per-package nvchecker diffs over an ordered `update_on` list.**
The schema documents `update_on` as "Configure how nvchecker should check for updates / rebuilds? The first should check for updates and others for rebuilds" (`lilac/schema-docs/lilac-yaml-schema.yaml`, rendered at https://archlinuxcn.github.io/lilac/). lilac emits an nvchecker TOML where index 0 becomes section `<pkgbase>` and index *i* becomes `<pkgbase>:<i>` (`lilac/lilac2/nvchecker.py`, `_gen_config_from_lilacinfos`); any index with `oldver != newver` is a rebuild trigger (`lilac/lilac`: `diff_idxs = [i for i, v in enumerate(vers) if v.oldver != v.newver]`). The `rebuild` set that `packages_need_update()` returns is assigned at `lilac/lilac:747` and **never used again** — the diff is the real trigger. Two more triggers: `need_rebuild_pkgrel` (a commit changed pkgrel) and `need_rebuild_failed` (`failed_prev & changed`).

**2. Dependency-change tracking *is* the rebuild mechanism, and it is soname-aware — but only for dependencies the maintainer declares.**
- `source: alpm` + `provided: libX.so` tracks the pacman *provides* entry (a soname) of an official package — e.g. `archlinuxcn/xdg-desktop-portal-hyprland-git/lilac.yaml`: `source: alpm / alpm: sdbus-cpp / provided: libsdbus-c++.so`.
- `source: alpmfiles` + `filename: 'usr/lib/libopencv_core\.so\.(\d+)'` tracks a **soname version inside another package's file list** (`archlinuxcn/wl-kbptr/lilac.yaml`).
- `alias: alpm-lilac` + `alpm: <pkgbase>` tracks a package **in archlinuxcn's own repo** (`archlinuxcn/telegram-portable/lilac.yaml`: `alpm: telegram-desktop-lily / repo: archlinuxcn`).
- `lilac/lilac2/aliases.yaml` ships soname aliases — `libssl → openssl/libssl.so`, `libcrypto → openssl/libcrypto.so`, `fmt`, `grpc`, `protobuf`, `spdlog`, `openmpi`, `libgit2`, `jsoncpp` (all `provided: libX.so`, `strip_release: true`) — plus version-only aliases (`python`, `ruby`, `perl`, `boost`, `icu`, `qt6-base`, …).
- `update_on_build: [{pkgbase: X}]` rebuilds when declared pkgbase X is built in the same batch (`archlinuxcn/twemoji-fonts/lilac.yaml`, comment "# Trigger rebuild when build tools update.").
- Scale (my script over all 2,788 `lilac.yaml`): 1,823 have >1 `update_on` entry; sources include `manual` 1,371, `github` 1,064, `alias:alpm-lilac` 955, `alpm` 923, `aur` 434, `alpmfiles` 196.

**3. No reverse-dependency rebuild and no ABI check of published binaries.**
`grep -rniE "namcap|checkpkg|soname|ldd|readelf|objdump"` over lilac's Python returns nothing. The dependency graph (`repo_depends`, `packages_with_depends`) drives **build ordering** and, when a package lists no maintainers, work attribution (`lilac/lilac2/repo.py`, `find_dependents`). `BuildReason.Depended` is emitted only when a dependency is managed but **no built `.pkg.tar.*` file exists** — `Dependency.resolve()` (`lilac/lilac2/packages.py`) merely lists files whose parsed name matches. That is "the dependency's binary is missing", not "the binary no longer links". archlinuxcn therefore relies on declared triggers plus rolling batch rebuilds; there is no equivalent of "published binaries no longer match current libraries".

**4. QA gates, two layers.**
- *Repo gate*: `archlinuxcn/repo`'s `pre-commit` is a Python `unittest` suite (also `.git/hooks/pre-commit`) run in CI by `.github/workflows/test.yml` ("Packaging consistency check", `./pre-commit --all`, Python 3.14, `jsonschema==4.26.0`). It validates changed `lilac.yaml` against `lilac-yaml-schema.yaml`, requires `maintainers`, requires `update_on` or `managed: false`, rejects duplicate YAML keys, verifies every `repo_depends` entry exists and is managed, rejects `replaces`/`groups` colliding with official core/extra (via `build.archlinuxcn.org/~farseerfc/dump-groups.gz`, parsed by `./parse-pkgbuild`) and rejects committed submodules.
- *Build gate*: devtools `<prefix>-build` → `makechrootpkg -l lilac-<n>` → `makepkg --noprogressbar --holdver`, then `PKGBUILD.check_srcinfo()`; on success `sign_and_copy()` runs `gpg --pinentry-mode loopback --passphrase '' --detach-sign` and hardlinks pkg + `.sig` into the repo dir (`lilac/lilac2/building.py`). **No namcap**, no test-suite gate beyond what the PKGBUILD runs.

**5. Failure handling.** Results enum `('successful','failed','skipped','staged')` in Postgres `lilac.pkglog` (`lilac/scripts/dbsetup.sql`); failures email maintainers via `repo.send_error_report` (optional `logurl`, log attached). The wiki FAQ: "lilac won't rebuild a failed package until a new commit of the package is pushed to repo." The `rebuild_failed_pkgs` option controls the related `nvtake` step (advance nvchecker's recorded version only for successful builds → failures get retried); a failed dependency is skipped as a build target (`if db.USE and db.is_last_build_failed(d.pkgname): continue`). No failed build removes a package from the repo; `scripts/lilac-cleaner` only deletes untracked working files.

**6. How state surfaces.** https://build.archlinuxcn.org/ links "lilac 打包状态界面" `/packages/`, a second dashboard `/~imlonghao/` (and `/current/` for in-flight builds), `/triggerabuild/` (GitHub-OAuth build queue) and `/~imlonghao/status/` (mirror sync). Both dashboards are client-side JS apps — my fetch returned no server-rendered content. Notifications are **email only**: grep for telegram/matrix/irc/webhook/discord/slack across lilac returns nothing. Users file issues through `archlinuxcn/repo`'s templates (`20-out-of-date.md`, `60-error.md`, …); the README says "Flag package OUT-OF-DATE by submiting new issues".

**7. Builder provisioning — no container registry involved.** `docs/setup.rst`: "It's recommended to run lilac on full-fledged Arch Linux (or derived) system, not in a Docker container". Builds use devtools chroots in `/var/lib/archbuild/<prefix>-<arch>`; `scripts/build-cleaner` deletes stale copies and `building.py:may_need_cleanup()` runs `sudo build-cleaner` below 60 GiB free. archlinuxcn never pulls a builder image, so it cannot hit Docker Hub/GHCR anonymous pull limits; optional remote workers are reached over SSH.

## Comparison table

| | archlinuxcn (lilac) | emoeem/pkgbuild |
|---|---|---|
| Build execution | own Arch hosts, devtools chroot under `/var/lib/archbuild`; optional remote workers over SSH | GitHub Actions in a GHCR-published CachyOS `x86-64-v3` container |
| Publish target | signed pkgs + `.sig` hardlinked into the repo dir → `archlinuxcn.db`/`.files` regenerated on the build host → mirrors. The DB *writer* is not confirmed to be archrepo2 (documented-optional only) — see [archlinuxcn-publish-research.md](archlinuxcn-publish-research.md) | GitHub Release assets (`repo` bundle) |
| Drift detection | per package, declared (`update_on` entries 2..n, `update_on_build`, `manual`); no global scan | global: `dependency-drift.yml` every 2h compares recorded dep versions of **published** packages |
| Soname/ABI checking | declared provider sonames only (`provided:` / `filename:` regex / alias table); nothing reads the built ELF | `check-repository-sonames.sh` checks published packages' linked sonames vs current providers, ≥100-provider sanity floor |
| QA gates | repo pre-commit + CI schema/lint checks; makepkg + `check_srcinfo` + GPG sign; **no namcap** | `run-namcap.sh`, `check-elf-needed.sh`, `verify-repository-elf.sh`, `runtime-smoke-test.sh`, `repository-install-test.sh` |
| Failure handling | email maintainers; failed package not retried until a new commit; `rebuild_failed_pkgs`; `pkglog`/`pkgcurrent` + web dashboards | job fails loudly (requires `^SUMMARY `, else `::error::`), dispatch rebuild `bump_pkgrel=true`, open issue; no persistent status DB |

## Borrowable for emoeem/pkgbuild

Ranked by value/effort:

1. **Port the `pre-commit`-style repo linter into `check.yml`** — low effort, high value. Pure Python + `jsonschema`/`pyyaml`; a required check that every package dir declares a version source and valid metadata.
2. **Declare per-package dependency/soname triggers next to each package** — medium effort, high value. The `provided: libX.so` / `filename: 'usr/lib/libX\.so\.N'` idea as package metadata lets `check-dependency-drift.sh` distinguish a declared ABI dep change from noise and dispatch only affected rebuilds.
3. **Document a `manual:`-style numeric rebuild trigger** — very low effort. lilac's cheapest idea, with priority over ordinary drift; pairs naturally with `workflow_dispatch`.
4. **Treat "no built artifact for a declared dependency" as a planner input** — low effort. `build-dag.py`/`build-planner.py` can fail fast instead of discovering a missing published dependency at link time.
5. **`update_on_build` semantics as DAG edges** — low effort. "If pkgbase X was built in this batch, rebuild the packages declaring X" is a `needs:`/edge in your existing planner and removes version bookkeeping for build-tool deps.

Not worth copying: the Postgres `pkglog`/status DB and the multi-host worker model — both need dedicated infra a GitHub-Actions repo lacks; the Release-asset manifest already fills that role.

## Uncertainty

- **Speculation:** whether production sets `rebuild_failed_pkgs` true or false. `config.toml.sample` has `true`; `docs/setup.rst` argues for `false`; the FAQ describes the `false` behaviour.
- **Speculation:** `/packages/` and `/~imlonghao/` are JS-only in my fetch, so I cannot confirm a dedicated "broken packages" list exists.
- **Not verified:** I read lilac's code but never executed it — the live nvchecker run, alias resolution at build time, and `alpmfiles`'s exact regex anchoring are unconfirmed.
- The wiki page `use-nvchecker-to-check-new-version.md` still describes a central `nvchecker.ini`; no such file exists in the repo root — treat that page as outdated.
