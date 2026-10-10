# How archlinuxcn publishes packages, end to end — primary-source research (publish half)

Companion to [archlinuxcn-rebuild-research.md](archlinuxcn-rebuild-research.md), which covers *why* a package rebuilds. This file covers *what happens to the artifact*: worker → signature → repo directory → database → mirror, plus the live scale numbers. Everything below is fetched primary source (URLs inline, retrieved 2026-10-10); anything inferred is labelled.

> **Correction to the existing doc.** [archlinuxcn-rebuild-research.md:36](archlinuxcn-rebuild-research.md#L36) says the publish path is "signed pkgs hardlinked into repo dir → **archrepo2** DB → mirrors". I could not confirm archrepo2 in the live path. archrepo2 still exists and was pushed 2026-07-20 (<https://github.com/lilydjwg/archrepo2>), and lilac's own docs still recommend it (<https://lilac.readthedocs.io/en/latest/setup.html>), but the live `archlinuxcn.db` is PostgreSQL-driven: `imlonghao/archlinuxcn-packages` queries `lilac.pkglog` / `lilac.batch`, and lilac's own setup page says only "You may use archrepo2 to do that", not that archlinuxcn does. Treat "archrepo2" as *the documented optional component*, not as a verified archlinuxcn fact.

## End-to-end flow

1. **Trigger.** A `systemd.timer`/cron run of `lilac` on the build host (setup page: "run `lilac` from cron/systemd.timer", `loginctl enable-linger`). Per package, nvchecker diffs decide rebuilds (see companion doc). `/triggerabuild/` on the build host is an extra manual, GitHub-OAuth-gated queue entry.
2. **Schedule.** `graphlib.TopologicalSorter(dep_building_map)` orders the batch; per-worker `max_concurrency`; under memory pressure lilac logs `insufficient memory, starting only one build on %s` and serialises. PKGBUILDs it edits (e.g. `pkgrel` bump under `may_update_pkgrel()`) are committed back to `archlinuxcn/repo` per `config.toml` `[lilac] git_push`.
3. **Build.** `extra-x86_64-build` (devtools; `devtools-archlinuxcn` until the `--keep-unit` issue is fixed) → `makechrootpkg -l lilac-<n>` → `makepkg --noprogressbar --holdver`. Runs as a **systemd user unit** (`systemd-run --user`, cgroup v2 `memory.peak` + `cpu.stat usage_usec` sampled for rusage). `PACKAGER` is rewritten to `'<lilac> (on behalf of <maintainer>) <email>'`. Output >1 GiB within one 10 s tick is killed ("Too much output, killed."). Optional SSH remote workers run the same worker under `systemd-run lilac2.remote.worker`.
4. **Sign + stage.** `sign_and_copy()`: `gpg --pinentry-mode loopback --passphrase '' --detach-sign --yes -- <pkg>` per built package, then the pkg **and its `.sig`** are hardlinked into the destination directory; `staging: true` targets `destdir/staging` instead. Live evidence of per-file signatures: the arch directories contain `*.pkg.tar.zst` next to `*.pkg.tar.zst.sig` (566 B for the primary key, 438 B for older/subkey signatures — e.g. `https://repo.archlinuxcn.org/aarch64/`). **The database itself is not signed**: `archlinuxcn.db.sig` returns 404 for `x86_64/`, `aarch64/` and `any/` — only the individual packages are. This matches the documented workflow, which ships an `archlinuxcn-keyring` package instead of a signed DB.
5. **Publish.** `archlinuxcn.db` / `archlinuxcn.files` are regenerated on the build host at the same instant as `lastupdate` (both `Last-Modified: Sat, 10 Oct 2026 00:20:2x GMT`). Until lilac 2025-09-27 the `lilac.pkglog` schema had no `builder` column; it now records the builder (`alter table lilac.pkglog add column builder text not null default 'local';`, lilac README).
6. **State.** Postgres `lilac.pkglog` (per-build `ts, pkgbase, pkg_version, elapsed, result, cputime, memory, maintainers`) plus `lilac.batch` (`event`, `logdir`). Batch events enum `start|stop`; build results `successful|failed|skipped|staged`; status `pending|building|done` (`imlonghao/archlinuxcn-packages`, `src/main.rs`).
7. **Serve.** `https://repo.archlinuxcn.org/` is a flat webroot of only `aarch64/ any/ x86_64/ header.html lastupdate pkginfo.db robots.txt` — no `pool/` at that root; arch dirs hold the package+`.sig` files directly (arch-specific and `-any` packages both live in each arch dir). `pkginfo.db` is a 12.6 MB auxiliary index, `lastupdate` an 11-byte timestamp.
8. **Mirror.** Main server is Amsterdam (per `archlinuxcn/mirrorlist-repo` generated 2026-07-06: "Our main server (Amsterdam, the Netherlands)"); mirrorlist ships CERNET, BFSU, PKU, Tencent, NetEase, Aliyun, Huawei, TUNA, USTC, HIT, JLU. Sync delays are tracked by the `/~imlonghao/status/` dashboard.

## Live scale (fetched 2026-10-10)

| Measure | Value | Source |
|---|---|---|
| Package directories in repo | 11,999 (API pages 1–12, each 1000) | `api.github.com/repos/archlinuxcn/repo/contents/archlinuxcn?per_page=1000` |
| Packages in live `x86_64` DB | 4,688 `desc` entries | `tar tz` over `x86_64/archlinuxcn.db` |
| Packages in live `aarch64` DB | 3,139 | same |
| Packages in live `any` DB | 1,782 | same |
| `x86_64/archlinuxcn.files` | 23.2 MB | HEAD `content-length` |
| `x86_64/archlinuxcn.db` | 1.45 MB (gzip, 34 MB uncompressed) | `file` + `content-length` |
| `lastupdate` | 1791591622 → 2026-10-10 00:20:22Z | `repo.archlinuxcn.org/lastupdate` |
| Recent build cadence | 20–114 builds/day over 2026-10-01…10-09 | `/imlonghao-api/logs` |
| 4,808 logged builds, 2021-12-29 → 2026-10-10 | 4,205 Successful / 573 Failed / 29 Staged / 1 Skipped | same API |
| Build cost | median 28 s, p90 177 s, max 19,829 s; peak RSS median 3.3 GiB, max 119.5 GiB | same API |

Scale note: 12.0k package dirs vs 4.7k live `x86_64` packages is consistent with `arch=('any')` packages landing in the separate `any/` DB (4,688 + 1,782 = 6,470), with retired/superseded dirs and arch-excluded packages accounting for the rest; the exact split is **not verified**.

## Borrowable for emoeem/pkgbuild

1. **`staging: true`** — build into a staging subdirectory, promote only after checks. Low effort, gives an explicit promote step to pair with the existing `run-namcap.sh` / `runtime-smoke-test.sh` gates.
2. **`.sig` next to every package, never a signed DB** — already the direction of this repo's `repo-add` + optional GPG signing, but archlinuxcn proves the simpler half: ship a keyring package and sign artifacts only, leave `emoeem.db` unsigned. Fewer moving parts than DB signatures.
3. **Rusage-driven concurrency** — a public per-build `elapsed / cpu / memory` record is what lets lilac pick workers (`db.get_pkgs_last_rusage`). A GitHub-Actions repo cannot schedule across hosts, but recording `elapsed`+peak RSS per build in the job summary is nearly free and feeds the 2-hourly drift job (`.github/workflows/dependency-drift.yml` cron `23 */2 * * *`).
4. **Hard "output too large" kill** — a 1 GiB-per-10 s cap is a cheap runaway-build guard for the container job (`timeout-minutes` alone does not bound log volume).
5. **`/triggerabuild/`** — a deliberately dumb web trigger for "rebuild this pkgbase now" as a complement to `workflow_dispatch`, with OAuth only at the door.

## Uncertainty

- **Not verified:** whether archlinuxcn runs archrepo2, `repo-add`, or a custom DB writer. The `lilac.pkglog`/`lilac.batch` Postgres schema and the 00:20:2x simultaneous mtime of `.db`/`.files`/`lastupdate`/`pkginfo.db` are consistent with any of them; archrepo2 is only *documented as supported*.
- **Speculation:** the Rust service at `build.archlinuxcn.org/~imlonghao/` runs on the same host as Postgres because it hardcodes `/home/lilydjwg/.lilac/log/{logdir}/{name}.log` — that path proves a host, not that the DB is local.
- **Not verified:** mirror sync lag and schedule; the status dashboard is JS-only in a text fetch.
- **Stale source warning:** lilac's wiki/readthedocs still describe archrepo2 and a central `nvchecker.ini`; the live repo has neither a root `nvchecker.ini` nor evidence of archrepo2.

## Adoption status in emoeem/pkgbuild (recorded 2026-10-10)

Both borrowable items below were checked against the live publish path before adoption;
neither was copied as-is. This section records the decision so it does not have to be
re-derived.

### Item 2 — "`.sig` next to every package, never a signed DB": rejected as stated

The borrowing is backwards here. emoeem/pkgbuild signs the *database* and lets
`repo-add` carry the package signatures inside it:

- `scripts/create-repository.sh:192` runs
  `repo-add --include-sigs "$database" "${repository_packages[@]}"`, so every package
  signature is embedded in `emoeem.db`'s `desc` entries (the per-package `.sig` files
  produced at `scripts/create-repository.sh:165-168` are the input to that).
- `scripts/create-repository.sh:208-220` detach-signs the DB archive and exposes it as
  `<repo>.db.sig`; `scripts/publish-release.sh:50-53` publishes `emoeem.db`,
  `emoeem.files` and both `.sig` files.
- Live check (2026-10-10, release `repo`): the assets are `emoeem.db`, `emoeem.db.sig`,
  `emoeem.files`, `emoeem.files.sig`, `emoeem-key.asc`, `SHA256SUMS` and the package
  files — there is **no** per-package `*.pkg.tar.zst.sig` asset.
- `README.md` documents the hardened client as `SigLevel = Required DatabaseRequired`,
  so the trust chain a remote client relies on is exactly "signed DB → signatures
  embedded in the DB".

Dropping the DB signature would remove the only integrity evidence such a client has.
archlinuxcn can ship an unsigned DB only because it also ships `archlinuxcn-keyring` and
its clients do not require a DB signature; that precondition does not hold here. The
transferable half of the idea — sign artifacts and distribute the key so users do not
import it by hand — is already implemented (`scripts/create-repository.sh:152-171` plus
the `emoeem-key.asc` asset).

### Item 1 — `staging: true`: deferred, not declined

A staging area promoted only after the build/install gates is the right shape, but every
file it would touch was dirty in the maintainer's in-flight work at the time of this note
(`scripts/create-repository.sh`, `scripts/publish-release.sh`, `client/install.sh`, plus
the new `scripts/repository-install-test.sh`), so it was not implemented on `main`. What
the change must do when it lands:

1. write the regenerated `<repo>.db` / `.files` and the new package files to a staging
   location that the live `repo` release does not serve, inside the existing
   `pacman-repository-release` concurrency group;
2. run the install / namcap / runtime-smoke gates against that staged repository;
3. promote only then (swap the staged DB and packages in, delete the superseded assets),
   so a client can never observe a DB that references packages which are not uploaded
   yet.

Neither item blocks the rebuild-side borrowings in
[archlinuxcn-rebuild-research.md](archlinuxcn-rebuild-research.md).
