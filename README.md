# mullrun — `vpn-run`

`vpn-run` is an on-demand, reference-counted, auto-closing launcher for
applications that must use a Mullvad WireGuard tunnel. It wraps
[`wgc`](https://github.com/colemar/wgc), which builds a dedicated Linux network
namespace for each WireGuard profile. The application never sees the host's
physical network interfaces; if the tunnel disappears, the namespace and the
application's network path disappear with it.

The repository is named **mullrun**; the installed command is **`vpn-run`**.

```
$ vpn-run qbittorrent
$ vpn-run firefox
$ vpn-run curl https://am.i.mullvad.net/connected
$ vpn-run --status
$ vpn-run --kill
```

## Contents

1. [Architecture](#architecture)
2. [Why a network namespace is a killswitch](#why-a-network-namespace-is-a-killswitch)
3. [Concurrency and crash-proof cleanup](#concurrency-and-crash-proof-cleanup)
4. [Installation](#installation)
5. [Mullvad WireGuard setup](#mullvad-wireguard-setup)
6. [Usage](#usage)
7. [qBittorrent: secondary interface binding](#qbittorrent-secondary-interface-binding)
8. [Runtime layout and configuration](#runtime-layout-and-configuration)
9. [Testing](#testing)
10. [Troubleshooting](#troubleshooting)
11. [Security notes](#security-notes)
12. [Uninstallation](#uninstallation)

---

## Architecture

```
                       desktop session (UID 1000)
 ┌──────────────────────────────────────────────────────────────────────┐
 │  shell:  vpn-run firefox                                             │
 │            │                                                         │
 │            ▼                                                         │
 │  ┌─────────────────────┐    shared flock     ┌────────────────────┐   │
 │  │ vpn-run launcher    │────────────────────▶│ <vpn>.ref.lock     │   │
 │  │ (one per app)       │                     └────────────────────┘   │
 │  │  - holds ref lock   │                              ▲               │
 │  │  - registers PID    │                              │ exclusive     │
 │  │  - waits for app    │                     ┌────────┴───────────┐   │
 │  └─────────┬───────────┘                     │ detached supervisor │   │
 │            │ sudo -n wgc exec <vpn> ...      │ - probes ref lock   │   │
 │            ▼                                 │ - reads netns PIDs  │   │
 │  ┌──────────────────────────────────────┐    │ - grace timer       │   │
 │  │ wgc_<vpn> network namespace          │    │ - wgc down / kill   │   │
 │  │                                      │    └────────┬───────────┘   │
 │  │  lo                                  │             │               │
 │  │  wgc_<vpn> (WireGuard interface)     │             │ sudo -n wgc   │
 │  │    default route → tunnel            │             ▼               │
 │  │  application (setpriv → UID 1000)    │       teardown after grace   │
 │  └──────────────────────────────────────┘                             │
 └──────────────────────────────────────────────────────────────────────┘
                                host network untouched
```

The namespace is created by `wgc nup <profile>` and is called `wgc_<profile>`
(`mullvad` → `wgc_mullvad`). The WireGuard interface inside the namespace has
the same name. Applications are launched with `wgc exec <profile> <command>`,
which enters the namespace and drops from root to the invoking desktop user
with `setpriv`.

The launcher does **not** modify host routes or host DNS. Traffic from the
application is only routable through the namespace's WireGuard interface.

## Why a network namespace is a killswitch

A normal "VPN app" can leak in several ways:

- the application opens a socket on the physical interface before the VPN is up;
- a reconnect briefly removes the default route;
- a DNS request goes to the host resolver;
- an IPv6 route bypasses an IPv4-only tunnel;
- a child process survives a GUI close and keeps using the host network.

A network namespace removes the physical interface from the application's
view entirely. Inside `wgc_<vpn>` there is only loopback and the WireGuard
interface. There is no physical NIC, no host route table, and no host default
gateway to fall back to. When the namespace is destroyed, every process in it
loses its network stack. This is a stronger guarantee than firewall rules
because there is no host interface to leak through in the first place.

`wgc nup` puts all traffic in the namespace through the tunnel. The host's
normal networking continues to work for everything else.

### IPv6

The namespace contains only `lo` and the `wgc_<vpn>` interface. The presence of
IPv6 connectivity depends on the profile and the `wgc` version. If you need a
hard IPv6 guarantee, either:

- confirm that the profile has no IPv6 address/route and that `ip -6 route`
  inside the namespace is empty; or
- disable IPv6 for the Mullvad device in the Mullvad account settings, or
  explicitly test with `vpn-run curl -6 ...` and verify failure.

Use `vpn-run sh -c 'ip -brief address; ip route; ip -6 route'` to inspect what
the application can actually see.

## Concurrency and crash-proof cleanup

### One namespace, many applications

Every launcher invocation opens `<profile>.ref.lock` and takes a **shared
`flock`**. The lock is held for the entire lifetime of the application and is
released by the kernel even if the launcher is killed with `SIGKILL`. Starting
a second application therefore does not run a second `wgc nup`: it waits for
the bring-up life-cycle lock, sees that `wgc_<profile>` already exists, and
shares it.

The following locks are used:

| Lock | Owner | Purpose |
| --- | --- | --- |
| `<profile>.ref.lock` | every app launcher (shared) | Exact kernel-enforced reference count |
| `<profile>.lifecycle.lock` | launcher bring-up / supervisor teardown | Serializes up and down transitions |
| `<profile>.supervisor.lock` | detached supervisor (exclusive) | Guarantees exactly one supervisor |

Lock ordering is deliberate:

- A launcher acquires a **shared ref lock first**, then the lifecycle lock.
- The supervisor acquires the lifecycle lock, then tries a **non-blocking
  exclusive ref lock**.
- Because the supervisor's second acquisition is non-blocking, it can never
  deadlock with a launcher that already holds a shared reference and is waiting
  for the lifecycle lock.
- Teardown only proceeds while holding the lifecycle lock and an exclusive ref
  lock. A new launcher that arrives during the grace period either gets a
  shared lock before the exclusive check (teardown is cancelled) or waits and
  starts a fresh namespace after teardown.

The status command reads the exact number of shared holders from
`/proc/locks`, not from a racy counter file. The JSON reference records are
only used for human-readable per-client details.

### How the supervisor handles crashes

The detached supervisor does not depend on a launcher staying alive. Once per
poll interval it checks:

1. whether any process holds the shared ref lock; and
2. which PIDs live in `wgc_<profile>` (via `ip netns pids`).

It ignores `wgc`'s own port-forwarding bridge helpers (identified by
`WGC_BRIDGE` or a `wgc.<profile>.` cgroup unit name), because those are
infrastructure, not applications.

When both sets are empty, the grace timer starts (default **5 seconds**). If
an application claims the namespace during the grace period, the timer is
reset. If not, the supervisor calls a forced teardown:

1. `wgc down <profile> force` (accepted by the requested wrapper interface and
   tolerated by upstream `wgc`); if that fails,
2. `wgc kill <profile>` (upstream `wgc`'s documented forced teardown, which
   also kills processes).

It then verifies that the namespace is gone and removes the transient state
directory. If teardown fails, the supervisor stays alive and retries after
another grace period rather than abandoning a live tunnel.

What each scenario does:

| Scenario | Result |
| --- | --- |
| Normal app exit | Ref released, grace timer runs, tunnel closes |
| App segfaults | Ref released, no PID remains, grace timer runs |
| App is `kill -9`ed | Same as segfault |
| Launcher is `kill -9`ed while app runs | Ref is released by the kernel, but the app PID remains visible; teardown waits until the app and its children exit |
| Child daemonizes inside the namespace | PID monitoring sees it and keeps the namespace alive |
| App crashes leaving a child | Namespace remains until the child exits; `--kill` is the manual override |
| Supervisor itself is killed | The launcher's post-exit check starts a replacement supervisor |
| New app arrives during grace | Shared ref lock is acquired, grace timer resets, namespace is reused |

### Firefox single-instance isolation

Firefox normally talks to an existing host instance over a Unix socket and can
silently open a tab in a non-VPN browser. When the target command is
`firefox`, `firefox-bin`, or `firefox-esr`, `vpn-run`:

- adds `--no-remote` (unless already supplied); and
- adds `--profile ~/.local/share/vpn-run/firefox-profile` (unless the caller
  supplied `--profile` or `-P`).

The directory is created with mode `0700`. The VPN Firefox instance therefore
has its own profile and never shares a running instance with the host browser.

### Desktop environment and privilege drop

The launcher runs as the normal desktop user. Only `wgc` and `ip` are invoked
through passwordless `sudo`. `wgc exec` reconstructs the unsanitised
environment from the process that invoked sudo, then drops privileges with
`setpriv`. This preserves:

- `DISPLAY`, `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`
- `DBUS_SESSION_BUS_ADDRESS`
- `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`
- PipeWire/PulseAudio environment and the per-user audio sockets
- `HOME`, `USER`, `LOGNAME`, locale and `PATH`

`vpn-run` applies missing session defaults and does one `execve` after a
possible root-to-user drop so the final environment is visible in
`/proc/PID/environ`, which is what `wgc exec` reads. The target app runs as the
invoking user, never as root. Running `sudo vpn-run` is explicitly refused
unless the original sudo user can be recovered and privileges can be dropped.

> The process is a Python script, not a setuid binary. Do not add a setuid bit;
> the install script uses mode `0755`.

## Installation

### Requirements

- Linux with network namespaces and WireGuard kernel support
- Python **3.8+** (standard library only; no pip packages)
- Bash 4.4+ for `wgc`
- `wgc` config support: `/etc/wireguard` owned by root, group/world-writable
  bits clear, and an approval file `/etc/wireguard/wgc_enable`
- A Mullvad account and a WireGuard profile

### Fedora 40+ (including Fedora 43/44 with dnf5)

```bash
cd ~/Apps/mullrun   # path where this repository is checked out
sudo ./install.sh
```

The installer detects Fedora, installs (via `dnf`):

```
python3 wireguard-tools iproute util-linux curl sudo
socat procps-ng
```

It then installs `wgc` from the official upstream URL, installs
`/usr/local/bin/vpn-run`, creates `/etc/wireguard/wgc_enable`, and writes
`/etc/sudoers.d/vpn-run-nopasswd` after validating it with `visudo -cf`.

Your user must be in the `wheel` group:

```bash
id -nG
# if wheel is missing:
sudo usermod -aG wheel "$USER"
# log out and back in, or run: newgrp wheel
```

### Arch Linux / CachyOS

```bash
cd ~/Apps/mullrun   # path where this repository is checked out
sudo ./install.sh
```

The installer uses `pacman -S --needed --noconfirm` and installs:

```
python wireguard-tools iproute2 util-linux curl sudo
socat procps-ng
```

Everything else is the same as Fedora. If `pacman` reports stale databases,
run `sudo pacman -Syu` and re-run the installer.

### What the sudoers policy allows

`/etc/sudoers.d/vpn-run-nopasswd` contains passwordless entries for the
`wheel` group only, restricted to:

- `/usr/local/bin/wgc`
- the installed `ip` path(s) (`/usr/bin/ip`, `/sbin/ip`, etc.)

It does **not** grant general root access. The file is validated with
`visudo -cf` before it is moved into `/etc/sudoers.d`; a validation failure
leaves the old configuration untouched.

### Manual inspection after installation

```bash
command -v vpn-run wgc ip
sudo visudo -cf /etc/sudoers.d/vpn-run-nopasswd
sudo /usr/local/bin/wgc req
ls -ld /etc/wireguard
```

## Mullvad WireGuard setup

1. Sign in at <https://mullvad.net/en/account/wireguard-config>.
2. Generate a WireGuard key pair for the device.
3. Choose a server (or leave the automatic selection if offered by the page).
4. Download the generated `.conf` file.
5. Install it with root-only permissions:

   ```bash
   sudo install -d -o root -g root -m 0700 /etc/wireguard
   sudo install -o root -g root -m 0600 \
       ~/Downloads/mullvad-*.conf /etc/wireguard/mullvad.conf
   sudo chmod 600 /etc/wireguard/mullvad.conf
   ```

6. Validate the configuration with `wgc`:

   ```bash
   sudo /usr/local/bin/wgc parse mullvad
   ```

7. Start a test through the namespace:

   ```bash
   vpn-run curl https://am.i.mullvad.net/connected
   ```

   A connected response looks like:

   ```text
   You are connected to Mullvad (server ...). Your IP address is ...
   ```

8. Compare with the host (only meaningful if the host is not already on a
   Mullvad tunnel):

   ```bash
   curl https://am.i.mullvad.net/connected
   ```

   The two exit IPs should differ.

Additional profiles are supported by naming the config
`/etc/wireguard/<profile>.conf`:

```bash
sudo install -m 600 ~/Downloads/office.conf /etc/wireguard/office.conf
vpn-run -v office curl https://am.i.mullvad.net/connected
```

`wgc` requires `/etc/wireguard` to be root-owned and not writable by group or
others. The installer enforces this; if you manage the directory yourself,
run `sudo chmod go-w /etc/wireguard`.

> If you prefer a different WireGuard directory, note that the installed
> launcher uses the standard `/etc/wireguard` profile namespace. Keep the
> profile name in `-v` and the file name identical.

## Usage

```text
Usage:
  vpn-run [OPTIONS] <COMMAND> [ARGS...]
  vpn-run --status [-v NAME]
  vpn-run --kill [-v NAME]
```

| Option | Description |
| --- | --- |
| `-v, --vpn NAME` | WireGuard profile name (default `mullvad`) |
| `-g, --grace SECONDS` | Idle grace period before teardown (default 5) |
| `-s, --status` | Show namespace, connection details, refs and PIDs |
| `-k, --kill` | Force-kill all namespace processes and destroy the tunnel |
| `-h, --help` | Help |
| `-V, --version` | Version |
| `--debug` | Verbose launcher diagnostics |
| `--` | End option parsing; the rest is the command |

### GUI applications

```bash
vpn-run qbittorrent
vpn-run firefox
```

Firefox receives an isolated profile automatically. For a different profile
name, supply `--profile` yourself; `--no-remote` is still added.

### CLI tools

```bash
vpn-run curl ifconfig.me
vpn-run curl https://am.i.mullvad.net/connected
vpn-run sh -c 'ip -brief address; ip route; getent hosts example.com'
```

### Alternative profile

```bash
vpn-run -v office firefox
vpn-run --vpn=office --status
```

### Status

```bash
vpn-run --status
```

Shows:

- active/inactive state and namespace name
- up time and exact kernel reference-lock count
- supervisor PID and runtime path
- `wgc state` connection details
- formatted PIDs in the namespace
- per-client reference records

The status command is read-only from the tunnel's perspective; it does not
start or stop anything.

### Kill / manual recovery

```bash
vpn-run --kill
vpn-run --kill -v office
```

`--kill` stops the supervisor, calls `wgc kill` (which terminates every
process in the namespace and removes the interface/namespace), verifies that
the namespace is gone, and removes transient runtime state. It does not touch
other VPN profiles or the host network.

### Grace period

The grace period prevents rapid tunnel flapping when you close one app and
start another immediately.

```bash
vpn-run --grace 15 qbittorrent
VPN_RUN_GRACE_PERIOD=10 vpn-run firefox
```

The supervisor reads the latest grace value from the runtime state file; a new
invocation updates it. `0` means "tear down as soon as the supervisor observes
zero references and zero processes".

## qBittorrent: secondary interface binding

The application is already inside a namespace with only the WireGuard
interface. As a **secondary defense**, bind qBittorrent explicitly to that
interface:

1. Start it with `vpn-run qbittorrent`.
2. Open **Tools → Options → Advanced**.
3. Set **Network Interface** to `wgc_mullvad` (or `wgc_<your-profile>`).
4. Apply and restart qBittorrent inside `vpn-run`.

Inside the namespace, qBittorrent only sees `lo` and `wgc_<profile>`. Binding to
the WireGuard interface means that even a future routing change cannot make it
use loopback or a newly exposed interface. This is defense in depth, not a
replacement for the namespace.

If qBittorrent is installed as a Flatpak, verify that the sandbox exposes the
namespace interface it needs; Flatpak's sandboxing can hide network details.
Native packages are simplest.

### Ports and incoming connections

Port forwarding is configured in the Mullvad profile or via the `wgc` bridge
syntax in `[WGC]`. If you expose a port from the namespace, use `wgc`'s bridge
feature; do not add a host-side route into the namespace.

## Runtime layout and configuration

Per-user runtime state lives under `$XDG_RUNTIME_DIR/vpn-run` (normally
`/run/user/<uid>/vpn-run`, mode `0700`):

```text
/run/user/<uid>/vpn-run/
├── locks/
│   ├── <profile>.ref.lock
│   ├── <profile>.lifecycle.lock
│   └── <profile>.supervisor.lock
├── logs/
│   └── <profile>.log
└── state/
    └── <profile>/           # transient; removed on teardown
        ├── state.json
        ├── supervisor.pid
        └── refs/
```

**Why lock files are not deleted during teardown:** deleting a live lock file
is a classic source of split-brain locking. A process that opened the old
inode and a process that creates a new file at the same path would no longer
exclude each other. The three small lock files are therefore intentionally
retained; they are zero-byte, mode `0600`, owned by the user, and contain no
state. `--kill` and normal teardown remove the transient `state/<profile>`
directory. `uninstall.sh` removes the entire runtime root when no session is
active.

Supervisor logs are retained for diagnostics and rotated at 1 MiB. They contain
no WireGuard private keys; `wgc` hides secret material in its own output.

### Environment variables

| Variable | Effect |
| --- | --- |
| `VPN_RUN_DEFAULT_VPN` | Default profile when `-v` is omitted (default `mullvad`) |
| `VPN_RUN_GRACE_PERIOD` | Default grace period in seconds |
| `VPN_RUN_LOCK_TIMEOUT` | Reference-lock acquisition timeout (1–300s; default 60) |
| `XDG_RUNTIME_DIR` | Private runtime directory; required for state |
| `NO_COLOR` | Disable ANSI colors |
| `VPN_RUN_DEBUG=1` | Verbose launcher diagnostics |
| `TERM=dumb` | Disables colors automatically |

`VPN_RUN_TEST_MODE`, `VPN_RUN_WGC`, `VPN_RUN_IP` and `VPN_RUN_RUNTIME_DIR` are
test-harness hooks. They are only honored when `VPN_RUN_TEST_MODE=1` and never
enable sudo. Do not set them in normal use.

## Testing

The lifecycle test is hermetic: it uses fake `wgc` and `ip` binaries, a private
temporary runtime directory, and no root, firewall changes, real namespaces, or
network access.

```bash
./tests/test_lifecycle.sh
```

It checks:

- syntax and static analysis (`bash -n`, `py_compile`, `shellcheck`/`flake8`
  when installed)
- help, usage and profile-name validation
- on-demand namespace creation
- TTY-independent status output
- concurrent launchers sharing one namespace and one `nup`
- exact reference-lock counts
- grace-period teardown
- namespace reuse when a new app claims during the grace period
- lock acquisition timeout behavior
- `--kill` cleanup
- launcher `SIGKILL` with a surviving orphan app (PID-monitored teardown)
- signal forwarding from the launcher to the application
- supervisor crash replacement
- desktop environment preservation and non-root UID execution
- Firefox `--no-remote`/isolated-profile augmentation

Run individual static checks manually:

```bash
python3 -m py_compile bin/vpn-run
shellcheck install.sh uninstall.sh tests/test_lifecycle.sh
flake8 --max-line-length=120 bin/vpn-run
```

`ruff check --select E,F --line-length 120 bin/vpn-run` is an equivalent
modern alternative when flake8 is unavailable.

## Troubleshooting

### `sudo: a password is required` / `no tty present`

The sudoers drop-in is missing, invalid, or your user is not in `wheel`.

```bash
id -nG
sudo visudo -cf /etc/sudoers.d/vpn-run-nopasswd
sudo visudo -c
```

Re-run `sudo ./install.sh` after adding the user to `wheel` and logging back in.
The launcher deliberately uses `sudo -n` so background supervisors fail fast
instead of hanging on a password prompt.

### `wgc not found` or `wgc nup ... failed`

Verify the installed path and its dependencies:

```bash
ls -l /usr/local/bin/wgc
sudo /usr/local/bin/wgc req
sudo /usr/local/bin/wgc parse mullvad
```

If `wgc` is missing, reinstall with the installer. The installer downloads the
official script over HTTPS, verifies that it is a plausible Bash script with
`bash -n`, and installs it as root-owned mode `0755`.

On Arch Linux, `wgc req` may warn that `resolvconf` is unavailable. The
namespace mode (`nup`) writes `/etc/netns/<namespace>/resolv.conf` directly and
does not need `resolvconf`; the warning is not fatal for `vpn-run`.

### `wgc_enable` / insecure config directory

Upstream `wgc` requires `/etc/wireguard` to be root-owned, not group/world
writable, and to contain the approval file:

```bash
sudo install -d -o root -g root -m 0700 /etc/wireguard
sudo chmod go-w /etc/wireguard
sudo touch /etc/wireguard/wgc_enable
sudo chmod 0644 /etc/wireguard/wgc_enable
```

The installer creates the approval file if it is absent. The uninstaller only
removes it when it carries the installer's marker.

### Tunnel does not close after closing the app

Inspect the supervisor log and namespace:

```bash
tail -n 100 /run/user/$(id -u)/vpn-run/logs/mullvad.log
vpn-run --status
sudo ip netns pids wgc_mullvad
sudo wgc state mullvad
```

If a daemonized child remains in the namespace, the supervisor intentionally
keeps the namespace alive. Use `vpn-run --kill` to force it down. If the
supervisor is missing, the next launch or the launcher's post-exit check starts
a new one.

### DNS leaks and systemd-resolved

`wgc nup` writes a namespace-specific resolver file at:

```text
/etc/netns/wgc_<profile>/resolv.conf
```

It also masks nscd sockets for the application via an ephemeral mount namespace
when necessary. That covers a large class of leaks, but **systemd-resolved has
a Unix socket** (`/run/systemd/resolve/io.systemd.Resolve`) that can be
reachable from the namespace. An application using `nss-resolve` can ask the
host daemon to resolve a name, and the daemon may perform that query outside
the tunnel. This is a DNS leak, even though the application's data traffic
remains inside the namespace.

Diagnosis:

```bash
# Does the app use the resolved socket?
vpn-run sh -c 'strace -f -e trace=connect getent hosts example.com' 2>&1 | grep -E 'resolve|53'

# What is nsswitch actually doing?
grep '^hosts:' /etc/nsswitch.conf
```

Mitigations, in increasing order of strength:

1. Make sure `/etc/netns/wgc_<profile>/resolv.conf` contains only Mullvad DNS
   servers (wgc does this from the profile).
2. For applications that use libc `getaddrinfo`, remove `resolve` from the
   hosts line in a **private mount namespace** for that app. Example with
   `bubblewrap` (if installed and unprivileged user namespaces are enabled):

   ```bash
   # Create a resolver config without nss-resolve
   sed 's/\bresolve\b//g' /etc/nsswitch.conf > /tmp/nsswitch.vpn

   vpn-run bwrap --dev-bind / / \
       --bind /tmp/nsswitch.vpn /etc/nsswitch.conf \
       --tmpfs /run/systemd/resolve \
       --tmpfs /run/nscd \
       --tmpfs /var/run/nscd \
       -- curl https://am.i.mullvad.net/connected
   ```

   The exact directories depend on the distribution; if a path does not exist,
   omit that `--tmpfs`. Do not apply a blind mount if the application needs a
   host service (for example, some portal integrations).
3. Use a resolver configuration that never tries `resolve` (for example, a
   system-wide `/etc/nsswitch.conf` with `hosts: files dns`). This affects the
   whole host, not just the VPN namespace.
4. For qBittorrent, libtorrent uses its own DNS path and usually reads the
   namespace resolver directly. Confirm with the app's connection settings.

Also remember that a **DNS-over-HTTPS** query inside Firefox is still sent
through the WireGuard tunnel; the leak concern is host resolver sockets, not
encrypted DNS traffic.

### SELinux on Fedora

Check denials before changing policy:

```bash
getenforce
sudo ausearch -m avc -ts recent
sudo journalctl -t audit --since today | grep -i avc
```

The root `wgc`/`ip` operations typically run as `unconfined_t` when launched
from a normal desktop session. If you use a confined terminal, a container, or
a third-party policy, label and policy adjustments may be required. Do not set
SELinux to permissive permanently. Test with `sudo setenforce 0` only for
diagnosis, then re-enable and write a targeted policy or report the denial.

Running confined Flatpak applications in a namespace is a separate sandboxing
layer; their network permissions and portals can behave differently. Native
packages are the least surprising option for VPN isolation.

### Firewall and routing

The namespace has its own routing table, so host firewall rules for the
physical interface do not automatically govern the namespace. `wgc` configures
the tunnel and namespace routes. Do not add host routes into
`wgc_<profile>`; use the tunnel interface or `wgc` bridges instead.

### Lock timeout

If a launcher reports:

```text
Timed out waiting for reference lock ...
```

another process is holding an exclusive lock or a supervisor is in a slow
teardown. Inspect:

```bash
vpn-run --status
fuser -v /run/user/$(id -u)/vpn-run/locks/mullvad.ref.lock
cat /run/user/$(id -u)/vpn-run/logs/mullvad.log
```

Increase `VPN_RUN_LOCK_TIMEOUT` only if `wgc down` is legitimately slow. If a
process is wedged, `vpn-run --kill` is the safe recovery path.

### Manual recovery

```bash
vpn-run --kill
sudo /usr/local/bin/wgc kill mullvad
sudo ip netns list
sudo ip netns pids wgc_mullvad
```

If the namespace persists after all applications are gone:

```bash
sudo ip netns del wgc_mullvad
rm -rf /run/user/$(id -u)/vpn-run/state/mullvad
```

The lock files can be left in place; they carry no state. If you remove the
whole runtime directory, do it only after no `vpn-run` process is running.

### Desktop integration

Launch `vpn-run` from the graphical session that owns the application. If you
start it from a bare SSH shell, `DISPLAY`, `WAYLAND_DISPLAY`, `DBUS_*`, and
`XDG_RUNTIME_DIR` may be absent; GUI applications will fail even though the
tunnel is up. Use `vpn-run curl ...` for headless checks.

## Security notes

- The installer grants passwordless sudo only for the exact `wgc` and `ip`
  binaries, and only to `wheel`. Members of `wheel` are already administrative
  users on Fedora and Arch; this policy does not grant a new class of access.
- The Mullvad private key lives in `/etc/wireguard/<profile>.conf` with mode
  `0600`. The launcher never reads or logs it directly.
- Runtime directories are mode `0700`, lock/log/state files are mode `0600`,
  and symlinked runtime paths are rejected.
- The launcher refuses to run the target app as root. If invoked under sudo, it
  drops to the original user before starting `wgc`; `wgc exec` then uses
  `setpriv` for the final drop.
- The Firefox profile is isolated and mode `0700`.
- Downloaded `wgc` is fetched over HTTPS and syntax-checked. For a fully
  reproducible supply chain, pin the upstream commit and verify a checksum in
  your fork of this repository.
- The upstream `wgc` project is licensed under GPL-3.0-or-later; this
  repository installs it as an external dependency.
- The lock files are intentionally retained on teardown to avoid inode-split
  locking races; `uninstall.sh` removes the runtime root only after stopping
  tracked supervisors/namespaces.

## Uninstallation

```bash
sudo ./uninstall.sh
```

The uninstaller:

1. finds tracked supervisors from runtime state and from `/proc` even if a
   user runtime directory disappeared, then stops them;
2. calls `wgc kill` for each tracked namespace (with a direct `ip netns del`
   fallback);
3. removes `/usr/local/bin/vpn-run`;
4. removes `/etc/sudoers.d/vpn-run-nopasswd`;
5. removes installer-managed `/etc/wireguard/wgc_enable` (only if marked);
6. cleans `/run/user/*/vpn-run/`.

It asks before removing `/usr/local/bin/wgc` (default: keep). If you keep the
wgc script and plan to use it directly, recreate
`/etc/wireguard/wgc_enable` because the uninstaller removes the
installer-managed approval file. Use:

```bash
sudo ./uninstall.sh --keep-wgc
sudo ./uninstall.sh --remove-wgc
sudo ./uninstall.sh --yes
```

Packages and your WireGuard profiles under `/etc/wireguard` are intentionally
left intact. Remove them manually if they are no longer needed.
