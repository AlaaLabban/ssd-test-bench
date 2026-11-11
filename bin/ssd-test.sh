#!/usr/bin/env bash
# ssd-test.sh — health-test and (optionally) wipe used SSDs, one at a time, in a USB enclosure.
#
#   ssd-test.sh check                  show which drive is in the enclosure; changes nothing
#   ssd-test.sh A <label>              READ-ONLY: SMART, short test, full-surface read, long test
#   ssd-test.sh B <label> <serial>     DESTRUCTIVE: secure erase, full write + verify, final TRIM
#   ssd-test.sh summary                one ranked table of every drive tested so far
#
# <label> = the number you write on the drive (1, 2, 3 ...). The runner picks it for you.
# Run A and B as root. Results go to RESULTS_DIR (default: <kit>/results/<label>-<serial>/).
#
# Safety: the target is found, never typed. Exactly one USB disk must be attached, nothing
# on it may be mounted, and phase B also needs the drive's serial typed back.
set -euo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$DIR/log.txt"; push 2 "SSD #${LABEL:-?}" "$*"; }

# --- find the one USB disk --------------------------------------------------
probe() {   # probe <-d type> -> prints "model<TAB>serial" if smartctl can identify the drive that way
    local out; out="$(timeout 30 smartctl -i -d "$1" "$DEV" 2>/dev/null || true)"
    local m s
    m="$(awk -F': *' '/^(Model Number|Device Model|Product):/ {print $2; exit}' <<<"$out")"
    s="$(awk -F': *' '/^Serial Number:/ {print $2; exit}' <<<"$out")"
    [[ -n "$s" ]] || return 1
    if [[ $2 == nvme ]]; then grep -q '^Model Number:' <<<"$out" || return 1; fi
    printf '%s\t%s\n' "$m" "$s"
}

find_drive() {
    local -a usb
    mapfile -t usb < <(lsblk -dn -o NAME,TRAN,TYPE | awk '$2=="usb" && $3=="disk" {print $1}')
    (( ${#usb[@]} == 1 )) || die "expected exactly 1 USB disk, found ${#usb[@]}: ${usb[*]:-none} — unplug other USB drives/sticks"
    [[ "${usb[0]}" != nvme* ]] || die "refusing: ${usb[0]} is an NVMe device"
    DEV="/dev/${usb[0]}"
    # never touch anything mounted, or the disk the system runs from
    if lsblk -n -o MOUNTPOINTS "$DEV" 2>/dev/null | grep -q . || lsblk -n -o MOUNTPOINT "$DEV" | grep -q .; then
        die "$DEV has mounted partitions — unmount them first (or it is the wrong disk)"
    fi
    # NVMe sticks in M.2 enclosures need the bridge's own passthrough; many bridges also
    # fake an ATA identity for NVMe drives, so try the NVMe types before "sat".
    local id t
    for t in sntrealtek sntjmicron sntasmedia; do
        if id="$(probe "$t" nvme)"; then KIND=nvme; SD=(-d "$t"); break; fi
    done
    if [[ -z "${KIND:-}" ]]; then
        for t in sat auto; do
            if id="$(probe "$t" sata)"; then KIND=sata; SD=(-d "$t"); break; fi
        done
    fi
    [[ -n "${KIND:-}" ]] || die "smartctl cannot read the drive through this enclosure (no SAT/NVMe passthrough) — see README, Troubleshooting"
    IFS=$'\t' read -r MODEL SERIAL <<<"$id"
    SERIAL="${SERIAL// /}"
    [[ -n "$SERIAL" ]] || die "could not read the drive serial through the enclosure"
}

smart_snap() {   # smart_snap <name>
    smartctl -x "${SD[@]}" "$DEV"    > "$DIR/$1.txt"  || true   # exit code is a bitmask, not failure
    smartctl -x "${SD[@]}" -j "$DEV" > "$DIR/$1.json" || true
}

run_selftest() {   # run_selftest short|long
    if [[ $KIND == nvme ]]; then log "$1 self-test skipped: not passed through the USB bridge for NVMe (run it natively)"; return 0; fi
    log "starting $1 self-test"
    smartctl "${SD[@]}" -t "$1" "$DEV" >/dev/null || { log "could not start $1 self-test"; return 0; }
    sleep 60
    while smartctl "${SD[@]}" -c "$DEV" | grep -q "in progress"; do sleep 60; done
    log "$1 self-test: $(smartctl "${SD[@]}" -l selftest "$DEV" | awk '/^# 1/ {$1=$2=""; print; exit}')"
}

temp_logger() {   # background: drive temperature once a minute
    while sleep 60; do
        t="$(smartctl "${SD[@]}" -A "$DEV" | awk '$1==194 || $1==190 {print $10; exit} /^Temperature:/ {print $2; exit}' || true)"
        printf '%(%F %T)T,%s\n' -1 "${t:-?}" >> "$DIR/temps.csv"
    done
}

kernel_errors() {   # anything the kernel said about this disk since phase start
    { journalctl -k --since "@$1" --no-pager 2>/dev/null || dmesg 2>/dev/null; } \
        | grep -E "\b${DEV#/dev/}\b|uas|I/O error" > "$DIR/kernel-$2.txt" || true
    wc -l < "$DIR/kernel-$2.txt"
}

setup_dir() {   # setup_dir <label>
    [[ "$1" =~ ^[0-9]+$ ]] || die "label must be a number, e.g. 3"
    mkdir -p "$BASE"
    local existing; existing="$(ls -d "$BASE/$1-"* 2>/dev/null || true)"
    if [[ -n "$existing" && "$existing" != "$BASE/$1-$SERIAL" ]]; then
        die "label $1 is already used by $(basename "$existing") — wrong number?"
    fi
    local other; other="$(ls -d "$BASE/"*"-$SERIAL" 2>/dev/null || true)"
    if [[ -n "$other" && "$other" != "$BASE/$1-$SERIAL" ]]; then
        die "this drive was already tested as $(basename "$other")"
    fi
    DIR="$BASE/$1-$SERIAL"; mkdir -p "$DIR"; chmod 755 "$BASE" "$DIR"
}

# --- phase A: read-only -----------------------------------------------------
phase_a() {
    local start; start=$(date +%s)
    log "PHASE A on #$LABEL ($KIND)  $MODEL  serial $SERIAL  ($DEV, $(lsblk -dn -o SIZE "$DEV"))"
    smart_snap A0-smart-start
    temp_logger & local tl=$!
    trap "kill $tl 2>/dev/null" EXIT

    run_selftest short

    log "full-surface read (old data, read-only)"
    local rc=0
    fio --name=fullread --filename="$DEV" --readonly --rw=read --bs=1M --direct=1 \
        --ioengine=libaio --iodepth=8 --write_bw_log="$DIR/A-read" --log_avg_msec=5000 \
        --output-format=json --output="$DIR/A-fullread.json" || rc=$?
    log "full read finished, fio exit $rc"

    run_selftest long
    smart_snap A1-smart-end
    local kerr; kerr=$(kernel_errors "$start" A)
    log "kernel lines mentioning the disk during phase A: $kerr"
    echo "$rc" > "$DIR/A-done"
    push 3 "SSD #$LABEL phase A done" "$MODEL $SERIAL: full read exit $rc, $kerr kernel lines."
}

# --- phase B: destructive ---------------------------------------------------
phase_b() {
    [[ $KIND == sata ]] || die "NVMe: wipe + write-test it natively in an M.2 slot (nvme format --ses=1), not through the USB bridge"
    [[ "$TYPED_SERIAL" == "$SERIAL" ]] || die "typed serial '$TYPED_SERIAL' != drive serial '$SERIAL'"
    [[ -f "$DIR/A-done" ]] || die "run phase A on #$LABEL first"
    local start; start=$(date +%s)
    log "PHASE B (DESTRUCTIVE) on #$LABEL  $MODEL  serial $SERIAL  ($DEV)"
    temp_logger & local tl=$!
    trap "kill $tl 2>/dev/null" EXIT

    # 1. ATA secure erase — also clears blocks the OS can't address (spares, retired blocks)
    hdparm -I "$DEV" > "$DIR/B-hdparm-before.txt" 2>&1 || true
    local erased=no
    if grep -q "supported" "$DIR/B-hdparm-before.txt" \
       && grep -qE "^\s+not\s+frozen" "$DIR/B-hdparm-before.txt"; then
        log "ATA secure erase (temporary password '$ERASE_PASS')"
        if hdparm --user-master u --security-set-pass "$ERASE_PASS" "$DEV" >>"$DIR/log.txt" 2>&1 \
           && hdparm --user-master u --security-erase "$ERASE_PASS" "$DEV" >>"$DIR/log.txt" 2>&1; then
            erased=yes
        else
            log "secure erase FAILED — if the drive is now locked: hdparm --user-master u --security-disable $ERASE_PASS $DEV"
        fi
    else
        log "secure erase not available (unsupported or frozen) — relying on full overwrite + TRIM"
    fi
    hdparm -I "$DEV" > "$DIR/B-hdparm-after.txt" 2>&1 || true
    grep -qE "^\s+not\s+locked" "$DIR/B-hdparm-after.txt" || log "WARNING: drive may still be password-locked"
    echo "$erased" > "$DIR/B-secure-erase"
    log "secure erase: $erased"

    # 2. fill every block with checksummed data, then read it all back and verify
    log "full write + verify"
    local rc=0
    fio --name=fullwrite --filename="$DEV" --rw=write --bs=1M --direct=1 \
        --ioengine=libaio --iodepth=8 --verify=crc32c --do_verify=1 --verify_fatal=1 \
        --write_bw_log="$DIR/B-write" --log_avg_msec=5000 \
        --output-format=json --output="$DIR/B-writeverify.json" || rc=$?
    log "write + verify finished, fio exit $rc"

    # 3. leave the drive clean: TRIM everything (some bridges refuse; the drive then holds only test data)
    if blkdiscard -f "$DEV" >>"$DIR/log.txt" 2>&1; then log "final TRIM done"; else log "final TRIM not supported by the bridge (drive holds only fio test data)"; fi

    smart_snap B1-smart-end
    local kerr; kerr=$(kernel_errors "$start" B)
    log "kernel lines mentioning the disk during phase B: $kerr"
    echo "$rc" > "$DIR/B-done"
    push 3 "SSD #$LABEL phase B done" "$MODEL $SERIAL: erase=$erased, write+verify exit $rc, $kerr kernel lines. Safe to unplug."
}

case "${1:-}" in
    check)
        find_drive
        echo "In the enclosure ($KIND, smartctl ${SD[*]}): $DEV  $MODEL  serial $SERIAL  $(lsblk -dn -o SIZE "$DEV")"
        echo "Previously tested: $(ls -d "$BASE/"*"-$SERIAL" 2>/dev/null | xargs -r -n1 basename || true)"
        ;;
    info)   # machine-readable: kind<TAB>serial<TAB>bytes<TAB>model
        find_drive
        printf '%s\t%s\t%s\t%s\n' "$KIND" "$SERIAL" "$(lsblk -bdn -o SIZE "$DEV")" "$MODEL" ;;
    A)  [[ $EUID -eq 0 ]] || die "run as root (sudo)"
        find_drive; LABEL="${2:?label}"; setup_dir "$LABEL"; phase_a ;;
    B)  [[ $EUID -eq 0 ]] || die "run as root (sudo)"
        find_drive; LABEL="${2:?label}"; TYPED_SERIAL="${3:?serial}"; setup_dir "$LABEL"; phase_b ;;
    summary)
        exec python3 -I "$BIN/ssd-summary.py" "$BASE" ;;
    *)  sed -n '2,13p' "$0"; exit 1 ;;
esac
