# Proxmox powersave CI checks

The workflow runs on pushes, pull requests and manual requests with read-only
repository permissions. The checkout Action is pinned to an immutable commit;
Dependabot checks GitHub Actions for updates weekly.

Blocking checks:
- Existing Perl tests (`prove -Ilib t`).
- Compilation of standalone modules under `lib/PVE/DC` and the daemon.
- Perl::Critic policies tagged for bug prevention or security.
- ShellCheck for the installer.
- Python syntax validation for the Proxmox integration helper.
- Systemd unit validation inside a temporary CI filesystem.

The existing API tests provide Proxmox dependency stubs for the API modules.
The isolated systemd check provides stub Proxmox services and system targets;
it validates unit syntax and executable paths without starting the daemon or
changing a Proxmox node.

`.perlcriticrc` deliberately selects the `bugs || security` themes at severity
1. This runs every core correctness and security policy while excluding Perl
Best Practices rules concerned only with layout, naming or personal style. A
finding now fails CI instead of being hidden behind `continue-on-error`.

These files configure repository validation only. They do not change governor
selection, workload detection, the daemon or the installed systemd unit.
