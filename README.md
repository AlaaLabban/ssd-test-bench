# SSD Test Bench

Test a pile of used SSDs one after another: plug a drive into a USB enclosure, watch a live
dashboard, swap when it says **DONE**, and get a ranked report at the end telling you which
drives are healthy, which to keep, and which to retire. Optionally wipes each drive securely.

Works for any number of drives (1, 4, 30 …), SATA or NVMe, any size.

---

## What it does to each drive

| Phase | Step | What it proves |
|---|---|---|
| **A** (read-only, always) | 1. SMART snapshot | Wear %, data written, power-on hours, bad-block counters |
| | 2. Short self-test | The drive's own quick self-check |
| | 3. Full-surface read | Every block can still be read; finds slow or failing areas in **old** data |
| | 4. Long self-test | The drive's own full self-check |
| **B** (only if `AUTO_WIPE=yes`, SATA only) | 5. ATA secure erase | Wipes all cells, including hidden spare ones |
| | 6. Write every block | Fills the drive with checksummed data |
| | 7. Verify every block | Reads it all back and checks every checksum |
| | 8. TRIM | Leaves the drive empty and fresh |

Phase A never writes anything. Phase B **destroys all data** on the drive and is off by default.

A drive gets flagged (**RETIRE**) if any of these happen: read errors, verify errors, a failed
self-test, reallocated / pending / uncorrectable sectors, bad-block counters growing during the
test, SMART overall status FAILED, or NVMe media errors.

Healthy drives are ranked: least worn first, then least data written, then best worst-case read
speed.

---

## What you need

1. **A Linux computer** with systemd — Ubuntu, Debian, Mint, Pop!_OS, Fedora, Arch, Raspberry Pi
   OS all work. A spare laptop or a Raspberry Pi 4/5 is perfect. *(Windows and macOS can't do
   this: they can't send secure-erase and SMART commands through a USB enclosure. A live-USB
   Ubuntu boot also works if you have nothing else.)*
2. **One USB enclosure or dock** that supports **SMART passthrough (UASP / SAT)**. Good chips:
   - M.2 NVMe **and** SATA sticks: **Realtek RTL9210B** (e.g. UGREEN, ORICO, many others)
   - M.2 NVMe only: RTL9210 / RTL9220, JMicron JMS583, ASMedia ASM2362
   - 2.5" SATA drives: ASMedia ASM1153E / ASM235CM, JMicron JMS578
   - Avoid no-name enclosures that don't list a chip — many hide SMART completely.
3. Plug it into a **blue/USB 3** port (USB 2.0 works but is ~10× slower; the dashboard will say so).
4. A marker pen and some tape to number the drives.

---

## Install (once)

```bash
# 1. copy this folder to the Linux computer (USB stick, scp, git — anything), then:
cd ssd-test-bench
sudo bash setup.sh
```

`setup.sh` checks for the tools it needs (`smartmontools`, `fio`, `hdparm`, `python3`,
`util-linux`, `curl`), offers to install any that are missing, creates `config.conf`, and starts
the **dashboard**. It installs the **runner** but does **not** start it.

Open the dashboard: `http://localhost:8095` on that computer, or `http://<its-ip>:8095` from your
phone on the same Wi-Fi (setup prints the exact address).

---

## Configure (2 minutes)

Edit `config.conf` in the kit folder. The ones that matter:

| Setting | Example | Meaning |
|---|---|---|
| `EXPECTED_DRIVES` | `12` | How many drives you'll test. Sets the number of bays on the dashboard. `0` = open-ended. |
| `KEEP_COUNT` | `8` | When all drives are done, the best 8 healthy ones are marked **KEEP**, the other healthy ones **SPARE**. `0` = no pick. |
| `MAX_GB` | `600` | Never touch a drive bigger than this. Set it just above your batch size so a backup disk plugged in by mistake is safe. |
| `AUTO_WIPE` | `no` / `yes` | `yes` = after the read test, **erase and stress-test** every SATA drive. Only if every drive is meant to be wiped. |
| `MODEL_FILTER` | `^(TOSHIBA\|Micron)` | Optional: only test these models. |
| `PROTECT_SERIALS` | `S4XXXX 1234ABC` | Serials that must never be touched. |
| `NTFY_URL` | `https://ntfy.sh/my-random-topic-8f3k` | Optional phone notifications: install the **ntfy** app, subscribe to the same (hard-to-guess) topic. |
| `TEMP_WARN` | `80` | °C at which the dashboard turns red. |

After editing: `sudo systemctl restart ssd-status` (and `ssd-runner` if it's running).

---

## Run a batch — step by step

1. **Unplug every other USB storage device** (sticks, backup drives). The tool refuses to run if
   it sees more than one USB disk — that's a safety feature, not a bug.
2. Start the runner:
   ```bash
   sudo systemctl start ssd-runner
   ```
3. Put **drive 1** in the enclosure and plug it in. *(Plug it in **after** starting the runner — a
   drive that was already attached when the runner started is deliberately ignored.)*
4. Within ~10 s the dashboard turns live: bay **01** glows, the stage pipeline starts, the speed
   scope and temperature gauge move.
5. **Write the bay number on the drive** (tape + marker). The number is how the report refers to it.
6. Wait for the green **COMPLETE — swap in the next drive** banner (and the ntfy push, if set).
   Rough times for a 512 GB SATA SSD: read-only ≈ 30–60 min, with wipe ≈ 1.5–2 h.
7. Unplug the enclosure, swap the drive, plug it back in. The next number is assigned
   automatically. Repeat.
8. When the last one is done: `sudo systemctl stop ssd-runner`.
9. Read the **Test report** table at the bottom of the dashboard (or run
   `sudo bin/ssd-test.sh summary` for the same thing as text).

**Interrupted?** If the power drops or you unplug mid-test, just plug the **same** drive back in
while the runner is running — it recognises the serial and resumes under the same number.

---

## Reading the dashboard

- **Device under test** — current drive, bay number, serial, wear %, total data written, hours.
- **Current step** — progress %, GB done, ETA. During self-tests there's no progress bar: the drive
  is testing itself internally.
- **Test sequence** — the 7 stages: ✓ pass, ✕ fail, ↷ skipped (e.g. wipe off, or NVMe stages
  that must be done in a real M.2 slot).
- **Throughput** — live MB/s. Old data read slower than the rest of the drive is normal on aged
  SSDs; dips to near zero or errors are not.
- **Temperature** — keep it under the warning line; give the enclosure air if it climbs.
- **Block map** — visual of how far the read / write / verify has got.
- **Bays** — one tile per drive: green PASS, red FAIL, amber = testing now.
- **Test report** — the ranking. Picks: **KEEP**, **SPARE**, **GOOD** (no keep count set),
  **RETIRE** (red flag found — don't trust it with data).
- **Console** — the live log for the current drive.

All raw data lives in `results/<number>-<serial>/` (SMART dumps, fio results, speed logs,
temperatures, kernel errors, the log). Nothing is ever sent anywhere except the optional ntfy push.

---

## Doing a single drive by hand (no runner)

```bash
sudo bin/ssd-test.sh check                    # what's in the enclosure? (changes nothing)
sudo bin/ssd-test.sh A 1                      # read-only test, call it drive #1
sudo bin/ssd-test.sh B 1 <SERIAL>             # DESTRUCTIVE wipe + write/verify; type the serial back
sudo bin/ssd-test.sh summary                  # ranking table
```
For long runs use `sudo systemd-run --unit=ssd-test --collect $PWD/bin/ssd-test.sh A 1` so
closing the terminal / SSH doesn't kill it.

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| Dashboard says nothing / "Waiting" with a drive plugged in | `sudo systemctl status ssd-runner` — is it running? Was the drive plugged in **before** the runner started? Unplug + replug. Any other USB disk attached? |
| `expected exactly 1 USB disk` | Unplug other USB drives/sticks (check `lsblk -o NAME,TRAN,SIZE,MODEL`). |
| `smartctl cannot read the drive through this enclosure` | The enclosure has no SMART passthrough. Use one from the list above. |
| Drive never appears, kernel log full of `uas` / reset / "Mode Sense" timeouts (some older Micron/Crucial drives do this) | Turn off UAS for that enclosure: find its ID with `lsusb` (e.g. `0bda:9210`), run `echo 0bda:9210:u \| sudo tee /sys/module/usb_storage/parameters/quirks`, then **physically** unplug and replug. Lasts until reboot; slower but stable. |
| "Drive stopped responding" banner | Unplug, wait 10 s, replug — it resumes. If it keeps happening on the same drive and spot, that drive is failing (RETIRE). |
| `secure erase not available (frozen)` | Some drives freeze security on power-up. Unplug/replug the enclosure **while the computer is on** usually unfreezes it. If not, the tool still fully overwrites + TRIMs, which is fine for reuse. |
| `drive may still be password-locked` after a failed erase | `sudo hdparm --user-master u --security-disable wipe /dev/sdX` (use the `ERASE_PASS` from config). |
| NVMe stick: self-tests and wipe show "skipped" | Normal. USB bridges don't pass those through. Phase A still reads the whole drive and checks NVMe health. To wipe an NVMe, put it in a real M.2 slot and run `sudo nvme format --ses=1 /dev/nvmeXn1`. |
| Speed stuck at ~40 MB/s | You're on a USB 2.0 port or cable — the dashboard header shows the link speed. |
| A Toshiba/Kioxia shows raw value 100 on attributes 5 / 179–182 | Normal for that firmware; the tool already judges those by the normalized value. |
| Can't open the dashboard from the phone | Same Wi-Fi? `DASH_HOST=0.0.0.0` in config? Firewall: `sudo ufw allow 8095/tcp` (Ubuntu). |

---

## Uninstall

```bash
sudo bash setup.sh remove      # removes both services; results and config stay
```
Then delete the folder if you want everything gone.

---

## Files

```
ssd-test-bench/
├── README.md              this guide
├── CLAUDE.md              instructions for Claude Code, if you use it in this folder
├── setup.sh               installer / uninstaller
├── config.example.conf    all settings, documented (setup copies it to config.conf)
├── bin/
│   ├── ssd-test.sh        the test itself (phases A and B)
│   ├── ssd-runner.sh      hands-off batch loop (systemd unit ssd-runner)
│   ├── ssd-status.py      dashboard server (systemd unit ssd-status)
│   ├── ssd-status.html    the dashboard page
│   ├── ssd-summary.py     ranking logic
│   └── lib.sh             shared settings + notifications
└── results/               one folder per drive: <number>-<serial>/
```
