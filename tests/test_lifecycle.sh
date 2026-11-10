#!/usr/bin/env bash
# shellcheck disable=SC2317  # dynamically dispatched test functions
# =============================================================================
# test_lifecycle.sh - hermetic lifecycle tests for bin/mullrun
#
# No root, real namespace, network access, or real wgc/ip/socat is required.
# Fake wgc, ip, and socat binaries live in a private temporary directory and
# model the namespace, refcount, and bridge contract used by the launcher.
# =============================================================================
set -Eeuo pipefail
IFS=$' \t\n'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
VPN_RUN="$ROOT_DIR/bin/mullrun"
TEST_FILE="$SCRIPT_DIR/test_lifecycle.sh"
GRACE=1

if [[ -t 1 && ${NO_COLOR:-} == "" && ${TERM:-} != "dumb" ]]; then
    C_RESET=$'\033[0m'
    C_GREEN=$'\033[1;32m'
    C_RED=$'\033[1;31m'
    C_YELLOW=$'\033[1;33m'
    C_BLUE=$'\033[1;34m'
else
    C_RESET=""
    C_GREEN=""
    C_RED=""
    C_YELLOW=""
    C_BLUE=""
fi

PASS=0
FAIL=0
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/mullrun-tests.XXXXXX")
chmod 700 "$SANDBOX"
MOCKBIN="$SANDBOX/mockbin"
APPBIN="$SANDBOX/appbin"
mkdir -p "$MOCKBIN" "$APPBIN"

info() { printf '%s==%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
pass() { PASS=$((PASS + 1)); printf '%sok%s - %s\n' "$C_GREEN" "$C_RESET" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '%snot ok%s - %s\n' "$C_RED" "$C_RESET" "$*"; }
skip() {
    printf '%s# skip%s - %s\n' "$C_YELLOW" "$C_RESET" "$*"
    printf 'skip\n' >> "$SANDBOX/skips"
}

assert_contains() {
    local file=$1 text=$2
    if ! grep -Fq -- "$text" "$file"; then
        printf '# expected %q in %s\n' "$text" "$file" >&2
        tail -n 40 "$file" >&2 || true
        return 1
    fi
}

assert_not_contains() {
    local file=$1 text=$2
    if grep -Fq -- "$text" "$file"; then
        printf '# did not expect %q in %s\n' "$text" "$file" >&2
        return 1
    fi
}

assert_file_mode() {
    local file=$1 mode=$2 actual
    actual=$(stat -c '%a' "$file")
    if [[ $actual != "$mode" ]]; then
        printf '# expected mode %s on %s, got %s\n' "$mode" "$file" "$actual" >&2
        return 1
    fi
}

assert_equal() {
    local actual=$1 expected=$2 what=${3:-value}
    if [[ $actual != "$expected" ]]; then
        printf '# %s: expected %q, got %q\n' "$what" "$expected" "$actual" >&2
        return 1
    fi
}

wait_for() {
    local timeout=$1
    shift
    local end=$((SECONDS + timeout))
    while (( SECONDS < end )); do
        if "$@"; then
            return 0
        fi
        sleep 0.1
    done
    return 1
}

ns_dir() { printf '%s/ns/wgc_%s' "$FAKE_STATE" "$1"; }
count_calls() {
    local count
    count=$(grep -c -- "$1" "$FAKE_STATE/calls.log" 2>/dev/null || true)
    printf '%s\n' "${count:-0}"
}

free_port() {
    python3 - <<'PYFREEPORT'
import socket
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PYFREEPORT
}

socat_lines() {
    local count
    count=$(grep -c -- '' "$FAKE_STATE/socat.log" 2>/dev/null || true)
    printf '%s\n' "${count:-0}"
}

bridge_pid() {
    local file=$1 key=$2 value
    value=$(grep -o "\"$key\"[[:space:]]*:[[:space:]]*[0-9]*" "$file" 2>/dev/null | head -n 1 | grep -o '[0-9]*$' || true)
    printf '%s\n' "$value"
}

new_case() {
    CASE="$SANDBOX/case-$1"
    rm -rf -- "$CASE"
    mkdir -p "$CASE"/{run,home,xdg,fake/ns,config/mullrun,etc/mullrun}
    chmod 700 "$CASE" "$CASE/run" "$CASE/xdg" "$CASE/home"
    export CASE
    export FAKE_STATE="$CASE/fake"
    export VPN_RUN_RUNTIME_DIR="$CASE/run"
    export HOME="$CASE/home"
    export XDG_RUNTIME_DIR="$CASE/xdg"
    export XDG_CONFIG_HOME="$CASE/config"
    export VPN_RUN_BRIDGE_CONFIG_USER="$CASE/config/mullrun/bridges.conf"
    export VPN_RUN_BRIDGE_CONFIG_SYSTEM="$CASE/etc/mullrun/bridges.conf"
    export FAKE_NUP_DELAY=0
    unset VPN_RUN_GRACE_PERIOD VPN_RUN_DEFAULT_VPN VPN_RUN_SOCAT_FAIL || true
}

# ---------------------------------------------------------------------------
# Fake wgc and ip
# ---------------------------------------------------------------------------
cat > "$MOCKBIN/ip" <<'FAKE_IP'
#!/usr/bin/env bash
set -euo pipefail
FAKE_STATE=${FAKE_STATE:?}
shopt -s nullglob

namespace_pids() {
    local ns=$1 dir="$FAKE_STATE/ns/$ns" pid
    [ -d "$dir" ] || return 1
    if [ -f "$dir/pids" ]; then
        while IFS= read -r pid; do
            [ -n "$pid" ] || continue
            if kill -0 "$pid" 2>/dev/null; then
                printf '%s\n' "$pid"
            fi
        done < <(sort -u "$dir/pids")
    fi
    return 0
}

case "${1:-} ${2:-}" in
    'netns list')
        for dir in "$FAKE_STATE"/ns/wgc_*; do
            [ -d "$dir" ] && basename "$dir"
        done
        ;;
    'netns pids')
        ns=${3:?missing namespace}
        namespace_pids "$ns"
        ;;
    'netns del')
        rm -rf -- "$FAKE_STATE/ns/${3:?missing namespace}"
        ;;
    *)
        printf 'fake ip: unsupported command: %s\n' "$*" >&2
        exit 2
        ;;
esac
FAKE_IP

cat > "$MOCKBIN/wgc" <<'FAKE_WGC'
#!/usr/bin/env bash
set -euo pipefail
FAKE_STATE=${FAKE_STATE:?}
cmd=${1:-}
vpn=${2:-}
ns="wgc_$vpn"
dir="$FAKE_STATE/ns/$ns"
mkdir -p "$FAKE_STATE/ns"
printf '%s\n' "$*" >> "$FAKE_STATE/calls.log"

live_pids() {
    [ -f "$dir/pids" ] || return 0
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        if kill -0 "$pid" 2>/dev/null; then
            printf '%s\n' "$pid"
        fi
    done < <(sort -u "$dir/pids")
    return 0
}

case "$cmd" in
    nup)
        sleep "${FAKE_NUP_DELAY:-0}"
        mkdir -p "$dir"
        : > "$dir/pids"
        printf 'up\n' > "$dir/state"
        printf 'nup\n' >> "$FAKE_STATE/nup.log"
        ;;
    exec)
        shift 2
        [ -d "$dir" ] || { printf 'VPN %s is not connected\n' "$vpn" >&2; exit 1; }
        printf '%s\n' "$$" >> "$dir/pids"
        exec "$@"
        ;;
    state)
        [ -d "$dir" ] || { printf 'VPN %s is DISCONNECTED\n' "$vpn" >&2; exit 1; }
        printf 'VPN %s is CONNECTED in namespace %s\n' "$vpn" "$ns"
        printf 'endpoint 203.0.113.7:51820\n'
        printf 'latest handshake: 12 seconds ago\n'
        ;;
    down)
        if [ -d "$dir" ]; then
            pids=$(live_pids)
            if [ -n "$pids" ]; then
                printf 'Processes running in namespace %s\n' "$ns" >&2
                exit 1
            fi
            rm -rf -- "$dir"
            printf 'down\n' >> "$FAKE_STATE/down.log"
        fi
        ;;
    kill)
        if [ -d "$dir" ]; then
            pids=$(live_pids)
            for pid in $pids; do
                kill -TERM "$pid" 2>/dev/null || true
            done
            sleep 0.2
            for pid in $pids; do
                kill -KILL "$pid" 2>/dev/null || true
            done
            rm -rf -- "$dir"
            printf 'kill\n' >> "$FAKE_STATE/down.log"
        fi
        ;;
    req)
        printf 'fake wgc dependencies look fine\n'
        ;;
    *)
        printf 'fake wgc: unsupported command: %s\n' "$*" >&2
        exit 2
        ;;
esac
FAKE_WGC

cat > "$MOCKBIN/socat" <<'FAKE_SOCAT'
#!/usr/bin/env python3
import os
import signal
import socket
import sys
import time

state = os.environ.get("FAKE_STATE")
if not state:
    print("fake socat: FAKE_STATE is not set", file=sys.stderr)
    raise SystemExit(2)
args = sys.argv[1:]
with open(os.path.join(state, "socat.log"), "a", encoding="utf-8") as fh:
    fh.write("%d %s\n" % (os.getpid(), " ".join(args)))

fail_match = os.environ.get("FAKE_SOCAT_FAIL", "")
if fail_match and fail_match in " ".join(args):
    print("fake socat: forced failure for %s" % fail_match, file=sys.stderr)
    raise SystemExit(3)

os.umask(0o077)
listeners = []
sockets = []


def cleanup():
    for sock in listeners:
        try:
            sock.close()
        except OSError:
            pass
    for path in sockets:
        try:
            os.unlink(path)
        except OSError:
            pass


def stop(signum, _frame):
    cleanup()
    raise SystemExit(128 + signum)


for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(signum, stop)

for arg in args:
    if arg.startswith("UNIX-LISTEN:"):
        path = arg.split(":", 1)[1].split(",", 1)[0]
        try:
            if os.path.lexists(path):
                os.unlink(path)
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.bind(path)
            os.chmod(path, 0o600)
            sock.listen(16)
        except OSError as exc:
            print("fake socat: unix bind %s failed: %s" % (path, exc), file=sys.stderr)
            cleanup()
            raise SystemExit(1)
        listeners.append(sock)
        sockets.append(path)
    elif arg.startswith("TCP4-LISTEN:") or arg.startswith("TCP6-LISTEN:"):
        family = socket.AF_INET6 if arg.startswith("TCP6-LISTEN:") else socket.AF_INET
        body = arg.split(":", 1)[1]
        port = int(body.split(",", 1)[0])
        bind = "::1" if family == socket.AF_INET6 else "127.0.0.1"
        for option in body.split(",")[1:]:
            if option.startswith("bind="):
                bind = option.split("=", 1)[1].strip("[]")
        try:
            sock = socket.socket(family, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            sock.bind((bind, port))
            sock.listen(16)
        except OSError as exc:
            print("fake socat: tcp bind %s:%d failed: %s" % (bind, port, exc), file=sys.stderr)
            cleanup()
            raise SystemExit(1)
        listeners.append(sock)

if not listeners:
    print("fake socat: no listener address found in %s" % " ".join(args), file=sys.stderr)
    raise SystemExit(2)

while True:
    time.sleep(1)
FAKE_SOCAT

cat > "$APPBIN/envdump" <<'ENVDUMP'
#!/usr/bin/env bash
set -eu
{
    printf 'UID=%s\n' "$(id -u)"
    printf 'DISPLAY=%s\n' "${DISPLAY:-}"
    printf 'WAYLAND_DISPLAY=%s\n' "${WAYLAND_DISPLAY:-}"
    printf 'XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR:-}"
    printf 'DBUS_SESSION_BUS_ADDRESS=%s\n' "${DBUS_SESSION_BUS_ADDRESS:-}"
} > "${ENV_OUT:?ENV_OUT not set}"
ENVDUMP

cat > "$APPBIN/firefox" <<'FAKE_FIREFOX'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" > "${FIREFOX_ARGS:?FIREFOX_ARGS not set}"
FAKE_FIREFOX

cat > "$APPBIN/procdump" <<'PROCDUMP'
#!/usr/bin/env bash
set -eu
tr '\0' '\n' < "/proc/$PPID/environ" > "${PROC_OUT:?PROC_OUT not set}"
PROCDUMP

chmod +x "$MOCKBIN/ip" "$MOCKBIN/wgc" "$MOCKBIN/socat" "$APPBIN/envdump" "$APPBIN/firefox" "$APPBIN/procdump"

export PATH="$MOCKBIN:$APPBIN:$PATH"
export VPN_RUN_TEST_MODE=1
export VPN_RUN_WGC="$MOCKBIN/wgc"
export VPN_RUN_IP="$MOCKBIN/ip"
export VPN_RUN_SOCAT="$MOCKBIN/socat"
export VPN_RUN_LOCK_TIMEOUT=3

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    local pid pidfile
    for pidfile in "$SANDBOX"/case-*/state/*/supervisor.pid; do
        [[ -f $pidfile ]] || continue
        pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$pidfile" | head -n 1)
        [[ $pid =~ ^[0-9]+$ ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
        sleep 0.1
        kill -KILL "$pid" 2>/dev/null || true
    done
    for pidfile in "$SANDBOX"/case-*/state/*/refs/*.json; do
        [[ -f $pidfile ]] || continue
        pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$pidfile" | head -n 1)
        [[ $pid =~ ^[0-9]+$ ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
    done
    for pidfile in "$SANDBOX"/case-*/fake/ns/wgc_*/pids; do
        [[ -f $pidfile ]] || continue
        while IFS= read -r pid; do
            [[ $pid =~ ^[0-9]+$ ]] || continue
            kill -TERM "$pid" 2>/dev/null || true
            kill -KILL "$pid" 2>/dev/null || true
        done < "$pidfile"
    done
    for logfile in "$SANDBOX"/case-*/fake/socat.log; do
        [[ -f $logfile ]] || continue
        while read -r pid _rest; do
            [[ $pid =~ ^[0-9]+$ ]] || continue
            kill -TERM "$pid" 2>/dev/null || true
            kill -KILL "$pid" 2>/dev/null || true
        done < "$logfile"
    done
    for pidfile in "$SANDBOX"/case-*/holder.pid; do
        [[ -f $pidfile ]] || continue
        pid=$(head -n 1 "$pidfile")
        [[ $pid =~ ^[0-9]+$ ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
    done
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

test_static() {
    new_case static
    bash -n "$ROOT_DIR/install.sh"
    bash -n "$ROOT_DIR/uninstall.sh"
    bash -n "$TEST_FILE"
    PYTHONPYCACHEPREFIX="$CASE/pycache" python3 -m py_compile "$VPN_RUN"

    if command -v shellcheck >/dev/null 2>&1; then
        shellcheck -x "$ROOT_DIR/install.sh" "$ROOT_DIR/uninstall.sh" "$TEST_FILE"
    else
        skip "shellcheck not installed; static Bash lint skipped"
    fi

    if command -v flake8 >/dev/null 2>&1; then
        flake8 --max-line-length=120 "$VPN_RUN"
    elif command -v ruff >/dev/null 2>&1; then
        ruff check --select E,F --line-length 120 "$VPN_RUN"
    else
        skip "flake8/ruff not installed; Python style lint skipped"
    fi
}

test_cli() {
    new_case cli
    "$VPN_RUN" --help > "$CASE/help" 2>&1
    assert_contains "$CASE/help" "Usage:"
    assert_contains "$CASE/help" "--kill"
    assert_contains "$CASE/help" "wgc_mullvad"

    "$VPN_RUN" --version > "$CASE/version" 2>&1
    assert_contains "$CASE/version" "mullrun 1.1.0"

    if "$VPN_RUN" > "$CASE/noargs" 2>&1; then
        return 1
    fi
    grep -q "No command specified" "$CASE/noargs"

    if "$VPN_RUN" -v 'bad/name' true > "$CASE/badname" 2>&1; then
        return 1
    fi
    grep -q "Invalid VPN name" "$CASE/badname"

    if "$VPN_RUN" --status --kill > "$CASE/conflict" 2>&1; then
        return 1
    fi
    grep -q "mutually exclusive" "$CASE/conflict"

    if "$VPN_RUN" --definitely-not-an-option true > "$CASE/badopt" 2>&1; then
        return 1
    fi
    grep -q "Unknown option" "$CASE/badopt"
}

test_single_lifecycle() {
    new_case single
    local vpn=mullvad
    local ns
    ns=$(ns_dir "$vpn")

    "$VPN_RUN" -v "$vpn" --grace "$GRACE" sleep 3 > "$CASE/app.log" 2>&1 &
    local app_launcher=$!
    wait_for 6 test -d "$ns"
    wait_for 6 test -s "$FAKE_STATE/ns/wgc_$vpn/pids"

    "$VPN_RUN" -v "$vpn" --status > "$CASE/status" 2>&1
    assert_contains "$CASE/status" "State:         ACTIVE"
    assert_contains "$CASE/status" "Reference locks: 1"
    assert_contains "$CASE/status" "endpoint 203.0.113.7:51820"
    assert_contains "$CASE/status" "sleep"
    if flock -n -x "$CASE/run/locks/mullvad.ref.lock" true 2>/dev/null; then
        printf '# reference lock was not held while the app was running\n' >&2
        return 1
    fi

    wait "$app_launcher"

    # The namespace must remain during the grace period, then disappear.
    sleep 0.3
    test -d "$ns"
    wait_for 6 test ! -d "$ns"
    assert_equal "$(count_calls '^nup mullvad')" "1" "nup calls"
    assert_equal "$(count_calls '^down mullvad')" "1" "down calls"
    assert_contains "$FAKE_STATE/calls.log" "down mullvad force"
    wait_for 3 test ! -d "$CASE/run/state/mullvad"
    wait_for 3 test ! -f "$CASE/run/state/mullvad/supervisor.pid"
    wait_for 3 flock -n -x "$CASE/run/locks/mullvad.ref.lock" true

    "$VPN_RUN" -v "$vpn" --status > "$CASE/status2" 2>&1
    assert_contains "$CASE/status2" "State:         INACTIVE"
}

test_concurrent_refcount() {
    new_case concurrent
    export FAKE_NUP_DELAY=0.4
    local vpn=office
    local ns
    ns=$(ns_dir "$vpn")

    "$VPN_RUN" -v "$vpn" --grace "$GRACE" sleep 2 > "$CASE/one.log" 2>&1 &
    local one=$!
    "$VPN_RUN" -v "$vpn" --grace "$GRACE" sleep 2 > "$CASE/two.log" 2>&1 &
    local two=$!

    wait_for 8 test -d "$ns"
    local end=$((SECONDS + 8))
    while (( SECONDS < end )); do
        if (( $(count_calls "^exec $vpn ") >= 2 )); then
            break
        fi
        sleep 0.1
    done
    assert_equal "$(count_calls "^exec $vpn ")" "2" "exec calls"

    "$VPN_RUN" -v "$vpn" --status > "$CASE/status" 2>&1
    assert_contains "$CASE/status" "Reference locks: 2"

    wait "$one"
    wait "$two"
    wait_for 6 test ! -d "$ns"
    assert_equal "$(count_calls "^nup $vpn")" "1" "nup calls"
    assert_equal "$(count_calls "^down $vpn")" "1" "down calls"
    wait_for 3 test ! -d "$CASE/run/state/$vpn"
}

test_lock_timeout() {
    new_case lock
    local lockfile="$CASE/run/locks/locktest.ref.lock"
    mkdir -p "$CASE/run/locks"
    chmod 700 "$CASE/run" "$CASE/run/locks"
    flock -x "$lockfile" -c 'sleep 4' &
    local holder=$!
    sleep 0.2

    local rc=0
    set +e
    VPN_RUN_LOCK_TIMEOUT=1 "$VPN_RUN" -v locktest --grace 0 true > "$CASE/out" 2>&1
    rc=$?
    set -e
    if (( rc == 0 )); then
        wait "$holder" || true
        return 1
    fi
    assert_contains "$CASE/out" "Timed out waiting for"
    test ! -d "$FAKE_STATE/ns/wgc_locktest"
    assert_equal "$(count_calls 'nup locktest')" "0" "nup calls"
    wait "$holder" || true
}

test_grace_reuse() {
    new_case reuse
    local vpn=reuse
    local ns
    ns=$(ns_dir "$vpn")

    "$VPN_RUN" -v "$vpn" --grace 2 sleep 1 > "$CASE/first.log" 2>&1 &
    local first=$!
    wait_for 6 test -d "$ns"
    wait "$first"
    sleep 0.3

    "$VPN_RUN" -v "$vpn" --grace 2 sleep 1 > "$CASE/second.log" 2>&1 &
    local second=$!
    wait_for 6 test -d "$ns"
    wait_for 6 test -s "$FAKE_STATE/ns/wgc_$vpn/pids"
    wait "$second"
    wait_for 8 test ! -d "$ns"
    assert_equal "$(count_calls "^nup $vpn")" "1" "nup calls"
    assert_equal "$(count_calls "^down $vpn")" "1" "down calls"
}

test_bridge_config_validation() {
    new_case bridgecfg
    cat > "$VPN_RUN_BRIDGE_CONFIG_USER" <<'EOF'
[bad-address]
vpn = mullvad
direction = host-to-netns
host_port = 39117
netns_port = 39118
host_addr = 0.0.0.0
enabled = true

[bad-port]
vpn = mullvad
direction = host-to-netns
host_port = 39119
netns_port = 70000
enabled = true

[bad-direction]
vpn = mullvad
direction = sideways
host_port = 39121
netns_port = 39122
enabled = true
EOF
    "$VPN_RUN" --status > "$CASE/status" 2>&1
    assert_contains "$CASE/status" "Active Bridges"
    assert_contains "$CASE/status" "refusing non-loopback host_addr"
    assert_contains "$CASE/status" "netns_port must be between 1 and 65535"
    assert_contains "$CASE/status" "direction must be 'host-to-netns' or 'netns-to-host'"

    cat > "$VPN_RUN_BRIDGE_CONFIG_SYSTEM" <<'EOF'
[precedence]
vpn = mullvad
direction = host-to-netns
host_port = 1111
netns_port = 1112
enabled = true
EOF
    cat > "$VPN_RUN_BRIDGE_CONFIG_USER" <<'EOF'
[precedence]
vpn = mullvad
direction = host-to-netns
host_port = 3333
netns_port = 3334
enabled = true
EOF
    "$VPN_RUN" --status > "$CASE/precedence" 2>&1
    assert_contains "$CASE/precedence" "127.0.0.1:3333"
    assert_not_contains "$CASE/precedence" "127.0.0.1:1111"

    cat > "$VPN_RUN_BRIDGE_CONFIG_USER" <<'EOF'
[unsafe]
vpn = mullvad
direction = host-to-netns
host_port = 39123
netns_port = 39124
host_addr = 0.0.0.0
unsafe = true
enabled = false
EOF
    "$VPN_RUN" --status > "$CASE/unsafe" 2>&1
    assert_not_contains "$CASE/unsafe" "refusing non-loopback host_addr"
    assert_contains "$CASE/unsafe" "disabled"
}

test_bridge_lifecycle() {
    new_case bridgelife
    local vpn=mullvad
    local ns host_port netns_port
    ns=$(ns_dir "$vpn")
    host_port=$(free_port)
    netns_port=$(free_port)
    while [[ $netns_port == "$host_port" ]]; do netns_port=$(free_port); done
    cat > "$VPN_RUN_BRIDGE_CONFIG_USER" <<EOF
[jackett]
vpn = mullvad
direction = host-to-netns
host_port = $host_port
netns_port = $netns_port
host_addr = 127.0.0.1
netns_addr = 127.0.0.1
enabled = true
EOF

    "$VPN_RUN" -v "$vpn" --grace "$GRACE" sleep 2 > "$CASE/app.log" 2>&1 &
    local launcher=$!
    wait_for 8 test -d "$ns"
    local state="$CASE/run/state/$vpn/bridges.json"
    local socket="$CASE/run/bridges/$vpn/jackett.sock"
    wait_for 8 test -f "$state"
    wait_for 8 test -S "$socket"
    if (( $(socat_lines) < 2 )); then
        printf '# expected at least two socat relay processes, got %s\n' "$(socat_lines)" >&2
        return 1
    fi
    local host_pid netns_pid
    host_pid=$(bridge_pid "$state" host_pid)
    netns_pid=$(bridge_pid "$state" netns_pid)
    test -n "$host_pid"
    test -n "$netns_pid"
    kill -0 "$host_pid"
    kill -0 "$netns_pid"
    assert_file_mode "$CASE/run/bridges/$vpn" "700"
    assert_file_mode "$socket" "600"

    "$VPN_RUN" -v "$vpn" --status > "$CASE/status" 2>&1
    assert_contains "$CASE/status" "Active Bridges"
    assert_contains "$CASE/status" "jackett"
    assert_contains "$CASE/status" "host-to-netns"
    assert_contains "$CASE/status" "running"
    assert_contains "$CASE/status" "host=$host_pid"
    assert_contains "$CASE/status" "netns=$netns_pid"
    assert_contains "$CASE/status" "127.0.0.1:$host_port"
    assert_contains "$CASE/status" "127.0.0.1:$netns_port"

    wait "$launcher"
    wait_for 10 test ! -d "$ns"
    wait_for 5 test ! -e "/proc/$host_pid"
    wait_for 5 test ! -e "/proc/$netns_pid"
    test ! -e "$socket"
    test ! -d "$CASE/run/bridges/$vpn"
    test ! -f "$state"
    assert_equal "$(count_calls "^down $vpn")" "1" "down calls"
}

test_bridge_kill() {
    new_case bridgekill
    local vpn=bridgekill
    local ns host_port netns_port
    ns=$(ns_dir "$vpn")
    host_port=$(free_port)
    netns_port=$(free_port)
    while [[ $netns_port == "$host_port" ]]; do netns_port=$(free_port); done
    cat > "$VPN_RUN_BRIDGE_CONFIG_USER" <<EOF
[webui]
vpn = $vpn
direction = netns-to-host
host_port = $host_port
netns_port = $netns_port
host_addr = 127.0.0.1
netns_addr = 127.0.0.1
enabled = true
EOF

    "$VPN_RUN" -v "$vpn" --grace 30 sleep 30 > "$CASE/app.log" 2>&1 &
    local launcher=$!
    wait_for 8 test -d "$ns"
    local state="$CASE/run/state/$vpn/bridges.json"
    wait_for 8 test -f "$state"
    local host_pid netns_pid
    host_pid=$(bridge_pid "$state" host_pid)
    netns_pid=$(bridge_pid "$state" netns_pid)
    test -n "$host_pid"
    test -n "$netns_pid"
    kill -0 "$host_pid"
    kill -0 "$netns_pid"

    "$VPN_RUN" -v "$vpn" --kill > "$CASE/kill.out" 2>&1
    wait_for 8 test ! -d "$ns"
    wait_for 5 test ! -e "/proc/$host_pid"
    wait_for 5 test ! -e "/proc/$netns_pid"
    test ! -d "$CASE/run/bridges/$vpn"
    test ! -f "$state"
    assert_equal "$(count_calls "^kill $vpn")" "1" "kill calls"
    wait "$launcher" || true
}

test_bridge_port_conflict() {
    new_case bridgeport
    local vpn=bridgeport
    local host_port netns_port holder
    host_port=$(free_port)
    netns_port=$(free_port)
    while [[ $netns_port == "$host_port" ]]; do netns_port=$(free_port); done
    python3 -c '
import socket, sys, time
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.bind(("127.0.0.1", int(sys.argv[1])))
sock.listen(1)
time.sleep(15)
' "$host_port" &
    holder=$!
    printf '%s\n' "$holder" > "$CASE/holder.pid"
    sleep 0.2
    cat > "$VPN_RUN_BRIDGE_CONFIG_USER" <<EOF
[webui]
vpn = $vpn
direction = netns-to-host
host_port = $host_port
netns_port = $netns_port
enabled = true
EOF

    "$VPN_RUN" -v "$vpn" --grace 0 sleep 1 > "$CASE/app.log" 2>&1
    assert_contains "$CASE/app.log" "already in use"
    assert_contains "$CASE/app.log" "Bridge 'webui' unavailable"
    wait_for 6 test ! -d "$(ns_dir "$vpn")"
    test ! -d "$CASE/run/bridges/$vpn"
    kill -TERM "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    rm -f -- "$CASE/holder.pid"
}

test_kill() {
    new_case kill
    local vpn=killme
    local ns
    ns=$(ns_dir "$vpn")

    "$VPN_RUN" -v "$vpn" --grace 30 sleep 30 > "$CASE/app.log" 2>&1 &
    local launcher=$!
    wait_for 6 test -d "$ns"
    wait_for 6 test -s "$FAKE_STATE/ns/wgc_$vpn/pids"
    local app_pid
    app_pid=$(head -n 1 "$FAKE_STATE/ns/wgc_$vpn/pids")
    kill -0 "$app_pid"

    "$VPN_RUN" -v "$vpn" --kill > "$CASE/kill.out" 2>&1
    wait_for 6 test ! -d "$ns"
    if kill -0 "$app_pid" 2>/dev/null; then
        printf '# app PID %s survived --kill\n' "$app_pid" >&2
        return 1
    fi
    assert_equal "$(count_calls "^kill $vpn")" "1" "kill calls"
    test ! -d "$CASE/run/state/$vpn"

    # The launcher blocks in wait(); the forced kill makes it exit non-zero.
    wait "$launcher" || true
}

test_launcher_crash() {
    new_case crash
    local vpn=crash
    local ns
    ns=$(ns_dir "$vpn")

    "$VPN_RUN" -v "$vpn" --grace "$GRACE" sleep 2 > "$CASE/app.log" 2>&1 &
    local launcher=$!
    wait_for 6 test -d "$ns"
    wait_for 6 test -s "$FAKE_STATE/ns/wgc_$vpn/pids"
    local app_pid
    app_pid=$(head -n 1 "$FAKE_STATE/ns/wgc_$vpn/pids")

    kill -KILL "$launcher"
    wait "$launcher" 2>/dev/null || true

    # The app is orphaned but alive.  PID monitoring must keep the namespace
    # open past the grace period; only app exit may start the teardown timer.
    sleep 1.2
    test -d "$ns"
    kill -0 "$app_pid"
    wait_for 8 test ! -d "$ns"
    if kill -0 "$app_pid" 2>/dev/null; then
        printf '# orphan app PID %s survived teardown\n' "$app_pid" >&2
        return 1
    fi
    assert_equal "$(count_calls "^down $vpn")" "1" "down calls"
}

test_signal_forwarding() {
    new_case signal
    local vpn=signal
    local ns
    ns=$(ns_dir "$vpn")

    "$VPN_RUN" -v "$vpn" --grace 0 sleep 30 > "$CASE/app.log" 2>&1 &
    local launcher=$!
    wait_for 6 test -d "$ns"
    wait_for 6 test -s "$FAKE_STATE/ns/wgc_$vpn/pids"
    local app_pid
    app_pid=$(head -n 1 "$FAKE_STATE/ns/wgc_$vpn/pids")

    kill -TERM "$launcher"
    wait "$launcher" || true
    wait_for 6 test ! -d "$ns"
    if kill -0 "$app_pid" 2>/dev/null; then
        printf '# app PID %s survived launcher SIGTERM\n' "$app_pid" >&2
        return 1
    fi
}

test_environment_and_firefox() {
    new_case env
    local vpn=envtest
    local ns
    ns=$(ns_dir "$vpn")

    export ENV_OUT="$CASE/env.out"
    export DISPLAY=":77"
    export WAYLAND_DISPLAY="wayland-77"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$CASE/fake-bus"
    "$VPN_RUN" -v "$vpn" --grace 0 envdump > "$CASE/env.log" 2>&1
    wait_for 6 test ! -d "$ns"
    assert_contains "$ENV_OUT" "UID=$(id -u)"
    assert_contains "$ENV_OUT" "DISPLAY=:77"
    assert_contains "$ENV_OUT" "WAYLAND_DISPLAY=wayland-77"
    assert_contains "$ENV_OUT" "XDG_RUNTIME_DIR=$CASE/xdg"
    assert_contains "$ENV_OUT" "DBUS_SESSION_BUS_ADDRESS=unix:path=$CASE/fake-bus"

    # wgc reads the launcher's initial environment from /proc/PID/environ.
    # Removing variables from our own environment proves the one-time re-exec
    # writes the inferred session defaults into that block.
    touch "$XDG_RUNTIME_DIR/wayland-test"
    export PROC_OUT="$CASE/launcher.env"
    env -u DISPLAY -u WAYLAND_DISPLAY -u DBUS_SESSION_BUS_ADDRESS \
        "$VPN_RUN" -v "$vpn" --grace 0 procdump > "$CASE/procdump.log" 2>&1
    wait_for 6 test ! -d "$ns"
    assert_contains "$PROC_OUT" "WAYLAND_DISPLAY=wayland-test"
    assert_contains "$PROC_OUT" "XDG_RUNTIME_DIR=$CASE/xdg"

    export FIREFOX_ARGS="$CASE/firefox.args"
    "$VPN_RUN" -v "$vpn" --grace 0 firefox about:blank > "$CASE/firefox.log" 2>&1
    wait_for 6 test ! -d "$ns"
    assert_contains "$FIREFOX_ARGS" "--no-remote"
    assert_contains "$FIREFOX_ARGS" "--profile"
    assert_contains "$FIREFOX_ARGS" "about:blank"
    local profile="$HOME/.local/share/mullrun/firefox-profile"
    test -d "$profile"
    assert_file_mode "$profile" "700"
}

test_supervisor_replacement() {
    new_case replacement
    local vpn=replace
    local ns
    ns=$(ns_dir "$vpn")

    "$VPN_RUN" -v "$vpn" --grace "$GRACE" sleep 3 > "$CASE/app.log" 2>&1 &
    local launcher=$!
    wait_for 6 test -d "$ns"
    wait_for 6 test -f "$CASE/run/state/$vpn/supervisor.pid"
    local old_pid
    old_pid=$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
        "$CASE/run/state/$vpn/supervisor.pid" | head -n 1)
    kill -KILL "$old_pid"
    wait "$launcher"
    wait_for 8 test ! -d "$ns"
    assert_equal "$(count_calls "^down $vpn")" "1" "down calls"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
run_test() {
    local name=$1 rc
    shift
    info "$name"
    set +e
    ( set -Eeuo pipefail; "$@" )
    rc=$?
    set -e
    if (( rc == 0 )); then
        pass "$name"
    else
        fail "$name"
    fi
}

printf '%s\n' "mullrun lifecycle tests"
printf '%s\n' "sandbox: $SANDBOX"

run_test "static analysis and syntax" test_static
run_test "CLI help, version and validation" test_cli
run_test "single app lifecycle and grace teardown" test_single_lifecycle
run_test "concurrent refcount and single nup" test_concurrent_refcount
run_test "reference lock timeout" test_lock_timeout
run_test "new claim during grace reuses namespace" test_grace_reuse
run_test "bridge configuration validation" test_bridge_config_validation
run_test "bridge lifecycle and supervisor immunity" test_bridge_lifecycle
run_test "bridge cleanup on --kill" test_bridge_kill
run_test "bridge port conflict is non-fatal" test_bridge_port_conflict
run_test "force kill cleanup" test_kill
run_test "launcher kill -9 leaves orphan supervised" test_launcher_crash
run_test "launcher signal forwarding" test_signal_forwarding
run_test "desktop environment and Firefox isolation" test_environment_and_firefox
run_test "supervisor crash replacement" test_supervisor_replacement

printf '\n%s\n' "----------------------------------------"
SKIP=0
if [[ -f "$SANDBOX/skips" ]]; then
    SKIP=$(wc -l < "$SANDBOX/skips")
fi
printf 'passed: %d  failed: %d  skipped: %d\n' "$PASS" "$FAIL" "$SKIP"
if (( FAIL > 0 )); then
    exit 1
fi
exit 0
