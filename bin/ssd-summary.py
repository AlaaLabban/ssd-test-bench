#!/usr/bin/env python3
"""Ranking of every SSD tested by ssd-test.sh.
Usage: ssd-summary.py <results dir> [--json]      (best drive first)"""
import glob, json, os, statistics, sys

BASE = sys.argv[1]


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def devstat(j, name):
    for page in (j or {}).get("ata_device_statistics", {}).get("pages", []):
        for row in page.get("table", []):
            if row.get("name") == name and "value" in row:
                return row["value"]
    return None


def attr(j, *ids):
    for row in (j or {}).get("ata_smart_attributes", {}).get("table", []):
        if row.get("id") in ids:
            return row
    return None


def raw(j, *ids):
    a = attr(j, *ids)
    return a["raw"]["value"] if a else None


def last_selftest(j):
    t = (j or {}).get("ata_smart_self_test_log", {}).get("standard", {}).get("table", [])
    if not t:
        return "-"
    s = t[0]
    ok = s.get("status", {}).get("passed")
    return f'{s.get("type", {}).get("string", "?")}:{"ok" if ok else s.get("status", {}).get("string", "FAIL")}'


def bwlog(prefix):
    """MB/s over 5 s windows -> (median, minimum)."""
    vals = []
    for p in glob.glob(prefix + "_bw*.log"):
        with open(p) as f:
            for line in f:
                parts = line.split(",")
                if len(parts) > 1 and parts[2].strip() in ("0", "1"):
                    vals.append(int(parts[1]) / 1024)
    if not vals:
        return None, None
    return round(statistics.median(vals)), round(min(vals))


def rc(path):   # exit code ssd-test.sh recorded for fio (fio's JSON is unreadable after I/O errors)
    try:
        return int(open(path).read().strip() or 0)
    except (OSError, ValueError):
        return None


def wear_used(j, nv, model):
    if nv:
        return nv.get("percentage_used")
    used = devstat(j, "Percentage Used Endurance Indicator")
    if used is not None:
        return used
    # vendor attributes, normalized value = % life LEFT
    for aid in (202, 231, 233, 177, 173, 169):   # Micron 202, many 231/169, Samsung 177, ...
        a = attr(j, aid)
        if a and a.get("name", "").lower().startswith(("percent_lifetime", "ssd_life", "media_wearout", "wear_level", "remaining_life")):
            return max(0, 100 - a["value"])
    return None


def tb_written(j, nv):
    if nv:
        return round(nv["data_units_written"] * 512000 / 1e12, 1)
    w = devstat(j, "Logical Sectors Written")
    if w:
        return round(w * 512 / 1e12, 1)
    a = attr(j, 241)                                # Total_LBAs_Written on most SATA SSDs
    if a and "lba" in a.get("name", "").lower():
        return round(a["raw"]["value"] * 512 / 1e12, 1)
    return None


rows = []
dirs = [d for d in glob.glob(os.path.join(BASE, "*-*")) if os.path.basename(d).split("-")[0].isdigit()]
for d in sorted(dirs, key=lambda p: int(os.path.basename(p).split("-")[0])):
    label, serial = os.path.basename(d).split("-", 1)
    start = load(f"{d}/A0-smart-start.json")
    if not start:
        continue
    end = next((j for j in (load(f"{d}/B1-smart-end.json"), load(f"{d}/A1-smart-end.json"))
                if j and j.get("model_name")), start)   # skip snapshots taken after the drive dropped off
    model = start.get("model_name", "?")
    cap = round(start.get("user_capacity", {}).get("bytes", 0) / 1e9)
    nv = (end or {}).get("nvme_smart_health_information_log")
    kind = "nvme" if nv or start.get("nvme_smart_health_information_log") else "sata"
    used, tbw = wear_used(end, nv, model), tb_written(end, nv)
    poh = (end or {}).get("power_on_time", {}).get("hours")
    bad = {k: raw(end, *ids) for k, ids in
           {"realloc": (5,), "pending": (197,), "uncorr": (187, 198), "crc": (199,)}.items()}
    bad_grew = any((raw(end, *ids) or 0) > (raw(start, *ids) or 0) for ids in ((5,), (197,), (187, 198)))
    rmed, rmin = bwlog(f"{d}/A-read")
    wmed, wmin = bwlog(f"{d}/B-write")
    a_err, b_err = rc(f"{d}/A-done"), rc(f"{d}/B-done")
    if a_err and os.path.exists(f"{d}/kernel-A.txt") and "uas_eh_abort" in open(f"{d}/kernel-A.txt").read():
        a_err = "hung"
    flags = []
    if nv and (nv.get("media_errors") or nv.get("critical_warning")):
        flags.append("NVME-MEDIA-ERR/WARN")
    # Toshiba/Kioxia SG-series firmware reports raw 100 on attr 5 and 179-182 when healthy;
    # for those, a NORMALIZED value below 100 is the sign of used spares.
    if model.upper().startswith(("TOSHIBA", "KIOXIA", "KSG")):
        a5 = attr(end, 5)
        bad["realloc"] = (100 - a5["value"]) if a5 else None
    if any((bad[k] or 0) > 0 for k in ("realloc", "pending", "uncorr")):
        flags.append("BAD-BLOCKS")
    if bad_grew:
        flags.append("GREW-IN-TEST")
    if a_err == "hung":
        flags.append("READ-ERR+HUNG")
    elif a_err:
        flags.append("READ-ERR")
    if b_err:
        flags.append("VERIFY-ERR")
    if (end or {}).get("smart_status", {}).get("passed") is False:
        flags.append("SMART-FAILED")
    st = last_selftest(end)
    if st != "-" and not st.endswith(":ok"):
        flags.append("SELFTEST")
    erase = open(f"{d}/B-secure-erase").read().strip() if os.path.exists(f"{d}/B-secure-erase") else None
    rows.append(dict(label=int(label), model=model, serial=serial, kind=kind, gb=cap, used=used, tbw=tbw,
                     hours=poh, rd_med=rmed, rd_min=rmin, wr_med=wmed, wr_min=wmin, crc=bad["crc"],
                     phase="B" if os.path.exists(f"{d}/B-done") else "A" if os.path.exists(f"{d}/A-done") else None,
                     erased=erase, verdict=",".join(flags) or "ok"))

# best first: clean before flagged, then least worn, least data written, fastest weakest-read window
rows.sort(key=lambda r: (r["verdict"] != "ok", r["used"] if r["used"] is not None else 999,
                         r["tbw"] or 0, -(r["rd_min"] or 0)))

if "--json" in sys.argv:
    print(json.dumps(rows))
    sys.exit()

hdr = ("#", "model", "serial", "type", "GB", "used%", "TBW", "hours", "rd MB/s med/min", "wr MB/s med/min",
       "crc", "done", "erased", "verdict")
print(" | ".join(hdr))
for r in rows:
    print(" | ".join(str("-" if x is None else x) for x in (
        r["label"], r["model"], r["serial"], r["kind"], r["gb"], r["used"], r["tbw"], r["hours"],
        f'{r["rd_med"]}/{r["rd_min"]}', f'{r["wr_med"]}/{r["wr_min"]}', r["crc"], r["phase"], r["erased"],
        r["verdict"])))
