"""Backup location, retention and legacy migration of the integration helper."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import urllib.parse


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "integrate-pve.py"
SPEC = importlib.util.spec_from_file_location("integrate_pve_backups", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
integrate_pve = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(integrate_pve)


class BackupTests(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.pve = self.root / "pve"
        self.pve.mkdir()
        self.backups = self.root / "var" / "backups"
        patcher = patch.object(integrate_pve, "BACKUP_DIR", self.backups)
        patcher.start()
        self.addCleanup(patcher.stop)
        # Never let a test reach the real systemctl.
        self.run_mock = patch.object(integrate_pve.subprocess, "run")
        self.run_mock.start()
        self.addCleanup(self.run_mock.stop)
        printer = patch("builtins.print")
        printer.start()
        self.addCleanup(printer.stop)

    def names(self, original: Path) -> list[str]:
        prefix = urllib.parse.quote(str(original), safe="") + "."
        return sorted(entry.name for entry in self.backups.iterdir() if entry.name.startswith(prefix))

    def test_new_backup_goes_to_private_directory_with_recoverable_name(self) -> None:
        target = self.pve / "Cluster.pm"
        target.write_text("old\n", encoding="utf-8")

        edits = integrate_pve.plan_edits([(target, lambda raw: raw + "new\n")])
        integrate_pve.apply_edits(edits, (), "Edited")

        self.assertEqual(stat.S_IMODE(self.backups.stat().st_mode), 0o700)
        (backup,) = list(self.backups.iterdir())
        self.assertEqual(backup.read_text(encoding="utf-8"), "old\n")
        match = integrate_pve.BACKUP_NAME.match(backup.name)
        assert match is not None
        self.assertEqual(urllib.parse.unquote(match["original"]), str(target))
        self.assertEqual(list(self.pve.glob("*backup*")), [])

    def test_retention_keeps_newest_five_per_original(self) -> None:
        one, two = self.pve / "Cluster.pm", self.pve / "Nodes.pm"
        self.backups.mkdir(parents=True)
        for stamp in range(1, 9):
            (self.backups / integrate_pve.backup_name(one, stamp)).write_text("c", encoding="utf-8")
        for stamp in range(1, 3):
            (self.backups / integrate_pve.backup_name(two, stamp)).write_text("n", encoding="utf-8")
        stranger = self.backups / "notes.txt"
        stranger.write_text("not ours", encoding="utf-8")

        integrate_pve.prune_backups()

        kept = [integrate_pve.BACKUP_NAME.match(name)["stamp"] for name in self.names(one)]
        self.assertEqual(sorted(map(int, kept)), [4, 5, 6, 7, 8])
        self.assertEqual(len(self.names(two)), 2)
        self.assertTrue(stranger.exists())

    def test_legacy_backups_are_moved_not_deleted_and_pruned_in_new_place(self) -> None:
        cluster = self.pve / "Cluster.pm"
        index = self.pve / "index.html.tpl"
        for stamp in range(100, 108):
            (self.pve / f"Cluster.pm.dc-powersave.backup.{stamp}").write_text(f"c{stamp}", encoding="utf-8")
        (self.pve / "index.html.tpl.dc-powersave.backup.50").write_text("i", encoding="utf-8")
        foreign = [
            self.pve / "Cluster.pm.dc-powersave.backup.notanumber",
            self.pve / "Cluster.pm.dc-powersave.backup.12.bak",
            self.pve / "Cluster.pm.orig",
            self.pve / "Other.pm.dc-powersave.backup.7",
        ]
        for entry in foreign:
            entry.write_text("keep", encoding="utf-8")

        integrate_pve.migrate_legacy_backups((cluster, index))

        self.assertEqual(sorted(p.name for p in self.pve.iterdir()), sorted(p.name for p in foreign))
        self.assertEqual(len(self.names(cluster)), 5)
        newest = self.backups / integrate_pve.backup_name(cluster, 107)
        self.assertEqual(newest.read_text(encoding="utf-8"), "c107")
        self.assertEqual(len(self.names(index)), 1)

    def test_every_run_migrates_legacy_backups(self) -> None:
        legacy = self.pve / "Cluster.pm.dc-powersave.backup.9"
        legacy.write_text("old", encoding="utf-8")
        cluster, nodes = self.pve / "Cluster.pm", self.pve / "Nodes.pm"
        index = self.pve / "index.html.tpl"
        for path in (cluster, nodes, index):
            path.write_text("x\n", encoding="utf-8")

        for argv in ([], ["--remove"]):
            legacy.write_text("old", encoding="utf-8")
            for stale in self.backups.glob("*") if self.backups.exists() else []:
                stale.unlink()
            with patch.object(integrate_pve.os, "geteuid", return_value=0), \
                    patch.object(integrate_pve, "perl_module_path",
                                 side_effect=lambda name: cluster if "Cluster" in name else nodes), \
                    patch.object(integrate_pve, "INDEX", index), \
                    patch.object(integrate_pve, "plan_edits", return_value=[]), \
                    patch.object(integrate_pve, "run_perl"):
                integrate_pve.main(argv)
            self.assertFalse(legacy.exists(), argv)
            self.assertEqual(len(self.names(cluster)), 1, argv)

    def test_symlinked_backup_directory_is_refused(self) -> None:
        elsewhere = self.root / "elsewhere"
        elsewhere.mkdir()
        self.backups.parent.mkdir(parents=True)
        self.backups.symlink_to(elsewhere)

        with self.assertRaisesRegex(RuntimeError, "is a symlink"):
            integrate_pve.ensure_backup_dir()


if __name__ == "__main__":
    unittest.main()
