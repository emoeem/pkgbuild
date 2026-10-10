#!/usr/bin/env python3
import unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

class CleanChrootTests(unittest.TestCase):
    def test_builder_installs_devtools_and_nvchecker(self):
        dockerfile = (ROOT / '.github/builder/Dockerfile').read_text()
        self.assertIn('devtools', dockerfile)
        self.assertIn('pacman.conf.pkgbuild-base', dockerfile)
        self.assertIn('nvchecker', dockerfile)

    def test_chroot_is_reflink_copy_and_disposable(self):
        script = (ROOT / 'scripts/build-in-clean-chroot.sh').read_text()
        self.assertIn('cp --reflink=auto -a', script)
        self.assertIn("trap 'rm -rf -- \"$work_root\"' EXIT INT TERM", script)
        self.assertIn('makechrootpkg -c -u', script)
        self.assertIn('base_packages=(base-devel gcc-objc ccache)', script)
        self.assertIn('export CARGO_HOME=/cache/cargo', script)
        self.assertIn('pacman.conf.pkgbuild-base', script)
        self.assertIn('base_packages+=(cuda gcc15)', script)
        self.assertIn('baseline_name="baseline-${generation}-${architecture}-${fingerprint}"', script)
        self.assertIn('baseline_archive="$cache_dir/chroot/${baseline_name}.tar.zst"', script)
        self.assertIn('runtime_root="/tmp/pkgbuild-chroot-${fingerprint}"', script)

    def test_repo_order_and_read_only_bind(self):
        script = (ROOT / 'scripts/build-in-clean-chroot.sh').read_text()
        import re
        order_text = re.search(r"order = \[([^\]]+)\]", script).group(1)
        order = [order_text.index(name) for name in ["'cachyos-v3'", "'cachyos-extra-v3'", "'cachyos-core-v3'", "'cachyos'"]]
        self.assertEqual(order, sorted(order))
        workflow = (ROOT / '.github/workflows/build.yml').read_text()
        self.assertIn('/run/pkgbuild-localrepo:ro', workflow)
        self.assertIn('CLEAN_CHROOT_BUILD=', workflow)
        self.assertIn('REQUESTED_BUILD_MODE', workflow)
        self.assertIn('build_mode=legacy', workflow)
        self.assertIn('container_security_args+=(--cap-add SYS_ADMIN --security-opt seccomp=unconfined)', workflow)
        self.assertIn('if [[ "$build_mode" == chroot ]]', workflow)
        self.assertIn("inputs.build_mode != 'chroot' && !cancelled() && needs.build.result == 'failure'", workflow)
        self.assertIn("inputs.build_mode != 'chroot' && (!cancelled() && needs.build.result == 'success'", workflow)
        self.assertIn('arch-nspawn -c "$cache_dir/pacman" "$work_root/root" pacman -Syu --noconfirm', script)
        self.assertIn('uses: ./.github/actions/setup-builder', workflow)
        self.assertIn('selected_deps=[d for d in deps if d in selected]; sys.stdout.write(\"\\n\".join(selected_deps))', workflow)
        local_runner = (ROOT / 'scripts/parallel-build.sh').read_text()
        self.assertNotIn('--cap-add SYS_ADMIN', local_runner)

    def test_checks_run_by_default_and_skip_is_explicit(self):
        script = (ROOT / 'scripts/build-in-clean-chroot.sh').read_text()
        self.assertIn('if [[ -f "$source_dir/.skip-check" ]]', script)
        self.assertIn('--nocheck --cleanbuild --noconfirm', script)
        self.assertIn('"${args[@]}" -- --cleanbuild --noconfirm', script)

    def test_no_arch_official_image_is_used_by_workflows(self):
        for path in (ROOT / '.github/workflows').glob('*.yml'):
            text = path.read_text()
            self.assertNotIn('docker.io/library/archlinux:base-devel', text, str(path))

    def test_upgrade_path_uses_old_repo_and_new_artifact_in_staging(self):
        script = (ROOT / 'scripts/test-upgrade-path.sh').read_text()
        self.assertIn("previous repository package set", script)
        self.assertIn('emoeem-staging', script)
        self.assertIn('pacman -Syu --noconfirm "$package_name"', script)
        self.assertIn('sing-box-ebpf', script)

if __name__ == '__main__': unittest.main()
