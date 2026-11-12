#!/usr/bin/env bash
# ssd-runner.sh — hands-off batch. Each new drive put in the USB enclosure gets the next
# free number and Phase A (read-only). With AUTO_WIPE=yes in config.conf, SATA drives
# then also get Phase B (secure erase + full write/verify). The dashboard (and ntfy, if
# set) tells you when to swap.
#
# It leaves a drive alone (and says so) if it:
#   - was already attached when the runner started (plug drives in AFTER starting it)
#   - is bigger than MAX_GB, doesn't match MODEL_FILTER, or is in PROTECT_SERIALS
#   - has a mounted partition
# Runs as the systemd unit ssd-runner:  sudo systemctl start|stop|status ssd-runner
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/lib.sh"
[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }
mkdir -p "$BASE"; chmod 755 "$BASE"

declare -A warned=() present=()
# remember what was already plugged in, so a disk attached before start is never touched
if first="$("$BIN/ssd-test.sh" info 2>/dev/null)"; then
    IFS=$'\t' read -r _ s _ _ <<<"$first"
    [[ -n "$s" ]] && ! ls -d "$BASE/"*"-$s" >/dev/null 2>&1 && present[$s]=1
fi
echo "ssd-runner: results in $BASE, AUTO_WIPE=$AUTO_WIPE, MAX_GB=$MAX_GB, MODEL_FILTER='${MODEL_FILTER}'"

skip() {   # skip <serial> <reason>
    [[ -n "${warned[$1]:-}" ]] || { echo "skipping $1: $2"; push 4 "SSD runner: not touching this drive" "$2"; }
    warned[$1]=1
}

while sleep 10; do
    info="$("$BIN/ssd-test.sh" info 2>/dev/null)" || continue          # 0 or >1 USB disks, or unreadable
    IFS=$'\t' read -r kind serial bytes model <<<"$info"
    [[ -n "$serial" ]] || continue
    gb=$(( bytes / 1000000000 ))
    done_dir="$(ls -d "$BASE/"*"-$serial" 2>/dev/null | head -1)"

    # already finished? (waiting for a swap)
    if [[ -n "$done_dir" ]]; then
        [[ -f "$done_dir/B-done" ]] && continue
        [[ -f "$done_dir/A-done" && ( $kind == nvme || $AUTO_WIPE != yes ) ]] && continue
    fi

    if [[ -n "${present[$serial]:-}" ]]; then skip "$serial" "$model $serial was already attached when the runner started. Unplug it and plug it back in to test it."; continue; fi
    if [[ " $PROTECT_SERIALS " == *" $serial "* ]]; then skip "$serial" "$model $serial is in PROTECT_SERIALS."; continue; fi
    if (( MAX_GB > 0 && gb > MAX_GB )); then skip "$serial" "$model $serial is $gb GB, above MAX_GB=$MAX_GB."; continue; fi
    if [[ -n "$MODEL_FILTER" && ! "$model" =~ $MODEL_FILTER ]]; then skip "$serial" "$model $serial doesn't match MODEL_FILTER."; continue; fi
    unset "present[$serial]"

    if [[ -n "$done_dir" ]]; then label="$(basename "$done_dir" | cut -d- -f1)"   # resume an interrupted drive
    else label=$(( $(ls -d "$BASE"/[0-9]*-* 2>/dev/null | xargs -rn1 basename | cut -d- -f1 | sort -n | tail -1) + 1 )); fi

    wipe=no; [[ $AUTO_WIPE == yes && $kind == sata ]] && wipe=yes
    push 3 "SSD #$label started" "$model $serial ($gb GB) — write $label on it. $([[ $wipe == yes ]] && echo 'Read test, then WIPE.' || echo 'Read-only test.') Don't unplug."
    if [[ ! -f "$BASE/$label-$serial/A-done" ]]; then
        "$BIN/ssd-test.sh" A "$label" || { push 4 "SSD #$label phase A aborted" "$serial — see $BASE/$label-$serial/log.txt"; sleep 60; continue; }
    fi
    if [[ $wipe == yes ]]; then
        "$BIN/ssd-test.sh" B "$label" "$serial" || { push 4 "SSD #$label phase B aborted" "$serial — see log; NOT wiped"; sleep 60; continue; }
    fi
    push 4 "SSD #$label DONE — swap now" "$model $serial finished. Write $label on it and put in the next drive."
done
