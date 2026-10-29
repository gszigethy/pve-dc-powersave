# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Added

- `pvesh set /cluster/power-management --enabled 0`, run as `root` on a
  quorate node, is now the command-line emergency stop. Policy updates accept
  any subset of the properties (and an optional `digest`) and merge them into
  the stored policy. If the stored file cannot be read, `--enabled 0` rewrites
  it with the defaults.

### Security

- Capability discovery is cached for about 10 seconds in
  `/run/pve-dc-powersave` and computed by one request at a time. Users with
  only `Sys.Audit` could previously start any number of discoveries, each
  holding one of `pvedaemon`'s three workers while it queried every node.
  Saving a policy that needs the capability check still uses a report at
  most 10 seconds old.

### Fixed

- Interval changes and disabling are no longer refused because one node is
  down or was just upgraded. Capabilities are checked only when a save turns
  the policy on or changes a governor of an enabled policy.
- A node whose Power Management API was removed by a `pve-manager` upgrade now
  shows as `plugin_not_installed`, with a hint to rerun the installer, in the
  UI and in the capability report. Proxmox answers 501 there, which the UI
  treated as a generic status error.
- A save that timed out in the browser but completed can be retried: the
  digest is checked before the slow capability check, and a retry whose
  result is already stored succeeds.
- The digest returned by a save belongs to that save. It could previously be
  read after the lock was released and belong to another admin's save.
- The stale node status message shows whole seconds.
- A failure in the Power Management page can no longer stop the other
  Datacenter, node, VM, container and storage panels from loading.
- A failed status refresh (expired login, `pveproxy` restart) is shown next
  to the node table and clears itself, instead of opening a dialog every 15
  seconds. The status loads once when the page is shown, and the Reconcile
  buttons are hidden for users without `Sys.Modify`.

## [0.3.0] - 2026-10-20

### Added

- `scripts/uninstall.sh` (installed as `/usr/lib/pve-dc-powersave/uninstall.sh`)
  and `integrate-pve.py --remove` take the plugin off a node: they stop the
  service, optionally set a governor on every CPU policy (`--governor`),
  remove the PVE API and web registrations before the files they load, and
  optionally delete the shared configuration (`--purge-config`).
- `pve-dc-powersave --once` now exits 1 when the running service holds the
  lock, and 2 when the node ends in `ERROR`.
- `docs/REVIEW-2026-10.md`: data flow, findings, security and performance
  review, and open proposals.

### Security

- The controller lock moved from world-writable `/run/lock` to
  `/run/pve-dc-powersave`. Any local user could previously hold the old lock
  and silently stop every reconciliation. The controller now refuses a lock
  directory it does not own or that others can write, and does not follow
  symlinks.
- The installer no longer mistakes the parent of the current directory for a
  source checkout when piped into `bash`, so `curl ... | bash` always
  downloads the requested ref.

### Fixed

- The cluster capabilities endpoint now runs in `pvedaemon`. In `pveproxy` it
  ran as `www-data`, where `pvesh` cannot run, so the UI could not discover
  governors or enable the policy.
- Backups, restores, clones, disk moves and any other task running on a node
  now keep it out of idle. Only interactive console sessions are ignored.
- CPUs that are offline no longer leave the node in `ERROR` or remove every
  governor from the cluster-wide common set.
- A command that writes a lot to stderr no longer blocks until it times out.
  All `pvesh` and `cpupower` calls share one runner that reads both pipes.
- When a governor is unavailable, the status shows the failsafe governor that
  was requested, and the error names both unavailable governors.
- A failed status write no longer leaves a temporary file behind.
- A node whose service is stopped is reported as such instead of as missing
  `cpupower`.
- The Power Management page no longer re-runs cluster capability discovery
  every 15 seconds, keeps the loaded governors when policy and capabilities
  arrive in either order, accepts whole numbers only in the interval fields,
  and lists nodes in a stable order.
- `integrate-pve.py` restarts the API daemons only when it changed a file.

### Changed

- The task wake-up poll reads the cluster task list in process through
  `PVE::Cluster` and falls back to `pvesh`, avoiding about 43,000 process
  starts per node per day. A node that stays idle no longer collects its
  runtime state twice per reconciliation.
- CI uses `actions/setup-node` 7.1.0 and shellchecks `scripts/uninstall.sh`.
- Perl test count grew from 66 to 141, with the CPU backend and the
  subprocess runner now covered.

## [0.2.1-beta.1] - 2026-10-07

### Fixed

- A concurrent read during a policy save could see an empty configuration
  file and silently report the node as disabled; saves now replace the file
  atomically.
- Losing a previously enabled shared configuration now stays an error instead
  of turning into `DISABLED` after one reconciliation.
- Rerunning the installer now restarts the controller and reloads the PVE API
  daemons, so upgrades take effect without a reboot.
- Overlapping status refreshes in the Power Management UI no longer duplicate
  node rows; all status columns are HTML-encoded.
- The design guide now shows the `cpupower` command the backend actually runs.

### Changed

- CI adds Perl coverage, Python helper tests, JavaScript syntax checks,
  SonarQube Cloud analysis and a guarded tag-based release workflow. Tags with
  a pre-release suffix are published as GitHub pre-releases.

## [0.2.0] - 2026-09-24

### Added

- Cluster-wide governor capability discovery and intersection.
- Datacenter UI governor selectors limited to governors available on every
  CPU policy on every node.
- Clear prerequisite and no-common-governor messages in the UI.
- Intel P-state active/passive and Proxmox VE bootloader configuration guide.

### Changed

- Enabling a policy now fails closed for incomplete, stale, or incompatible
  node capability reports.
- Node-level available governors now represent the intersection across local
  CPU policies rather than their union.

## [0.1.0] - 2026-09-24

Initial public release.

### Added

- Cluster-wide policy stored in `/etc/pve/dc-powersave.cfg`.
- Node-local systemd controller with safe boot and workload protection.
- Runtime detection for guests, migrations, and Proxmox tasks.
- CPU governor selection through `cpupower` with capability verification.
- Authenticated Proxmox API endpoints and Datacenter → Power Management UI.
- Idempotent installer for Proxmox VE 8 and newer.
- Design documentation and Perl test coverage for policy and runtime behavior.
