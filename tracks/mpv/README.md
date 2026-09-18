# mpv-Emo tracks

mpv is maintained as three independent tracks. Package names are deliberately
separate so a broken development build or optional patch can never silently
replace Stable.

| Track | Package | Upstream | Update policy |
| --- | --- | --- | --- |
| Stable | `mpv-emo` | mpv release tags | automatic daily check |
| Development | `mpv-emo-git` | mpv `master` | automatic daily check, exact commit pin |
| Optional Patch | `mpv-emo-omniphony` | Omniphony release + matching mpv | independent check; build is gated by patch compatibility |

## Rules

1. Stable never consumes mpv `master`.
2. Development never blocks Stable.
3. Optional patches never modify the Stable package in place.
4. Every source update changes a tracked pin in Git before CI builds it.
5. Patch application is a hard gate: a failed patch means no publication.
6. A successful build is required before the `repo` release is updated.
7. Linux-native mpv features belong in the common build policy; Windows-only
   Yaozhi functionality does not enter these packages.

The current Stable release is `v0.41.0`; mpv also publishes a separate
master development build, so the two tracks are intentionally kept distinct.
