#!/bin/sh

set -eu

: "${VPN_USER:?VPN_USER is required}"
: "${VPN_PASSWORD:?VPN_PASSWORD is required}"

echo "Starting Tinyproxy..."

tinyproxy -d -c /etc/tinyproxy/tinyproxy.conf &

PROXY_PID=$!

# 等待代理真正监听
i=0

while [ "$i" -lt 10 ]; do

    if ! kill -0 "$PROXY_PID" 2>/dev/null; then
        echo "Tinyproxy exited unexpectedly"
        cat /tmp/tinyproxy.log 2>/dev/null || true
        exit 1
    fi

    if ss -lnt | grep -q ':8888'; then
        break
    fi

    sleep 0.5
    i=$((i + 1))
done

if ! ss -lnt | grep -q ':8888'; then
    echo "Tinyproxy failed to listen on port 8888"
    cat /tmp/tinyproxy.log 2>/dev/null || true
    exit 1
fi

echo "Tinyproxy successfully listening on :8888"

echo "Starting Cisco OpenConnect..."

exec /usr/bin/expect /usr/local/bin/openconnect.exp