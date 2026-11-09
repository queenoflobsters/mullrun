#!/usr/bin/env bash
# =============================================================================
# uninstall.sh - remove mullrun, its runtime state and its sudoers policy
# =============================================================================
set -Eeuo pipefail
IFS=$' \t\n'

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
INSTALL_BIN="/usr/local/bin/mullrun"
WGC_BIN="/usr/local/bin/wgc"
SUDOERS_FILE="/etc/sudoers.d/mullrun-nopasswd"
WG_ENABLE="/etc/wireguard/wgc_enable"
WG_ENABLE_MARKER="# Managed by mullrun install.sh"
VPN_RE='^[A-Za-z0-9_-]{1,16}$'

if [[ -t 1 && ${NO_COLOR:-} == "" && ${TERM:-} != "dumb" ]]; then
    C_RESET=$'\033[0m'
    C_BLUE=$'\033[1;34m'
    C_YELLOW=$'\033[1;33m'
    C_RED=$'\033[1;31m'
else
    C_RESET=""
    C_BLUE=""
    C_YELLOW=""
    C_RED=""
fi

info()  { printf '%s[mullrun]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn()  { printf '%s[mullrun]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
error() { printf '%s[mullrun]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()   { error "$*"; exit 1; }

usage() {
    cat <<EOF
Usage: sudo ./uninstall.sh [--yes] [--keep-wgc|--remove-wgc]

  --yes          Do not ask interactive questions (wgc is kept by default)
  --keep-wgc     Keep /usr/local/bin/wgc
  --remove-wgc   Remove /usr/local/bin/wgc without asking
  --help         Show this help

This stops namespaces tracked by mullrun, removes /usr/local/bin/mullrun,
removes $SUDOERS_FILE, and cleans /run/user/*/mullrun.
EOF
}

ASSUME_YES=0
WGC_ACTION="ask"
ORIGINAL_ARGS=("$@")
while (( $# > 0 )); do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --yes)
            ASSUME_YES=1
            ;;
        --keep-wgc)
            [[ $WGC_ACTION == remove ]] && die "--keep-wgc and --remove-wgc are mutually exclusive."
            WGC_ACTION="keep"
            ;;
        --remove-wgc)
            [[ $WGC_ACTION == keep ]] && die "--keep-wgc and --remove-wgc are mutually exclusive."
            WGC_ACTION="remove"
            ;;
        *)
            die "Unknown argument: $1 (use --help)"
            ;;
    esac
    shift
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Root privileges required and sudo is not installed."
    info "Elevating with sudo..."
    exec sudo -- "$SCRIPT_PATH" "${ORIGINAL_ARGS[@]}"
fi

# ---------------------------------------------------------------------------
# Stop every namespace tracked by mullrun
# ---------------------------------------------------------------------------
shopt -s nullglob
stopped_any=0
declare -A tracked_vpns=()

stop_namespace() {
    local vpn=$1
    local pid
    local -a ns_pids=()
    [[ $vpn =~ $VPN_RE ]] || return 0
    [[ -e "/run/netns/wgc_$vpn" || -e "/var/run/netns/wgc_$vpn" ]] || return 0
    info "Stopping VPN namespace wgc_$vpn..."
    if [[ -x $WGC_BIN ]] && "$WGC_BIN" kill "$vpn"; then
        stopped_any=1
        return 0
    fi
    warn "wgc could not stop '$vpn'; removing the namespace directly."
    mapfile -t ns_pids < <(ip netns pids "wgc_$vpn" 2>/dev/null || true)
    for pid in "${ns_pids[@]}"; do
        [[ $pid =~ ^[0-9]+$ ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.5
    for pid in "${ns_pids[@]}"; do
        [[ $pid =~ ^[0-9]+$ ]] || continue
        kill -KILL "$pid" 2>/dev/null || true
    done
    ip netns del "wgc_$vpn" 2>/dev/null || true
    stopped_any=1
}

# Find supervisors even if their user's runtime state directory disappeared.
for proc_dir in /proc/[0-9]*; do
    [[ -d $proc_dir ]] || continue
    supervisor_pid=${proc_dir##*/}
    [[ $supervisor_pid =~ ^[0-9]+$ ]] || continue
    [[ -r "$proc_dir/cmdline" ]] || continue
    cmdline=$(tr '\0' ' ' < "$proc_dir/cmdline" 2>/dev/null || true)
    [[ $cmdline == *"--internal-supervisor"* && $cmdline == *"/mullrun"* ]] || continue
    read -r -a supervisor_args <<< "$cmdline"
    vpn=""
    for ((i = 0; i < ${#supervisor_args[@]} - 1; i++)); do
        if [[ ${supervisor_args[i]} == "--internal-supervisor" ]]; then
            vpn=${supervisor_args[i + 1]}
            break
        fi
    done
    [[ $vpn =~ $VPN_RE ]] || continue
    tracked_vpns[$vpn]=1
    info "Stopping mullrun supervisor PID $supervisor_pid for VPN '$vpn'..."
    kill -TERM "$supervisor_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL "$supervisor_pid" 2>/dev/null || true
done

for run_root in /run/user/*/mullrun; do
    [[ -d $run_root ]] || continue
    state_root="$run_root/state"
    [[ -d $state_root ]] || continue
    for state_dir in "$state_root"/*; do
        [[ -d $state_dir && ! -L $state_dir ]] || continue
        vpn=${state_dir##*/}
        if [[ ! $vpn =~ $VPN_RE ]]; then
            warn "Ignoring unsafe runtime state directory: $state_dir"
            continue
        fi
        tracked_vpns[$vpn]=1

        pid_file="$state_dir/supervisor.pid"
        if [[ -f $pid_file ]]; then
            supervisor_pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$pid_file" | head -n 1)
            if [[ $supervisor_pid =~ ^[0-9]+$ ]] && [[ -r /proc/$supervisor_pid/cmdline ]]; then
                cmdline=$(tr '\0' ' ' < "/proc/$supervisor_pid/cmdline" 2>/dev/null || true)
                if [[ $cmdline == *"--internal-supervisor"* && $cmdline == *"$vpn"* ]]; then
                    info "Stopping supervisor PID $supervisor_pid for VPN '$vpn'..."
                    kill -TERM "$supervisor_pid" 2>/dev/null || true
                    sleep 0.2
                    kill -KILL "$supervisor_pid" 2>/dev/null || true
                fi
            fi
        fi
    done
done

# Also catch a namespace whose user runtime directory vanished after logout
# but whose mullrun log still identifies it.
for log_file in /run/user/*/mullrun/logs/*.log; do
    [[ -f $log_file ]] || continue
    vpn=${log_file##*/}
    vpn=${vpn%.log}
    [[ $vpn =~ $VPN_RE ]] || continue
    tracked_vpns[$vpn]=1
done

for vpn in "${!tracked_vpns[@]}"; do
    stop_namespace "$vpn"
done

for run_root in /run/user/*/mullrun; do
    [[ -e $run_root ]] || continue
    rm -rf -- "$run_root"
done
(( stopped_any == 0 )) && info "No active mullrun namespace was found."

# ---------------------------------------------------------------------------
# Remove installed files
# ---------------------------------------------------------------------------
if [[ -e $INSTALL_BIN ]]; then
    info "Removing $INSTALL_BIN..."
    rm -f -- "$INSTALL_BIN"
fi

if [[ -e $SUDOERS_FILE ]]; then
    info "Removing $SUDOERS_FILE..."
    rm -f -- "$SUDOERS_FILE"
fi

if [[ -f $WG_ENABLE ]] && grep -qF "$WG_ENABLE_MARKER" "$WG_ENABLE"; then
    info "Removing installer-managed wgc approval file: $WG_ENABLE"
    rm -f -- "$WG_ENABLE"
fi

# ---------------------------------------------------------------------------
# Optional wgc removal
# ---------------------------------------------------------------------------
if [[ -x $WGC_BIN ]]; then
    other_namespaces=$(ip netns list 2>/dev/null | awk '$1 ~ /^wgc_/ {print $1}' || true)
    if [[ -n $other_namespaces ]]; then
        warn "These wgc namespaces are still present:"
        printf '  %s\n' "$other_namespaces" >&2
        warn "Removing the wgc script does not remove those namespaces."
    fi

    remove_wgc=0
    case "$WGC_ACTION" in
        remove)
            remove_wgc=1
            ;;
        keep)
            remove_wgc=0
            ;;
        ask)
            if (( ASSUME_YES == 1 )) || [[ ! -t 0 ]]; then
                remove_wgc=0
            else
                printf '%s' "Remove $WGC_BIN too? [y/N] "
                answer=""
                read -r answer || true
                [[ $answer =~ ^[Yy]$ ]] && remove_wgc=1
            fi
            ;;
    esac

    if (( remove_wgc == 1 )); then
        if head -n 1 "$WGC_BIN" 2>/dev/null | grep -q 'bash' \
            && grep -q 'Manage multiple WireGuard VPNs' "$WGC_BIN" 2>/dev/null; then
            info "Removing $WGC_BIN..."
            rm -f -- "$WGC_BIN"
        else
            warn "$WGC_BIN does not look like the upstream wgc script; leaving it in place."
        fi
    else
        info "Keeping $WGC_BIN (use --remove-wgc to remove it)."
        if [[ ! -f $WG_ENABLE ]]; then
            warn "The installer-managed wgc approval file was removed. Recreate"
            warn "/etc/wireguard/wgc_enable before using wgc directly."
        fi
    fi
fi

info "Uninstallation complete."
printf '\n'
info "WireGuard profiles in /etc/wireguard and installed packages were left untouched."
info "Remove those manually if they are no longer needed."
