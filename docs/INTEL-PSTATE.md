# Intel P-state modes and common governors on Proxmox VE

The Datacenter PowerSave policy can only offer governors supported by every
CPU frequency policy on every cluster node. Intel hosts commonly have no
cluster-wide governor when some nodes use `intel_pstate` active mode and others
use passive mode.

In active mode, `scaling_driver` reports `intel_pstate`. The names `powersave`
and `performance` select Intel P-state algorithms; they are not the generic
CPUFreq governors with the same names. In passive mode, `scaling_driver`
reports `intel_cpufreq` and the generic CPUFreq governors available in the
running kernel can be used. See the Linux kernel's
[Intel P-state documentation](https://docs.kernel.org/admin-guide/pm/intel_pstate.html)
for the full behavioral differences.

Do not change modes merely to make the governor lists match. Choose the mode
appropriate for the hardware and workload, test it, and configure it
identically on every node managed by one Datacenter policy.

## Inspect every node

Run these commands on each node and compare the output:

```sh
cat /proc/cmdline
cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null || true
grep . /sys/devices/system/cpu/cpufreq/policy*/scaling_driver
grep . /sys/devices/system/cpu/cpufreq/policy*/scaling_available_governors
proxmox-boot-tool status
```

`proxmox-boot-tool status` helps identify how the node boots. Do not assume
that every UEFI installation uses systemd-boot; Proxmox VE can also use GRUB on
UEFI systems. The Proxmox VE administration guide documents both kernel command
line paths in its
[bootloader section](https://pve.proxmox.com/pve-docs/pve-admin-guide.html#sysboot_edit_kernel_cmdline).

## Configure GRUB nodes

Schedule a maintenance window and migrate or stop workloads before rebooting a
node. Edit `/etc/default/grub` and add one explicit mode to the existing
`GRUB_CMDLINE_LINUX_DEFAULT` value.

For passive mode:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_pstate=passive"
```

For active mode:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_pstate=active"
```

Preserve any other kernel parameters already present. Then regenerate the GRUB
configuration and reboot:

```sh
update-grub
reboot
```

Repeat this on every GRUB-based cluster node. Change and verify one node at a
time so workloads can remain on known-good nodes.

## Configure systemd-boot nodes

If `proxmox-boot-tool status` shows systemd-boot, edit the single line in
`/etc/kernel/cmdline` instead. Add either `intel_pstate=passive` or
`intel_pstate=active`, preserve the existing root and other parameters, then
run:

```sh
proxmox-boot-tool refresh
reboot
```

## Verify after every reboot

Run the inspection commands again. Confirm that:

- `/proc/cmdline` contains the intended setting;
- every policy on the node reports the expected driver;
- every node intended for the Datacenter policy uses the same mode; and
- the Power Management page reports a non-empty common governor list.

The plugin will not enable a policy while any node is offline, has a
stale or missing capability report, or has no governor in common with the
other nodes.
