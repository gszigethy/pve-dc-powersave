#!/usr/bin/env bash
# Remove Proxmox Datacenter PowerSave from one PVE node.
set -Eeuo pipefail

readonly SERVICE="pve-dc-powersave.service"
# TEST-ONLY: pytests/test_uninstall_sh.py sets this to a temporary directory that is prefixed
# to every absolute path below (and lets the script run without root). It is
# empty in real use; never set it on a node.
root="${PVE_DC_POWERSAVE_TEST_ROOT:-}"
readonly CONFIG="$root/etc/pve/dc-powersave.cfg"
readonly LIB_DIR="$root/usr/lib/pve-dc-powersave"
readonly PERL_DIR="$root/usr/share/perl5"
readonly PVE_MANAGER_DIR="$root/usr/share/pve-manager"
readonly RUN_DIR="$root/run/pve-dc-powersave"
readonly BACKUP_DIR="/var/lib/pve-dc-powersave/backups"
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

if (( EUID != 0 )) && [[ -z "$root" ]]; then
    echo "Run as root." >&2
    exit 1
fi
if [[ -n "$governor" && ! "$governor" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "--governor contains unsupported characters." >&2
    exit 2
fi

# --- Choose and vet the integration helper before changing anything. --------
# Helpers installed by v0.1.0 through v0.2.1-beta.1 ignore their arguments:
# running one with --remove (or even --help) re-runs the integration and exits
# 0. So the helper is never run to find out what it supports; its source is
# checked instead.
supports_remove() {
    grep -Eq "add_argument\(\s*['\"]--remove['\"]" "$1" 2>/dev/null
}

helper=""
script_path="${BASH_SOURCE[0]:-}"
if [[ -f "$script_path" ]]; then
    sibling="$(cd -- "$(dirname -- "$script_path")" && pwd -P)/integrate-pve.py"
    [[ -f "$sibling" ]] && helper="$sibling"
fi
[[ -n "$helper" ]] || helper="$LIB_DIR/integrate-pve.py"
if [[ ! -f "$helper" ]] || ! supports_remove "$helper"; then
    {
        echo "Cannot uninstall safely: no integration helper that supports --remove was found."
        echo "Checked: $helper"
        echo "Helpers installed by v0.2.1-beta.1 or older ignore --remove and would leave the"
        echo "PVE registrations in place; deleting the plugin files then breaks pvedaemon and"
        echo "pveproxy at their next restart."
        echo "Either run scripts/uninstall.sh from a complete source tree or release archive"
        echo "of this release or newer, which uses the helper next to it, or first rerun this"
        echo "release's installer on the node (it installs the current helper and uninstaller)"
        echo "and then run /usr/lib/pve-dc-powersave/uninstall.sh. Nothing was changed."
    } >&2
    exit 1
fi

echo "Stopping $SERVICE ..."
if systemctl list-unit-files "$SERVICE" >/dev/null 2>&1; then
    systemctl disable --now "$SERVICE" || true
fi
# The unit's RuntimeDirectory may be preserved across restarts, so remove it
# explicitly, but only a real directory (never follow a symlink).
if [[ -d "$RUN_DIR" && ! -L "$RUN_DIR" ]]; then
    rm -rf -- "$RUN_DIR"
fi

if [[ -n "$governor" ]]; then
    echo "Setting every CPU policy to $governor ..."
    cpupower -c all frequency-set -g "$governor" >/dev/null
fi

# Take the registrations out first, while the modules they load still exist,
# so pvedaemon and pveproxy reload cleanly.
echo "Removing the Datacenter UI and API registrations ..."
if ! python3 "$helper" --remove; then
    echo "The integration helper failed; the plugin files were NOT deleted." >&2
    echo "Fix the error above, then run this uninstaller again." >&2
    exit 1
fi

# Do not trust the helper: confirm that no registration is left before any
# module file is deleted. A remaining one makes pvedaemon/pveproxy fail to
# start once the module is gone.
perl_file() {
    local dir
    while IFS= read -r dir; do
        if [[ -f "$dir/$1" ]]; then
            printf '%s\n' "$dir/$1"
            return 0
        fi
    done < <(perl -e 'print join "\n", @INC' 2>/dev/null)
    return 1
}
remaining=()
check_file() { # file, fixed string that must be gone
    if [[ -z "$1" || ! -f "$1" ]]; then
        remaining+=("could not locate the file to check for '$2'")
    elif grep -qF -- "$2" "$1"; then
        remaining+=("$1 still contains '$2'")
    fi
}
check_file "$(perl_file PVE/API2/Cluster.pm || true)" "PVE::API2::Cluster::DCPowerSave"
check_file "$(perl_file PVE/API2/Nodes.pm || true)" "PVE::API2::Nodes::DCPowerSave"
check_file "$PVE_MANAGER_DIR/index.html.tpl" "dc-powersave.js"
if ((${#remaining[@]})); then
    {
        echo "The registrations are not fully removed, so the plugin files were NOT deleted:"
        printf '  - %s\n' "${remaining[@]}"
        echo "Remove them by hand: in Cluster.pm and Nodes.pm delete the 'use PVE::API2::...::DCPowerSave;'"
        echo "line and the block from '# BEGIN pve-dc-powersave' to '# END pve-dc-powersave'; in"
        echo "index.html.tpl delete the <script> tag for dc-powersave.js. Then run"
        echo "'systemctl reload-or-restart pvedaemon pveproxy' and this uninstaller again."
    } >&2
    exit 1
fi

echo "Removing installed files ..."
rm -f -- "$root/usr/sbin/pve-dc-powersave" \
    "$PERL_DIR/PVE/API2/Cluster/DCPowerSave.pm" \
    "$PERL_DIR/PVE/API2/Nodes/DCPowerSave.pm" \
    "$PVE_MANAGER_DIR/js/dc-powersave.js" \
    "$root/etc/systemd/system/$SERVICE"
rm -rf -- "$PERL_DIR/PVE/DC/PowerSave" "$LIB_DIR"
rmdir --ignore-fail-on-non-empty "$PERL_DIR/PVE/DC" 2>/dev/null || true
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
governors="$(cat "$root"/sys/devices/system/cpu/cpufreq/policy*/scaling_governor 2>/dev/null | sort | uniq -c | xargs)" || true
echo "Current governors (count name): ${governors:-unknown}"
echo "Backups of the edited PVE files were kept in $BACKUP_DIR (older versions left"
echo "*.dc-powersave.backup.* copies next to the PVE files). They are for inspection only:"
echo "never restore one after a PVE upgrade, it would downgrade PVE's API. Delete them"
echo "yourself when no longer needed."
echo "linux-cpupower was not removed. Refresh the browser to drop the Power Management page."
