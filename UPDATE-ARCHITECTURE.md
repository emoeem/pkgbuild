# Update Architecture

## Flow

```text
upstream monitor
  -> route resolver
  -> AUR sync / dedicated updater / vendored owner / manual review
  -> package metadata validation
  -> candidate build
  -> runtime and ELF validation
  -> commit/dispatch
  -> staged publish and verification
```

## Vendored Dependencies

Vendored names must remain attached to their owning package. For example,
`lensfun-master` and `whisper-cpp` belong to `ffmpeg-full`; they are never
dispatched as AUR package directories.

## Stale Protection

- nvchecker failures do not produce a clean report.
- the DSH maintenance watchdog independently compares upstream and pinned versions;
- stale update issues are closed only after the pin is current;
- failure issue comments distinguish route, validation and publication failures.
