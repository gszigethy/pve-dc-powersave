"""Integration helper tests that run the real perl against a temporary lib tree."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "integrate-pve.py"
SPEC = importlib.util.spec_from_file_location("integrate_pve_perl", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
integrate_pve = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(integrate_pve)

RELOAD = ["systemctl", "reload-or-restart", "pvedaemon", "pveproxy"]
REAL_RUN = subprocess.run

CLUSTER_PM = """package PVE::API2::Cluster;
use strict;
use warnings;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method({
    path => 'other',
});

1;
"""
NODES_PM = """package PVE::API2::Nodes;
use strict;
use warnings;
use base qw(PVE::RESTHandler);
use PVE::API2::NodeConfig;

__PACKAGE__->register_method({
    path => 'other',
});

1;
"""
INDEX_TPL = '    <script type="text/javascript" src="/pve2/ext6/locale/x.js"></script>\n'


def plugin_stub(package: str) -> str:
    return f"package {package};\nuse strict;\n1;\n"


class PerlTreeCase(unittest.TestCase):
    """A fake PVE perl tree on PERL5LIB with a recorded, mocked systemctl."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.lib = self.root / "lib"
        (self.lib / "PVE" / "API2" / "Cluster").mkdir(parents=True)
        (self.lib / "PVE" / "API2" / "Nodes").mkdir(parents=True)
        # `require` runs register_method, so the stub base class defines it.
        self.write("PVE/RESTHandler.pm", "package PVE::RESTHandler;\nsub register_method { 1 }\n1;\n")
        self.write("PVE/API2/NodeConfig.pm", plugin_stub("PVE::API2::NodeConfig"))
        self.cluster = self.write("PVE/API2/Cluster.pm", CLUSTER_PM)
        self.nodes = self.write("PVE/API2/Nodes.pm", NODES_PM)
        self.index = self.root / "index.html.tpl"
        self.index.write_text(INDEX_TPL, encoding="utf-8")
        self.calls: list[tuple[list[str], object]] = []

        def run(cmd, **kwargs):
            if cmd[0] == "systemctl":
                self.calls.append((cmd, kwargs.get("check")))
                return subprocess.CompletedProcess(cmd, 0, "", "")
            return REAL_RUN(cmd, **kwargs)

        for patcher in (
            patch.dict(os.environ, {"PERL5LIB": str(self.lib)}),
            patch.object(integrate_pve.os, "geteuid", return_value=0),
            patch.object(integrate_pve, "INDEX", self.index),
            patch.object(integrate_pve, "BACKUP_DIR", self.root / "backups"),
            patch.object(integrate_pve.subprocess, "run", side_effect=run),
            patch("builtins.print"),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    def write(self, relative: str, text: str) -> Path:
        path = self.lib / relative
        path.write_text(text, encoding="utf-8")
        return path

    def install_plugin_modules(self) -> None:
        self.write("PVE/API2/Cluster/DCPowerSave.pm", plugin_stub("PVE::API2::Cluster::DCPowerSave"))
        self.write("PVE/API2/Nodes/DCPowerSave.pm", plugin_stub("PVE::API2::Nodes::DCPowerSave"))


class PerlLookupTests(PerlTreeCase):
    def test_lookup_works_while_a_used_module_is_missing(self) -> None:
        # Cluster.pm loads a plugin module that does not exist (the broken
        # state after a bad uninstall). `require` dies here; the @INC
        # lookup must not.
        self.cluster.write_text(CLUSTER_PM.replace(
            "use base", "use PVE::API2::Cluster::DCPowerSave;\nuse base"), encoding="utf-8")

        old_approach = REAL_RUN(
            ["perl", "-e", "require PVE::API2::Cluster; print $INC{'PVE/API2/Cluster.pm'}"],
            capture_output=True, text=True)
        self.assertNotEqual(old_approach.returncode, 0)
        self.assertIn("DCPowerSave.pm", old_approach.stderr)

        self.assertEqual(integrate_pve.perl_module_path("PVE::API2::Cluster"), self.cluster)

    def test_lookup_follows_inc_order(self) -> None:
        first = self.root / "first" / "PVE" / "API2"
        first.mkdir(parents=True)
        (first / "Cluster.pm").write_text("1;\n", encoding="utf-8")
        with patch.dict(os.environ, {"PERL5LIB": f"{self.root / 'first'}:{self.lib}"}):
            self.assertEqual(integrate_pve.perl_module_path("PVE::API2::Cluster"),
                             first / "Cluster.pm")

    def test_perl_stderr_is_shown_on_failure(self) -> None:
        with self.assertRaises(RuntimeError) as caught:
            integrate_pve.run_perl(["-e", 'die "boom from perl\\n"'])
        self.assertIn("boom from perl", str(caught.exception))
        self.assertNotIn("non-zero exit status", str(caught.exception))


class RemoveAndRollbackTests(PerlTreeCase):
    def test_remove_repairs_node_whose_plugin_modules_are_missing(self) -> None:
        self.install_plugin_modules()
        integrate_pve.main([])
        self.assertIn("PVE::API2::Cluster::DCPowerSave", self.cluster.read_text())
        # The uninstall that deleted the modules but not the registrations.
        (self.lib / "PVE/API2/Cluster/DCPowerSave.pm").unlink()
        (self.lib / "PVE/API2/Nodes/DCPowerSave.pm").unlink()
        self.calls.clear()

        integrate_pve.main(["--remove"])

        self.assertEqual(self.cluster.read_text(), CLUSTER_PM)
        self.assertEqual(self.nodes.read_text(), NODES_PM)
        self.assertEqual(self.index.read_text(), INDEX_TPL)
        self.assertEqual(self.calls, [(RELOAD, True)])

    def test_integrate_rolls_back_and_shows_perl_error_when_modules_missing(self) -> None:
        # Plugin modules not installed: the compile check must catch it,
        # restore the files from the backups and reload gracefully.
        with self.assertRaises(RuntimeError) as caught:
            integrate_pve.main([])

        self.assertIn("Can't locate PVE/API2/Cluster/DCPowerSave.pm", str(caught.exception))
        self.assertEqual(self.cluster.read_text(), CLUSTER_PM)
        self.assertEqual(self.nodes.read_text(), NODES_PM)
        self.assertEqual(self.index.read_text(), INDEX_TPL)
        self.assertEqual(self.calls, [(RELOAD, False)])

    def test_normal_path_uses_reload_or_restart_only_when_a_file_changed(self) -> None:
        self.install_plugin_modules()
        integrate_pve.main([])
        self.assertEqual(self.calls, [(RELOAD, True)])
        self.calls.clear()
        integrate_pve.main([])
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
