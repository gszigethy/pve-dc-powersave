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
   ```

2. The installer creates `/etc/pve/dc-powersave.cfg` with `enabled: 0`. This
   file is shared by Proxmox across the cluster. It is created once; later
   installs on other nodes preserve it. The installer restarts `pvedaemon` and
   `pveproxy` to expose the new UI and API. Refresh your browser after install.

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
| Boot protection | 120 s | Active period after service start. |

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

`--once` exits with status 2 when the node ends in `ERROR`, and with status 1
without reconciling when the service is reconciling at that moment.

## Proxmox upgrades and removal

Proxmox does not expose a general third-party UI/API plugin loader for this
feature. The installer makes small registrations in Proxmox's API
modules and web template and keeps backups of the files it edits (see below). A `pve-manager` package upgrade may replace those
registrations. **Rerun the installer on every node after a PVE upgrade**, then
refresh the browser and check the Power Management page. The installer keeps
the shared configuration and is idempotent.

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
node installed with 0.2.1-beta.1 or older. Run `uninstall.sh` from a
v0.3.0-or-newer source checkout or release archive instead
(`scripts/uninstall.sh`); it uses the helper next to it. If a registration
cannot be removed, the uninstaller stops without deleting the modules and lists
what is left, because removing the modules while PVE still loads them stops
`pvedaemon` and `pveproxy` from starting.

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
