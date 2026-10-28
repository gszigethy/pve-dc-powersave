"""Run scripts/uninstall.sh against a temporary root with stub commands.

The script's PVE_DC_POWERSAVE_TEST_ROOT seam prefixes every absolute path and
skips the root check. Nothing here touches the real system: systemctl and
cpupower are stubs on PATH and the integration helper is a stub too.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "uninstall.sh"
CLUSTER_REGISTERED = ("package PVE::API2::Cluster;\n"
                      "use PVE::API2::Cluster::DCPowerSave;\n"
                      "# BEGIN pve-dc-powersave\n# END pve-dc-powersave\n")
NODES_REGISTERED = "package PVE::API2::Nodes;\nuse PVE::API2::Nodes::DCPowerSave;\n"
INDEX_REGISTERED = '<script src="/pve2/js/dc-powersave.js"></script>\n<script src="other.js"></script>\n'

# A helper that supports removal (the option definition is what the static
# check looks for) and removes the registrations from the files in $FAKE_*.
GOOD_HELPER = """#!/usr/bin/env python3
import argparse, os, pathlib, re
parser = argparse.ArgumentParser()
parser.add_argument('--remove', action='store_true')
args = parser.parse_args()
pathlib.Path(os.environ['HELPER_LOG']).write_text('ran remove=%s\\n' % args.remove)
if os.environ.get('HELPER_FAIL'):
    raise SystemExit(3)
if not os.environ.get('HELPER_NOOP'):
    for var, pattern in (('FAKE_CLUSTER', r'use PVE::API2::Cluster::DCPowerSave;\\n'),
                         ('FAKE_NODES', r'use PVE::API2::Nodes::DCPowerSave;\\n'),
                         ('FAKE_INDEX', r'<script src="/pve2/js/dc-powersave.js"></script>\\n')):
        path = pathlib.Path(os.environ[var])
        path.write_text(re.sub(pattern, '', path.read_text()))
"""

# What v0.1.0 through v0.2.1-beta.1 shipped: no argument handling at all.
OLD_HELPER = """#!/usr/bin/env python3
import os, pathlib
pathlib.Path(os.environ['HELPER_LOG']).write_text('old helper ran\\n')
"""


class UninstallShTests(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.root = self.tmp / "root"
        self.src = self.tmp / "src" / "scripts"
        self.stubs = self.tmp / "stubs"
        self.perl = self.tmp / "perl5"
        for directory in (self.root, self.src, self.stubs):
            directory.mkdir(parents=True)
        shutil.copy2(SCRIPT, self.src / "uninstall.sh")
        self.log = self.tmp / "commands.log"
        self.helper_log = self.tmp / "helper.log"
        for name in ("systemctl", "cpupower"):
            stub = self.stubs / name
            stub.write_text(f'#!/bin/sh\necho "{name} $*" >> "{self.log}"\n', encoding="utf-8")
            stub.chmod(0o755)

        self.lib = self.root / "usr/lib/pve-dc-powersave"
        self.lib.mkdir(parents=True)
        pm = self.root / "usr/share/perl5/PVE"
        (pm / "API2/Cluster").mkdir(parents=True)
        (pm / "API2/Nodes").mkdir(parents=True)
        self.plugin_files = [pm / "API2/Cluster/DCPowerSave.pm", pm / "API2/Nodes/DCPowerSave.pm"]
        for path in self.plugin_files:
            path.write_text("1;\n", encoding="utf-8")
        # PERL5LIB makes the script's @INC lookup find the fake PVE files.
        (self.perl / "PVE/API2").mkdir(parents=True)
        self.cluster = self.perl / "PVE/API2/Cluster.pm"
        self.nodes = self.perl / "PVE/API2/Nodes.pm"
        self.cluster.write_text(CLUSTER_REGISTERED, encoding="utf-8")
        self.nodes.write_text(NODES_REGISTERED, encoding="utf-8")
        manager = self.root / "usr/share/pve-manager"
        manager.mkdir(parents=True)
        self.index = manager / "index.html.tpl"
        self.index.write_text(INDEX_REGISTERED, encoding="utf-8")
        self.run_dir = self.root / "run/pve-dc-powersave"
        self.run_dir.mkdir(parents=True)
        (self.run_dir / "status.json").write_text("{}", encoding="utf-8")

    def run_script(self, script: Path | None = None, *args: str, **extra_env: str):
        env = {
            "PATH": f"{self.stubs}:{os.environ['PATH']}",
            "PERL5LIB": str(self.perl),
            "PVE_DC_POWERSAVE_TEST_ROOT": str(self.root),
            "HELPER_LOG": str(self.helper_log),
            "FAKE_CLUSTER": str(self.cluster),
            "FAKE_NODES": str(self.nodes),
            "FAKE_INDEX": str(self.index),
            **extra_env,
        }
        return subprocess.run(["bash", str(script or self.src / "uninstall.sh"), *args],
                              env=env, capture_output=True, text=True, check=False)

    def commands(self) -> str:
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""

    def install_helper(self, directory: Path, text: str) -> None:
        helper = directory / "integrate-pve.py"
        helper.write_text(text, encoding="utf-8")
        helper.chmod(0o755)

    def test_old_helper_is_refused_without_running_it_or_changing_anything(self) -> None:
        self.install_helper(self.lib, OLD_HELPER)
        installed_script = self.lib / "uninstall.sh"
        shutil.copy2(SCRIPT, installed_script)

        result = self.run_script(installed_script)

        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("complete source tree or release archive", result.stderr)
        self.assertIn("rerun this", result.stderr)
        self.assertFalse(self.helper_log.exists(), "the old helper must never be executed")
        self.assertEqual(self.commands(), "", "service must not be touched")
        self.assertTrue(all(p.exists() for p in self.plugin_files))
        self.assertTrue(self.run_dir.is_dir())

    def test_missing_helper_aborts_before_stopping_the_service(self) -> None:
        result = self.run_script()

        self.assertEqual(result.returncode, 1)
        self.assertIn("Nothing was changed", result.stderr)
        self.assertEqual(self.commands(), "")
        self.assertTrue(all(p.exists() for p in self.plugin_files))

    def test_helper_next_to_script_is_preferred_over_the_installed_one(self) -> None:
        self.install_helper(self.lib, OLD_HELPER)
        self.install_helper(self.src, GOOD_HELPER)

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.helper_log.read_text(), "ran remove=True\n")

    def test_installed_helper_is_used_when_none_is_next_to_the_script(self) -> None:
        self.install_helper(self.lib, GOOD_HELPER)

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.helper_log.read_text(), "ran remove=True\n")

    def test_full_run_removes_files_run_dir_and_reports_backups(self) -> None:
        self.install_helper(self.src, GOOD_HELPER)

        result = self.run_script(None, "--governor", "performance")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(p.exists() for p in self.plugin_files))
        self.assertFalse(self.run_dir.exists())
        self.assertNotIn("DCPowerSave", self.cluster.read_text())
        self.assertIn("other.js", self.index.read_text())
        commands = self.commands()
        self.assertIn("cpupower -c all frequency-set -g performance", commands)
        self.assertLess(commands.index("disable --now"), commands.index("cpupower"))
        self.assertIn("/var/lib/pve-dc-powersave/backups", result.stdout)
        self.assertIn("never restore", result.stdout)

    def test_run_dir_symlink_is_not_followed_or_removed(self) -> None:
        self.install_helper(self.src, GOOD_HELPER)
        target = self.tmp / "elsewhere"
        target.mkdir()
        (target / "keep").write_text("x", encoding="utf-8")
        shutil.rmtree(self.run_dir)
        self.run_dir.symlink_to(target)

        result = self.run_script()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.run_dir.is_symlink())
        self.assertTrue((target / "keep").exists())

    def test_leftover_registration_blocks_deletion_of_modules(self) -> None:
        self.install_helper(self.src, GOOD_HELPER)

        result = self.run_script(None, HELPER_NOOP="1")

        self.assertEqual(result.returncode, 1)
        self.assertIn("NOT deleted", result.stderr)
        self.assertIn("PVE::API2::Cluster::DCPowerSave", result.stderr)
        self.assertIn("PVE::API2::Nodes::DCPowerSave", result.stderr)
        self.assertIn("dc-powersave.js", result.stderr)
        self.assertTrue(all(p.exists() for p in self.plugin_files))

    def test_single_leftover_in_index_blocks_deletion(self) -> None:
        self.install_helper(self.src, GOOD_HELPER)
        self.cluster.write_text("package PVE::API2::Cluster;\n", encoding="utf-8")
        self.nodes.write_text("package PVE::API2::Nodes;\n", encoding="utf-8")

        result = self.run_script(None, HELPER_NOOP="1")

        self.assertEqual(result.returncode, 1)
        self.assertIn("index.html.tpl", result.stderr)
        self.assertNotIn("Cluster.pm still", result.stderr)
        self.assertTrue(all(p.exists() for p in self.plugin_files))

    def test_helper_failure_keeps_the_modules(self) -> None:
        self.install_helper(self.src, GOOD_HELPER)

        result = self.run_script(None, HELPER_FAIL="1")

        self.assertEqual(result.returncode, 1)
        self.assertIn("helper failed", result.stderr)
        self.assertTrue(all(p.exists() for p in self.plugin_files))

    def test_unlocatable_pve_file_blocks_deletion(self) -> None:
        self.install_helper(self.src, GOOD_HELPER)
        self.cluster.unlink()

        result = self.run_script(None, HELPER_NOOP="1")

        self.assertEqual(result.returncode, 1)
        self.assertIn("could not locate", result.stderr)
        self.assertTrue(all(p.exists() for p in self.plugin_files))


if __name__ == "__main__":
    unittest.main()
