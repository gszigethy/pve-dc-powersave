# Design and safety guide

## Intended use

Proxmox Datacenter PowerSave is intended for **homelab and other non-production
environments** where reducing idle-node power use is useful and the operator can
accept conservative automation and occasional manual intervention.

It is **not advised for production use**. CPU frequency policies are platform
dependent, Proxmox task visibility can differ between releases and cluster
states, and an error in this class of automation may affect workload
performance during a lifecycle operation or migration. Keep normal Proxmox HA,
backup, monitoring, and capacity practices in place; this controller does not
replace any of them.

Deploy it first on a test cluster. Validate every configured governor on every
node, test successful and failed migrations, and observe the journal before
enabling it on a relied-upon homelab.

## The rule that drives every decision

> Active is the safe fallback. Idle is a privileged state that requires
> positive proof.

The controller does not equate a configured VM or container with work. A node
with stopped guests can be idle; a node with a running guest cannot. More
importantly, observing zero running guests alone is not enough to make a node
idle. Before selecting the idle governor, the controller must have a complete,
recent view of guest runtime state and task state, valid CPU-governor
capabilities, no protection condition, and a second confirmation immediately
before the transition.

Any uncertainty has the opposite outcome: retain or request the active
governor.

## What runs on each node

Each Proxmox node runs one local systemd service. The configuration is shared
cluster-wide through pmxcfs at `/etc/pve/dc-powersave.cfg`, but CPU policy is
always applied locally. Nodes do not make independent policy choices from
node-local configuration. An authenticated Proxmox API module exposes policy
and status to **Datacenter → Power Management**.

```text
Proxmox tasks and runtime views
             |
             v
      RuntimeStateCollector
             |
             v
       DesiredStateEngine
             |
             v
   ReconciliationController
             |
             v
      CpupowerBackend -> CPU frequency policies
```

The boundaries are deliberate:

- The runtime collector only obtains state from stable `pvesh` views.
- The desired-state engine is deterministic policy; it does not run commands.
- The controller coalesces triggers, serializes reconciliation, and verifies
  results.
- The cpupower backend is the only component that changes governors.

This separation keeps Proxmox workload reasoning independent of Linux CPU
details and makes the policy unit-testable.

## Events are triggers; runtime state is truth

Proxmox does not provide a documented, generic third-party event subscription
that this project should depend on. The service therefore polls the stable
cluster task view at a short interval. It reads that list in process through
`PVE::Cluster` (pmxcfs IPC, the source of `GET /cluster/tasks`) and falls back
to `pvesh get /cluster/tasks` if that fails, so the poll does not start a new
process every few seconds. A task change wakes a reconciliation
quickly; it does not directly execute `cpupower`.

A periodic full reconciliation is also required. It self-heals after missed,
duplicated, or reordered task changes. This gives the controller two paths:

```text
task change -> prompt reconciliation
periodic timer -> safety reconciliation and recovery
```

In either path, the authoritative guest state is read from the local node's
`/nodes/<node>/qemu` and `/nodes/<node>/lxc` runtime views. The controller also
requires cluster status, the recent cluster task view, and the active task view
of every online node. This can add API traffic on larger clusters; the default
intervals are intended for small homelabs. Historical metrics and guest
configuration placement are never used to decide workload.

## Node states

| State | Meaning | Effective governor |
| --- | --- | --- |
| ACTIVE | Running work, boot protection, or uncertainty | Active/failsafe |
| IDLE_CANDIDATE | Empty node waiting for delay and re-check | Active |
| IDLE | Empty node has passed every check | Idle |
| PROTECTED | Lifecycle, migration, or other local task is in progress | Migration governor |
| ERROR | Invalid configuration, or CPU management prerequisite/apply/verification failed | Active/failsafe requested |
| DISABLED | Management is switched off (`enabled: 0`) | Left as it is |

`IDLE_CANDIDATE` prevents a VM stop from instantly becoming an idle transition.
After `idle_candidate_delay`, the controller collects runtime state again. If
anything changed or cannot be verified, it cancels the idle transition. A node
that is already `IDLE` with the idle governor on every policy is not about to
transition, so later reconciliations skip that second collection. If the
confirming collection finds work, or cannot verify the node, the idle delay
starts over: a short task cannot shorten the delay of the next attempt.

`ERROR` always requests the failsafe (or active) governor and names every
distinct problem in `last_error`, joined with `; `, so a runtime error does not
hide a configuration error or the other way round.

## Workload and protection rules

The following make a node active:

- A running VM or container.
- A guest start, stop, shutdown, or reboot task on that node.
- Any other running task on that node, such as a backup, restore, clone,
  disk move, or download, including task types this release does not know.
  Only interactive console sessions (`vncproxy`, `vncshell`, `spiceproxy`,
  `spiceshell`, `termproxy`) are ignored.
- Boot protection: the first `boot_protection_period` seconds after the
  service started. `pve-dc-powersave --once` counts from system boot instead,
  because every run is a new process.
- An unavailable or incomplete runtime/task/cluster-quorum view.
- Missing `cpupower`, missing frequency policies, unsupported configuration, or
  governor verification failure.

The following do not by themselves make a node active:

- Stopped VMs or containers.
- Templates, snapshots, and configuration-only guests.
- The mere existence of guest configuration on the node.

Migration is treated specially. Both source and destination are protected
before and during the operation. If the task summary does not expose a target,
the controller protects **every node** until that migration task ends. This is
less power-efficient, but it avoids allowing an unknown destination to remain
on the idle governor.

After a completed, failed, or cancelled migration, protection is not converted
directly into idle. The next reconciliation reads the actual guest locations
and calculates the state again. Task polling has an inherent detection delay;
PVE offers no stable general pre-migration callback for this integration. Test
target activation timing on your PVE release before enabling the policy.

## CPU governor safety

Modern Linux systems can expose multiple CPU frequency policies. One apparent
machine-wide governor value is not sufficient. Before control is enabled, the
backend discovers each `/sys/devices/system/cpu/cpufreq/policy*` policy, its
driver, available governors, and current governor.

Policies whose CPUs are all offline (for example after `echo 0 >
/sys/devices/system/cpu/cpuN/online` or disabling SMT at runtime) are inactive:
the kernel answers `EBUSY` for their attributes and `cpupower` skips their
CPUs, so the backend ignores them. Any other unreadable policy still makes the
node's CPU management unavailable.

A requested governor is applied only when every relevant policy supports it.
The backend invokes `cpupower -c all frequency-set -g <governor>` and then reads all
policies back. Command success alone does not count as a successful transition.

If the idle governor is missing on even one policy, the node remains active.
If management is unavailable, the software does not claim that an idle change
succeeded.

The failsafe governor is held to the same standard. When the requested
governor cannot be applied or does not read back, the controller sets the
failsafe governor and reads the policies back again. The status then names the
governor that is now requested, `actual_governors` shows what the node really
runs, and a failsafe that also fails adds its own error to `last_error`.

All intervals and deadlines (boot protection, the idle delay, retry backoff and
the time limit of every `pvesh` and `cpupower` call) use the monotonic clock,
so a clock step at boot cannot shorten or stretch them. Timestamps in
`status.json` are epoch seconds. A command that outlives its time limit is
stopped as a process group: `SIGTERM`, up to 2 s later `SIGKILL`; a process
that survives even that (uninterruptible sleep) is abandoned and reaped later,
so a reconciliation is never blocked for more than the limit plus about 4 s.

When a reconciliation cannot run (another one holds the lock) or fails, the
change that triggered it is not considered handled. The controller retries
after `event_poll_interval`, doubling the wait up to `reconciliation_interval`,
until a reconciliation completes.

The Datacenter capability endpoint first intersects the policy governor sets
on each node, then intersects those node-local results across the cluster. The
UI only offers this final common set. Enabling a policy is rejected when any
node is offline, missing, stale, or unable to report CPU policies, when the
common set is empty, or when a configured governor is outside the common set.
See the [Intel P-state mode guide](INTEL-PSTATE.md) when otherwise healthy
nodes expose incompatible governor sets.

## Configuration and rollout

The essential shared settings are:

```ini
enabled: 0
active_governor: performance
idle_governor: powersave
migration_governor: performance
failsafe_governor: performance
reconciliation_interval: 30
event_poll_interval: 2
idle_candidate_delay: 5
boot_protection_period: 120
```

How the shared file is read:

- A **missing** file means the unmanaged defaults, unless this node saw
  management enabled before; then the missing file is an error.
- An **existing file without a valid `enabled` line** is an error: an empty,
  whitespace-only or comments-only file, or one that was cut off before the
  `enabled` line. It must not look like "disabled" on every node. The node goes
  to `ERROR` with the failsafe governor and `last_error` says why. Every other
  missing setting takes its default.
- An **unknown setting** is a warning and is ignored, so a newer node can write
  a new key during a rolling upgrade. The UI/API save keeps such lines, in their
  original order, after the known settings. Warnings appear in `status.json` as
  `configuration_warnings` (an array, empty when there is nothing to report) and
  are logged once when they change.
- A valid **`enabled: 0`** is honoured as `DISABLED` even if other lines are
  invalid; those problems are listed in `configuration_warnings` as `ignored
  while management is disabled: ...`. With `enabled: 1`, or an unreadable
  `enabled`, any invalid line is an `ERROR`.

Start with `enabled: 0`. Confirm `linux-cpupower` is installed and inspect the
available governors on every node. Use the active governor for migration unless
you have measured and explicitly accepted another choice. Enable the controller
only after testing workload starts/stops and migrations.

The datacenter UI is the normal configuration and status interface. It shows
the shared policy, the actual and desired governors for each node, workload
counts, protection reason, errors, and detailed CPU policy discovery. Its
**Reconcile** buttons schedule the same controller path used by task polling.

The API routes are `GET`/`PUT /cluster/power-management`,
`GET /nodes/{node}/power-management`, and
`POST /nodes/{node}/power-management/reconcile`. Reads require `Sys.Audit` and
writes require `Sys.Modify`; browser writes require a Proxmox CSRF token. No
endpoint accepts an arbitrary governor command.

Proxmox has no general third-party UI/API loader for this feature. Installation
adds small registrations to the Proxmox API modules and web template. Before
each edit it copies the file to `/var/lib/pve-dc-powersave/backups/` (the newest
five per file are kept; they are for inspection, never for restoring after an
upgrade). The helper finds the files in Perl's `@INC` without loading them and
compiles each edited Perl module before it gives the API daemons a graceful
`reload-or-restart`; on failure it restores the files from its backups.
Removal takes the registrations out before the files they load are deleted, and
the uninstaller verifies this independently of the helper. A `pve-manager`
upgrade may remove the registrations. Rerun the installer on every node after an
upgrade, then confirm the UI and API are available.

The installer verifies before it replaces and undoes what it cannot finish:

1. It resolves one source. `--from-dir` is a local tree that must be complete
   (it never falls back to a download), `--ref`/`--repo` always download, and
   the two cannot be combined.
2. It stages all files in a root-only temporary directory and compile-checks
   every staged module and the daemon with the staged library directory ahead
   of the node's own PVE libraries. A failure prints Perl's error and leaves
   the node untouched, because `pvedaemon` and `pveproxy` load these modules
   at their next restart.
3. It installs `linux-cpupower` and `python3` only if `dpkg-query` reports them
   missing; a failing `apt-get update` is then a warning, a failing install an
   error, both before any installed file is touched.
4. It backs up the installed files, then replaces them; the module directory
   is replaced as a whole.
5. A failure of `systemctl daemon-reload`, the integration helper, the API
   daemon reload or the API check restores the backup (a failed fresh install
   is removed, including its registrations), reloads systemd and the API
   daemons, and exits non-zero. A failure to start only the
   `pve-dc-powersave` service keeps the files and the API integration and
   exits non-zero with the cause to investigate.
6. The default configuration is written only when `/etc/pve/dc-powersave.cfg`
   does not exist, as a temporary file renamed into place. Without quorum the
   write fails with a warning, not an error: a missing file means disabled.

Useful diagnostic checks on a node are:

```sh
cpupower frequency-info
pve-dc-powersave --once --verbose
journalctl -u pve-dc-powersave.service
```

`--once` reports the state the service would reach and writes `status.json`. It
is built not to change a node the service has already settled: boot protection
counts from system boot, and a node published as `IDLE` within the stale
threshold of the Nodes API (`max(2 * reconciliation_interval + 15, 120)` s)
counts as having served the idle delay. This shortcut is never taken when any
work is visible. Otherwise an empty node reports `IDLE_CANDIDATE` first;
`--once` then waits `idle_candidate_delay`, reconciles once more on the same
controller, and reports that result. It never makes more than that one extra
pass. Exit status 1 means another reconciliation held the lock; 2 means the
node ended in `ERROR`.

Disable the plugin by setting `enabled: 0`; it becomes unmanaged and will not
make further governor changes. Use your normal host-management method if you
need to restore a governor manually.
