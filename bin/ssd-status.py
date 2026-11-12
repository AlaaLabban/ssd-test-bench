#!/usr/bin/env python3
"""SSD Test Bench — live dashboard server.  http://<this computer>:DASH_PORT  (default 8095)
  /      the page (ssd-status.html, re-read on every request so it can be edited live)
  /api   JSON snapshot: current drive, stage pipeline, progress, speed trace, temps, results
Reads the results folder and /sys/block/<usb disk>/stat. Read-only: it never touches the drive."""
import collections, glob, json, os, re, socket, subprocess, sys, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

BIN = os.path.dirname(os.path.realpath(__file__))
KIT = os.path.dirname(BIN)
HTML = f"{BIN}/ssd-status.html"


def load_conf():
    c = dict(EXPECTED_DRIVES="0", KEEP_COUNT="0", AUTO_WIPE="no", RESULTS_DIR="", DASH_HOST="0.0.0.0",
             DASH_PORT="8095", TEMP_WARN="80")
    path = os.environ.get("SSD_BENCH_CONF", f"{KIT}/config.conf")
    try:
        for line in open(path):
            m = re.match(r"^([A-Z_]+)=(.*)$", line.strip())
            if m:
                c[m.group(1)] = m.group(2).split("#")[0].strip().strip("\"'")
    except OSError:
        pass
    return c


CONF = load_conf()
BASE = CONF["RESULTS_DIR"] or f"{KIT}/results"
AUTO_WIPE = CONF["AUTO_WIPE"].lower() == "yes"
num = lambda k: int(CONF.get(k) or 0) if str(CONF.get(k) or "0").isdigit() else 0

_rates = {}                                   # disk -> (read MB/s, write MB/s)
_verify_base = {}                             # disk -> read bytes when its full write finished
_trace = collections.deque(maxlen=180)        # (t, read MB/s, write MB/s), one per 2 s = 6 min


def usb_disk():
    out = subprocess.run(["lsblk", "-bdn", "-o", "NAME,TRAN,SIZE"], capture_output=True, text=True).stdout
    disks = [p for p in (l.split() for l in out.splitlines()) if len(p) == 3 and p[1] == "usb"]
    return (disks[0][0], int(disks[0][2])) if len(disks) == 1 else (None, 0)


def bridge(name):
    """USB bridge chip of the enclosure, e.g. 'Realtek RTL9210B-CG · 0bda:9210'."""
    if not name:
        return None
    p = os.path.realpath(f"/sys/block/{name}/device")
    while p != "/":
        if os.path.exists(f"{p}/idVendor"):
            rd = lambda f: (open(f"{p}/{f}").read().strip() if os.path.exists(f"{p}/{f}") else "")
            label = " ".join(x for x in (rd("manufacturer"), rd("product")) if x)
            speed = rd("speed")
            speed = {"5000": "USB 5 Gb/s", "10000": "USB 10 Gb/s", "20000": "USB 20 Gb/s", "480": "USB 2.0 (slow!)"}.get(speed, "")
            return " · ".join(x for x in (label, f'{rd("idVendor")}:{rd("idProduct")}', speed) if x)
        p = os.path.dirname(p)
    return None


def sampler():
    last = {}
    while True:
        name, _ = usb_disk()
        if name:
            try:
                f = open(f"/sys/block/{name}/stat").read().split()
                now, r, w = time.time(), int(f[2]) * 512, int(f[6]) * 512
                cap = int(open(f"/sys/block/{name}/size").read()) * 512
                if w < cap * 0.999:
                    _verify_base[name] = r
                if name in last:
                    t0, r0, w0 = last[name]
                    if r >= r0 and w >= w0:
                        rs, ws = (r - r0) / (now - t0) / 1e6, (w - w0) / (now - t0) / 1e6
                        _rates[name] = (rs, ws)
                        _trace.append((round(now), round(rs, 1), round(ws, 1)))
                last[name] = (now, r, w)
            except OSError:
                pass
        else:
            last.clear()
            _trace.append((round(time.time()), 0, 0))
        time.sleep(2)


def drive_dirs():
    return [d for d in glob.glob(f"{BASE}/[0-9]*-*") if os.path.basename(d).split("-")[0].isdigit()]


def current_dir():
    dirs = [d for d in drive_dirs() if os.path.exists(f"{d}/log.txt")]
    return max(dirs, key=lambda d: os.path.getmtime(f"{d}/log.txt")) if dirs else None


def ts(line):
    m = re.match(r"\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\]", line)
    return time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")) if m else None


STAGES = [("short", "Short self-test", "A"), ("read", "Full read · old data", "A"), ("long", "Long self-test", "A"),
          ("erase", "Secure erase", "B"), ("write", "Write every block", "B"), ("verify", "Verify every block", "B"),
          ("trim", "TRIM", "B")]


def pipeline(lines, kind, wrote_all, a_done=False):
    st = {k: {"status": "pending", "note": "", "t0": None} for k, _, _ in STAGES}

    def go(k, status, note="", t=None):
        st[k]["status"] = status
        if note:
            st[k]["note"] = note
        if status == "active" and t:
            st[k]["t0"] = t

    for line in lines:
        t, msg = ts(line), re.sub(r"^\[.*?\]\s*", "", line)
        if msg.startswith("starting short"): go("short", "active", t=t)
        elif msg.startswith("short self-test skipped"): go("short", "skip", "native")
        elif msg.startswith("short self-test:"): go("short", "done" if "without error" in msg else "fail")
        elif msg.startswith("full-surface read"): go("read", "active", t=t)
        elif msg.startswith("full read finished"):
            rc = msg.rsplit(" ", 1)[-1]
            go("read", "done" if rc == "0" else "fail", "0 errors" if rc == "0" else "I/O errors")
        elif msg.startswith("starting long"): go("long", "active", t=t)
        elif msg.startswith("long self-test skipped"): go("long", "skip", "native")
        elif msg.startswith("could not start long"): go("long", "fail", "drive not responding")
        elif msg.startswith("long self-test:"): go("long", "done" if "without error" in msg else "fail")
        elif msg.startswith("PHASE B"): go("erase", "active", t=t)
        elif msg.startswith("secure erase: yes"): go("erase", "done", "ATA secure erase")
        elif msg.startswith("secure erase: no"): go("erase", "skip", "overwrite only")
        elif msg.startswith("full write + verify"):
            go("write", "active", t=t)
            st["verify"]["status"] = "pending"
        elif msg.startswith("write + verify finished"):
            ok = msg.endswith(" 0")
            go("write", "done" if ok else "fail")
            go("verify", "done" if ok else "fail", "all blocks match" if ok else "mismatch / error")
            go("trim", "active", t=t)
        elif msg.startswith("final TRIM done"): go("trim", "done")
        elif msg.startswith("final TRIM not"): go("trim", "skip")
    if st["write"]["status"] == "active" and wrote_all:
        st["write"]["status"] = "done"
        st["verify"]["status"] = "active"
        st["verify"]["t0"] = st["write"]["t0"]
    b_note = "native, in an M.2 slot" if kind == "nvme" else None if AUTO_WIPE else "wipe off (AUTO_WIPE=no)"
    if b_note:
        for k in ("erase", "write", "verify", "trim"):
            if st[k]["status"] == "pending" and (a_done or kind == "nvme"):
                st[k] = {"status": "skip", "note": b_note, "t0": None}
    return [{"key": k, "name": n, "phase": p, **st[k]} for k, n, p in STAGES]


def results():
    out = subprocess.run([sys.executable, "-I", f"{BIN}/ssd-summary.py", BASE, "--json"],
                         capture_output=True, text=True).stdout
    try:
        return json.loads(out or "[]")
    except ValueError:
        return []


def finished(d, kind):
    return os.path.exists(f"{d}/B-done") or (os.path.exists(f"{d}/A-done") and (kind == "nvme" or not AUTO_WIPE))


def snapshot():
    name, cap = usb_disk()
    d = current_dir()
    snap = {"now": time.time(), "state": "idle", "message": "Waiting for the first drive", "drive": None,
            "stages": pipeline([], "sata", False), "active": None, "pct": None, "done_gb": None, "cap_gb": None,
            "speed": None, "dir": None, "eta": None, "temp": None, "temps": [], "trace": list(_trace),
            "log": [], "rows": results(), "attached": bool(name),
            "config": {"expected": num("EXPECTED_DRIVES"), "keep": num("KEEP_COUNT"), "auto_wipe": AUTO_WIPE,
                       "temp_warn": num("TEMP_WARN") or 80, "results": BASE},
            "host": socket.gethostname(), "bridge": bridge(name)}
    if not d:
        return snap
    label, serial = os.path.basename(d).split("-", 1)
    lines = [l.rstrip() for l in open(f"{d}/log.txt") if l.startswith("[")]
    head = next((l for l in lines if "PHASE A" in l), lines[0] if lines else "")
    kind = "nvme" if "(nvme)" in head else "sata"
    m = re.search(r"\)\s+(.*?)\s+serial", head)
    model = m.group(1) if m else ""
    try:
        temps = [int(x.split(",")[1]) for x in open(f"{d}/temps.csv") if x.split(",")[1].strip().isdigit()]
    except OSError:
        temps = []
    r = w = 0
    if name:
        try:
            f = open(f"/sys/block/{name}/stat").read().split()
            r, w = int(f[2]) * 512, int(f[6]) * 512
        except OSError:
            pass
    stages = pipeline(lines, kind, bool(cap) and w >= cap * 0.999, os.path.exists(f"{d}/A-done"))
    snap.update(drive={"label": int(label), "serial": serial, "model": model, "kind": kind,
                       "started": ts(head)}, stages=stages, temps=temps[-120:],
                temp=temps[-1] if temps else None, log=lines[-40:])
    offline = bool(name) and os.path.exists(f"/sys/block/{name}/device/state") and \
        open(f"/sys/block/{name}/device/state").read().strip() == "offline"
    if finished(d, kind):
        snap["state"] = "done"
        snap["message"] = "Finished — swap in the next drive" if name else "Enclosure empty — insert the next drive"
        return snap
    if offline or not name:
        snap["state"] = "attention"
        snap["message"] = ("Drive stopped responding — unplug the enclosure, wait 10 s, plug it back in"
                           if offline else "Enclosure unplugged mid-test — plug the same drive back in to resume")
        return snap
    active = next((s for s in stages if s["status"] == "active"), None)
    snap["state"], snap["active"] = "running", active["key"] if active else None
    snap["message"] = active["name"] if active else "Preparing"
    snap["cap_gb"] = round(cap / 1e9)
    rs, ws = _rates.get(name, (0, 0))
    done = spd = None
    if snap["active"] == "read":
        done, spd, snap["dir"] = r, rs, "read"
    elif snap["active"] == "write":
        done, spd, snap["dir"] = w, ws, "write"
    elif snap["active"] == "verify":
        base = _verify_base.get(name, cap if r >= cap * 1.5 else 0)
        done, spd, snap["dir"] = max(r - base, 0), rs, "verify"
    if done is not None:
        snap.update(pct=min(done / cap * 100, 100), done_gb=round(done / 1e9, 1), speed=round(spd),
                    eta=(cap - done) / (spd * 1e6) if spd > 5 else None)
    return snap


class H(BaseHTTPRequestHandler):
    def send(self, body, ctype):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        try:
            if self.path.startswith("/api"):
                self.send(json.dumps(snapshot()), "application/json")
            else:
                self.send(open(HTML, "rb").read(), "text/html; charset=utf-8")
        except Exception as e:                       # keep serving even if one snapshot breaks
            self.send(json.dumps({"error": repr(e)}), "application/json")

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    host, port = CONF["DASH_HOST"] or "0.0.0.0", num("DASH_PORT") or 8095
    threading.Thread(target=sampler, daemon=True).start()
    print(f"SSD Test Bench dashboard on http://{host}:{port}  (results: {BASE})", flush=True)
    ThreadingHTTPServer((host, port), H).serve_forever()
