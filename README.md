# mullrun

`mullrun` is an on-demand, reference-counted, auto-closing launcher for
applications that must use a Mullvad WireGuard tunnel. It wraps
[`wgc`](https://github.com/colemar/wgc), which builds a dedicated Linux network
namespace for each WireGuard profile. The application never sees the host's
physical network interfaces; if the tunnel disappears, the namespace and the
application's network path disappear with it.

The repository is named **mullrun**; the installed command is **`mullrun`**.

```
$ mullrun qbittorrent
$ mullrun firefox
$ mullrun curl https://am.i.mullvad.net/connected
$ mullrun --status
$ mullrun --kill
```

## Contents

1. [Architecture](#architecture)
2. [Why a network namespace is a killswitch](#why-a-network-namespace-is-a-killswitch)
3. [Concurrency and crash-proof cleanup](#concurrency-and-crash-proof-cleanup)
4. [Installation](#installation)
5. [Mullvad WireGuard setup](#mullvad-wireguard-setup)
6. [Usage](#usage)
7. [Inter-Namespace Service Bridging (socat)](#inter-namespace-service-bridging-socat)
8. [qBittorrent: secondary interface binding](#qbittorrent-secondary-interface-binding)
9. [Runtime layout and configuration](#runtime-layout-and-configuration)
10. [Testing](#testing)
11. [Troubleshooting](#troubleshooting)
12. [Security notes](#security-notes)
13. [Uninstallation](#uninstallation)

---

## Architecture

```
                       desktop session (UID 1000)
 ┌──────────────────────────────────────────────────────────────────────┐
 │  shell:  mullrun firefox                                             │
 │            │                                                         │
 │            ▼                                                         │
 │  ┌─────────────────────┐    shared flock     ┌────────────────────┐  │
 │  │ mullrun launcher    │────────────────────▶│ <vpn>.ref.lock     │  │
 │  │ (one per app)       │                     └────────────────────┘  │
 │  │  - holds ref lock   │                              ▲              │
 │  │  - registers PID    │                              │ exclusive    │
 │  │  - waits for app    │                     ┌────────┴───────────┐  │
 │  └─────────┬───────────┘                     │ detached supervisor│  │
 │            │ sudo -n wgc exec <vpn> <cmd>    │ - probes ref lock  │  │
 │            ▼                                 │ - reads netns PIDs │  │
 │  ┌──────────────────────────────────────┐    │ - grace timer      │  │
 │  │ wgc_<vpn> network namespace          │    │ - wgc down / kill  │  │
 │  │                                      │    └────────┬───────────┘  │
 │  │  lo                                  │             │              │
 │  │  wgc_<vpn> (WireGuard interface)     │             │ sudo -n wgc  │
 │  │    default route → tunnel            │             ▼              │
 │  │  application (setpriv → UID 1000)    │       teardown after grace │
 │  └──────────────────────────────────────┘                            │
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
  explicitly test with `mullrun curl -6 https://ifconfig.co` and verify failure.

Use `mullrun sh -c 'ip -brief address; ip route; ip -6 route'` to inspect what
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
`firefox`, `firefox-bin`, or `firefox-esr`, `mullrun`:

- adds `--no-remote` (unless already supplied); and
- adds `--profile ~/.local/share/mullrun/firefox-profile` (unless the caller
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

`mullrun` applies missing session defaults and does one `execve` after a
possible root-to-user drop so the final environment is visible in
`/proc/PID/environ`, which is what `wgc exec` reads. The target app runs as the
invoking user, never as root. Running `sudo mullrun` is explicitly refused
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
`/usr/local/bin/mullrun`, creates `/etc/wireguard/wgc_enable`, installs
`/etc/mullrun/bridges.conf.example`, and writes
`/etc/sudoers.d/mullrun-nopasswd` after validating it with `visudo -cf`.

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

`/etc/sudoers.d/mullrun-nopasswd` contains passwordless entries for the
`wheel` group only, restricted to:

- `/usr/local/bin/wgc`
- the installed `ip` path(s) (`/usr/bin/ip`, `/sbin/ip`, etc.)

It does **not** grant general root access. The file is validated with
`visudo -cf` before it is moved into `/etc/sudoers.d`; a validation failure
leaves the old configuration untouched.

### Manual inspection after installation

```bash
command -v mullrun wgc ip socat
sudo visudo -cf /etc/sudoers.d/mullrun-nopasswd
sudo /usr/local/bin/wgc req
ls -ld /etc/wireguard /etc/mullrun
cat /etc/mullrun/bridges.conf.example
```

## Mullvad WireGuard setup

1. Sign in at <https://mullvad.net/en/account/wireguard-config>.
2. Generate a WireGuard key pair for the device.
3. Choose a server (or leave the automatic selection if offered by the page).
4. Download the generated archive file.
5. Choose the desired configuration file (for instance `co-cit-wg-001.conf`)
6. Install it with root-only permissions:

   ```bash
   sudo install -d -o root -g root -m 0755 /etc/wireguard
   sudo chmod o+rx
   sudo install -o root -g root -m 0600 ./co-cit-wg-001.conf /etc/wireguard/mullvad.conf
   sudo chmod 600 /etc/wireguard/mullvad.conf
   ```

7. Validate the configuration with `wgc`:

   ```bash
   sudo /usr/local/bin/wgc parse mullvad
   ```

8. Start a test through the namespace:

   ```bash
   mullrun curl https://am.i.mullvad.net/connected
   ```

   A connected response looks like:

   ```text
   You are connected to Mullvad (server <name>). Your IP address is <address>
   ```

9. Compare with the host (only meaningful if the host is not already on a
   Mullvad tunnel):

   ```bash
   curl https://am.i.mullvad.net/connected
   ```

   The two exit IPs should differ.

Additional profiles are supported by naming the config
`/etc/wireguard/<profile>.conf`:

```bash
sudo install -m 600 ~/Downloads/office.conf /etc/wireguard/office.conf
mullrun -v office curl https://am.i.mullvad.net/connected
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
  mullrun [OPTIONS] <COMMAND> [ARGS...]
  mullrun --status [-v NAME]
  mullrun --kill [-v NAME]
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
mullrun qbittorrent
mullrun firefox
```

Firefox receives an isolated profile automatically. For a different profile
name, supply `--profile` yourself; `--no-remote` is still added.

### CLI tools

```bash
mullrun curl ifconfig.me
mullrun curl https://am.i.mullvad.net/connected
mullrun sh -c 'ip -brief address; ip route; getent hosts example.com'
```

### Alternative profile

```bash
mullrun -v office firefox
mullrun --vpn=office --status
```

### Status

```bash
mullrun --status
```

Shows:

- active/inactive state and namespace name
- up time and exact kernel reference-lock count
- supervisor PID and runtime path
- `wgc state` connection details
- **Active Bridges**: configured direction, state, relay PIDs, and endpoints
- formatted PIDs in the namespace
- per-client reference records

The status command is read-only from the tunnel's perspective; it does not
start or stop anything.

### Kill / manual recovery

```bash
mullrun --kill
mullrun --kill -v office
```

`--kill` stops the supervisor, terminates all bridge relays, calls `wgc kill`
(which terminates every process in the namespace and removes the
interface/namespace), verifies that the namespace is gone, and removes
transient runtime state. It does not touch other VPN profiles or the host
network.

### Grace period

The grace period prevents rapid tunnel flapping when you close one app and
start another immediately.

```bash
mullrun --grace 15 qbittorrent
VPN_RUN_GRACE_PERIOD=10 mullrun firefox
```

The supervisor reads the latest grace value from the runtime state file; a new
invocation updates it. `0` means "tear down as soon as the supervisor observes
zero references and zero processes".

## Inter-Namespace Service Bridging (socat)

### Why a netns `127.0.0.1` is not the host `127.0.0.1`

`CLONE_NEWNET` gives the namespace its own loopback interface and routing
table. An application inside `wgc_mullvad` cannot connect to Jackett on the
host at `127.0.0.1:9117`: inside the namespace that address belongs to the
namespace's own loopback.

mullrun bridges the two loopback worlds through the filesystem, which is shared
across namespaces. `socat` relays carry bytes over a private Unix domain socket:

```text
host-to-netns (inward)
  qBittorrent search plugin
    -> 127.0.0.1:<netns_port> inside wgc_<vpn>
    -> unprivileged socat listener in the namespace
    -> Unix socket (mode 0600, in $XDG_RUNTIME_DIR/mullrun/bridges/<vpn>/)
    -> unprivileged socat relay on the host
    -> 127.0.0.1:<host_port> (for example Jackett)

netns-to-host (outward)
  host browser
    -> 127.0.0.1:<host_port>
    -> unprivileged socat listener on the host
    -> Unix socket
    -> unprivileged socat relay in the namespace
    -> 127.0.0.1:<netns_port> (for example qBittorrent WebUI)
```

No `veth`, bridge, route, or iptables rule is created between the host and the
namespace. The namespace's only network path is still the WireGuard interface;
the Unix socket is a filesystem conduit, not a network route.

Both relay processes run as the invoking user. The namespace-side relay is
started with `wgc exec`, which drops root privileges with `setpriv` before
`socat` runs.

### Configuration locations and precedence

Bridge definitions use INI syntax and are read from:

1. `$XDG_CONFIG_HOME/mullrun/bridges.conf`
   (or `~/.config/mullrun/bridges.conf`)
2. `/etc/mullrun/bridges.conf`

A section in the user file overrides a section with the same name in the system
file. `/etc/mullrun/bridges.conf.example` is installed as a documented template;
the installer never overwrites an existing `/etc/mullrun/bridges.conf`.

```ini
[jackett]
vpn = mullvad
direction = host-to-netns
host_port = 9117
netns_port = 9117
host_addr = 127.0.0.1
netns_addr = 127.0.0.1
enabled = true

[qbittorrent-webui]
vpn = mullvad
direction = netns-to-host
host_port = 8080
netns_port = 8080
enabled = false
```

| Key | Required | Meaning |
| --- | --- | --- |
| `vpn` | yes | Profile name, or `*` for all profiles |
| `direction` | yes | `host-to-netns` or `netns-to-host` |
| `host_port` | yes | Port on the host side (1–65535) |
| `netns_port` | yes | Port inside the namespace (1–65535) |
| `host_addr` | no | Host loopback address; default `127.0.0.1` |
| `netns_addr` | no | Namespace loopback address; default `127.0.0.1` |
| `enabled` | no | `true`/`false`; default `true` |
| `unsafe` | no | Permit non-loopback addresses; default `false` |

Addresses must be valid IPv4 or IPv6 loopback addresses. `0.0.0.0`, `::`, and
external interface addresses are rejected unless the section explicitly sets
`unsafe = true`. Avoid that override unless you have deliberately audited the
exposure; it weakens the zero-leak model.

### Jackett tutorial (host service available inside the VPN)

1. Confirm Jackett is listening on host loopback:

   ```bash
   curl -fsS http://127.0.0.1:9117/ >/dev/null && echo "Jackett is up"
   ```

2. Create the per-user bridge configuration:

   ```bash
   mkdir -p ~/.config/mullrun
   cat > ~/.config/mullrun/bridges.conf <<'EOF'
   [jackett]
   vpn = mullvad
   direction = host-to-netns
   host_port = 9117
   netns_port = 9117
   host_addr = 127.0.0.1
   netns_addr = 127.0.0.1
   enabled = true
   EOF
   ```

3. Start or restart qBittorrent through mullrun:

   ```bash
   mullrun qbittorrent
   ```

   The bridge starts with the namespace. If the VPN is already running, the
   supervisor reconciles bridge changes within its monitoring interval, or you
   can restart the app after applying the configuration.

4. Verify from inside the namespace:

   ```bash
   mullrun curl http://127.0.0.1:9117/
   ```

   This `curl` runs in the same `wgc_mullvad` namespace, so it exercises the
   same path qBittorrent uses.

5. In qBittorrent's search plugin configuration, use:

   ```text
   http://127.0.0.1:9117
   ```

   with your Jackett API key. No host IP, hostname, or route is needed.

6. Inspect the bridge:

   ```bash
   mullrun --status
   ```

   The **Active Bridges** section shows the relay PIDs, direction, state, and
   both endpoints.

### Exposing qBittorrent WebUI to the host browser

qBittorrent's WebUI listens inside the namespace. Enable an outward bridge:

```ini
[qbittorrent-webui]
vpn = mullvad
direction = netns-to-host
host_port = 8080
netns_port = 8080
host_addr = 127.0.0.1
netns_addr = 127.0.0.1
enabled = true
```

Restart qBittorrent under mullrun and browse to:

```text
http://127.0.0.1:8080
```

The host listener is bound to loopback only. Ensure qBittorrent's WebUI is
listening on the namespace loopback/port you configured; if it is disabled or
bound to a different namespace address, the host connection will be refused.

### Security model

- **Loopback by default:** all TCP listeners bind `127.0.0.1` or `::1`.
  Non-loopback requires an explicit `unsafe = true` per bridge.
- **Private conduit:** sockets live in
  `$XDG_RUNTIME_DIR/mullrun/bridges/<vpn>/`, directory mode `0700`, owned by the
  invoking UID. Socket files are mode `0600`; symlinked paths are rejected.
- **No privilege escalation:** both `socat` processes run as the unprivileged
  user. `wgc exec` performs the namespace-side privilege drop.
- **No route pollution:** mullrun never creates `veth` pairs, host routes, or
  firewall rules for bridges. The namespace's data path remains WireGuard-only.
- **Credential scope:** a bridge exposes only the configured loopback port to
  processes that can access the user's runtime directory and namespace. It does
  not bind a LAN interface.

### Bridge lifecycle

- Bridges are loaded from configuration when the namespace is brought up.
- Both relay PIDs, start times, endpoints, and the socket path are written to
  `state/<vpn>/bridges.json`.
- The supervisor checks bridge health while applications are running and
  restarts a missing or crashed configured bridge.
- Teardown, `--kill`, emergency cleanup, and uninstall terminate relays with
  `SIGTERM`, wait a short grace period, then use `SIGKILL`, unlink the socket,
  and remove the transient bridge directory.
- The supervisor explicitly excludes managed namespace-side relay PIDs from the
  application PID set, so a bridge cannot prevent idle teardown.

### Troubleshooting bridges

**Port already in use**

The bridge is skipped and the application still launches. `mullrun --status`
shows an `error` state with the reason. Find the listener:

```bash
ss -ltnp 'sport = :9117'
```

Change `host_port` or `netns_port`, then restart the bridge/app. For inward
bridges, the namespace-side port is the listener; it must be free inside
`wgc_<vpn>`.

**Host service is not running**

The host-side relay can still listen, but a connection through the bridge will
be refused. Verify on the host:

```bash
curl -fsS http://127.0.0.1:9117/ >/dev/null && echo up
```

**Configuration rejected**

Run `mullrun --status` and read the warning. Common causes:

- non-loopback `host_addr`/`netns_addr` without `unsafe = true`
- port outside `1..65535`
- invalid `direction`
- unknown keys
- group/world-writable or symlinked configuration file
- malformed INI

**Where are the logs?**

```text
/run/user/$(id -u)/mullrun/bridges/<vpn>/<bridge>.host.log
/run/user/$(id -u)/mullrun/bridges/<vpn>/<bridge>.netns.log
```

The supervisor log at `/run/user/$(id -u)/mullrun/logs/<vpn>.log` records bridge
starts, failures, restarts, and teardown.

**Recovery**

```bash
mullrun --kill
```

This removes the namespace, bridge relays, sockets, and transient state. A new
launch re-reads the configuration.

### IPv6

Use unbracketed IPv6 addresses in the INI file:

```ini
host_addr = ::1
netns_addr = ::1
```

The generated socat addresses use the required `TCP6:[::1]:port` and
`TCP6-LISTEN:port,bind=[::1]` syntax internally.

## qBittorrent: secondary interface binding

The application is already inside a namespace with only the WireGuard
interface. As a **secondary defense**, bind qBittorrent explicitly to that
interface:

1. Start it with `mullrun qbittorrent`.
2. Open **Tools → Options → Advanced**.
3. Set **Network Interface** to `wgc_mullvad` (or `wgc_<your-profile>`).
4. Apply and restart qBittorrent inside `mullrun`.

Inside the namespace, qBittorrent only sees `lo` and `wgc_<profile>`. Binding to
the WireGuard interface means that even a future routing change cannot make it
use loopback or a newly exposed interface. This is defense in depth, not a
replacement for the namespace.

If qBittorrent is installed as a Flatpak, verify that the sandbox exposes the
namespace interface it needs; Flatpak's sandboxing can hide network details.
Native packages are simplest.

### Ports and incoming connections

For host-loopback access to a qBittorrent WebUI or another namespace service,
use the mullrun socat bridge described above. Do not add a host route into the
namespace. For WAN-side port forwarding defined in the Mullvad profile, use
`wgc`'s `[WGC]` bridge feature; mullrun does not replace that mechanism.

## Runtime layout and configuration

Per-user runtime state lives under `$XDG_RUNTIME_DIR/mullrun` (normally
`/run/user/<uid>/mullrun`, mode `0700`):

```text
/run/user/<uid>/mullrun/
├── locks/
│   ├── <profile>.ref.lock
│   ├── <profile>.lifecycle.lock
│   └── <profile>.supervisor.lock
├── bridges/
│   └── <profile>/           # transient; removed on teardown
│       ├── <bridge>.sock    # Unix conduit, mode 0600
│       ├── <bridge>.host.log
│       └── <bridge>.netns.log
├── logs/
│   └── <profile>.log
└── state/
    └── <profile>/           # transient; removed on teardown
        ├── state.json
        ├── supervisor.pid
        ├── bridges.json
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

`VPN_RUN_TEST_MODE`, `VPN_RUN_WGC`, `VPN_RUN_IP`, `VPN_RUN_SOCAT`,
`VPN_RUN_RUNTIME_DIR`, `VPN_RUN_BRIDGE_CONFIG_USER`, and
`VPN_RUN_BRIDGE_CONFIG_SYSTEM` are test-harness hooks. They are only honored
when `VPN_RUN_TEST_MODE=1` and never enable sudo. Do not set them in normal use.

## Testing

The lifecycle test is hermetic: it uses fake `wgc`, `ip`, and `socat` binaries,
a private temporary runtime directory, and no root, firewall changes, real
namespaces, or network access.

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
- bridge configuration parsing, loopback enforcement, and clear rejection of
  invalid ports/directions/addresses
- user-config-over-system-config precedence
- bridge relay startup, socket/Directory permissions, status reporting, and
  teardown when the namespace closes
- supervisor immunity from managed bridge PIDs
- bridge cleanup on `--kill`
- non-fatal bridge startup failures such as host port conflicts
- `--kill` cleanup
- launcher `SIGKILL` with a surviving orphan app (PID-monitored teardown)
- signal forwarding from the launcher to the application
- supervisor crash replacement
- desktop environment preservation and non-root UID execution
- Firefox `--no-remote`/isolated-profile augmentation

Run individual static checks manually:

```bash
python3 -m py_compile bin/mullrun
shellcheck install.sh uninstall.sh tests/test_lifecycle.sh
flake8 --max-line-length=120 bin/mullrun
```

`ruff check --select E,F --line-length 120 bin/mullrun` is an equivalent
modern alternative when flake8 is unavailable.

## Troubleshooting

### `sudo: a password is required` / `no tty present`

The sudoers drop-in is missing, invalid, or your user is not in `wheel`.

```bash
id -nG
sudo visudo -cf /etc/sudoers.d/mullrun-nopasswd
sudo visudo -c
```

Re-run `sudo ./install.sh` after adding the user to `wheel` and logging back in.
The launcher deliberately uses `sudo -n` so background supervisors fail fast
instead of hanging on a password prompt.

### `wgc not found` or `wgc nup` failure

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
does not need `resolvconf`; the warning is not fatal for `mullrun`.

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
tail -n 100 /run/user/$(id -u)/mullrun/logs/mullvad.log
mullrun --status
sudo ip netns pids wgc_mullvad
sudo wgc state mullvad
```

If a daemonized child remains in the namespace, the supervisor intentionally
keeps the namespace alive. Use `mullrun --kill` to force it down. If the
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
mullrun sh -c 'strace -f -e trace=connect getent hosts example.com' 2>&1 | grep -E 'resolve|53'

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

   mullrun bwrap --dev-bind / / \
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
Timed out waiting for reference lock
```

another process is holding an exclusive lock or a supervisor is in a slow
teardown. Inspect:

```bash
mullrun --status
fuser -v /run/user/$(id -u)/mullrun/locks/mullvad.ref.lock
cat /run/user/$(id -u)/mullrun/logs/mullvad.log
```

Increase `VPN_RUN_LOCK_TIMEOUT` only if `wgc down` is legitimately slow. If a
process is wedged, `mullrun --kill` is the safe recovery path.

### Manual recovery

```bash
mullrun --kill
sudo /usr/local/bin/wgc kill mullvad
sudo ip netns list
sudo ip netns pids wgc_mullvad
```

If the namespace persists after all applications are gone:

```bash
sudo ip netns del wgc_mullvad
rm -rf /run/user/$(id -u)/mullrun/state/mullvad
```

The lock files can be left in place; they carry no state. If you remove the
whole runtime directory, do it only after no `mullrun` process is running.

### Desktop integration

Launch `mullrun` from the graphical session that owns the application. If you
start it from a bare SSH shell, `DISPLAY`, `WAYLAND_DISPLAY`, `DBUS_*`, and
`XDG_RUNTIME_DIR` may be absent; GUI applications will fail even though the
tunnel is up. Use `mullrun curl https://am.i.mullvad.net/connected` for headless checks.

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
- Bridge relays bind loopback by default, use mode `0700` directories and mode
  `0600` Unix sockets, and run as the invoking user on both sides. Explicit
  `unsafe = true` is required for any non-loopback binding.
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
2. terminates host and namespace-side `socat` bridge relay processes and cleans
   transient bridge sockets/logs;
3. calls `wgc kill` for each tracked namespace (with a direct `ip netns del`
   fallback);
4. removes `/usr/local/bin/mullrun`;
5. removes `/etc/sudoers.d/mullrun-nopasswd`;
6. removes installer-managed `/etc/wireguard/wgc_enable` (only if marked);
7. removes the example `/etc/mullrun/bridges.conf.example`, warns if a user
   `/etc/mullrun/bridges.conf` remains, and cleans `/run/user/*/mullrun/`.

It asks before removing `/usr/local/bin/wgc` (default: keep). If you keep the
wgc script and plan to use it directly, recreate
`/etc/wireguard/wgc_enable` because the uninstaller removes the
installer-managed approval file. Use:

```bash
sudo ./uninstall.sh --keep-wgc
sudo ./uninstall.sh --remove-wgc
sudo ./uninstall.sh --yes
```

Packages, your WireGuard profiles under `/etc/wireguard`, and user bridge
configuration under `/etc/mullrun/bridges.conf` are intentionally left intact.
Remove them manually if they are no longer needed.
