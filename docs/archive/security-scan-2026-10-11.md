# GitHub Actions security scan evidence — 2026-10-11

Follow-up to [`security-scan-2026-10-10.md`](security-scan-2026-10-10.md). That
attempt was blocked inside the CI container (no scanner binary, no API egress);
this scan ran on the local CachyOS machine where both are available.

- Scanner: `zizmor` v1.30.1 (CachyOS package `cachyos-extra-v3/zizmor
  1.30.1-1.1`, installed user-side via `uv tool install zizmor`). Offline mode
  (`--no-online-audits`); the local workflows carry no secret- or
  cache-audit-relevant online state that the offline mode would miss.
- Command: `zizmor --no-online-audits .github/workflows/*.yml`
- Default-persona result after remediation: **no findings** (38 suppressed by
  zizmor's default policy).

## Findings fixed in this pass (all in `sing-box-ebpf-update.yml`)

1. `template-injection` (low): `--env BUILDER_GENERATION="${{
   steps.generation.outputs.value }}"` interpolated an expression directly into
   the `run:` block. Replaced with an `env:`-indirected variable
   (`BUILDER_GENERATION: ${{ ... }}` on the step, `"$BUILDER_GENERATION"` in
   the script), matching the convention the 2026-10-10 hardening applied
   everywhere else.
2. `self-repository` (informational): `uses: ./.github/actions/setup-builder`
   → `uses: $/.github/actions/setup-builder`, matching the other workflows;
   `.github/actionlint.yaml` already carries the exact actionlint-compatibility
   suppression documented in the 2026-10-10 report.

## Deliberately accepted (pedantic persona only, not default-mode findings)

- `template-injection` flags for `${{ github.run_id }}` /
  `${{ github.repository }}` / `${{ github.ref_name }}`-class expressions:
  these are GitHub-controlled trusted contexts, not user-controllable inputs;
  the 2026-10-10 rule (env-indirect every *event-derived* value) is what
  matters and holds.
- `undocumented-permissions`: the top-level least-privilege `permissions:`
  blocks from commit 45bec09 are intentional; adding per-block comments is a
  documentation nicety, not a control gap.

Re-run after remediation: `No findings to report. Good job! (38 suppressed)`.
