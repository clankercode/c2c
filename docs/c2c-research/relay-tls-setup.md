# c2c relay TLS setup

Companion doc for **Layer 2** of `relay-internet-build-plan.md`. Covers
how to get a c2c relay running behind HTTPS: the Let's Encrypt path for
a public endpoint, and the self-signed path for Tailscale / private
networks.

Scope: TLS transport only. Per-peer Ed25519 identity is Layer 3 and
lives in a separate doc.

---

## 1. Prerequisites

- Python ≥ 3.11 (for `ssl.SSLContext` with TLS 1.3 defaults).
- `c2c_relay_server.py` built from a commit that accepts
  `--tls-cert` / `--tls-key` (Layer 2 slice 1).
- A machine that can accept inbound connections on the chosen port.

Pick one of the two deployment shapes below.

---

## 2. Path A — Public endpoint with Let's Encrypt

Use this when the relay has a DNS name resolvable from the open
internet and you want peers to trust it without any extra config.

### 2.1 Obtain a cert with certbot (standalone)

```sh
sudo certbot certonly --standalone \
    --preferred-challenges http \
    -d relay.example.com
```

Certbot drops a cert chain + key at:

```
/etc/letsencrypt/live/relay.example.com/fullchain.pem
/etc/letsencrypt/live/relay.example.com/privkey.pem
```

Certbot needs to bind :80 during challenge — stop any nginx/caddy
fronting the port for the duration, or use the `--webroot` variant if
you already have a server there.

### 2.2 Launch the relay

```sh
c2c relay serve \
    --listen 0.0.0.0:443 \
    --tls-cert /etc/letsencrypt/live/relay.example.com/fullchain.pem \
    --tls-key  /etc/letsencrypt/live/relay.example.com/privkey.pem \
    --token-file /etc/c2c/operator-token \
    --storage sqlite \
    --db-path /var/lib/c2c/relay.sqlite
```

Bind :443 either by running as root, giving the binary
`cap_net_bind_service`, or fronting with a reverse proxy (see §4).

### 2.3 Client side

No flags needed — the default TLS context trusts the system CA bundle:

```sh
c2c relay setup --url https://relay.example.com --token "$TOKEN"
c2c relay status
```

### 2.4 Auto-renewal

certbot installs a systemd timer by default. The relay keeps the cert
file handles open, so a renewal does NOT hot-reload — you need a
`systemctl reload c2c-relay` (or SIGHUP-on-reload, once the server
grows that) in a certbot `deploy-hook`:

```ini
# /etc/letsencrypt/renewal-hooks/deploy/c2c-relay.sh
#!/bin/sh
systemctl reload c2c-relay || systemctl restart c2c-relay
```

Until SIGHUP-reload lands, a restart is the pragmatic choice; the
brief outage (<1s) is bounded by the relay's startup time, and
connectors reconnect on the next heartbeat.

---

## 3. Path B — Self-signed for Tailscale / private networks

Use this when peers reach the relay over a trust-bounded overlay
(Tailscale, WireGuard, VPN) and a public CA is unavailable or
undesirable.

### 3.1 Generate a self-signed cert

```sh
# One-liner: 10-year RSA-2048 cert; SAN covers Tailscale hostname + IP.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout relay.key -out relay.crt \
    -subj "/CN=relay.tailnet-xyz.ts.net" \
    -addext "subjectAltName = DNS:relay.tailnet-xyz.ts.net,IP:100.64.0.5"
```

Notes:
- Prefer the Tailscale MagicDNS hostname as the SAN; the IP SAN is a
  fallback for peers that bypass DNS.
- ECDSA-P256 works too (`openssl req ... -newkey ec:<(openssl ecparam -name prime256v1)>`)
  and keeps the cert/handshake smaller; stick with RSA-2048 if your
  OCaml TLS stack is fussy.

Ship `relay.crt` to every peer. Keep `relay.key` only on the relay
host, mode `0600`, owned by the relay runtime user.

### 3.2 Launch the relay

```sh
c2c relay serve \
    --listen 0.0.0.0:8443 \
    --tls-cert /etc/c2c/relay.crt \
    --tls-key  /etc/c2c/relay.key
```

### 3.3 Client trust — `C2C_RELAY_CA_BUNDLE`

Peers refuse self-signed certs by default. Point them at the CA file:

```sh
export C2C_RELAY_CA_BUNDLE=/etc/c2c/relay.crt
c2c relay setup --url https://relay.tailnet-xyz.ts.net:8443 --token "$TOKEN"
c2c relay status
```

`C2C_RELAY_CA_BUNDLE` is consumed by `c2c_relay_config.py` and
threaded into `ssl.create_default_context(cafile=...)` in the Python
client, and into the `tls` library's `X509.authenticator_of_pem_cstruct`
on the OCaml side.

Persist the env var in `~/.config/c2c/relay.json` if preferred:

```json
{
  "relay_url": "https://relay.tailnet-xyz.ts.net:8443",
  "token": "...",
  "ca_bundle": "/etc/c2c/relay.crt"
}
```

### 3.4 Rotation

Self-signed certs survive as long as the `-days` allows. Rotate by
regenerating, redistributing `relay.crt` to peers, then restarting the
relay. If peers pin via `C2C_RELAY_CA_BUNDLE`, the new cert replaces
the old file atomically (`mv -f`) and peers pick it up on next
connection.

---

## 4. Alternative: reverse proxy in front (nginx, caddy)

If you already run nginx or caddy, you can skip the built-in TLS flags
and let the proxy terminate TLS:

```
# caddy
relay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

```nginx
server {
    listen 443 ssl http2;
    server_name relay.example.com;
    ssl_certificate     /etc/letsencrypt/live/relay.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.example.com/privkey.pem;
    ssl_protocols TLSv1.3;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
    }
}
```

Run the relay on loopback, plain HTTP, behind the proxy:

```sh
c2c relay serve --listen 127.0.0.1:8080 ...
```

This is the recommended path for v1 OCaml deployments until
`ocaml/relay.ml` grows native TLS support — see the plan's Layer 2
slice 5.

---

## 5. Security checklist

- [ ] `relay.key` is mode `0600`, owned by the relay runtime user.
- [ ] Operator bearer token (for `/admin/*`) is in a separate file,
      not in shell history or systemd env.
- [ ] `--listen` address is explicit — prefer `0.0.0.0` only on
      firewalled hosts; otherwise bind to the specific interface.
- [ ] Peers verify TLS (default on). Never disable verification in
      production; if you're tempted, use `C2C_RELAY_CA_BUNDLE` with the
      right CA file instead.
- [ ] Reverse-proxy path: make sure the proxy forces TLS 1.3 and
      disables cipher suites weaker than `TLS_AES_128_GCM_SHA256`.
- [ ] Renewal hook restarts the relay — verify with
      `systemctl status c2c-relay` after a dry-run renew.

---

## 6. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ssl.SSLCertVerificationError: unable to get local issuer certificate` | Self-signed cert, no CA bundle on client | Set `C2C_RELAY_CA_BUNDLE` |
| `HTTPSConnectionPool: ... certificate verify failed: Hostname mismatch` | Cert SAN doesn't match the URL hostname | Regenerate with the correct `-addext subjectAltName=` |
| Peers disconnect after ~60 days | LE cert expired, renewal didn't restart relay | Install the `deploy-hook` in §2.4 |
| `c2c relay status` hangs instead of erroring | Plain-HTTP client hitting HTTPS port | Update `relay_url` to include `https://` |
| TLS handshake closed on first byte | Server listening plain HTTP; check `--tls-cert` flags were passed | `ss -tlnp`, then `openssl s_client -connect host:port` |

---

## 7. Status

- [x] Doc drafted (Layer 2 slice 2).
- [ ] `--tls-cert` / `--tls-key` flags landed in `c2c_relay_server.py` (Layer 2 slice 1).
- [ ] `C2C_RELAY_CA_BUNDLE` wired into `c2c_relay_config.py` (Layer 2 slice 3).
- [ ] OCaml relay TLS (Layer 2 slice 5).

Update this doc as slices land — particularly the flag names and
config-file schema, which may drift before Layer 2 is fully in.
