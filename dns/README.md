# DNS — AdGuard Home (local DNS + ad blocking)

Gives every service on your server a stable name — `http://sonarr.home:8989`
from any device on the LAN — plus network-wide ad/tracker blocking.

- **DNS:** `$DNS_SERVER_IP:53` · **UI:** `http://<server>:3005`
- **Names:** the seed config rewrites `*.home` (and bare `home`) to your
  server, so every current and future app has a name with zero bookkeeping.
- **Config model:** `AdGuardHome.yaml` here is the **first-boot seed**
  (`__DNS_SERVER_IP__` is substituted from `.env` at first start). AdGuard
  writes UI changes back to its config, so the live copy lives in the
  `adguard_conf` volume. Force-reapply the seed:
  `docker compose -p dns down -v` + redeploy.

## Setup

1. Set `DNS_SERVER_IP` in `.env` (your server's LAN IP — give the server a
   DHCP reservation or static address first).
2. Deploy the stack.
3. **Router** → DHCP/LAN settings → set the DNS server to `$DNS_SERVER_IP`
   (only that — a public secondary lets devices bypass local names and ad
   blocking). Devices pick it up on lease renewal.
4. Verify from any LAN device: `nslookup anything.home` → your server's IP.

## Hard-won operational notes (read before changing upstreams)

- **Keep upstreams as DoH by IP** (`https://1.1.1.1/dns-query`). Hostname
  upstreams need a plain-DNS bootstrap lookup — and many routers, once their
  DHCP points at your server, also *intercept* all outbound port-53 traffic
  and forward it back to your server. The bootstrap then loops into AdGuard
  itself and upstream resolution dies on the next cold start (cache empty).
  This exact failure happened in production; DoH-by-IP needs no bootstrap.
- **DoT (`tls://…`, port 853) may be blocked** outbound by your router or ISP.
  Test with `nc -z -w4 1.1.1.1 853` from the server before relying on it.
- **Bind port 53 to the server's IP, not 0.0.0.0** (the compose file already
  does) — a wildcard bind conflicts with systemd-resolved's stub listener on
  `127.0.0.53`.
- **If DNS is down, the whole LAN loses resolution.** Quick fix on any device:
  set DNS manually to `1.1.1.1`; on the router: point DHCP DNS back at a
  public resolver until the stack is back.
- **VPN clients** (Mullvad etc.) hijack port 53 and bypass local DNS. Fix
  varies by client; for Mullvad set its custom DNS to your **gateway** IP
  (LAN-sharing on), and revert when leaving the LAN.

## Going further

- **Port-free names / HTTPS:** pair with a reverse proxy on `:80`/`:443`
  (Caddy/Traefik/nginx) proxying `sonarr.home → sonarr:8989`. For
  browser-trusted HTTPS you need names under a real domain you own (wildcard
  cert via DNS-01) — `.home` cannot get public certs.
- **Per-app rewrites** instead of the wildcard: UI → Filters → DNS rewrites,
  or `filtering.rewrites` in the seed.
