# Proxmox powersave CI checks

The workflow runs on pushes, pull requests and manual requests with read-only
repository permissions. The checkout Action is pinned to an immutable commit;
Dependabot checks GitHub Actions for updates weekly.

Blocking checks:
- Existing Perl tests (`prove -Ilib t`).
- Compilation of standalone modules under `lib/PVE/DC` and the daemon.
- ShellCheck for the installer.
- Python syntax validation for the Proxmox integration helper.
- Systemd unit validation inside a temporary CI filesystem.

The existing API tests provide Proxmox dependency stubs for the API modules.
The isolated systemd check provides stub Proxmox services and system targets;
it validates unit syntax and executable paths without starting the daemon or
changing a Proxmox node.

Perl::Critic starts as a nonblocking severity-1 diagnostic. Findings are visible
in Actions logs; a green workflow does not mean those findings are absent.
It can become a blocking check after the existing findings are addressed.

These files configure repository validation only. They do not change governor
selection, workload detection, the daemon or the installed systemd unit.
