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

    # Wait for tailscaled socket to become ready
    i=0
    until tailscale --socket=/var/run/tailscale/tailscaled.sock status >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -gt 30 ]; then
            echo "tailscaled failed to start within 15s; continuing without tailscale" >&2
            break
        fi
        sleep 0.5
    done

    if tailscale --socket=/var/run/tailscale/tailscaled.sock status >/dev/null 2>&1; then
        TS_HOSTNAME=${TS_HOSTNAME:-paperclip}
        echo "Bringing up tailscale (hostname=$TS_HOSTNAME, ssh enabled)"
        tailscale --socket=/var/run/tailscale/tailscaled.sock up \
            --ssh \
            --authkey="$TS_AUTHKEY" \
            --hostname="$TS_HOSTNAME" \
            ${TS_EXTRA_ARGS:-} || echo "tailscale up failed; continuing" >&2
    fi
else
    echo "TS_AUTHKEY not set; skipping tailscale startup"
fi

exec gosu node "$@"
