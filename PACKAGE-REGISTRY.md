# Package Registry

## Update Routes

| Route | Marker | Handler |
|---|---|---|
| AUR | `.aur-url` + `.aur-commit` | `sync.yml` |
| Automated workflow | `config/package-updates.txt` workflow entry | named workflow |
| Vendored dependency | nvchecker entry owned by another package | owner package pin/update |
| Manual | `config/package-updates.txt` manual entry | review only |

Use `scripts/resolve-update-route.py --package <name>` to resolve a name.
Unknown names fail rather than guessing.

## Per-Package Triggers

`.rebuild-on` supports:

- `soname <soname> <provider>`
- `package <provider>`

Every declaration is validated against the source dependency graph and, for
SONAMEs, against the published ELF artifact.
