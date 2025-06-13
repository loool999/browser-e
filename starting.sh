#!/bin/bash

# ==============================================================================
#   Memory-Efficient VNC Chrome Desktop (Local‑User Edition)
# ==============================================================================
#   Optimized for stability in low-resource environments.
# ==============================================================================

set -e  # Exit immediately if a command exits with a non-zero status.

# --- Configuration ---
VNC_GEOMETRY=${VNC_GEOMETRY:-1366x768}
VNC_DEPTH=${VNC_DEPTH:-24}
WEB_PORT=${WEB_PORT:-8080}
VNC_PORT=5901
VNC_DISPLAY=:1

# Chrome flags for reducing memory usage and improving stability in containers
CHROME_FLAGS="--no-sandbox \
              --disable-gpu \
              --disable-dev-shm-usage \
              --single-process \
              --no-zygote \
              --start-maximized"

# Who is our “real” user?
TARGET_USER=${SUDO_USER:-$(id -un)}
TARGET_HOME=$(eval echo "~$TARGET_USER")

PUBLIC_URL=""
WEBSOCKIFY_PID=""

# --- Helper Functions ---
print_info()  { echo -e "\e[34m[INFO]\e[0m    $1"; }
print_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
print_warn()  { echo -e "\e[33m[WARN]\e[0m   $1"; }
print_error() { echo -e "\e[31m[ERROR]\e[0m  $1" >&2; }

# --- Cleanup on Exit ---
# A trap ensures that our background processes are killed when the script exits.
cleanup() {
  print_info "Cleaning up background processes..."
  # Kill the specific websockify PID if it's running
  if [ -n "$WEBSOCKIFY_PID" ]; then
    kill "$WEBSOCKIFY_PID" &>/dev/null || true
  fi
  # Kill any other stray processes owned by the user (just in case)
  pkill -u "$TARGET_USER" -f "Xtigervnc"    &>/dev/null || true
  pkill -u "$TARGET_USER" -f "websockify"   &>/dev/null || true
  # Clean up the temporary chrome profile
  if [ -d "/tmp/chrome_profile_${TARGET_USER}" ]; then
      rm -rf "/tmp/chrome_profile_${TARGET_USER}"
  fi
  print_success "Cleanup complete."
}
trap cleanup EXIT

# --- Must be root to install deps ---
if [ "$(id -u)" -ne 0 ]; then
  print_error "This script must be run with sudo."
  exit 1
fi

# --- 1. Install Dependencies as root ---
install_dependencies() {
  print_info "Updating package lists..."
  apt-get update

  print_info "Installing dependencies..."
  # Added xterm as a fallback terminal for robustness
  DEPS=(tigervnc-standalone-server openbox websockify wget ca-certificates gnupg jq xterm)
  apt-get install -y "${DEPS[@]}"

  if ! command -v google-chrome-stable &>/dev/null; then
    print_info "Installing Google Chrome..."
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub \
      | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] \
      http://dl.google.com/linux/chrome/deb/ stable main" \
      > /etc/apt/sources.list.d/google-chrome.list
    apt-get update
    apt-get install -y google-chrome-stable
  else
    print_info "Google Chrome already installed."
  fi
}

# --- 2. Setup noVNC as root ---
setup_novnc() {
  if [ ! -d "/usr/local/novnc" ]; then
    print_info "Downloading noVNC..."
    wget -qO- https://github.com/novnc/noVNC/archive/v1.4.0.tar.gz \
      | tar -xz -C /usr/local/
    mv /usr/local/noVNC-1.4.0 /usr/local/novnc
    ln -sf /usr/local/novnc/vnc.html /usr/local/novnc/index.html
  else
    print_info "noVNC already present."
  fi
}

# --- 3. Configure VNC under TARGET_USER ---
configure_vnc() {
  print_info "Configuring VNC for $TARGET_USER..."
  # Use sudo to run commands as the target user.
  # Note: Variables like $HOME must be escaped (\$) to be expanded by the user's shell, not root's.
  sudo -u "$TARGET_USER" bash -c '
    VNC_PASSWORD=${VNC_PASSWORD} # Inherit from parent environment if set
    mkdir -p "$HOME/.vnc"
    if [ -z "$VNC_PASSWORD" ]; then
      echo "[WARN] No VNC_PASSWORD environment variable set. You will be prompted to set one now."
      vncpasswd
    else
      echo "$VNC_PASSWORD" | vncpasswd -f > "$HOME/.vnc/passwd"
    fi
    chmod 600 "$HOME/.vnc/passwd"

    # Create the xstartup file
    cat > "$HOME/.vnc/xstartup" <<EOF
#!/bin/bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS

# Start a terminal as a fallback, in case Chrome fails
xterm &

# Launch Chrome with memory-saving flags and a temporary profile
google-chrome-stable '"${CHROME_FLAGS}"' --user-data-dir="/tmp/chrome_profile_'${TARGET_USER}'" &

# Start Openbox window manager
exec openbox
EOF
    chmod +x "$HOME/.vnc/xstartup"
  '
  print_success "VNC xstartup configured in $TARGET_HOME/.vnc."
}

# --- 4. Start Services and Wait ---
start_services() {
  print_info "Starting noVNC (port $WEB_PORT) as $TARGET_USER..."
  sudo -u "$TARGET_USER" websockify --web /usr/local/novnc \
    "$WEB_PORT" "localhost:$VNC_PORT" &
  WEBSOCKIFY_PID=$!

  # Forward port on Codespaces (non-fatal)
  if [ "${CODESPACES}" = "true" ] && command -v gh &>/dev/null; then
      print_info "Codespace detected. Forwarding port $WEB_PORT publicly..."
      if ! gh auth status &>/dev/null; then
          print_warn "GitHub CLI not authenticated. Skipping public port forwarding."
      else
          su -l "$TARGET_USER" -c "gh codespace ports visibility '${WEB_PORT}:public' >/dev/null"
          PORT_JSON=$(su -l "$TARGET_USER" -c "gh codespace ports --json portNumber,browseUrl")
          PUBLIC_URL=$(echo "$PORT_JSON" | jq -r ".[] | select(.portNumber==${WEB_PORT}) | .browseUrl")
      fi
  fi

  print_success "Remote Desktop READY!"
  echo "------------------------------------------------------------"
  if [ -n "$PUBLIC_URL" ]; then
    echo -e "\e[1mPublic URL:\e[0m ${PUBLIC_URL}/vnc.html"
  else
    IP=$(hostname -I | awk "{print \$1}")
    echo -e "\e[1mLocal URL:\e[0m http://${IP}:${WEB_PORT}"
    print_warn "Forward port ${WEB_PORT} if you need external access."
  fi
  echo "Use the VNC password you set for $TARGET_USER."
  echo "------------------------------------------------------------"
  print_info "Starting VNC server (display $VNC_DISPLAY) as $TARGET_USER..."
  print_info "The script will now wait. Press [CTRL+C] to stop."

  # Start the VNC server in the foreground.
  # The script will block here until the VNC server is stopped (e.g., via CTRL+C).
  # The `trap` will then handle cleanup.
  sudo -u "$TARGET_USER" vncserver "$VNC_DISPLAY" \
    -geometry "$VNC_GEOMETRY" -depth "$VNC_DEPTH" -localhost -fg
}

# --- Main Flow ---
cleanup # Run cleanup first to remove any old instances
install_dependencies
setup_novnc
configure_vnc
start_services