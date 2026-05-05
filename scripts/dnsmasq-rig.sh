#!/usr/bin/env bash
# dnsmasq-rig.sh — start / stop / status the ws_pi5 hardware test
# rig's dnsmasq instance.
#
# Runs as the invoking user. Requires the one-time `make rig-setup`
# (cap_net_bind_service + cap_net_admin on /usr/sbin/dnsmasq).
#
# Subcommands:
#   start [conf]   — launch dnsmasq with the given conf file
#                    (default /tmp/dnsmasq-wspi5.conf).
#   stop           — SIGTERM the running instance.
#   restart [conf] — stop + start, optionally swapping the conf.
#   status         — print pid, listening sockets, lease count.
#
# Conf, pid, and (depending on the conf) log file paths default to
# /tmp/dnsmasq-wspi5.{conf,pid,log}. The lease file is wherever
# dnsmasq's default puts it on this distro — usually
# /var/lib/misc/dnsmasq.leases (which is world-readable; the rig
# resolver in scripts/hw_tests.sh reads it directly).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DNSMASQ=/usr/sbin/dnsmasq
# Default conf lives in the repo so the rig is reproducible from a
# fresh checkout; runtime state (pid, log, leases) lives in /tmp
# per the conf file's directives.
CONF_DEFAULT="$SCRIPT_DIR/dnsmasq-wspi5.conf"
PID_FILE=/tmp/dnsmasq-wspi5.pid
# Default lease path matches what /tmp/dnsmasq-wspi5.conf sets via
# `dhcp-leasefile=`. The system default (/var/lib/misc/dnsmasq.leases)
# is root-owned and unwritable when dnsmasq runs as the operator.
LEASES_DEFAULT=/tmp/dnsmasq-wspi5.leases

require_caps() {
    # getcap prints the cap set in a libcap-canonical order with
    # either `=ep` or `+ep`, both equivalent. Check by membership
    # plus the e+p suffix instead of string-comparing the line.
    local raw
    raw="$(getcap "$DNSMASQ" 2>/dev/null)"
    if [ -n "$raw" ] \
       && echo "$raw" | grep -q 'cap_net_bind_service' \
       && echo "$raw" | grep -q 'cap_net_admin' \
       && echo "$raw" | grep -q 'cap_net_raw' \
       && echo "$raw" | grep -qE '[=+][ip]*e[ip]*p[ip]*( |$)'; then
        return 0
    fi
    echo "dnsmasq-rig: $DNSMASQ missing required caps" >&2
    echo "  getcap: ${raw:-(none)}" >&2
    echo "  needed: cap_net_bind_service + cap_net_admin + cap_net_raw" \
         "(effective + permitted)" >&2
    echo "Run 'make rig-setup' to apply." >&2
    return 1
}

dnsmasq_pid() {
    if [ -r "$PID_FILE" ]; then
        cat "$PID_FILE"
    fi
}

is_running() {
    local pid
    pid="$(dnsmasq_pid)"
    [ -n "$pid" ] || return 1
    # /proc/$pid/comm is readable regardless of UID, so this works
    # whether the existing dnsmasq is root-owned (sudo'd at session
    # start) or running as us. kill -0 was the obvious choice but
    # returns EPERM on a root-owned process and gives a false "not
    # running" reading.
    [ -r "/proc/$pid/comm" ] && [ "$(cat /proc/$pid/comm)" = "dnsmasq" ]
}

# is_ours — is the running dnsmasq owned by the current user? If
# not, the launcher's stop/restart can't signal it cleanly.
is_ours() {
    local pid
    pid="$(dnsmasq_pid)"
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

cmd="${1:-status}"
shift || true

case "$cmd" in
    start)
        require_caps
        local_conf="${1:-$CONF_DEFAULT}"
        if [ ! -r "$local_conf" ]; then
            echo "dnsmasq-rig: conf $local_conf missing" >&2
            exit 1
        fi
        if is_running; then
            if is_ours; then
                echo "dnsmasq-rig: already running (pid $(dnsmasq_pid))"
                exit 0
            fi
            pid="$(dnsmasq_pid)"
            uid="$(stat -c '%U' /proc/$pid 2>/dev/null || echo unknown)"
            echo "dnsmasq-rig: existing dnsmasq (pid $pid, owner $uid) is" \
                 "not ours" >&2
            echo "  Stop it manually and re-run start. For a sudo'd" \
                 "instance:" >&2
            echo "    sudo kill $pid" >&2
            exit 1
        fi
        # Clear stale runtime files we can't reuse. A previous
        # sudo-launched dnsmasq may have left log / lease / pid
        # files owned by 'nobody' or root that we can read but not
        # write. Removing them here is idempotent for the normal
        # case (we own them, rm is a no-op if absent) and recovers
        # the post-sudo case without a separate cleanup step. Bail
        # if we can't remove (likely means a dnsmasq we don't see
        # is still holding the file open).
        for f in /tmp/dnsmasq-wspi5.log /tmp/dnsmasq-wspi5.leases \
                 /tmp/dnsmasq-wspi5.pid; do
            if [ -e "$f" ] && [ ! -w "$f" ]; then
                if ! rm -f "$f" 2>/dev/null; then
                    echo "dnsmasq-rig: stale $f is owned by another user" \
                         "and rm failed" >&2
                    echo "  sudo rm $f" >&2
                    exit 1
                fi
            fi
        done
        # --user / --group keep dnsmasq running as us instead of
        # trying to drop to 'nobody' (the default), which would fail
        # because we don't start as root. Caps from setcap let us
        # bind UDP/67 without sudo.
        "$DNSMASQ" --conf-file="$local_conf" \
                   --pid-file="$PID_FILE" \
                   --user="$USER" --group="$(id -gn)"
        # dnsmasq backgrounds itself by default; the pid file is
        # written before exec returns, so we can read it here.
        sleep 0.1
        echo "dnsmasq-rig: started (pid $(dnsmasq_pid)) using $local_conf"
        ;;
    stop)
        if ! is_running; then
            echo "dnsmasq-rig: not running"
            rm -f "$PID_FILE"
            exit 0
        fi
        if ! is_ours; then
            pid="$(dnsmasq_pid)"
            uid="$(stat -c '%U' /proc/$pid 2>/dev/null || echo unknown)"
            echo "dnsmasq-rig: dnsmasq (pid $pid, owner $uid) is not" \
                 "ours — refusing to signal." >&2
            echo "  For a sudo'd instance:  sudo kill $pid" >&2
            exit 1
        fi
        pid="$(dnsmasq_pid)"
        kill "$pid"
        for _ in $(seq 1 20); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
            echo "dnsmasq-rig: did not exit cleanly, sending SIGKILL" >&2
            kill -9 "$pid" || true
        fi
        rm -f "$PID_FILE"
        echo "dnsmasq-rig: stopped"
        ;;
    restart)
        "$0" stop
        "$0" start "$@"
        ;;
    status)
        if ! is_running; then
            echo "dnsmasq-rig: not running"
            exit 1
        fi
        pid="$(dnsmasq_pid)"
        uid="$(stat -c '%U' /proc/$pid 2>/dev/null || echo unknown)"
        if is_ours; then
            echo "dnsmasq-rig: running (pid $pid, ours)"
        else
            echo "dnsmasq-rig: running (pid $pid, owner $uid — not ours)"
        fi
        ss -ulnp 2>/dev/null \
            | awk -v p="$pid" '$0 ~ "pid="p {print "  " $0}' \
            || true
        if [ -r "$LEASES_DEFAULT" ]; then
            n=$(wc -l < "$LEASES_DEFAULT")
            echo "  leases: $n in $LEASES_DEFAULT"
        fi
        ;;
    *)
        echo "Usage: $0 {start [conf]|stop|restart [conf]|status}" >&2
        exit 1
        ;;
esac
