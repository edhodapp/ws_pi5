# Hardware Test Tools — One-Time Setup

Commands to grant the hardware test tools raw-network capabilities so they
run without `sudo`. Run each `sudo setcap` command once from an outside
shell; no password prompts required after that.

After running these, restart any existing shell sessions so they pick up
the new capabilities.

## 1. Check current state (no sudo needed)

```bash
getcap /usr/bin/tcpdump
getcap /usr/bin/dumpcap
getcap /usr/sbin/ethtool
getcap /usr/bin/arping
```

Empty output means no caps set yet. If a tool is at a different path, find
it with `which <tool>` and substitute.

## 2. tcpdump

```bash
sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/tcpdump
```

Verify: `tcpdump -D` should list interfaces without complaining.

## 3. tshark (needs dumpcap, not tshark itself)

`tshark` delegates actual packet capture to `dumpcap`. Granting caps on
tshark does nothing — you need them on dumpcap:

```bash
sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/dumpcap
```

Verify: `tshark -D` should list interfaces without errors.

## 4. ethtool

ethtool is typically at `/usr/sbin/ethtool` on Ubuntu. Speed/duplex changes
need `cap_net_admin`:

```bash
sudo setcap cap_net_admin=eip /usr/sbin/ethtool
```

If it's at `/sbin/ethtool` instead (`which ethtool`), use that path.

Verify: `ethtool <iface>` shows NIC info, `ethtool -s <iface> speed 100
duplex full autoneg off` works without permission errors.

## 5. arping

```bash
sudo setcap cap_net_raw=eip /usr/bin/arping
```

Verify: `arping -c 1 10.0.0.2` (if Pi is up) completes without complaint.

## 6. scapy (Python)

Scapy is pure Python — no binary to setcap. It uses raw sockets (`AF_PACKET`
or `SOCK_RAW`) which require `cap_net_raw` on the **Python interpreter**
doing the sending.

### Install scapy in the venv

```bash
cd /home/ed/ws_pi5
.venv/bin/pip install scapy
```

### Grant cap_net_raw to the venv's Python interpreter

The venv's `bin/python3` is a symlink to the system `/usr/bin/python3`.
`setcap` can't be applied to a symlink, and you **should not** apply it
to `/usr/bin/python3` directly (too broad — every Python script would
gain raw socket power).

The clean solution: copy the system python3 into the venv as a real file,
then setcap it:

```bash
cd /home/ed/ws_pi5/.venv/bin

# Verify it's a symlink:
ls -l python3

# Replace the symlink with a real copy:
rm python3 python3.12  # or whatever version shows
cp /usr/bin/python3 python3
ln -s python3 python3.12

# Grant the cap:
sudo setcap cap_net_raw=eip /home/ed/ws_pi5/.venv/bin/python3
```

Only scripts run via `./.venv/bin/python3` (or with that venv activated)
get the cap. The system python stays clean.

**Caveat:** Some distros strip caps from binaries on `noexec`/`nosuid`
mounts. `/home` should be fine, but verify with `getcap
/home/ed/ws_pi5/.venv/bin/python3` after the setcap.

### Verify scapy can open raw sockets

```bash
cd /home/ed/ws_pi5
./.venv/bin/python3 -c 'from scapy.all import *; print(conf.L2socket)'
```

Should print the L2 socket class name without a permission error.

## 7. Final verification

```bash
getcap /usr/bin/tcpdump /usr/bin/dumpcap /usr/sbin/ethtool /usr/bin/arping /home/ed/ws_pi5/.venv/bin/python3
tcpdump -D
tshark -D
ethtool <iface>
arping -c 1 10.0.0.2
./.venv/bin/python3 -c 'from scapy.all import *; print(conf.L2socket)'
```

If any step still complains about permissions, check that `getcap` shows
the expected caps on the binary. Common gotchas:

- Applied to a symlink instead of the real file (caps get silently dropped)
- Wrong binary path (`which <tool>` to confirm)
- Python interpreter was upgraded and the setcap'd copy is stale
- Binary on a `nosuid` mount (check with `mount | grep <mountpoint>`)

## 8. Persistence — surviving reboots, package upgrades, and new shells

File capabilities are stored as extended attributes (xattrs) in the
`security.capability` namespace, directly on the binary's inode. Once
`setcap` succeeds, the cap is part of the file itself. The kernel
checks it at every `execve()`, so:

- **Reboots:** Caps persist automatically. No service, config file, or
  startup script needed — ext4/xfs/btrfs store xattrs alongside the
  file, and the kernel reads them on every exec.
- **New shells, ssh sessions, cron jobs, tmux panes:** All see the
  caps immediately. There is no per-shell state. The kernel grants the
  cap when the binary is exec'd, regardless of which shell or user
  invoked it. `bash`, `zsh`, `sh -c`, a Python `subprocess` call —
  same result.
- **Existing shells:** Strictly speaking, don't need to be restarted.
  The next `tcpdump` invocation picks up the caps because the kernel
  checks them on `execve()`, not when bash started. (If you renamed
  or moved the binary, `hash -r` clears bash's path cache so it
  re-resolves on the next call.)
- **No PATH or env changes needed.** Caps live on the binary, not in
  your shell environment. Nothing to add to `~/.bashrc`.

### When caps get silently lost

These are the failure modes to watch for. None of them produce a
warning — the binary just starts failing with `Operation not permitted`
again.

- **Package upgrades.** `sudo apt upgrade tcpdump` replaces the binary
  with a fresh copy from the `.deb` and your `setcap` is gone. Same for
  `wireshark-common` (which owns `dumpcap`), `ethtool`, and `iputils-arping`.
  Re-run `setcap` after any upgrade that touches these packages. To check
  what was recently touched:

  ```bash
  grep -E 'tcpdump|wireshark|ethtool|iputils' /var/log/apt/history.log
  ```

- **Copying the binary.** Plain `cp` does NOT preserve xattrs. Use
  `cp --preserve=xattr` (or `cp -a` for archive mode). `mv` within the
  same filesystem preserves them; across filesystems behaves like `cp`.

- **`nosuid` mount option.** A filesystem mounted with `nosuid` strips
  file capabilities at exec time. Check with `mount | grep <mountpoint>`.
  `/home` and `/usr` are normally fine; removable media and some
  container bind-mounts are not.

- **Filesystem can't store xattrs.** ext4/xfs/btrfs do. FAT, exFAT, and
  most network filesystems (NFSv3, SMB) do not — `setcap` will appear
  to succeed but `getcap` returns nothing.

- **Python venv recreated.** If you `rm -rf .venv && python3 -m venv .venv`,
  the setcap'd `python3` is gone. Redo step 6.

- **Python system upgrade.** If `apt` upgrades `/usr/bin/python3` to a
  new minor version, the copy in the venv is now stale (different
  stdlib). You'll want to recreate the venv copy and re-`setcap`.

### Making re-application painless

The cleanest workflow is an idempotent setup script you can re-run any
time something stops working. `setcap` is safe to run repeatedly —
applying the same caps twice is a no-op. Save this as
`hw_test/bin/setup-caps.sh`:

```bash
#!/bin/bash
set -e
sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/tcpdump
sudo setcap cap_net_raw,cap_net_admin=eip /usr/bin/dumpcap
sudo setcap cap_net_admin=eip                /usr/sbin/ethtool
sudo setcap cap_net_raw=eip                  /usr/bin/arping
sudo setcap cap_net_raw=eip                  /home/ed/ws_pi5/.venv/bin/python3
getcap /usr/bin/tcpdump /usr/bin/dumpcap /usr/sbin/ethtool \
       /usr/bin/arping /home/ed/ws_pi5/.venv/bin/python3
```

`chmod +x hw_test/bin/setup-caps.sh` and run it after any system update,
venv rebuild, or unexplained `Operation not permitted` from these tools.

### Sanity check after a reboot or upgrade

```bash
getcap /usr/bin/tcpdump /usr/bin/dumpcap /usr/sbin/ethtool \
       /usr/bin/arping /home/ed/ws_pi5/.venv/bin/python3
```

Each line should show the expected caps. Any blank line means that
binary lost its caps and needs a re-run of `setup-caps.sh`.

## Notes

- `=eip` means the cap is Effective, Inheritable, and Permitted — the
  minimum to actually use it.
- `cap_net_raw` alone is enough for packet capture and sending.
- `cap_net_admin` is additionally needed for interface changes (speed,
  duplex, promiscuous mode, MTU).
- These caps are a scoped alternative to `sudo`: the binary can do one
  specific privileged operation, nothing else.
- File caps grant the capability to **anyone who can execute the
  binary**, not just you. On a single-user dev machine this is fine;
  on a shared host, restrict execute permission with group ownership
  (`chgrp netcap /usr/bin/tcpdump && chmod 750 /usr/bin/tcpdump`) and
  add yourself to the group.
