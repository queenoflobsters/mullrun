#!/usr/bin/env bash
# shellcheck disable=SC2317  # dynamically dispatched test functions
# =============================================================================
# test_lifecycle.sh - hermetic lifecycle tests for bin/vpn-run
#
# No root, real namespace, network access, or real wgc/ip is required.  Fake
# wgc and ip binaries live in a private temporary directory and model the
# namespace/refcount contract used by the launcher.
# =============================================================================
set -Eeuo pipefail
IFS=$' \t\n'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
VPN_RUN="$ROOT_DIR/bin/vpn-run"
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
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/vpn-run-tests.XXXXXX")
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

new_case() {
    CASE="$SANDBOX/case-$1"
    rm -rf -- "$CASE"
    mkdir -p "$CASE"/{run,home,xdg,fake/ns}
    chmod 700 "$CASE" "$CASE/run" "$CASE/xdg" "$CASE/home"
    export CASE
    export FAKE_STATE="$CASE/fake"
    export VPN_RUN_RUNTIME_DIR="$CASE/run"
    export HOME="$CASE/home"
    export XDG_RUNTIME_DIR="$CASE/xdg"
    export FAKE_NUP_DELAY=0
    unset VPN_RUN_GRACE_PERIOD VPN_RUN_DEFAULT_VPN || true
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

chmod +x "$MOCKBIN/ip" "$MOCKBIN/wgc" "$APPBIN/envdump" "$APPBIN/firefox" "$APPBIN/procdump"

export PATH="$MOCKBIN:$APPBIN:$PATH"
export VPN_RUN_TEST_MODE=1
export VPN_RUN_WGC="$MOCKBIN/wgc"
export VPN_RUN_IP="$MOCKBIN/ip"
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
    assert_contains "$CASE/version" "vpn-run 1.0.0"

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
    local profile="$HOME/.local/share/vpn-run/firefox-profile"
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

printf '%s\n' "vpn-run lifecycle tests"
printf '%s\n' "sandbox: $SANDBOX"

run_test "static analysis and syntax" test_static
run_test "CLI help, version and validation" test_cli
run_test "single app lifecycle and grace teardown" test_single_lifecycle
run_test "concurrent refcount and single nup" test_concurrent_refcount
run_test "reference lock timeout" test_lock_timeout
run_test "new claim during grace reuses namespace" test_grace_reuse
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
