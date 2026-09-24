# Proxmox Datacenter PowerSave

CPU governor management targeting Proxmox VE 8 and 9 clusters. It is designed for
**homelabs where idle power use matters**. **Production use is not advised.**

The controller uses running VM and container state, current tasks, and CPU
policy capabilities to choose a governor for each node. The policy and all
node status are available in **Datacenter → Power Management** in the Proxmox
web interface. See the [design and safety guide](docs/DESIGN.md) for the state
machine and migration rules.

## Install on every node

1. Sign in to a Proxmox shell as `root` on each node. Run the installer once
   per node. It installs `linux-cpupower`, the controller, the authenticated
   API routes, and the datacenter UI:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/gszigethy/proxmox-dc-powersave/main/scripts/install.sh \
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

4. Check `cpupower frequency-info` on every node. Start and stop a VM and a
   container, then perform a migration while watching both node rows. Only
   after these checks, tick **Enabled** and save the cluster policy in the UI.

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
runtime information requests active; it never proves a node idle.

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

## Proxmox upgrades and removal

Proxmox does not expose a general third-party UI/API plugin loader for this
feature. The installer makes small, backed-up registrations in Proxmox's API
modules and web template. A `pve-manager` package upgrade may replace those
registrations. **Rerun the installer on every node after a PVE upgrade**, then
refresh the browser and check the Power Management page. The installer keeps
the shared configuration and is idempotent.

To stop automation immediately, clear **Enabled** in the UI. If the UI is
unavailable, set `enabled: 0` in `/etc/pve/dc-powersave.cfg` on a quorate node.
This leaves the current governor in place. See [the design guide](docs/DESIGN.md)
for the safety model and operational limits.
