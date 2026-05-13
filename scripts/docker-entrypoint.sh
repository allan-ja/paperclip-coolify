#!/bin/sh
set -e

# Capture runtime UID/GID from environment variables, defaulting to 1000
PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}

# Adjust the node user's UID/GID if they differ from the runtime request
# and fix volume ownership only when a remap is needed
changed=0

if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
    changed=1
fi

if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
    changed=1
fi

if [ "$changed" = "1" ]; then
    chown -R node:node /paperclip
fi

# Start tailscale (userspace networking) if TS_AUTHKEY provided.
# Enables Tailscale SSH so operators can `ssh node@<tailnet-host>` into this container.
if [ -n "$TS_AUTHKEY" ]; then
    mkdir -p /var/lib/tailscale /var/run/tailscale
    echo "Starting tailscaled (userspace networking)"
    tailscaled \
        --state=/var/lib/tailscale/tailscaled.state \
        --socket=/var/run/tailscale/tailscaled.sock \
        --tun=userspace-networking \
        >/var/log/tailscaled.log 2>&1 &

    # Wait for tailscaled socket to appear. `tailscale status` exits non-zero
    # in the pre-login NeedsLogin state, so we probe the socket file instead.
    i=0
    until [ -S /var/run/tailscale/tailscaled.sock ]; do
        i=$((i + 1))
        if [ "$i" -gt 30 ]; then
            echo "tailscaled socket not ready within 15s; continuing without tailscale" >&2
            break
        fi
        sleep 0.5
    done

    if [ -S /var/run/tailscale/tailscaled.sock ]; then
        TS_HOSTNAME=${TS_HOSTNAME:-paperclip}
        echo "Bringing up tailscale (hostname=$TS_HOSTNAME, ssh enabled)"
        tailscale --socket=/var/run/tailscale/tailscaled.sock up \
            --ssh \
            --authkey="$TS_AUTHKEY" \
            --hostname="$TS_HOSTNAME" \
            ${TS_EXTRA_ARGS:-} || echo "tailscale up failed; continuing" >&2

        # Expose Paperclip on the tailnet only (HTTPS via MagicDNS cert).
        TS_SERVE_PORT=${TS_SERVE_PORT:-3100}
        echo "Configuring tailscale serve: tailnet:443 -> 127.0.0.1:${TS_SERVE_PORT}"
        tailscale --socket=/var/run/tailscale/tailscaled.sock serve reset >/dev/null 2>&1 || true
        tailscale --socket=/var/run/tailscale/tailscaled.sock serve \
            --bg --https=443 \
            "http://127.0.0.1:${TS_SERVE_PORT}" \
            || echo "tailscale serve failed; continuing" >&2
    fi
else
    echo "TS_AUTHKEY not set; skipping tailscale startup"
fi

if [ "${SYNCTHING_ENABLE:-0}" = "1" ]; then
    mkdir -p /paperclip/.syncthing
    chown -R node:node /paperclip/.syncthing
    echo "Starting syncthing"
    gosu node syncthing serve \
        --home=/paperclip/.syncthing \
        --gui-address="${SYNCTHING_GUI_ADDR:-127.0.0.1:8384}" \
        --no-browser --no-restart \
        >/var/log/syncthing.log 2>&1 &
fi

exec gosu node "$@"
