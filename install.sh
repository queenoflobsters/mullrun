#!/usr/bin/env bash
# =============================================================================
# install.sh - install mullrun, wgc and the required sudoers policy
# =============================================================================
set -Eeuo pipefail
IFS=$' \t\n'

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)
INSTALL_BIN="/usr/local/bin/mullrun"
WGC_BIN="/usr/local/bin/wgc"
SUDOERS_FILE="/etc/sudoers.d/mullrun-nopasswd"
WG_DIR="/etc/wireguard"
WG_CONFIG="$WG_DIR/mullvad.conf"
WGC_ENABLE="$WG_DIR/wgc_enable"
WGC_URL="https://raw.githubusercontent.com/colemar/wgc/main/wgc"
WGC_ENABLE_MARKER="# Managed by mullrun/mullrun install.sh - do not remove while wgc is in use."

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
Usage: sudo ./install.sh [--help]

Installs:
  - python3, wireguard-tools, iproute2/iproute, util-linux, curl, sudo,
    socat, and procps (using dnf or pacman)
  - /usr/local/bin/wgc from $WGC_URL (if not already installed)
  - /usr/local/bin/mullrun
  - $SUDOERS_FILE for the wheel group (wgc and ip only)

After installation, place a Mullvad WireGuard profile at:
  $WG_CONFIG   (mode 0600)

Then run: mullrun curl https://am.i.mullvad.net/connected
EOF
}

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    "")
        ;;
    *)
        die "Unknown argument: $1 (use --help)"
        ;;
esac

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    command -v sudo >/dev/null 2>&1 || die "Root privileges required and sudo is not installed."
    info "Elevating with sudo..."
    exec sudo -- "$SCRIPT_PATH" "$@"
fi

# ---------------------------------------------------------------------------
# Source validation and OS detection
# ---------------------------------------------------------------------------
[[ -f "$SCRIPT_DIR/bin/mullrun" ]] || die "Missing source file: $SCRIPT_DIR/bin/mullrun"
[[ -f "$SCRIPT_DIR/uninstall.sh" ]] || die "Missing source file: $SCRIPT_DIR/uninstall.sh"
[[ -f "$SCRIPT_DIR/README.md" ]] || die "Missing source file: $SCRIPT_DIR/README.md"

[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; unsupported distribution."
# shellcheck source=/dev/null
. /etc/os-release
OS_ID=${ID:-}
OS_LIKE=${ID_LIKE:-}
OS_NAME=${PRETTY_NAME:-${NAME:-unknown Linux}}

PACKAGE_MANAGER=""
PACKAGES=()
if [[ " $OS_ID $OS_LIKE " == *" fedora "* ]] || { command -v dnf >/dev/null 2>&1 && [[ $OS_ID == fedora ]]; }; then
    PACKAGE_MANAGER="dnf"
    PACKAGES=(
        python3 wireguard-tools iproute util-linux curl sudo
        socat procps-ng
    )
elif [[ " $OS_ID $OS_LIKE " == *" arch "* ]] || [[ $OS_ID == cachyos ]] || [[ $OS_LIKE == *arch* ]]; then
    PACKAGE_MANAGER="pacman"
    PACKAGES=(
        python wireguard-tools iproute2 util-linux curl sudo
        socat procps-ng
    )
else
    die "Unsupported distribution: $OS_NAME. This installer supports Fedora, Arch Linux and CachyOS."
fi

command -v "$PACKAGE_MANAGER" >/dev/null 2>&1 || die "Package manager '$PACKAGE_MANAGER' not found."

info "Detected $OS_NAME (using $PACKAGE_MANAGER)."
info "Installing prerequisites: ${PACKAGES[*]}"

case "$PACKAGE_MANAGER" in
    dnf)
        dnf -y --setopt=install_weak_deps=False install "${PACKAGES[@]}"
        ;;
    pacman)
        if ! pacman -S --needed --noconfirm "${PACKAGES[@]}"; then
            error "pacman failed. Refresh/upgrade the system database with 'sudo pacman -Syu' and re-run this installer."
            exit 1
        fi
        ;;
    *)
        die "Internal error: unknown package manager $PACKAGE_MANAGER"
        ;;
esac

for required in bash curl flock ip python3 sed stat sudo visudo; do
    command -v "$required" >/dev/null 2>&1 || die "Required command missing after package installation: $required"
done
python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' \
    || die "Python 3.8 or newer is required (found: $(python3 --version 2>&1))."

# ---------------------------------------------------------------------------
# Secure WireGuard directory and wgc approval file
# ---------------------------------------------------------------------------
if [[ -e "$WG_DIR" && ! -d "$WG_DIR" ]]; then
    die "$WG_DIR exists but is not a directory."
fi
[[ ! -L "$WG_DIR" ]] || die "Refusing symlinked WireGuard directory: $WG_DIR"
install -d -o root -g root -m 0700 "$WG_DIR"
# wgc refuses a group/world-writable configuration directory.
chmod go-w "$WG_DIR"

if [[ ! -f "$WGC_ENABLE" ]]; then
    printf '%s\n' "$WGC_ENABLE_MARKER" > "$WGC_ENABLE"
    chmod 0644 "$WGC_ENABLE"
    chown root:root "$WGC_ENABLE"
    info "Created wgc approval file: $WGC_ENABLE"
fi
[[ -f "$WGC_ENABLE" ]] || die "Cannot create $WGC_ENABLE."
chown root:root "$WGC_ENABLE" 2>/dev/null || true
chmod 0644 "$WGC_ENABLE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# wgc
# ---------------------------------------------------------------------------
if [[ -x "$WGC_BIN" ]]; then
    info "Using existing wgc: $WGC_BIN"
else
    info "Downloading wgc from the official upstream repository..."
    tmp_wgc=$(mktemp /tmp/wgc.install.XXXXXX)
    cleanup_wgc() { rm -f -- "$tmp_wgc"; }
    trap cleanup_wgc EXIT
    curl --fail --silent --show-error --location \
        --proto '=https' --tlsv1.2 --retry 2 --max-time 60 \
        --output "$tmp_wgc" "$WGC_URL"
    [[ -s "$tmp_wgc" ]] || die "Downloaded wgc is empty."
    [[ $(stat -c '%s' "$tmp_wgc") -gt 10000 ]] || die "Downloaded wgc is implausibly small."
    head -n 1 "$tmp_wgc" | grep -q 'bash' || die "Downloaded wgc does not look like a Bash script."
    bash -n "$tmp_wgc" || die "Downloaded wgc failed 'bash -n' syntax validation."
    grep -q 'WGC_CFGDIR' "$tmp_wgc" || die "Downloaded file does not look like the wgc implementation."
    install -o root -g root -m 0755 "$tmp_wgc" "$WGC_BIN"
    rm -f -- "$tmp_wgc"
    trap - EXIT
    info "Installed wgc: $WGC_BIN"
fi
[[ -f "$WGC_BIN" ]] || die "wgc is not a regular file: $WGC_BIN"
[[ -x "$WGC_BIN" ]] || die "wgc is not executable: $WGC_BIN"
[[ ! -L "$WGC_BIN" ]] || die "Refusing symlinked wgc: $WGC_BIN"
[[ $(stat -c '%u' "$WGC_BIN") -eq 0 ]] || die "wgc must be owned by root: $WGC_BIN"
if (( (8#$(stat -c '%a' "$WGC_BIN") & 022) != 0 )); then
    die "wgc must not be writable by group or others: $WGC_BIN"
fi
grep -q 'exec_in_namespace' "$WGC_BIN" || die "wgc does not provide the required 'exec' support."
"$WGC_BIN" req || warn "wgc dependency self-check reported problems; review its output above."

# ---------------------------------------------------------------------------
# mullrun
# ---------------------------------------------------------------------------
info "Installing $INSTALL_BIN..."
install -o root -g root -m 0755 "$SCRIPT_DIR/bin/mullrun" "$INSTALL_BIN"
"$INSTALL_BIN" --help >/dev/null || die "Installed mullrun failed to run '--help'."
if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$WGC_BIN" "$INSTALL_BIN" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Sudoers drop-in (validate before committing)
# ---------------------------------------------------------------------------
getent group wheel >/dev/null 2>&1 || die "The 'wheel' group does not exist; this installer requires it."
[[ -d /etc/sudoers.d ]] || die "/etc/sudoers.d does not exist; install sudo first."
if ! grep -Eq '^[[:space:]]*(@|#)includedir[[:space:]]+/etc/sudoers\.d/?([[:space:]]|$)' /etc/sudoers; then
    die "/etc/sudoers does not include /etc/sudoers.d; refusing to install an ignored policy."
fi

ip_primary=$(command -v ip) || die "ip command not found after package installation."
ip_real=$(readlink -f -- "$ip_primary")
declare -A seen_ip=()
ip_paths=()
for candidate in "$ip_primary" "$ip_real" /usr/bin/ip /sbin/ip /usr/sbin/ip /bin/ip; do
    [[ -n ${seen_ip[$candidate]:-} ]] && continue
    seen_ip[$candidate]=1
    [[ -x $candidate ]] && ip_paths+=("$candidate")
done
(( ${#ip_paths[@]} > 0 )) || die "No executable ip path found."

tmp_sudoers=$(mktemp /etc/sudoers.d/.mullrun-nopasswd.XXXXXX)
cleanup_sudoers() { rm -f -- "$tmp_sudoers"; }
trap cleanup_sudoers EXIT
chown root:root "$tmp_sudoers"
chmod 0440 "$tmp_sudoers"
{
    printf '%s\n' '# Managed by mullrun/mullrun install.sh.'
    printf '%s\n' '# Passwordless execution is restricted to the exact commands below.'
    printf '%%wheel ALL=(root) NOPASSWD: %s\n' "$WGC_BIN"
    for ip_path in "${ip_paths[@]}"; do
        printf '%%wheel ALL=(root) NOPASSWD: %s\n' "$ip_path"
    done
} > "$tmp_sudoers"

if ! visudo -cf "$tmp_sudoers" >/dev/null; then
    error "visudo rejected the generated sudoers policy. It was NOT installed."
    exit 1
fi
install -o root -g root -m 0440 "$tmp_sudoers" "$SUDOERS_FILE"
rm -f -- "$tmp_sudoers"
trap - EXIT
if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$SUDOERS_FILE" 2>/dev/null || true
fi
if ! visudo -cf "$SUDOERS_FILE" >/dev/null; then
    rm -f -- "$SUDOERS_FILE"
    die "Installed sudoers file failed validation and was removed."
fi
info "Installed and validated $SUDOERS_FILE"

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
printf '\n'
info "Installation complete."
printf '\n'

if [[ -f "$WG_CONFIG" ]]; then
    info "Found WireGuard profile: $WG_CONFIG"
    mode=$(stat -c '%a' "$WG_CONFIG")
    if (( (8#$mode & 077) != 0 )); then
        warn "Tightening permissions on $WG_CONFIG (was $mode)."
        chmod 0600 "$WG_CONFIG"
    fi
    if "$WGC_BIN" parse mullvad >/dev/null 2>&1; then
        info "Mullvad profile parses successfully."
    else
        warn "wgc could not parse mullvad.conf; run 'sudo $WGC_BIN parse mullvad' for details."
    fi
else
    warn "No Mullvad profile found at $WG_CONFIG."
    cat <<EOF

  Create a WireGuard profile:
    1. Sign in at https://mullvad.net/en/account/wireguard-config
    2. Generate a key and select a server.
    3. Download the .conf file.
    4. Install it privately:
         sudo install -d -o root -g root -m 0700 $WG_DIR
         sudo install -o root -g root -m 0600 ~/Downloads/mullvad-*.conf $WG_CONFIG
    5. Validate it:
         sudo $WGC_BIN parse mullvad
    6. Test the tunnel:
         $INSTALL_BIN curl https://am.i.mullvad.net/connected

EOF
fi

if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce 2>/dev/null || true) == "Enforcing" ]]; then
    warn "SELinux is enforcing. If wgc/ip is denied, inspect 'sudo ausearch -m avc -ts recent'."
    warn "Do not disable SELinux permanently; see README.md for safe diagnosis."
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    info "systemd-resolved is active. Review the DNS leak notes in README.md."
fi

current_user=${SUDO_USER:-}
if [[ -n $current_user ]]; then
    if id -nG "$current_user" 2>/dev/null | tr ' ' '\n' | grep -qx wheel; then
        info "User '$current_user' is in the wheel group; passwordless wgc/ip is enabled."
    else
        warn "User '$current_user' is NOT in the wheel group; add it with: sudo usermod -aG wheel $current_user"
    fi
fi

cat <<EOF

Quick start:
  $INSTALL_BIN --status
  $INSTALL_BIN qbittorrent
  $INSTALL_BIN firefox
  $INSTALL_BIN curl https://am.i.mullvad.net/connected

The namespace created by wgc is named wgc_<profile> (for example wgc_mullvad).
Uninstall with: sudo $SCRIPT_DIR/uninstall.sh
EOF
