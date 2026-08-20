#!/bin/bash
# AdGuard DNS watchdog — probe, auto-recover, alert, emit metrics.
# Runs every minute via cron (see crontab). Drill-tested logic: detection →
# restart → recovery in ~80s of a hard container stop.
#
# Once your router's DHCP points at this server, DNS is the LAN's single
# point of failure — and if the router also intercepts outbound port 53
# (common), a dead AdGuard leaves LAN devices with NO fallback at all, since
# even hardcoded public resolvers get intercepted into the dead server.
# Recovery speed is everything; alerting is secondary.
#
# Probes (against $DNS_SERVER_IP:53 — the same path clients use):
#   rewrite  — a *.home name must answer $DNS_SERVER_IP (service alive)
#   upstream — a RANDOM subdomain of example.com must return NOERROR/NXDOMAIN
#              (proves the full upstream path; the random label defeats the
#              cache, which otherwise masks upstream death for hours)
#
# Escalation ladder on consecutive failures (state in ~/.local/state —
# must be writable by the cron user; /var/lib is not):
#   2 → docker restart adguard
#   4 → docker compose up -d --force-recreate (dns stack)
#   6 → webhook alert via DEPLOY_NOTIFY_URL (re-alerted ≤ every 15 min)
#   every 10 thereafter → force-recreate again
#   recovery → all-clear webhook (only if an alert was sent; note that during
#              a total DNS outage the alert webhook itself may fail — the
#              all-clear confirms recovery either way)
#
# Metrics: written to the node-exporter textfile dir if it exists (enable by
# adding a textfile collector to the monitoring stack) — lets Prometheus
# alert independently, incl. on a dead watchdog via the timestamp metric.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
[ -f "$REPO_DIR/.env" ] && . "$REPO_DIR/.env"

DNS_IP="${DNS_SERVER_IP:?DNS_SERVER_IP not set (see .env.example)}"

# Probe-tool preflight. Without dig both probes read as "failed" on a healthy
# AdGuard and the escalation ladder below would restart/recreate it forever.
if ! command -v dig >/dev/null 2>&1; then
  logger -t dns-watchdog "FATAL: dig not installed (apt: bind9-dnsutils / dnf: bind-utils) — watchdog disabled"
  echo "dns-watchdog: dig not installed; install bind9-dnsutils (Debian/Ubuntu) or bind-utils (Fedora)" >&2
  exit 1
fi
REWRITE_NAME=watchdog-probe.home
STATE_DIR="$HOME/.local/state/dns-watchdog"
PROM_DIR=/var/lib/node-exporter
LOG_TAG=dns-watchdog
ALERT_INTERVAL=900   # seconds between repeat alerts while down

mkdir -p "$STATE_DIR" || { logger -t "$LOG_TAG" "FATAL: cannot create $STATE_DIR"; exit 1; }
FAILS_FILE="$STATE_DIR/consecutive_failures"
ALERTED_FILE="$STATE_DIR/last_alert_epoch"

log() { logger -t "$LOG_TAG" "$1"; }

notify() {
    [ -z "${DEPLOY_NOTIFY_URL:-}" ] && return 0
    curl -sf -m 10 -X POST "$DEPLOY_NOTIFY_URL" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"$1\", \"message\": \"$2\"}" >/dev/null 2>&1 || true
}

# ── Probes ─────────────────────────────────────────────────────────────────
rewrite_ok=0
[ "$(dig +short +time=2 +tries=1 @"$DNS_IP" "$REWRITE_NAME" 2>/dev/null | head -1)" = "$DNS_IP" ] && rewrite_ok=1

upstream_ok=0
rc=$(dig +time=3 +tries=1 @"$DNS_IP" "wd-${RANDOM}${RANDOM}.example.com" 2>/dev/null \
     | grep -oE 'status: [A-Z]+' | awk '{print $2}')
case "$rc" in NOERROR|NXDOMAIN) upstream_ok=1 ;; esac

fails=$(cat "$FAILS_FILE" 2>/dev/null || echo 0)

# ── Healthy path ───────────────────────────────────────────────────────────
if [ "$rewrite_ok" = 1 ] && [ "$upstream_ok" = 1 ]; then
    if [ "$fails" -gt 0 ]; then
        log "recovered after $fails failed checks"
        if [ -f "$ALERTED_FILE" ]; then
            notify "✅ AdGuard DNS recovered" "was down for ~${fails} min"
            rm -f "$ALERTED_FILE"
        fi
        echo 0 > "$FAILS_FILE"
    fi
else
    # ── Failure path ───────────────────────────────────────────────────────
    fails=$((fails + 1))
    echo "$fails" > "$FAILS_FILE"
    what="rewrite=$rewrite_ok upstream=$upstream_ok (rc=${rc:-timeout})"
    log "check failed ($fails consecutive): $what"

    if [ "$fails" -eq 2 ]; then
        log "action: docker restart adguard"
        docker restart adguard >/dev/null 2>&1
    elif [ "$fails" -eq 4 ] || { [ "$fails" -gt 6 ] && [ $((fails % 10)) -eq 0 ]; }; then
        log "action: force-recreate dns stack"
        cd "$SCRIPT_DIR" && docker compose -p dns up -d --force-recreate >/dev/null 2>&1
    fi

    if [ "$fails" -ge 6 ]; then
        now=$(date +%s)
        last=$(cat "$ALERTED_FILE" 2>/dev/null || echo 0)
        if [ $((now - last)) -ge "$ALERT_INTERVAL" ]; then
            notify "🚨 AdGuard DNS failing for ${fails} min" "$what — auto-recovery not working, LAN DNS degraded; check docker logs adguard"
            echo "$now" > "$ALERTED_FILE"
        fi
    fi
fi

# ── Metrics (only if a textfile collector dir exists) ─────────────────────
if [ -d "$PROM_DIR" ] && [ -w "$PROM_DIR" ]; then
    tmp=$(mktemp)
    cat > "$tmp" <<EOF
# HELP adguard_rewrite_ok Local DNS rewrite resolution working (1=ok)
# TYPE adguard_rewrite_ok gauge
adguard_rewrite_ok $rewrite_ok
# HELP adguard_upstream_ok Upstream (internet) resolution working (1=ok)
# TYPE adguard_upstream_ok gauge
adguard_upstream_ok $upstream_ok
# HELP adguard_watchdog_consecutive_failures Consecutive failed watchdog checks
# TYPE adguard_watchdog_consecutive_failures gauge
adguard_watchdog_consecutive_failures $(cat "$FAILS_FILE" 2>/dev/null || echo 0)
# HELP adguard_watchdog_timestamp_seconds Last watchdog run (unix epoch)
# TYPE adguard_watchdog_timestamp_seconds gauge
adguard_watchdog_timestamp_seconds $(date +%s)
EOF
    mv "$tmp" "$PROM_DIR/adguard_health.prom"
    chmod 644 "$PROM_DIR/adguard_health.prom"
fi
