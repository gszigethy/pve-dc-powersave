#!/usr/bin/env bash
# Install Proxmox Datacenter PowerSave on one PVE node.
set -Eeuo pipefail

readonly PROGRAM="pve-dc-powersave"
readonly SERVICE="pve-dc-powersave.service"
repo="gszigethy/pve-dc-powersave"
repo_specified=0
ref="main"
source_dir=""

usage() {
    cat <<'EOF'
Usage:
  install.sh [--from-dir DIRECTORY]
  install.sh [--repo OWNER/REPOSITORY] [--ref BRANCH_OR_TAG]

Installs on the current node only. Run it on every PVE cluster node.
The controller is installed disabled; review /etc/pve/dc-powersave.cfg before
enabling it. The default repository is gszigethy/pve-dc-powersave.
EOF
}

while (($#)); do
    case "$1" in
        --repo) repo="${2:?--repo requires OWNER/REPOSITORY}"; repo_specified=1; shift 2 ;;
        --ref) ref="${2:?--ref requires a branch, tag, or commit}"; shift 2 ;;
        --from-dir) source_dir="${2:?--from-dir requires a directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if (( EUID != 0 )); then
    echo "Run as root (for example: sudo bash install.sh ...)." >&2
    exit 1
fi
if [[ -n "$repo" && ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "--repo must look like OWNER/REPOSITORY." >&2
    exit 2
fi
if [[ -n "$ref" && ! "$ref" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "--ref contains unsupported characters." >&2
    exit 2
fi

cleanup_dir=""
cleanup() { [[ -z "$cleanup_dir" ]] || rm -rf -- "$cleanup_dir"; }
trap cleanup EXIT

if [[ -z "$source_dir" && "$repo_specified" -eq 0 ]]; then
    source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
fi
if [[ "$repo_specified" -eq 1 || ! -f "$source_dir/bin/$PROGRAM" ]]; then
    command -v curl >/dev/null || { echo "curl is required for --repo mode." >&2; exit 1; }
    command -v tar >/dev/null || { echo "tar is required for --repo mode." >&2; exit 1; }
    cleanup_dir="$(mktemp -d /tmp/pve-dc-powersave.XXXXXX)"
    archive="$cleanup_dir/source.tar.gz"
    echo "Downloading $repo at $ref ..."
    curl --fail --location --proto '=https' --tlsv1.2 \
        "https://github.com/$repo/archive/$ref.tar.gz" -o "$archive"
    tar -xzf "$archive" -C "$cleanup_dir"
    source_dir="$(find "$cleanup_dir" -mindepth 1 -maxdepth 1 -type d -name '*-*' -print -quit)"
fi

[[ -n "$source_dir" && -f "$source_dir/bin/$PROGRAM" ]] || { echo "Controller source files were not found." >&2; exit 1; }
[[ -f "$source_dir/systemd/$SERVICE" ]] || { echo "Systemd unit was not found." >&2; exit 1; }
command -v pveversion >/dev/null || { echo "This installer must run on Proxmox VE." >&2; exit 1; }
pve_release="$(pveversion)"
if [[ "$pve_release" =~ ^pve-manager/([0-9]+)\. ]]; then
    pve_major="${BASH_REMATCH[1]}"
else
    pve_major=0
fi
if (( pve_major < 8 )); then
    echo "Proxmox VE 8 or newer is required; found: $pve_release" >&2
    exit 1
fi

echo "Installing linux-cpupower ..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y linux-cpupower python3

echo "Installing $PROGRAM ..."
install -D -m 0755 "$source_dir/bin/$PROGRAM" "/usr/sbin/$PROGRAM"
for module in Config DesiredState CpupowerBackend ClusterCapabilities RuntimeStateCollector EventObserver Controller; do
    install -D -m 0644 "$source_dir/lib/PVE/DC/PowerSave/$module.pm" "/usr/share/perl5/PVE/DC/PowerSave/$module.pm"
done
install -D -m 0644 "$source_dir/lib/PVE/API2/Cluster/DCPowerSave.pm" "/usr/share/perl5/PVE/API2/Cluster/DCPowerSave.pm"
install -D -m 0644 "$source_dir/lib/PVE/API2/Nodes/DCPowerSave.pm" "/usr/share/perl5/PVE/API2/Nodes/DCPowerSave.pm"
install -D -m 0644 "$source_dir/web/dc-powersave.js" "/usr/share/pve-manager/js/dc-powersave.js"
install -D -m 0755 "$source_dir/scripts/integrate-pve.py" "/usr/lib/pve-dc-powersave/integrate-pve.py"
install -D -m 0755 "$source_dir/scripts/uninstall.sh" "/usr/lib/pve-dc-powersave/uninstall.sh"
install -D -m 0644 "$source_dir/systemd/$SERVICE" "/etc/systemd/system/$SERVICE"
systemctl daemon-reload

if [[ ! -e /etc/pve/dc-powersave.cfg ]]; then
    cat > /etc/pve/dc-powersave.cfg <<'EOF'
# Proxmox Datacenter PowerSave — shared cluster configuration
# Review supported governors on every node before changing enabled to 1.
enabled: 0
active_governor: performance
idle_governor: powersave
migration_governor: performance
failsafe_governor: performance
reconciliation_interval: 30
event_poll_interval: 2
idle_candidate_delay: 5
boot_protection_period: 120
EOF
    echo "Created disabled shared configuration: /etc/pve/dc-powersave.cfg"
else
    echo "Keeping existing configuration: /etc/pve/dc-powersave.cfg"
fi

echo "Integrating the Datacenter UI and authenticated PVE API ..."
python3 /usr/lib/pve-dc-powersave/integrate-pve.py
# The integration helper only restarts the API daemons when it edits a PVE
# file. On a reinstall or upgrade the registrations already exist, so reload
# them here to load the newly installed API modules.
systemctl reload-or-restart pvedaemon pveproxy
pvesh get /cluster/power-management --output-format json >/dev/null
# enable --now does not restart a running service; an upgrade must replace
# the controller code that is already loaded in memory.
systemctl enable "$SERVICE"
systemctl restart "$SERVICE"
systemctl is-active --quiet "$SERVICE"
echo
echo "Installed $PROGRAM on this node. Existing shared policy settings were preserved."
echo "Open Datacenter -> Power Management, validate every node, then enable the policy."
echo "To remove it from this node later: /usr/lib/pve-dc-powersave/uninstall.sh --help"
