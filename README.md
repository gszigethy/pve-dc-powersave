# Proxmox Datacenter PowerSave

CPU governor management targeting Proxmox VE 8 and 9 clusters. It is designed for
**homelabs where idle power use matters**. **Production use is not advised.**

The controller uses running VM and container state, current tasks, and CPU
policy capabilities to choose a governor for each node. Governor choices are
limited to the intersection supported by every CPU policy on every cluster
node. The policy and all
node status are available in **Datacenter → Power Management** in the Proxmox
web interface. See the [design and safety guide](docs/DESIGN.md) for the state
machine and migration rules.

## Install on every node

1. Sign in to a Proxmox shell as `root` on each node. Run the installer once
   per node. It installs `linux-cpupower`, the controller, the authenticated
   API routes, and the datacenter UI:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/gszigethy/pve-dc-powersave/main/scripts/install.sh \
     | bash
   ```

   Prefer a release tag or reviewed local checkout when one is available:

   ```sh
   bash scripts/install.sh --from-dir .
   bash scripts/install.sh --ref v0.3.0
   ```

   `--from-dir DIR` installs a local source tree and downloads nothing; it
   must contain the files the installer needs, or the installer exits without
   changing anything. `--ref` (and `--repo OWNER/REPOSITORY`) always
   downloads that ref, even when the script sits in a checkout. The two cannot
   be combined. With neither option, the installer uses the checkout the
   script belongs to, or downloads `main` when run from a pipe.

   Before it replaces anything, the installer stages all files in a private
   temporary directory and compile-checks every Perl module and the daemon
   against this node's own Proxmox libraries. If one does not compile it
   prints Perl's error and exits without touching the node. It installs
   `linux-cpupower` and `python3` only when they are missing; an unreachable
   package repository (for example the enterprise repository without a
   subscription) therefore does not matter when nothing is missing. It then
   backs up the installed files and replaces them, and the module directory is
   replaced as a whole so modules removed in a newer version do not linger.
   If a later step fails (`systemctl daemon-reload`, the integration helper,
   or the `pvedaemon`/`pveproxy` reload and API check), it restores the
   previous files, removes the registrations of a failed fresh install,
   reloads what needs it and exits non-zero. If only starting the
   `pve-dc-powersave` service fails, the files and the API integration are
   kept, because they are good; the installer reports the failure and exits
   non-zero, and you rerun it after fixing the cause.

2. The installer creates `/etc/pve/dc-powersave.cfg` with `enabled: 0`. This
   file is shared by Proxmox across the cluster. It is created once, as a
   temporary file that is renamed into place so no node reads a half-written
   file; later installs on other nodes preserve it. The installer reloads
   `pvedaemon` and `pveproxy` (gracefully, no restart) to expose the new UI and API. Refresh your
   browser after install.

   Without quorum `/etc/pve` is read-only. The installer then warns, skips the
   file and continues; the controller treats a missing file as disabled. Create
   it later by saving the policy in **Datacenter → Power Management**, or by
   rerunning the installer on a node that has quorum.

3. Open **Datacenter → Power Management**. Review the cluster policy and each
   node's prerequisites. A node's row shows its state, actual and desired
   governors, running VM/CT counts, protection, reason, and last error.
   Double click a node for driver, CPU policy, version, and timing details.

4. Check `cpupower frequency-info` on every node. If the page reports no common
   governor, follow the [Intel P-state mode guide](docs/INTEL-PSTATE.md) and
   configure the CPU frequency driver consistently across the cluster. Start
   and stop a VM and a container, then perform a migration while watching both
   node rows. Only after these checks, tick **Enabled** and save the cluster
   policy in the UI.

The service is local to each node, but the policy is shared. Install it on
**all** nodes before enabling; an uninstalled node cannot change its governor
or report status.

## Policy fields

| Field | Default | Meaning |
| --- | --- | --- |
| Enabled | Off | Start or stop automatic governor changes. Disabling leaves the current governor as is. |
| Active governor | `performance` | Running guests and uncertain state. |
| Idle governor | `powersave` | Verified empty nodes only. |
| Migration governor | `performance` | Protected lifecycle and migration work. |
| Failsafe governor | `performance` | Active policy requested after a transition or configuration failure. |
| Safety reconciliation | 30 s | Full check even when no task change is seen. |
| Task poll | 2 s | How quickly task changes can wake the controller. |
| Idle candidate delay | 5 s | Time a node must remain empty before the final check. |
| Boot protection | 120 s | Active period after service start (the daemon) or after system boot (`--once`). |

Governors are checked on **every CPU frequency policy** on each node. The
controller reads the actual governor back after a change. Missing or uncertain
runtime information requests active; it never proves a node idle. Enabling is
rejected unless every node reports fresh capabilities and all four configured
governors are available everywhere.

## UI and API behavior

The UI calls authenticated Proxmox endpoints. Reading policy and node status
requires `Sys.Audit`; changing policy and requesting reconciliation requires
`Sys.Modify`. Browser writes use Proxmox's CSRF token. There is no API action
to set an arbitrary governor.

The **Reconcile selected** and **Reconcile all** buttons schedule the normal
controller path. They do not bypass the runtime and safety checks. The local
CLI remains useful for diagnostics:

```sh
pve-dc-powersave --once --verbose
journalctl -u pve-dc-powersave.service -n 50 --no-pager
```

`--once` runs one reconciliation (add `--verbose` to log the result) without
disturbing a node the service has already settled. It counts boot protection
from system boot instead of from its own start, and a node that the service
published as `IDLE` within the last `max(2 x safety reconciliation + 15, 120)`
seconds stays idle: the idle delay it already served counts. In every other
case an empty node first reports `IDLE_CANDIDATE`; `--once` then waits the
idle candidate delay and reconciles one more time, and reports that second
result. It writes `status.json` like the service does.

`--once` exits with status 2 when the node ends in `ERROR`, and with status 1
without reconciling when the service is reconciling at that moment.

## Proxmox upgrades and removal

Proxmox does not expose a general third-party UI/API plugin loader for this
feature. The installer makes small, backed-up registrations in Proxmox's API
modules and web template. A `pve-manager` package upgrade may replace those
registrations. **Rerun the installer on every node after a PVE upgrade**, then
refresh the browser and check the Power Management page. The installer keeps
the shared configuration and is idempotent. If a rerun fails after it has
started replacing files, it restores the previous ones.

To stop automation immediately, clear **Enabled** in the UI. If the UI is
unavailable, set `enabled: 0` in `/etc/pve/dc-powersave.cfg` on a quorate node.
This leaves the current governor in place. See [the design guide](docs/DESIGN.md)
for the safety model and operational limits.

To remove the plugin from a node, run the uninstaller the installer placed
there:

```sh
/usr/lib/pve-dc-powersave/uninstall.sh --governor performance
```

It stops the service, sets every CPU policy to the given governor (omit
`--governor` to leave the current one), takes the registrations out of the PVE
API modules and web template, reloads `pvedaemon` and `pveproxy` (a graceful
reload, not a restart), checks that no registration is left, and only then
deletes the installed files and `/run/pve-dc-powersave`. The shared
`/etc/pve/dc-powersave.cfg` is kept unless you pass `--purge-config`, which you
should only do on the last node.

The uninstaller refuses to continue, before it changes anything, when the only
integration helper it can find predates removal support. This is the case on a
node installed with 0.2.1-beta.1 or older. Either run `scripts/uninstall.sh`
from a complete source tree or release archive of this release or newer, which
uses the helper next to it, or first rerun this release's installer on the node
(it installs the current helper and uninstaller) and then run
`/usr/lib/pve-dc-powersave/uninstall.sh`. If a registration cannot be removed,
the uninstaller stops without deleting the modules and lists what is left,
because removing the modules while PVE still loads them stops `pvedaemon` and
`pveproxy` from starting.

Backups of the edited PVE files are kept in
`/var/lib/pve-dc-powersave/backups/` (mode 0700, the newest five per file; the
file name is the original path with `/` written as `%2F`). Backups that older
versions left next to the PVE files (`*.dc-powersave.backup.*`) are moved there
the next time the installer or uninstaller runs. They are for inspection only:
after a PVE upgrade, restoring one would downgrade Proxmox's API. The
uninstaller does not delete them; remove them yourself when you no longer need
them:

```sh
rm -r /var/lib/pve-dc-powersave
```
