# Changelog

All notable changes to this project are documented here.

## [Unreleased]

### Security

- The SonarQube Cloud token is now handed only to the analysis step of the CI
  workflow. Package installs, test runs and the other steps no longer see it.
- Release builds and tests now run without write access to the repository.
  A separate job that only publishes the finished archive and `SHA256SUMS`
  is the only one allowed to write.
- CI and release checkouts no longer keep the repository token in
  `.git/config`.

- A mistyped `--from-dir` no longer falls back to downloading `main` and
  running it as root. The directory must be a complete source tree, or the
  installer exits without downloading anything. `--from-dir` cannot be
  combined with `--ref` or `--repo`, and an explicit `--ref` is honoured even
  when the script is run from a checkout.

### Fixed

- Uninstalling a node that was installed with 0.2.1-beta.1 or older no longer
  deletes the plugin modules while PVE still loads them, which stopped
  `pvedaemon` and `pveproxy` at their next restart. The uninstaller never runs
  an integration helper that ignores `--remove`, checks that every
  registration is gone before it deletes anything, and stops before changing
  anything, with instructions, when it finds no suitable helper.
- `integrate-pve.py --remove` now repairs a node whose plugin modules are
  already missing. It finds `Cluster.pm` and `Nodes.pm` in Perl's `@INC`
  without loading them, and Perl's own error message is shown when a Perl
  command fails.
- The helper reloads `pvedaemon` and `pveproxy` (`systemctl reload-or-restart`)
  instead of hard-restarting them, including when it rolls a failed edit back.
  Running API workers are no longer killed.

- The installer compile-checks every module and the daemon against the node's
  own Proxmox libraries before replacing any installed file. If a later step
  fails, it restores the previous files (or removes a failed fresh install),
  reloads systemd and the API daemons, and exits non-zero, instead of leaving
  a module that `pvedaemon` and `pveproxy` cannot load. A failure to start
  only the controller service keeps the installed files and says so.
- The installer installs `linux-cpupower` and `python3` only when they are
  missing, so an unreachable repository (such as the enterprise repository
  without a subscription) no longer stops it. When a package is missing, a
  failing `apt-get update` is a warning.
- The installer works on a node without quorum: it warns that it could not
  create `/etc/pve/dc-powersave.cfg` and continues. The default configuration
  is written as a temporary file and renamed into place, so no node reads a
  half-written file.
- Node status now survives manual restarts and crashes of the service: the
  runtime directory is kept across restarts (a real stop still removes it),
  so the Nodes API no longer reports `service_not_reporting` and policy saves
  are no longer refused while the service restarts.

- An empty, whitespace-only, comments-only or truncated
  `/etc/pve/dc-powersave.cfg` no longer reads as "disabled" on every node.
  A file without a valid `enabled` line puts the node in `ERROR` on the
  failsafe governor and the status says why. A missing file still means the
  unmanaged defaults.
- A setting this version does not know is now a warning instead of an error,
  so a node that writes a new setting no longer pushes every older node into
  `ERROR` during a rolling upgrade. Saving the policy keeps such lines, and
  `status.json` lists them as `configuration_warnings`.
- A valid `enabled: 0` is honoured as `DISABLED` even when other lines in the
  file are invalid; the ignored problems are listed in
  `configuration_warnings`. With `enabled: 1` an invalid line is still an
  `ERROR`.
- A `pvesh` or `cpupower` call that ignores `SIGTERM` can no longer freeze the
  controller while it holds the lock. The command runs in its own process
  group and gets `SIGTERM`, then `SIGKILL`, so a call returns within its time
  limit plus about 4 seconds, and a stuck grandchild no longer keeps the pipes
  open.
- A task change or configuration change that arrives while the lock is busy
  (for example during `pve-dc-powersave --once`) or while a reconciliation
  fails is no longer dropped until the next timer. The controller retries
  after the poll interval, backing off up to the reconciliation interval.
- `pve-dc-powersave --once` no longer switches an idle node to the active
  governor or reports it as `ACTIVE`: it counts boot protection from system
  boot, and a node the service published as `IDLE` stays idle. A node that is
  not yet idle waits one idle candidate delay and is reconciled a second time.
- When the requested governor cannot be applied, the failsafe governor is
  now read back as well. The status names the governor that is requested and
  the governors the node actually runs, and a failsafe that fails adds an
  error.
- A short task seen while the controller confirms an idle transition no longer
  lets the next reconciliation skip the idle candidate delay.
- `last_error` keeps configuration, runtime and CPU governor problems side by
  side, joined with `; `, instead of the last one hiding the others, and
  names a governor that is both requested and failsafe once.

- Storage removals (`dirremove`, `lvmremove`, `zfsremove`, ...), disk moves
  (`qmmove`, `move_volume`) and HA `hastart`/`hastop` tasks no longer put
  every node on the migration governor. Only `qmigrate`, `vzmigrate`,
  `migrateall`, `hamigrate`, `harelocate` and other migration task types do;
  other work protects just the node that runs it.
- A guest start that begins and ends between two task polls is noticed within
  seconds instead of at the next safety reconciliation. Finished tasks now
  change the wake-up fingerprint too.
- One unreachable cluster node no longer puts every node into `ERROR`. The
  nodes stay on the active governor with reason `task_state_unknown`, the
  status names the unreachable member in `task_state_detail`, and the member
  is not queried again for 60 seconds.

### Changed

- Backups of `Cluster.pm`, `Nodes.pm` and `index.html.tpl` now live in
  `/var/lib/pve-dc-powersave/backups/` (mode 0700) instead of next to the PVE
  files, and only the newest five per file are kept. Existing
  `*.dc-powersave.backup.*` copies are moved there the next time the installer
  or uninstaller runs. They are for inspection only; do not restore one after
  a PVE upgrade. The uninstaller keeps them and tells you where they are.
- The uninstaller removes `/run/pve-dc-powersave` after stopping the service,
  but only when it is a real directory and not a symlink.

- The service never hits systemd's start limit and, on systemd 254 or newer
  (Proxmox VE 9), backs off from 3 seconds to 5 minutes while it keeps
  failing. Proxmox VE 8 (systemd 252) ignores the two new keys and logs an
  "Unknown key" notice at `systemctl daemon-reload`.
- The installer installs every `lib/PVE/DC/PowerSave/*.pm` module and replaces
  the module directory as a whole, so modules removed in a newer version do
  not stay behind.

- Boot protection, the idle candidate delay, retry backoff and the time limit
  of every subprocess use the monotonic clock, so a clock step at boot (for
  example NTP correcting the hardware clock) cannot shorten or stretch them.
  Timestamps in `status.json` stay in epoch seconds.
- `pve-dc-powersave --once` counts boot protection from system boot, not from
  its own start, and may take one extra pass of `idle_candidate_delay` before
  it reports. Exit codes are unchanged.

- A node that runs storage services (`ceph-osd`, `ceph-mon`, `ceph-mds`,
  `nfsd`, `glusterfsd`, `tgtd`, `proxmox-backup-proxy`) stays on the active
  governor with reason `storage_service`, and the status lists them in
  `storage_services`. Ceph, NFS and Proxmox Backup Server nodes therefore no
  longer idle at all.
- Each reconciliation starts fewer `pvesh` processes: the other nodes' active
  task lists are only fetched when the node could otherwise become idle.
- Opening or closing a console, and tasks on other nodes that are not
  migrations, no longer trigger a reconciliation on every node.

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
