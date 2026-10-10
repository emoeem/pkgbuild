# Current repository status

This is the short index for active operational follow-ups. The working tree may contain intentional uncommitted WIP; do not infer that it is disposable.

| Item | Current state | Next action / source of truth |
|---|---|---|
| Clean-chroot shadow run | Code and instructions ready; no CI dispatch performed; real rootful E2E still unverified | Follow the exact two-run procedure and N=3 promotion gate in [`docs/build-pipeline.md`](docs/build-pipeline.md#7-shadow-run-acceptance-legacy-vs-clean-chroot); compare with [`scripts/compare-build-artifacts.sh`](scripts/compare-build-artifacts.sh) |
| Narrow seccomp profile | Not proven; current runner uses `SYS_ADMIN` + unconfined seccomp after rootless nested `/dev` mount failure | Follow-up in build-pipeline chroot permissions section; do not guess an allowlist |
| zizmor | **Blocked, not clean**: scanner binary unavailable in the container and GitHub API connection failed | Evidence and exact retry command in [`docs/archive/security-scan-2026-10-10.md`](docs/archive/security-scan-2026-10-10.md); rerun in a network-enabled builder-derived tooling container |
| Upgrade transaction coverage | Unit test covers ordinary upgrade, official `sing-box` replacement, and missing-old unverified outcome | `tests/test_upgrade_path.sh`, `scripts/test-upgrade-path.sh` |
| namcap issue dedup/exemptions | Key is package + normalized warning digest; exact-line exemptions supported | `scripts/namcap_warnings.py`, `tests/test_namcap_warnings.py`, `packages/<pkg>/.namcap-ignore` |
| Cache budget | Daily API report and 80% alert added; weekly baseline-key invalidation added | `.github/workflows/maintenance.yml`; API readings may lag |
| Local rootless chroot | Known unsupported for devtools due to nested `/dev` mount permission failure; do not retry `makechrootpkg` locally | Evidence retained in [`docs/archive/build-platform-validation-2026-10-10.md`](docs/archive/build-platform-validation-2026-10-10.md) |
| Historical reviews | Kept, not deleted | [`docs/archive/`](docs/archive/) |

## Verification baseline

Final local verification in the CachyOS builder-derived tooling container: `./tests/run-all.sh --fast` — 80 passed, 0 failed, 2 skipped; `./scripts/run-static-checks.sh` — 5 groups passed; ShellCheck, actionlint and Python compilation passed. The builder-only environment check also passed separately. The two expected fast-suite skips remain `tests/test-cachyos-environment.sh` (run separately) and `tests/test_repository.sh` (`--fast`).
