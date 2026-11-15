# lib.sh — shared settings + notifications. Sourced by ssd-test.sh and ssd-runner.sh.
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$KIT/bin"
CONF="${SSD_BENCH_CONF:-$KIT/config.conf}"

# defaults (config.conf overrides them)
EXPECTED_DRIVES=0; KEEP_COUNT=0; AUTO_WIPE=no; MAX_GB=0; MODEL_FILTER=""; PROTECT_SERIALS=""
WIPE_GRACE_SEC=120; RESULTS_DIR=""; DASH_HOST=0.0.0.0; DASH_PORT=8095; TEMP_WARN=80; NTFY_URL=""; NTFY_TOKEN=""; ERASE_PASS=wipe

if [[ -r "$CONF" ]]; then
    # read KEY=value lines only — the file is never executed
    while IFS='=' read -r k v; do
        [[ "$k" =~ ^[A-Z_]+$ ]] || continue
        v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"; v="${v#[\"\']}"; v="${v%[\"\']}"
        printf -v "$k" '%s' "$v"
    done < <(grep -E '^[A-Z_]+=' "$CONF")
fi
BASE="${RESULTS_DIR:-$KIT/results}"

push() {   # push <priority 1-5> <title> <message>   (no-op unless NTFY_URL is set)
    [[ -n "$NTFY_URL" ]] || return 0
    local -a auth=()
    [[ -n "$NTFY_TOKEN" ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
    curl -s -m 10 -o /dev/null "${auth[@]}" -H "Title: $2" -H "Priority: $1" -H "Tags: floppy_disk" \
         -d "$3" "$NTFY_URL" || true
}
