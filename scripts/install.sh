#!/usr/bin/env bash
# Install Proxmox Datacenter PowerSave on one PVE node.
#
# Order of work: resolve the source, stage every file in a private temporary
# directory, compile-check the staged Perl against this node's PVE libraries,
# install any missing packages, back up the installed files, replace them,
# register the API and UI, and only then (re)start the controller. A failure
# before the replacement changes nothing; a failure after it restores the
# previous files.
set -Eeuo pipefail
umask 022

readonly PROGRAM="pve-dc-powersave"
readonly SERVICE="pve-dc-powersave.service"
# Test-only: when PVE_DC_POWERSAVE_ROOT is set, every installed path and
# /etc/pve are resolved below it and the root check is skipped, so
# pytests/test_install.py can run this script in a sandbox. Never set it on a
# node. Commands (apt-get, systemctl, ...) are still looked up on PATH.
readonly ROOT="${PVE_DC_POWERSAVE_ROOT:-}"
readonly CONFIG="$ROOT/etc/pve/dc-powersave.cfg"
repo="gszigethy/pve-dc-powersave"
repo_specified=0
ref="main"
ref_specified=0
source_dir=""

usage() {
    cat <<'EOF'
Usage:
  install.sh [--from-dir DIRECTORY]
  install.sh [--repo OWNER/REPOSITORY] [--ref BRANCH_OR_TAG]

Installs on the current node only. Run it on every PVE cluster node.
The controller is installed disabled; review /etc/pve/dc-powersave.cfg before
enabling it. The default repository is gszigethy/pve-dc-powersave.

Source selection:
  (no option)    Install the checkout this script is part of. When it is run
                 from a pipe (curl ... | bash) or outside a checkout, download
                 the main branch.
  --from-dir     Install this source tree. It must contain the files the
                 installer needs, and nothing is downloaded. It cannot be
                 combined with --repo or --ref.
  --ref, --repo  Always download that ref (default main) of that repository
                 (default gszigethy/pve-dc-powersave), even when this script
                 sits inside a checkout.
EOF
}

while (($#)); do
    case "$1" in
        --repo) repo="${2:?--repo requires OWNER/REPOSITORY}"; repo_specified=1; shift 2 ;;
        --ref) ref="${2:?--ref requires a branch, tag, or commit}"; ref_specified=1; shift 2 ;;
        --from-dir) source_dir="${2:?--from-dir requires a directory}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -n "$source_dir" ]] && (( repo_specified || ref_specified )); then
    echo "--from-dir installs a local source tree and cannot be combined with --repo or --ref." >&2
    usage >&2
    exit 2
fi
if [[ -z "$ROOT" ]] && (( EUID != 0 )); then
    echo "Run as root (for example: sudo bash install.sh ...)." >&2
    exit 1
fi
if [[ ! "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "--repo must look like OWNER/REPOSITORY." >&2
    exit 2
fi
if [[ ! "$ref" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "--ref contains unsupported characters." >&2
    exit 2
fi

# Everything the installer places on the node, relative to the root. The
# module directory is replaced as a whole so that a module removed in a newer
# version does not linger.
readonly -a TARGETS=(
    "usr/share/perl5/PVE/DC/PowerSave"
    "usr/share/perl5/PVE/API2/Cluster/DCPowerSave.pm"
    "usr/share/perl5/PVE/API2/Nodes/DCPowerSave.pm"
    "usr/share/pve-manager/js/dc-powersave.js"
    "usr/lib/pve-dc-powersave/integrate-pve.py"
    "usr/lib/pve-dc-powersave/uninstall.sh"
    "usr/sbin/$PROGRAM"
    "etc/systemd/system/$SERVICE"
)

workdir=""
stage=""
backup=""
rollback_armed=0
placed=()
fresh_install=0
api_touched=0
current_step="starting"

rollback() {
    set +e
    local i rel dest
    echo "Restoring the previous installation ..." >&2
    if (( api_touched && fresh_install )); then
        # The registrations may already exist; take them out while the
        # modules they load are still there. If that fails, keep the new
        # (compile-checked) files so PVE can still load them.
        if ! python3 "$ROOT/usr/lib/pve-dc-powersave/integrate-pve.py" --remove >&2; then
            echo "ERROR: could not remove the PVE registrations; leaving the new files in place." >&2
            echo "Run /usr/lib/pve-dc-powersave/uninstall.sh to remove them, or fix the problem and rerun the installer." >&2
            return 1
        fi
    fi
    for ((i = ${#placed[@]} - 1; i >= 0; i--)); do
        rel="${placed[i]}"
        dest="$ROOT/$rel"
        rm -rf -- "$dest"
        if [[ -e "$backup/$rel" || -L "$backup/$rel" ]]; then
            cp -a -- "$backup/$rel" "$dest" || echo "ERROR: could not restore $dest" >&2
        fi
    done
    if (( fresh_install )); then
        rmdir --ignore-fail-on-non-empty -- "$ROOT/usr/share/perl5/PVE/DC" "$ROOT/usr/lib/pve-dc-powersave" 2>/dev/null
    fi
    systemctl daemon-reload >&2
    if (( api_touched )); then
        systemctl reload-or-restart pvedaemon pveproxy >&2 \
            || echo "WARNING: could not reload pvedaemon and pveproxy; run: systemctl restart pvedaemon pveproxy" >&2
    fi
    if (( fresh_install )); then
        echo "The failed installation was removed; this node is as it was before." >&2
    else
        echo "The previous version was restored; this node is as it was before." >&2
    fi
}

on_exit() {
    local rc=$?
    trap - EXIT
    if (( rc != 0 && rollback_armed )); then
        rollback_armed=0
        echo "ERROR: installation failed while ${current_step} (exit status $rc)." >&2
        rollback
    fi
    [[ -z "$workdir" ]] || rm -rf -- "$workdir"
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

die() { echo "ERROR: $*" >&2; exit 1; }

# Print the files a source tree is missing; succeed only when it is complete.
check_source() {
    local dir="$1" file missing=0
    for file in "bin/$PROGRAM" "systemd/$SERVICE" scripts/integrate-pve.py scripts/uninstall.sh \
        web/dc-powersave.js lib/PVE/API2/Cluster/DCPowerSave.pm lib/PVE/API2/Nodes/DCPowerSave.pm; do
        [[ -f "$dir/$file" ]] || { echo "Missing in $dir: $file" >&2; missing=1; }
    done
    compgen -G "$dir/lib/PVE/DC/PowerSave/*.pm" >/dev/null \
        || { echo "Missing in $dir: lib/PVE/DC/PowerSave/*.pm" >&2; missing=1; }
    return "$missing"
}

make_workdir() {
    [[ -n "$workdir" ]] || workdir="$(mktemp -d -t pve-dc-powersave.XXXXXX)"
}

download_source() {
    command -v curl >/dev/null || die "curl is required to download the source."
    command -v tar >/dev/null || die "tar is required to download the source."
    make_workdir
    mkdir -p -- "$workdir/download"
    echo "Downloading $repo at $ref ..."
    curl --fail --location --proto '=https' --tlsv1.2 \
        "https://github.com/$repo/archive/$ref.tar.gz" -o "$workdir/source.tar.gz"
    tar -xzf "$workdir/source.tar.gz" -C "$workdir/download"
    source_dir="$(find "$workdir/download" -mindepth 1 -maxdepth 1 -type d -name '*-*' -print -quit)"
    [[ -n "$source_dir" ]] || die "The downloaded archive did not contain a source tree."
}

if [[ -n "$source_dir" ]]; then
    # Explicit local source: never fall back to a download.
    [[ -d "$source_dir" ]] || die "--from-dir: $source_dir is not a directory."
    source_dir="$(cd -- "$source_dir" && pwd -P)"
    check_source "$source_dir" || die "--from-dir: $source_dir is not a complete source tree."
elif (( repo_specified || ref_specified )); then
    download_source
else
    # Use the checkout this script belongs to only when it was run from a
    # file. Under "curl ... | bash" BASH_SOURCE is empty, and dirname would
    # resolve to the parent of the current directory, which could install an
    # unrelated or stale tree as root instead of downloading the main branch.
    if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
        source_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
    fi
    if [[ -z "$source_dir" || ! -f "$source_dir/bin/$PROGRAM" ]]; then
        download_source
    fi
fi
check_source "$source_dir" || die "The source tree $source_dir is incomplete."

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

# Stage every file, with its final mode, in a root-only directory.
current_step="staging the files"
make_workdir
stage="$workdir/stage"
backup="$workdir/backup"
mkdir -p -- "$stage" "$backup"
stage_file() { install -D -m "$1" -- "$2" "$stage/$3"; }
install -d -m 0755 -- "$stage/usr/share/perl5/PVE/DC/PowerSave"
for module in "$source_dir"/lib/PVE/DC/PowerSave/*.pm; do
    stage_file 0644 "$module" "usr/share/perl5/PVE/DC/PowerSave/${module##*/}"
done
stage_file 0644 "$source_dir/lib/PVE/API2/Cluster/DCPowerSave.pm" usr/share/perl5/PVE/API2/Cluster/DCPowerSave.pm
stage_file 0644 "$source_dir/lib/PVE/API2/Nodes/DCPowerSave.pm" usr/share/perl5/PVE/API2/Nodes/DCPowerSave.pm
stage_file 0644 "$source_dir/web/dc-powersave.js" usr/share/pve-manager/js/dc-powersave.js
stage_file 0755 "$source_dir/scripts/integrate-pve.py" usr/lib/pve-dc-powersave/integrate-pve.py
stage_file 0755 "$source_dir/scripts/uninstall.sh" usr/lib/pve-dc-powersave/uninstall.sh
stage_file 0755 "$source_dir/bin/$PROGRAM" "usr/sbin/$PROGRAM"
stage_file 0644 "$source_dir/systemd/$SERVICE" "etc/systemd/system/$SERVICE"

# Compile-check the staged Perl against this node's own PVE libraries, with
# the staged modules ahead of any installed ones, before any installed file is
# touched. pvedaemon and pveproxy load these modules at their next restart.
current_step="compile-checking the staged Perl"
echo "Compile-checking the plugin against this node's Proxmox libraries ..."
compile_failed=0
while IFS= read -r -d '' file; do
    if ! output="$(perl -I"$stage/usr/share/perl5" -c "$file" 2>&1)"; then
        echo "$output" >&2
        compile_failed=1
    fi
done < <(find "$stage" -type f \( -name '*.pm' -o -name "$PROGRAM" \) -print0 | sort -z)
if (( compile_failed )); then
    die "A staged Perl file does not compile on this node. Nothing was changed."
fi

# Packages: only what is missing, so an unreachable repository (for example
# the enterprise repository without a subscription) cannot stop an install
# that needs nothing from it.
current_step="installing packages"
missing_packages=()
for package in linux-cpupower python3; do
    # shellcheck disable=SC2016  # ${db:Status-Status} is a dpkg-query field, not shell
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null)" == installed ]] \
        || missing_packages+=("$package")
done
if ((${#missing_packages[@]})); then
    echo "Installing ${missing_packages[*]} ..."
    apt-get update || echo "WARNING: apt-get update failed; trying the install with the existing package lists." >&2
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}" \
        || die "Could not install ${missing_packages[*]}. Nothing was changed."
fi

# Back up whatever is installed, then replace it.
current_step="backing up the installed files"
for rel in "${TARGETS[@]}"; do
    if [[ -e "$ROOT/$rel" || -L "$ROOT/$rel" ]]; then
        mkdir -p -- "$backup/$(dirname -- "$rel")"
        cp -a -- "$ROOT/$rel" "$backup/$rel" || die "Could not back up $ROOT/$rel. Nothing was changed."
    fi
done
if [[ ! -e "$backup/usr/share/perl5/PVE/API2/Cluster/DCPowerSave.pm" \
    && ! -e "$backup/usr/share/perl5/PVE/API2/Nodes/DCPowerSave.pm" ]]; then
    fresh_install=1
fi

echo "Installing $PROGRAM ..."
rollback_armed=1
current_step="installing the files"
for rel in "${TARGETS[@]}"; do
    dest="$ROOT/$rel"
    placed+=("$rel")
    rm -rf -- "${dest:?}"
    mkdir -p -- "$(dirname -- "$dest")"
    cp -a -- "$stage/$rel" "$dest"
done
current_step="reloading systemd"
systemctl daemon-reload

# The default policy is created only when it is missing, and a failure here is
# not an installation failure: the controller treats a missing file as
# disabled. Write a temporary file and rename it so that no node ever reads a
# half-written or empty file.
default_config() {
    cat <<'EOF'
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
}
write_default_config() {
    local tmp="$CONFIG.tmp.$$" rc=0
    # mv -n never replaces a file another node created in the meantime.
    { default_config > "$tmp" && mv -n -- "$tmp" "$CONFIG"; } 2>/dev/null || rc=$?
    rm -f -- "$tmp" 2>/dev/null || true
    return "$rc"
}
if [[ -e "$CONFIG" ]]; then
    echo "Keeping existing configuration: /etc/pve/dc-powersave.cfg"
elif write_default_config || [[ -e "$CONFIG" ]]; then
    echo "Created disabled shared configuration: /etc/pve/dc-powersave.cfg"
else
    echo "WARNING: could not create /etc/pve/dc-powersave.cfg (is this node quorate?)." >&2
    echo "The controller treats a missing file as disabled, so this is safe. Create it later" >&2
    echo "by saving the policy in Datacenter -> Power Management, or by rerunning this" >&2
    echo "installer on a node with quorum." >&2
fi

echo "Integrating the Datacenter UI and authenticated PVE API ..."
current_step="integrating with the PVE API and UI"
api_touched=1
python3 "$ROOT/usr/lib/pve-dc-powersave/integrate-pve.py"
# The integration helper only restarts the API daemons when it edits a PVE
# file. On a reinstall or upgrade the registrations already exist, so reload
# them here to load the newly installed API modules.
current_step="reloading pvedaemon and pveproxy"
systemctl reload-or-restart pvedaemon pveproxy
current_step="checking the API"
pvesh get /cluster/power-management --output-format json >/dev/null

# The plugin files are in place and the API works. From here a failure does
# not undo them: only our own service is affected, and the files are good.
rollback_armed=0
current_step="starting $SERVICE"
# enable --now does not restart a running service; an upgrade must replace
# the controller code that is already loaded in memory.
if ! { systemctl enable "$SERVICE" && systemctl restart "$SERVICE" && systemctl is-active --quiet "$SERVICE"; }; then
    echo "ERROR: the plugin and its API integration are installed, but $SERVICE did not start." >&2
    echo "The installed files were kept. See: systemctl status $SERVICE; journalctl -u $PROGRAM" >&2
    echo "Fix the cause and rerun the installer, or run /usr/lib/pve-dc-powersave/uninstall.sh --help." >&2
    exit 1
fi
echo
echo "Installed $PROGRAM on this node. Existing shared policy settings were preserved."
echo "Open Datacenter -> Power Management, validate every node, then enable the policy."
echo "To remove it from this node later: /usr/lib/pve-dc-powersave/uninstall.sh --help"
