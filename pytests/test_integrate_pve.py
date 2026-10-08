"""Unit tests for the Proxmox integration helper."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "integrate-pve.py"
SPEC = importlib.util.spec_from_file_location("integrate_pve", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
integrate_pve = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(integrate_pve)


class IntegratePveTests(unittest.TestCase):
    def test_insert_once_adds_before_anchor_and_is_idempotent(self) -> None:
        raw = "before\nANCHOR\nafter\n"
        modified = integrate_pve.insert_once(raw, "MARKER", "ANCHOR", "MARKER\n")

        self.assertEqual(modified, "before\nMARKER\nANCHOR\nafter\n")
        self.assertEqual(
            integrate_pve.insert_once(modified, "MARKER", "ANCHOR", "MARKER\n"),
            modified,
        )

    def test_insert_once_rejects_unknown_layout(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "Insertion anchor missing"):
            integrate_pve.insert_once("text", "MARKER", "missing", "addition")

    def test_cluster_transform_is_idempotent(self) -> None:
        raw = """package PVE::API2::Cluster;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
"""
        modified = integrate_pve.cluster_transform(raw)

        self.assertIn("use PVE::API2::Cluster::DCPowerSave;", modified)
        self.assertIn("# BEGIN pve-dc-powersave", modified)
        self.assertEqual(integrate_pve.cluster_transform(modified), modified)

    def test_node_transform_is_idempotent(self) -> None:
        raw = """package PVE::API2::Nodes;
use PVE::API2::NodeConfig;

__PACKAGE__->register_method({
"""
        modified = integrate_pve.node_transform(raw)

        self.assertIn("use PVE::API2::Nodes::DCPowerSave;", modified)
        self.assertIn("# BEGIN pve-dc-powersave", modified)
        self.assertEqual(integrate_pve.node_transform(modified), modified)

    def test_index_transform_is_idempotent(self) -> None:
        raw = """<html>
    <script type="text/javascript" src="/pve2/ext6/locale/pve-lang.js"></script>
</html>
"""
        modified = integrate_pve.index_transform(raw)

        self.assertIn('/pve2/js/dc-powersave.js', modified)
        self.assertEqual(integrate_pve.index_transform(modified), modified)

    def test_write_atomic_replaces_content_and_preserves_mode(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "target"
            path.write_text("old", encoding="utf-8")
            path.chmod(0o640)

            integrate_pve.write_atomic(path, "new content")

            self.assertEqual(path.read_text(encoding="utf-8"), "new content")
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)

    def test_perl_module_path_finds_core_module(self) -> None:
        path = integrate_pve.perl_module_path("strict")
        self.assertTrue(path.is_file())
        self.assertEqual(path.name, "strict.pm")

    def test_remove_restores_original_files(self) -> None:
        cluster = """package PVE::API2::Cluster;
use strict;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    subclass => "PVE::API2::ReplicationConfig",
"""
        nodes = """package PVE::API2::Nodes;
use PVE::API2::NodeConfig;

__PACKAGE__->register_method({
    subclass => "PVE::API2::Qemu",
"""
        index = """<head>
    <script type="text/javascript" src="/pve2/js/pvemanagerlib.js?ver=[% version %]"></script>
    <script type="text/javascript" src="/pve2/ext6/locale/locale-[% lang %].js?ver=7.0.0"></script>
</head>
"""
        self.assertEqual(integrate_pve.api_remove(integrate_pve.cluster_transform(cluster)), cluster)
        self.assertEqual(integrate_pve.api_remove(integrate_pve.node_transform(nodes)), nodes)
        self.assertEqual(integrate_pve.index_remove(integrate_pve.index_transform(index)), index)
        self.assertEqual(integrate_pve.api_remove(cluster), cluster)
        self.assertEqual(integrate_pve.index_remove(index), index)

    def test_main_installs_and_removes_registrations(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            files = {
                "PVE::API2::Cluster": (root / "Cluster.pm",
                                       "use base qw(PVE::RESTHandler);\n\n__PACKAGE__->register_method({\n"),
                "PVE::API2::Nodes": (root / "Nodes.pm",
                                     "use PVE::API2::NodeConfig;\n\n__PACKAGE__->register_method({\n"),
            }
            for path, text in files.values():
                path.write_text(text, encoding="utf-8")
            index = root / "index.html.tpl"
            index_text = '    <script type="text/javascript" src="/pve2/ext6/locale/x.js"></script>\n'
            index.write_text(index_text, encoding="utf-8")
            calls = []

            def run(cmd, check):
                calls.append((cmd, check))

            with patch.object(integrate_pve.os, "geteuid", return_value=0), \
                    patch.object(integrate_pve, "perl_module_path", side_effect=lambda name: files[name][0]), \
                    patch.object(integrate_pve, "INDEX", index), \
                    patch.object(integrate_pve.subprocess, "run", side_effect=run), \
                    patch("builtins.print"):
                integrate_pve.main([])
                self.assertIn("# BEGIN pve-dc-powersave", files["PVE::API2::Cluster"][0].read_text())
                self.assertIn("/pve2/js/dc-powersave.js", index.read_text())
                self.assertIn((["systemctl", "restart", "pvedaemon", "pveproxy"], True), calls)

                calls.clear()
                integrate_pve.main([])
                self.assertNotIn((["systemctl", "restart", "pvedaemon", "pveproxy"], True), calls)

                integrate_pve.main(["--remove"])
                for path, text in files.values():
                    self.assertEqual(path.read_text(), text)
                self.assertEqual(index.read_text(), index_text)
                self.assertIn((["systemctl", "restart", "pvedaemon", "pveproxy"], True), calls)

    def test_main_requires_root(self) -> None:
        with patch.object(integrate_pve.os, "geteuid", return_value=1000):
            with self.assertRaisesRegex(RuntimeError, "Run integration as root"):
                integrate_pve.main([])


if __name__ == "__main__":
    unittest.main()
