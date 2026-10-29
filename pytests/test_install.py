"""Sandbox tests for scripts/install.sh.

The installer runs against a throw-away root (PVE_DC_POWERSAVE_ROOT, a
test-only seam in the script) with stub commands on PATH, so nothing touches
the real system and no root, PVE or network is needed. Every stub logs its
call to ``calls.log``; ``fail/<command>`` or ``fail/<command>.<first arg>``
makes a stub exit 1.
"""

from __future__ import annotations

import filecmp
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


REPO = Path(__file__).resolve().parents[1]
INSTALL = Path(os.environ.get("INSTALL_SH_UNDER_TEST", REPO / "scripts" / "install.sh"))

PERL_STUBS = {
    "PVE/RESTHandler.pm": "package PVE::RESTHandler; sub register_method {} 1;\n",
    "PVE/JSONSchema.pm": textwrap.dedent(
        """\
        package PVE::JSONSchema;
        sub get_standard_option { return {} }
        sub import { my $to = caller; no strict 'refs'; *{"${to}::get_standard_option"} = \\&get_standard_option }
        1;
        """
    ),
    "PVE/Cluster.pm": "package PVE::Cluster; 1;\n",
}

STUB = textwrap.dedent(
    """\
    #!/bin/sh
    name=$(basename "$0")
    echo "$name $*" >> "$STUB_DIR/calls.log"
    [ -e "$STUB_DIR/fail/$name" ] && exit 1
    [ -e "$STUB_DIR/fail/$name.$1" ] && exit 1
    {extra}
    exit 0
    """
)

STUBS = {
    "apt-get": "",
    "systemctl": "",
    "pvesh": "",
    "pveversion": 'echo "pve-manager/8.4.1/abcdef (running kernel: 6.8.12-4-pve)"',
    # dpkg-query -W -f=FORMAT PACKAGE: "installed" only for packages listed
    # in installed/.
    "dpkg-query": '[ -e "$STUB_DIR/installed/$3" ] && { echo installed; exit 0; }; exit 1',
    # Anything that could fetch source must never be called by a local install.
    "curl": 'touch "$STUB_DIR/download-attempted"; exit 22',
    "wget": 'touch "$STUB_DIR/download-attempted"; exit 22',
    "git": 'touch "$STUB_DIR/download-attempted"; exit 22',
}

HELPER = textwrap.dedent(
    """\
    #!/usr/bin/env python3
    import os, sys
    with open(os.path.join(os.environ["STUB_DIR"], "calls.log"), "a") as log:
        log.write("integrate-pve.py %s\\n" % " ".join(sys.argv[1:]))
    if "--remove" not in sys.argv and os.path.exists(os.path.join(os.environ["STUB_DIR"], "fail", "helper")):
        sys.exit(1)
    """
)


class InstallTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="install-test."))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.root = self.tmp / "root"
        self.stub_dir = self.tmp / "stubs"
        self.work_tmp = self.tmp / "tmp"
        self.src = self.tmp / "src"
        for path in (self.root / "etc" / "pve", self.stub_dir / "fail",
                     self.stub_dir / "installed", self.work_tmp):
            path.mkdir(parents=True)
        (self.stub_dir / "calls.log").touch()
        for package in ("linux-cpupower", "python3"):
            (self.stub_dir / "installed" / package).touch()

        bin_dir = self.stub_dir / "bin"
        bin_dir.mkdir()
        for name, extra in STUBS.items():
            stub = bin_dir / name
            stub.write_text(STUB.replace("{extra}", extra))
            stub.chmod(0o755)
        perl_lib = self.tmp / "perl"
        for rel, text in PERL_STUBS.items():
            (perl_lib / rel).parent.mkdir(parents=True, exist_ok=True)
            (perl_lib / rel).write_text(text)

        # A copy of the source tree whose helper is a stub.
        for part in ("bin", "lib", "systemd", "web"):
            shutil.copytree(REPO / part, self.src / part)
        (self.src / "scripts").mkdir()
        shutil.copy(REPO / "scripts" / "uninstall.sh", self.src / "scripts")
        helper = self.src / "scripts" / "integrate-pve.py"
        helper.write_text(HELPER)
        helper.chmod(0o755)

        self.env = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "PERL5LIB": str(perl_lib),
            "STUB_DIR": str(self.stub_dir),
            "PVE_DC_POWERSAVE_ROOT": str(self.root),
            "TMPDIR": str(self.work_tmp),
        }

    # -- helpers -----------------------------------------------------------

    def run_install(self, *args: str, script: Path = INSTALL, cwd: Path | None = None,
                    stdin_script: bool = False) -> subprocess.CompletedProcess[str]:
        if stdin_script:
            command = ["bash", "-s", "--", *args]
            stdin = script.read_text()
        else:
            command = ["bash", str(script), *args]
            stdin = None
        return subprocess.run(command, env=self.env, cwd=cwd, input=stdin, text=True,
                              capture_output=True, timeout=60, check=False)

    def run_ok(self, *args: str) -> subprocess.CompletedProcess[str]:
        result = self.run_install("--from-dir", str(self.src), *args)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return result

    def stub_fails(self, name: str) -> None:
        (self.stub_dir / "fail" / name).touch()

    def calls(self) -> list[str]:
        return (self.stub_dir / "calls.log").read_text().splitlines()

    def installed(self, rel: str) -> Path:
        return self.root / rel

    def seed_previous_install(self) -> None:
        """Lay down an older installation, including a module that no longer exists."""
        for rel in (
            "usr/sbin/pve-dc-powersave",
            "usr/share/perl5/PVE/DC/PowerSave/Config.pm",
            "usr/share/perl5/PVE/DC/PowerSave/Removed.pm",
            "usr/share/perl5/PVE/API2/Cluster/DCPowerSave.pm",
            "usr/share/perl5/PVE/API2/Nodes/DCPowerSave.pm",
            "usr/share/pve-manager/js/dc-powersave.js",
            "usr/lib/pve-dc-powersave/integrate-pve.py",
            "usr/lib/pve-dc-powersave/uninstall.sh",
            "etc/systemd/system/pve-dc-powersave.service",
        ):
            path = self.installed(rel)
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"previous {rel}\n")
        self.previous = self.snapshot()

    def snapshot(self) -> dict[str, str]:
        files: dict[str, str] = {}
        for path in sorted(self.root.rglob("*")):
            if path.is_file():
                files[str(path.relative_to(self.root))] = path.read_text()
        return files


class SourceSelectionTests(InstallTestCase):
    def test_bad_from_dir_exits_without_downloading(self) -> None:
        result = self.run_install("--from-dir", str(self.tmp / "no-such-dir"))

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.stub_dir / "download-attempted").exists())
        self.assertEqual(self.snapshot().keys() - {"etc/pve"}, set())
        self.assertIn("not a directory", result.stderr)

    def test_incomplete_from_dir_exits_without_downloading(self) -> None:
        (self.src / "web" / "dc-powersave.js").unlink()

        result = self.run_install("--from-dir", str(self.src))

        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.stub_dir / "download-attempted").exists())
        self.assertIn("web/dc-powersave.js", result.stderr)
        self.assertEqual(self.snapshot(), {})

    def test_from_dir_with_ref_or_repo_is_a_usage_error(self) -> None:
        for extra in (["--ref", "v0.3.0"], ["--repo", "someone/fork"]):
            with self.subTest(extra=extra):
                result = self.run_install("--from-dir", str(self.src), *extra)

                self.assertEqual(result.returncode, 2)
                self.assertIn("cannot be combined", result.stderr)
                self.assertFalse((self.stub_dir / "download-attempted").exists())
                self.assertEqual(self.snapshot(), {})

    def test_explicit_ref_downloads_even_inside_a_checkout(self) -> None:
        # The copied tree is a complete checkout and the script sits in it.
        shutil.copy(INSTALL, self.src / "scripts" / "install.sh")
        curl_args = self.tmp / "curl-args"
        (self.stub_dir / "bin" / "curl").write_text(
            f'#!/bin/sh\necho "$*" > {curl_args}\nexit 22\n'
        )

        result = self.run_install("--ref", "v9.9.9", script=self.src / "scripts" / "install.sh")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("archive/v9.9.9.tar.gz", curl_args.read_text())
        self.assertEqual(self.snapshot(), {})

    def test_piped_script_downloads_instead_of_using_the_working_directory(self) -> None:
        # "curl ... | bash" has no BASH_SOURCE; the parent of the current
        # directory must not be taken for a checkout.
        cwd = self.src / "scripts"

        result = self.run_install(script=INSTALL, cwd=cwd, stdin_script=True)

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.stub_dir / "download-attempted").exists())
        self.assertEqual(self.snapshot(), {})

    def test_script_in_a_checkout_installs_that_checkout(self) -> None:
        shutil.copy(INSTALL, self.src / "scripts" / "install.sh")

        result = self.run_install(script=self.src / "scripts" / "install.sh")

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((self.stub_dir / "download-attempted").exists())
        self.assertTrue(self.installed("usr/sbin/pve-dc-powersave").exists())


class PackageTests(InstallTestCase):
    def test_nothing_missing_means_apt_is_not_run(self) -> None:
        self.run_ok()

        self.assertEqual([c for c in self.calls() if c.startswith("apt-get")], [])

    def test_only_missing_packages_are_installed(self) -> None:
        (self.stub_dir / "installed" / "linux-cpupower").unlink()

        self.run_ok()

        self.assertIn("apt-get install -y linux-cpupower", self.calls())

    def test_failing_apt_update_still_attempts_the_install(self) -> None:
        (self.stub_dir / "installed" / "linux-cpupower").unlink()
        self.stub_fails("apt-get.update")

        result = self.run_ok()

        calls = self.calls()
        self.assertIn("apt-get update", calls)
        self.assertIn("apt-get install -y linux-cpupower", calls)
        self.assertIn("WARNING: apt-get update failed", result.stderr)
        self.assertTrue(self.installed("usr/sbin/pve-dc-powersave").exists())

    def test_failing_package_install_changes_nothing(self) -> None:
        (self.stub_dir / "installed" / "linux-cpupower").unlink()
        self.stub_fails("apt-get.install")
        self.seed_previous_install()

        result = self.run_install("--from-dir", str(self.src))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not install linux-cpupower", result.stderr)
        self.assertEqual(self.snapshot(), self.previous)
        self.assertNotIn("systemctl daemon-reload", self.calls())


class VerifyAndRollbackTests(InstallTestCase):
    def test_module_that_does_not_compile_leaves_installed_files_untouched(self) -> None:
        self.seed_previous_install()
        with (self.src / "lib/PVE/DC/PowerSave/Controller.pm").open("a") as module:
            module.write("\nmy $broken = ;\n")
        before = self.snapshot()

        result = self.run_install("--from-dir", str(self.src))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("syntax error", result.stderr)
        self.assertIn("Controller.pm", result.stderr)
        self.assertIn("Nothing was changed", result.stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.calls(), ["pveversion "])

    def test_api_module_that_does_not_compile_is_caught(self) -> None:
        with (self.src / "lib/PVE/API2/Nodes/DCPowerSave.pm").open("a") as module:
            module.write("\nuse PVE::No::Such::Module;\n")

        result = self.run_install("--from-dir", str(self.src))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PVE/No/Such/Module.pm", result.stderr)
        self.assertEqual(self.snapshot(), {})

    def test_staged_modules_win_over_installed_ones(self) -> None:
        # A previously installed module with a syntax error must not hide a
        # good staged one (and vice versa): the staged lib dir comes first.
        self.seed_previous_install()
        stale = self.installed("usr/share/perl5/PVE/DC/PowerSave/Config.pm")
        stale.write_text("this is not perl;;;(\n")
        self.previous = self.snapshot()

        self.run_ok()

        self.assertEqual(
            stale.read_text(), (REPO / "lib/PVE/DC/PowerSave/Config.pm").read_text()
        )

    def test_failing_helper_restores_the_previous_files(self) -> None:
        self.seed_previous_install()
        self.stub_fails("helper")

        result = self.run_install("--from-dir", str(self.src))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("integrating with the PVE API and UI", result.stderr)
        self.assertEqual(
            {k: v for k, v in self.snapshot().items() if k != "etc/pve/dc-powersave.cfg"},
            self.previous,
        )
        calls = self.calls()
        # The new unit was loaded and the old one is loaded again; the API
        # daemons are reloaded so they run the restored code.
        self.assertEqual(calls.count("systemctl daemon-reload"), 2)
        self.assertEqual(calls.count("systemctl reload-or-restart pvedaemon pveproxy"), 1)
        # Registrations of the previous install stay; only a fresh install is undone.
        self.assertNotIn("integrate-pve.py --remove", calls)
        self.assertNotIn("systemctl restart pve-dc-powersave.service", calls)

    def test_failing_api_reload_restores_the_previous_files(self) -> None:
        self.seed_previous_install()
        self.stub_fails("systemctl.reload-or-restart")

        result = self.run_install("--from-dir", str(self.src))

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            {k: v for k, v in self.snapshot().items() if k != "etc/pve/dc-powersave.cfg"},
            self.previous,
        )
        self.assertIn("previous version was restored", result.stderr)

    def test_failing_daemon_reload_restores_the_previous_files(self) -> None:
        self.seed_previous_install()
        self.stub_fails("systemctl.daemon-reload")

        result = self.run_install("--from-dir", str(self.src))

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.snapshot(), self.previous)

    def test_failed_fresh_install_is_removed_and_registrations_undone(self) -> None:
        self.stub_fails("helper")

        result = self.run_install("--from-dir", str(self.src))

        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(
            {k for k in self.snapshot() if k != "etc/pve/dc-powersave.cfg"}, set()
        )
        self.assertFalse(self.installed("usr/lib/pve-dc-powersave").exists())
        self.assertFalse(self.installed("usr/share/perl5/PVE/DC").exists())
        self.assertIn("integrate-pve.py --remove", self.calls())

    def test_failing_service_start_keeps_the_installed_files(self) -> None:
        self.seed_previous_install()
        self.stub_fails("systemctl.restart")

        result = self.run_install("--from-dir", str(self.src))

        self.assertEqual(result.returncode, 1)
        self.assertIn("did not start", result.stderr)
        self.assertEqual(
            self.installed("usr/share/perl5/PVE/DC/PowerSave/Controller.pm").read_text(),
            (REPO / "lib/PVE/DC/PowerSave/Controller.pm").read_text(),
        )
        self.assertNotIn("integrate-pve.py --remove", self.calls())
        self.assertEqual(self.calls().count("systemctl daemon-reload"), 1)

    def test_workdir_is_removed_on_every_exit_path(self) -> None:
        self.run_ok()
        self.assertEqual(list(self.work_tmp.iterdir()), [])

        self.stub_fails("helper")
        self.assertNotEqual(self.run_install("--from-dir", str(self.src)).returncode, 0)
        self.assertEqual(list(self.work_tmp.iterdir()), [])

        (self.src / "lib/PVE/DC/PowerSave/Config.pm").write_text("1 +;\n")
        self.assertNotEqual(self.run_install("--from-dir", str(self.src)).returncode, 0)
        self.assertEqual(list(self.work_tmp.iterdir()), [])


class InstalledFilesTests(InstallTestCase):
    def test_every_module_in_the_source_is_installed_and_stale_ones_are_removed(self) -> None:
        self.seed_previous_install()
        (self.src / "lib/PVE/DC/PowerSave/Extra.pm").write_text(
            "package PVE::DC::PowerSave::Extra; 1;\n"
        )

        self.run_ok()

        installed = self.installed("usr/share/perl5/PVE/DC/PowerSave")
        sources = REPO / "lib/PVE/DC/PowerSave"
        expected = {p.name for p in sources.glob("*.pm")} | {"Extra.pm"}
        self.assertEqual({p.name for p in installed.iterdir()}, expected)
        self.assertTrue(filecmp.cmp(installed / "Extra.pm", self.src / "lib/PVE/DC/PowerSave/Extra.pm"))

    def test_install_places_every_file_with_its_mode_and_starts_the_service(self) -> None:
        self.run_ok()

        modes = {
            "usr/sbin/pve-dc-powersave": 0o755,
            "usr/lib/pve-dc-powersave/integrate-pve.py": 0o755,
            "usr/lib/pve-dc-powersave/uninstall.sh": 0o755,
            "usr/share/pve-manager/js/dc-powersave.js": 0o644,
            "etc/systemd/system/pve-dc-powersave.service": 0o644,
            "usr/share/perl5/PVE/API2/Cluster/DCPowerSave.pm": 0o644,
            "usr/share/perl5/PVE/DC/PowerSave/Config.pm": 0o644,
        }
        for rel, mode in modes.items():
            with self.subTest(rel=rel):
                self.assertEqual(self.installed(rel).stat().st_mode & 0o777, mode)
        self.assertEqual(
            self.calls()[-3:],
            [
                "systemctl enable pve-dc-powersave.service",
                "systemctl restart pve-dc-powersave.service",
                "systemctl is-active --quiet pve-dc-powersave.service",
            ],
        )


class DefaultConfigTests(InstallTestCase):
    CONFIG = "etc/pve/dc-powersave.cfg"

    def test_default_config_is_created_once_without_leftovers(self) -> None:
        self.run_ok()

        config = self.installed(self.CONFIG)
        self.assertTrue(config.read_text().startswith("# Proxmox Datacenter PowerSave"))
        self.assertIn("\nenabled: 0\n", config.read_text())
        self.assertEqual([p.name for p in config.parent.iterdir()], ["dc-powersave.cfg"])

    def test_existing_config_is_kept(self) -> None:
        self.installed(self.CONFIG).write_text("enabled: 1\n")

        result = self.run_ok()

        self.assertEqual(self.installed(self.CONFIG).read_text(), "enabled: 1\n")
        self.assertIn("Keeping existing configuration", result.stdout)

    def test_config_is_skipped_with_a_warning_when_etc_pve_is_not_writable(self) -> None:
        # A regular file in place of the directory makes every write fail,
        # also when the tests run as root.
        (self.root / "etc" / "pve").rmdir()
        (self.root / "etc" / "pve").write_text("not a directory\n")

        result = self.run_ok()

        self.assertIn("WARNING: could not create /etc/pve/dc-powersave.cfg", result.stderr)
        self.assertIn("quorate", result.stderr)
        self.assertTrue(self.installed("usr/sbin/pve-dc-powersave").exists())
        self.assertEqual(self.calls()[-1], "systemctl is-active --quiet pve-dc-powersave.service")

    def test_config_is_written_by_renaming_a_complete_file(self) -> None:
        # The temporary file is created next to the target and renamed over
        # it, so the final path never exists half-written. Record what mv
        # is asked to move and whether the source is complete.
        log = self.tmp / "mv-calls"
        mv = self.stub_dir / "bin" / "mv"
        mv.write_text(
            "#!/bin/sh\n"
            f'printf "%s size=%s\\n" "$*" "$(wc -c < "$(for a; do case $a in -*) ;; *) echo $a; break;; esac; done)")" >> {log}\n'
            'exec /bin/mv "$@"\n'
        )
        mv.chmod(0o755)

        self.run_ok()

        line = log.read_text().strip()
        self.assertRegex(line, r"-n -- \S+/etc/pve/dc-powersave\.cfg\.tmp\.\d+ \S+/etc/pve/dc-powersave\.cfg size=\d+")
        self.assertGreater(int(line.rsplit("=", 1)[1]), 200)


if __name__ == "__main__":
    unittest.main()
