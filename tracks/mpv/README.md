# mpv-Emo tracks

`mpv-Emo` is a real mpv-full-style core build: upstream mpv is the base, and
curated core patches are applied before compilation.

| Track | Package | Upstream | Patch policy |
| --- | --- | --- | --- |
| Stable | `mpv-emo` | mpv release tags | stable patch series is part of the core build |
| Development | `mpv-emo-git` | mpv `master` | matching master patch series; drift blocks publication |

## Rules

1. Stable never consumes mpv `master`.
2. Development pins an exact upstream commit.
3. Core patches live under `packages/mpv-emo/patches/` and the corresponding
   development series under `packages/mpv-emo-git/patches/`.
4. Omniphony is a core Patch layer, not a second mpv package.
5. `orender` is runtime-only and is not linked at mpv build time.
6. Patch application is a hard gate: any failed patch means no publication.
7. A successful build and test are required before the private pacman repo updates.
8. When a feature lands upstream, its private Patch is removed instead of being
   maintained forever.

The current Stable baseline is mpv `v0.41.0` with the Omniphony v0.4.2 mpv-side
series. Upstream mpv currently publishes a separate development build for
master, so Stable and Development remain separate tracks.
