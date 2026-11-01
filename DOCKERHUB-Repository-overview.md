# Openconnect-VPN-proxy

A containerized [OpenConnect](https://www.infradead.org/openconnect/) client that connects to **Cisco AnyConnect-compatible** VPN gateways and exposes an **HTTP/HTTPS forward proxy** (Tinyproxy) on port **8888**.

Business containers reach intranet APIs through the proxy — no VPN client installed inside the app image, no change to the host's default routes:

```text
app container ──HTTP proxy──► Tinyproxy :8888 ──tun0 / OpenConnect──► VPN gateway ──► intranet API
```

## Features

- AnyConnect-compatible login via OpenConnect (SSL/CSTP)
- Tinyproxy forward proxy listening on `:8888`
- Password auto-filled from environment variables; SMS/OTP prompts are handed to a human via `docker attach`
- Single-submit guards: password and OTP are each sent **at most once**, preventing retry loops and account lockouts
- Graceful shutdown: the Expect wrapper forwards SIGTERM to OpenConnect (run with `--init` and a stop grace period)
- Built-in healthcheck (tun0 has an IPv4 address — proves the interface is up, **not** that a specific API is reachable)
- Minimal privileges: only `NET_ADMIN` + `/dev/net/tun`, no `--privileged`

## Quick Start (docker compose)

```yaml
services:
  vpn-proxy:
    image: cnlove2012/openconnect-vpn-proxy:latest
    container_name: vpn-proxy
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    stdin_open: true
    tty: true
    init: true
    stop_grace_period: 15s
    restart: "no"
    ports:
      - "127.0.0.1:8888:8888"   # local curl testing; drop on shared servers
    environment:
      VPN_GATEWAY: ${VPN_GATEWAY:?Set VPN_GATEWAY in .env}
      VPN_USER: ${VPN_USER:?Set VPN_USER in .env}
      VPN_PASSWORD: ${VPN_PASSWORD:?Set VPN_PASSWORD in .env}
      VPN_AUTHGROUP: ${VPN_AUTHGROUP:-}
      VPN_USERAGENT: ${VPN_USERAGENT:-AnyConnect Linux_64 5.1.2.42}
      VPN_VERSION_STRING: ${VPN_VERSION_STRING:-5.1.2.42}
      VPN_RECONNECT_TIMEOUT: ${VPN_RECONNECT_TIMEOUT:-300}
```

```bash
cp .env.example .env && chmod 600 .env   # fill in VPN_GATEWAY / VPN_USER / VPN_PASSWORD
docker compose up -d vpn-proxy
```

### Complete the OTP challenge

```bash
docker attach vpn-proxy
```

1. The password is submitted automatically.
2. When you see `Please input SMS Code:`, type the code from your phone and press Enter.
3. On success you will see `Connected as ...` / `Configured as <VPN-IP>`.
4. Detach with `Ctrl+P` then `Ctrl+Q`. **Never use `Ctrl+C`** — it kills the tunnel.

### Verify

```bash
docker exec vpn-proxy ip -4 addr show tun0     # VPN address
docker exec vpn-proxy ip route                  # routes via tun0
docker exec vpn-proxy ping -c 3 <intranet-ip>   # reachability
curl -x http://127.0.0.1:8888 https://intranet.example.com/health
```

## Plain `docker run`

```bash
docker run -d --name vpn-proxy \
  --cap-add NET_ADMIN \
  --device /dev/net/tun \
  -p 127.0.0.1:8888:8888 \
  --init --stop-timeout 15 \
  --env VPN_GATEWAY=https://vpn.example.com \
  --env VPN_USER=your-username \
  --env VPN_PASSWORD=your-password \
  cnlove2012/openconnect-vpn-proxy:latest
```

## Using the proxy from other containers

Join the same Docker user-defined network and point your HTTP client at:

```text
http://vpn-proxy:8888
```

- PHP cURL: `CURLOPT_PROXY` / `CURLOPT_PROXYTYPE => CURLPROXY_HTTP`
- Guzzle: the `proxy` client option
- For HTTPS targets the client issues an HTTP `CONNECT` through the proxy — keep the `https://` URL and keep TLS verification **on**.
- Set the proxy **per request**, not as a container-wide `HTTP_PROXY`, so unrelated traffic never leaks into the VPN.

## Environment Variables

| Variable | Required | Default | Description |
| --- | --- | --- | --- |
| `VPN_GATEWAY` | yes | — | AnyConnect gateway URL |
| `VPN_USER` | yes | — | VPN username |
| `VPN_PASSWORD` | yes | — | VPN password (cleared from the environment before spawning) |
| `VPN_AUTHGROUP` | no | — | Connection profile / group alias shown in the client's group list |
| `VPN_USERAGENT` | no | `AnyConnect Linux_64 5.1.2.42` | Reported client user-agent |
| `VPN_VERSION_STRING` | no | `5.1.2.42` | Reported client version |
| `VPN_RECONNECT_TIMEOUT` | no | `300` | OpenConnect reconnect window in seconds |

## Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Clean stop (SIGTERM/SIGINT) or normal tunnel exit |
| `1` | Missing required variable, or Tinyproxy failed to start/listen |
| `10` | Password prompt repeated (retry-loop guard) |
| `11` | SMS prompt repeated (double-prompt guard) |
| `21` | Login / authentication failed |

OpenConnect's own exit code is passed through on the normal EOF path.

## Security Notes

- Use only with VPNs you are **authorized** to access. The user-agent/version flags are client-compatibility settings; they do not replace device-compliance or endpoint-security checks required by your IT policy.
- Tinyproxy has **no authentication**. The security boundary is the Docker network: never publish port 8888 on `0.0.0.0`, and only join authorized containers to the network.
- Do not bake credentials into images or logs; the SMS code may be visible in the attached terminal — do not share such terminal output.
