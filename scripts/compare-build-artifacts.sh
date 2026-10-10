#!/usr/bin/env bash
# Compare two package artifacts and emit a machine-readable JSON summary.
set -Eeuo pipefail
legacy_pkg="${1:?usage: compare-build-artifacts.sh LEGACY.pkg.tar.zst CHROOT.pkg.tar.zst [SUMMARY.json]}"
chroot_pkg="${2:?usage: compare-build-artifacts.sh LEGACY.pkg.tar.zst CHROOT.pkg.tar.zst [SUMMARY.json]}"
summary_path="${3:-build-artifact-diff.json}"
for tool in bsdtar ldd file python3 vercmp; do command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 127; }; done
[[ -f "$legacy_pkg" && -f "$chroot_pkg" ]] || { echo 'Both package artifacts must exist.' >&2; exit 2; }
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT INT TERM
mkdir -p "$work/legacy" "$work/chroot"
for kind in legacy chroot; do
  if [[ "$kind" == legacy ]]; then artifact="$legacy_pkg"; else artifact="$chroot_pkg"; fi
  bsdtar -xf "$artifact" -C "$work/$kind"
  bsdtar -xOf "$artifact" .BUILDINFO > "$work/$kind.BUILDINFO" 2>/dev/null || :
  bsdtar -xOf "$artifact" .PKGINFO > "$work/$kind.PKGINFO" 2>/dev/null || :
  (cd "$work/$kind" && find . -mindepth 1 -printf '%P\n' | LC_ALL=C sort) > "$work/$kind.files"
  : > "$work/$kind.ldd"
  while IFS= read -r -d '' file; do
    file "$file" | grep -q 'ELF .* executable\|ELF .* shared object\|ELF .* pie executable' || continue
    ldd "$file" 2>&1 | sed "s#^#${file#"$work/$kind"}: #" >> "$work/$kind.ldd" || true
  done < <(find "$work/$kind" -type f -print0)
done
python3 - "$work" "$legacy_pkg" "$chroot_pkg" "$summary_path" <<'PY'
import hashlib, json, pathlib, re, subprocess, sys
root, legacy_pkg, chroot_pkg, out = map(pathlib.Path, sys.argv[1:])
def read(path): return path.read_text(errors='replace').splitlines() if path.exists() else []
def pkginfo(path):
    return sorted(x for x in read(path) if x and not x.startswith('#'))
def buildinfo(path):
    rows=[]
    for line in read(path):
        if line.startswith('installed = '): rows.append(line.removeprefix('installed = '))
    return sorted(rows)
def dependency_age():
    old, new = {}, {}
    for entry, dest in ((buildinfo(root/'legacy.BUILDINFO'), old), (buildinfo(root/'chroot.BUILDINFO'), new)):
        for item in entry:
            # split package name from its final -version boundary (package names may contain dashes)
            m=re.match(r'^(.*?)-([0-9][A-Za-z0-9.+_~-]*)$', item)
            if m: dest[m.group(1)] = m.group(2)
    older=[]; missing=[]; comparisons=[]
    for name, oldver in old.items():
        newver=new.get(name)
        if newver is None: missing.append(name); continue
        try: cmp=subprocess.run(['vercmp',newver,oldver],capture_output=True,text=True,check=True).stdout.strip()
        except (FileNotFoundError,subprocess.CalledProcessError): cmp='unknown'
        comparisons.append({'name':name,'legacy':oldver,'chroot':newver,'vercmp':cmp})
        if cmp != 'unknown' and int(cmp)<0: older.append(name)
    return {'comparisons':comparisons,'older_than_legacy':older,'missing_from_chroot':missing,'not_older':not older and not missing}
sections={}
for name in ('BUILDINFO','PKGINFO','files','ldd'):
    a=read(root/f'legacy.{name}') if name in ('BUILDINFO','PKGINFO') else read(root/f'legacy.{name}')
    b=read(root/f'chroot.{name}')
    if name=='PKGINFO': a=pkginfo(root/'legacy.PKGINFO'); b=pkginfo(root/'chroot.PKGINFO')
    if name=='BUILDINFO': a=buildinfo(root/'legacy.BUILDINFO'); b=buildinfo(root/'chroot.BUILDINFO')
    sections[name]={'equal':a==b,'legacy_sha256':hashlib.sha256(('\n'.join(a)+'\n').encode()).hexdigest(),'chroot_sha256':hashlib.sha256(('\n'.join(b)+'\n').encode()).hexdigest(),'legacy_only':sorted(set(a)-set(b)),'chroot_only':sorted(set(b)-set(a))}
comparison=dependency_age()
metadata_ok=bool(buildinfo(root/'legacy.BUILDINFO')) and bool(buildinfo(root/'chroot.BUILDINFO'))
comparison['buildinfo_present_and_populated']=metadata_ok
comparison['not_older']=comparison['not_older'] and metadata_ok
summary={'schema_version':1,'artifacts':{'legacy':str(legacy_pkg),'chroot':str(chroot_pkg)},'sections':sections,'dependency_versions':comparison,'pass':comparison['not_older'],'notes':['ldd compares unresolved/runtime dependency output from extracted ELF files; paths are normalized to package-relative paths.','Missing dependencies in the chroot BUILDINFO are treated as non-pass.']}
out.parent.mkdir(parents=True,exist_ok=True); out.write_text(json.dumps(summary,indent=2,sort_keys=True)+'\n')
print(json.dumps(summary,indent=2,sort_keys=True))
if not summary['pass']: raise SystemExit(1)
PY
