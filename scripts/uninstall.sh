#!/usr/bin/env bash
# Remove Proxmox Datacenter PowerSave from one PVE node.
set -Eeuo pipefail

readonly SERVICE="pve-dc-powersave.service"
readonly CONFIG="/etc/pve/dc-powersave.cfg"
governor=""
purge_config=0

usage() {
    cat <<'EOF'
Usage:
  uninstall.sh [--governor NAME] [--purge-config]

Removes the controller, API modules, UI script and PVE registrations from the
current node only. Run it on every node that should no longer be managed.

  --governor NAME   Set every CPU policy to NAME (for example performance)
                    after the controller stops. Without it, the current
                    governor stays as it is, which may be the idle governor.
  --purge-config    Also delete the shared /etc/pve/dc-powersave.cfg. This
                    affects every node; use it on the last node only.
EOF
}

while (($#)); do
    case "$1" in
        --governor) governor="${2:?--governor requires a governor name}"; shift 2 ;;
        --purge-config) purge_config=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if (( EUID != 0 )); then
    echo "Run as root." >&2
    exit 1
fi
if [[ -n "$governor" && ! "$governor" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "--governor contains unsupported characters." >&2
    exit 2
fi

echo "Stopping $SERVICE ..."
if systemctl list-unit-files "$SERVICE" >/dev/null 2>&1; then
    systemctl disable --now "$SERVICE" || true
fi

if [[ -n "$governor" ]]; then
    echo "Setting every CPU policy to $governor ..."
    cpupower -c all frequency-set -g "$governor" >/dev/null
fi

# Take the registrations out first, while the modules they load still exist,
# so pvedaemon and pveproxy restart cleanly.
helper=/usr/lib/pve-dc-powersave/integrate-pve.py
if [[ ! -f "$helper" && -f "${BASH_SOURCE[0]:-}" ]]; then
    helper="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/integrate-pve.py"
fi
if [[ -f "$helper" ]]; then
    echo "Removing the Datacenter UI and API registrations ..."
    python3 "$helper" --remove
else
    echo "Integration helper not found; check PVE::API2::Cluster, PVE::API2::Nodes and" >&2
    echo "/usr/share/pve-manager/index.html.tpl for 'pve-dc-powersave' manually." >&2
fi

echo "Removing installed files ..."
rm -f -- /usr/sbin/pve-dc-powersave \
    /usr/share/perl5/PVE/API2/Cluster/DCPowerSave.pm \
    /usr/share/perl5/PVE/API2/Nodes/DCPowerSave.pm \
    /usr/share/pve-manager/js/dc-powersave.js \
    "/etc/systemd/system/$SERVICE"
rm -rf -- /usr/share/perl5/PVE/DC/PowerSave /usr/lib/pve-dc-powersave
rmdir --ignore-fail-on-non-empty /usr/share/perl5/PVE/DC 2>/dev/null || true
systemctl daemon-reload
systemctl reset-failed "$SERVICE" 2>/dev/null || true

if (( purge_config )); then
    rm -f -- "$CONFIG"
    echo "Deleted the shared configuration $CONFIG for the whole cluster."
elif [[ -e "$CONFIG" ]]; then
    echo "Kept the shared configuration $CONFIG; other nodes may still use it."
fi

echo
echo "Removed pve-dc-powersave from this node."
governors="$(cat /sys/devices/system/cpu/cpufreq/policy*/scaling_governor 2>/dev/null | sort | uniq -c | xargs)" || true
echo "Current governors (count name): ${governors:-unknown}"
echo "Backups of the edited PVE files (*.dc-powersave.backup.*) were left in place."
echo "linux-cpupower was not removed. Refresh the browser to drop the Power Management page."
