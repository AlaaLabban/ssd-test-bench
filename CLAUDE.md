# CLAUDE.md — SSD Test Bench

This folder is a small kit for health-testing (and optionally wiping) used SSDs one at a time
through a USB enclosure on Linux, with a live web dashboard. Read `README.md` for the user-facing
guide. This file tells you, Claude, how to help the user operate it safely.

## Your role

Help the user install, configure, run, monitor and interpret the tests; diagnose problems from
the logs; explain results in plain language. Prefer reading the results files over guessing.

## 🔴 Safety rules — never break these

1. **Never run Phase B, `hdparm --security-*`, `blkdiscard`, `wipefs`, `nvme format`, `dd`, or
   `fio` with writes against any device unless the user has explicitly said, in this conversation,
   that the specific drive (by number or serial) is meant to be erased.** Phase B destroys all data.
2. **Never set `AUTO_WIPE=yes` on your own initiative.** Explain the consequence and let the user
   decide. Default is `no` (read-only), and that is what most users want. Never lower
   `WIPE_GRACE_SEC` or delete a drive's `B-cancelled` marker unless the user asks for that drive.
3. **Never pass `--yes` to `ssd-test.sh B`, and never pipe or script an answer into its `ERASE`
   prompt.** `--yes` exists only for the runner in wipe mode. If the user wants a drive wiped by
   hand, give them the command to run in their own terminal so they see the warning and type
   `ERASE` themselves.
4. **Never pass a device path you typed yourself to anything destructive.** The scripts find the
   target themselves (exactly one USB disk, nothing mounted) — keep it that way. Don't "fix" a
   "found 2 USB disks" error by editing the check; tell the user to unplug the other disk.
5. **Never weaken the safety checks** in `bin/ssd-test.sh` / `bin/ssd-runner.sh` (one-USB-disk
   rule, mounted check, serial typed back and `ERASE` confirmation for Phase B, the wipe grace
   period, ignore drives present at runner start, `MAX_GB`, `MODEL_FILTER`, `PROTECT_SERIALS`).
6. **Don't stop `ssd-runner` or unplug while a drive is mid-test** without telling the user it
   aborts that drive's run (it resumes when the same drive is plugged back in).
7. Before any command that needs `sudo`, say what it does. Read-only commands are fine to run.

## Layout

- `bin/ssd-test.sh` — the test. `check` / `info` (read-only), `A <n>` (read-only phase),
  `B <n> <serial>` (destructive: warning box + typed `ERASE`), `summary`.
- `bin/ssd-runner.sh` — loop run by systemd unit **`ssd-runner`** (root; not enabled at boot).
  Assigns the next number to each newly plugged drive and runs A. Only with `AUTO_WIPE=yes` and a
  SATA drive: writes `B-pending` (deadline), counts down `WIPE_GRACE_SEC`, then runs B with
  `--yes`; unplugging during the countdown writes `B-cancelled` and the drive is never wiped.
- `bin/ssd-status.py` + `bin/ssd-status.html` — dashboard, systemd unit **`ssd-status`**
  (runs as the user, read-only). `/api` returns the JSON snapshot. The HTML is re-read on every
  request, so page edits show on refresh without a restart.
- `bin/ssd-summary.py <results> [--json]` — verdict flags and ranking.
- `bin/lib.sh` — reads `config.conf` (KEY=value only, never executed), `push()` for ntfy.
- `config.conf` — the user's settings (see `config.example.conf` for every key).
- `results/<n>-<serial>/` — per drive: `log.txt`, `A0/A1/B1-smart-*.json|txt` (smartctl -x),
  `A-fullread.json`, `B-writeverify.json` (fio), `A-read_bw*.log` / `B-write_bw*.log`
  (MB/s in 5 s windows, KiB/s in column 2), `temps.csv`, `kernel-A.txt` / `kernel-B.txt`,
  marker files `A-done` / `B-done` (contain fio's exit code), `B-secure-erase` (yes/no),
  `B-pending` (wipe countdown deadline, epoch s), `B-cancelled` (wipe cancelled by unplugging).

## Useful read-only commands

```bash
systemctl status ssd-runner ssd-status --no-pager
journalctl -u ssd-runner -n 50 --no-pager
lsblk -o NAME,TRAN,SIZE,MODEL,SERIAL,MOUNTPOINTS
sudo bin/ssd-test.sh check
sudo bin/ssd-test.sh summary
curl -s localhost:8095/api | python3 -m json.tool | head -60
tail -n 30 results/*/log.txt
journalctl -k --since "-30min" | grep -Ei "uas|reset|I/O error|sd[a-z]"
```

## Interpreting results

- Verdict `ok` + finished = healthy. Any flag = **RETIRE** recommendation:
  `READ-ERR` / `READ-ERR+HUNG` (old data unreadable, or drive hung), `VERIFY-ERR` (written data
  came back wrong — worst), `BAD-BLOCKS` (reallocated / pending / uncorrectable > 0),
  `GREW-IN-TEST` (counters rose during the test — actively failing), `SELFTEST`,
  `SMART-FAILED`, `NVME-MEDIA-ERR/WARN`.
- Ranking among healthy drives: lower wear %, then fewer TB written, then higher minimum
  old-data read speed.
- Slow reads of **old** data (well below the drive's normal speed) on an otherwise clean drive are
  common on aged SSDs (read-retry on stale cells) — note it, it's not a failure by itself. Speeds
  near zero or I/O errors are.
- SATA speed ceiling is ~530–560 MB/s; USB 5 Gb/s caps near ~400; USB 2.0 ~40.
- Toshiba/Kioxia SG-series report raw 100 on attributes 5 and 179–182 when healthy; the summary
  already uses the normalized value for those. Don't flag them yourself on the raw value.
- NVMe through USB: Phase A only (no self-tests, no wipe via bridge). The drive is "done" after A.
  To wipe: native M.2 slot + `nvme format --ses=1` — only with the user's explicit OK (rule 1).

## Known fixes

- **UAS hang** (drive never shows up, `uas` resets / Mode Sense timeouts, common with older
  Micron/Crucial behind Realtek bridges): `echo <vid>:<pid>:u | sudo tee
  /sys/module/usb_storage/parameters/quirks` (IDs from `lsusb`), then the user must
  **physically** replug. Re-authorising the USB port from software can wedge it — don't.
- **Security frozen**: replug the enclosure with the computer on; otherwise Phase B falls back to
  full overwrite + TRIM, which is acceptable.
- **Locked after failed erase**: `sudo hdparm --user-master u --security-disable <ERASE_PASS> /dev/sdX`
  — confirm the device with `lsblk` and the user first.
- **"Drive stopped responding"**: unplug 10 s, replug, it resumes. Repeats on the same drive =
  failing drive.

## Changing the kit

- Keep it dependency-free (bash + Python standard library + the listed system tools).
- After editing `config.conf`: `sudo systemctl restart ssd-status` (and `ssd-runner` if running —
  only between drives).
- Test any script change with `bash -n` / `python3 -m py_compile` and a read-only `check` before
  running it on a drive.
