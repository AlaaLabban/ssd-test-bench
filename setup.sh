#!/usr/bin/env bash
# setup.sh — install the SSD Test Bench on a Linux computer that uses systemd.
#
#   sudo ./setup.sh            check/install tools, create config.conf, install + start the dashboard
#   sudo ./setup.sh remove     stop and remove both services (keeps your results and config)
#
# The runner (the part that actually tests drives) is installed but NOT started.
# Start it yourself when you're ready:  sudo systemctl start ssd-runner
set -euo pipefail
KIT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
[[ $EUID -eq 0 ]] || { echo "Run with sudo:  sudo ./setup.sh"; exit 1; }
[[ "$(uname -s)" == Linux ]] || { echo "This kit needs Linux (it talks to the drive through Linux tools)."; exit 1; }
command -v systemctl >/dev/null || { echo "This kit needs systemd (Ubuntu, Debian, Fedora, Arch, Mint, Pop!_OS, Raspberry Pi OS ... all have it)."; exit 1; }
RUN_AS="${SUDO_USER:-root}"

if [[ "${1:-}" == remove ]]; then
    systemctl disable --now ssd-runner ssd-status 2>/dev/null || true
    rm -f /etc/systemd/system/ssd-runner.service /etc/systemd/system/ssd-status.service
    systemctl daemon-reload
    echo "Removed both services. Your results ($KIT/results) and config.conf are untouched."
    exit 0
fi

echo "== 1. Tools"
declare -A pkg=([smartctl]=smartmontools [fio]=fio [hdparm]=hdparm [python3]=python3 [lsblk]=util-linux [blkdiscard]=util-linux [curl]=curl)
missing=()
for cmd in "${!pkg[@]}"; do command -v "$cmd" >/dev/null || missing+=("${pkg[$cmd]}"); done
mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u | sed '/^$/d')
if (( ${#missing[@]} )); then
    echo "Missing: ${missing[*]}"
    if   command -v apt-get >/dev/null; then inst=(apt-get install -y)
    elif command -v dnf     >/dev/null; then inst=(dnf install -y)
    elif command -v pacman  >/dev/null; then inst=(pacman -S --needed --noconfirm)
    elif command -v zypper  >/dev/null; then inst=(zypper install -y)
    else echo "Install them with your package manager, then run setup.sh again."; exit 1; fi
    read -rp "Install them now with '${inst[*]} ${missing[*]}'? [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]] || { echo "Stopped. Install them, then run setup.sh again."; exit 1; }
    [[ ${inst[0]} == apt-get ]] && apt-get update
    "${inst[@]}" "${missing[@]}"
fi
sv="$(smartctl --version | awk 'NR==1 {print $2}')"
echo "smartctl $sv, fio $(fio --version), $(python3 --version)"
awk -v v="$sv" 'BEGIN { split(v,a,"."); exit !(a[1] > 7 || (a[1] == 7 && a[2] >= 3)) }' \
    || echo "  ⚠ smartctl older than 7.3: NVMe sticks in USB enclosures may not be readable (SATA is fine)."

echo "== 2. Config"
if [[ ! -f "$KIT/config.conf" ]]; then
    cp "$KIT/config.example.conf" "$KIT/config.conf"
    chown "$RUN_AS": "$KIT/config.conf"
    echo "Created config.conf (AUTO_WIPE=no: read-only testing until you change it)."
else
    echo "config.conf already exists — kept as is."
fi
chmod +x "$KIT"/bin/*.sh "$KIT"/bin/*.py "$KIT/setup.sh"
mkdir -p "$KIT/results"; chmod 755 "$KIT/results"

echo "== 3. Services"
cat > /etc/systemd/system/ssd-runner.service <<EOF
[Unit]
Description=SSD Test Bench runner (tests each drive plugged into the USB enclosure)
After=local-fs.target

[Service]
Type=simple
ExecStart=$KIT/bin/ssd-runner.sh
Restart=on-failure
RestartSec=30
# stopping the runner also stops a test in progress — only stop it between drives
TimeoutStopSec=30
KillMode=control-group
EOF

cat > /etc/systemd/system/ssd-status.service <<EOF
[Unit]
Description=SSD Test Bench dashboard (read-only web page)
After=network-online.target

[Service]
Type=simple
User=$RUN_AS
ExecStart=/usr/bin/env python3 -I $KIT/bin/ssd-status.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ssd-status >/dev/null
systemctl restart ssd-status

port="$(sed -n 's/^DASH_PORT=\([0-9]*\).*/\1/p' "$KIT/config.conf")"; port="${port:-8095}"
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

✅ Installed.
   Dashboard:   http://localhost:$port   (from a phone/laptop on the same Wi-Fi: http://${ip:-<this-computer-ip>}:$port)
   Next:        1) edit $KIT/config.conf  (EXPECTED_DRIVES, KEEP_COUNT, MAX_GB, AUTO_WIPE ...)
                2) unplug every other USB drive / stick
                3) sudo systemctl start ssd-runner
                4) plug the enclosure with drive #1 in
   Stop:        sudo systemctl stop ssd-runner
EOF
