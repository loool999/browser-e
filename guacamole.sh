#!/bin/bash

# ==============================================================================
#   Memory-Optimized VNC Chrome Desktop with Integrated Audio via Guacamole
# ==============================================================================
#   - Replaces noVNC with Apache Guacamole for seamless in-browser audio.
#   - Uses Docker for easy deployment of Guacamole.
#   - Smartly handles pre-installed Docker environments (like GitHub Codespaces).
#   - RAM-backed Chrome profile for speed and stability.
#   - Increased ulimits and shared memory.
# ==============================================================================

set -e

# --- Configuration ---
VNC_GEOMETRY=${VNC_GEOMETRY:-1366x768}
VNC_DEPTH=${VNC_DEPTH:-24}
WEB_PORT=${WEB_PORT:-8080}
PULSE_PORT=4713
VNC_PORT=5901
VNC_DISPLAY=:1

# Chrome Flags (optimized for RAM performance)
TARGET_USER=${SUDO_USER:-$(id -un)}
TARGET_HOME=$(eval echo "~$TARGET_USER")
TMP_CHROME_PROFILE="/dev/shm/chrome_profile_${TARGET_USER}"
CHROME_FLAGS="--no-sandbox \
              --disable-gpu \
              --disable-dev-shm-usage \
              --no-zygote \
              --start-maximized \
              --enable-low-end-device-mode \
              --disable-background-timer-throttling \
              --disable-backgrounding-occluded-windows \
              --disable-ipc-flooding-protection \
              --user-data-dir=${TMP_CHROME_PROFILE}"

# Guacamole Configuration
GUAC_USER=${GUAC_USER:-123}
GUAC_PASS=${GUAC_PASS:-123} # WARNING: Change this for production environments!
GUAC_CONFIG_DIR="/etc/guacamole"

print_info()  { echo -e "\e[34m[INFO]\e[0m    $1"; }
print_success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
print_warn()  { echo -e "\e[33m[WARN]\e[0m   $1"; }
print_error() { echo -e "\e[31m[ERROR]\e[0m  $1" >&2; }

# --- Cleanup only our temp files & containers, not the Guacamole config ---
cleanup() {
  print_info "Cleaning up background processes and containers..."
  # Only try to stop/rm if docker is actually running
  if docker info >/dev/null 2>&1; then
    docker stop guacd guacamole &>/dev/null || true
    docker rm   guacd guacamole &>/dev/null || true
  fi

  pkill -u "$TARGET_USER" -f "Xtigervnc"  &>/dev/null || true
  pkill -u "$TARGET_USER" -f "pulseaudio" &>/dev/null || true

  rm -rf "/tmp/chrome_profile_${TARGET_USER}" \
         "/dev/shm/chrome_profile_${TARGET_USER}"   || true

  print_success "Cleanup complete."
}

# --- Expand shared memory and set ulimits ---
expand_system_resources() {
  print_info "Attempting to expand shared memory to 2G..."
  if mount -o remount,size=2G /dev/shm 2>/dev/null; then
    print_success "Shared memory expanded to 2G."
  else
    print_warn "Could not resize /dev/shm (common in containerized environments)."
    print_info "Current /dev/shm size: $(df -h /dev/shm | tail -1 | awk '{print $2}')"
  fi

  print_info "Setting high ulimits for $TARGET_USER..."
  cat > /etc/security/limits.d/90-desktop.conf <<EOF
${TARGET_USER} soft nproc 65535
${TARGET_USER} hard nproc 65535
${TARGET_USER} soft nofile 65535
${TARGET_USER} hard nofile 65535
EOF

  # Only modify PAM if the file exists
  if [ -f /etc/pam.d/common-session ]; then
    grep -q "pam_limits.so" /etc/pam.d/common-session || \
      echo "session required pam_limits.so" >> /etc/pam.d/common-session
  fi
}

install_dependencies() {
  print_info "Updating package lists..."
  apt-get update

  print_info "Installing base dependencies (audio, VNC, etc.)..."
  DEPS=(tigervnc-standalone-server tigervnc-common openbox wget ca-certificates gnupg jq xterm pulseaudio pavucontrol)
  apt-get install -y --no-install-recommends "${DEPS[@]}"

  # Check if Docker is installed. If not, install it.
  if ! command -v docker &> /dev/null; then
      print_info "Docker not found. Installing docker.io..."
      apt-get install -y docker.io
  else
      print_info "Docker is already installed. Skipping installation."
  fi

  # Use `docker info` as the most reliable check for a running daemon.
  if ! docker info >/dev/null 2>&1; then
    print_info "Docker daemon is not responsive. Attempting to start it..."
    # Clean up a potential stale PID file that prevents startup
    rm -f /var/run/docker.pid
    # Start the daemon in the background and log to a file for debugging
    dockerd > /var/log/dockerd.log 2>&1 &
    sleep 5 # Give the daemon a few seconds to initialize
    # Final check to see if it worked
    if ! docker info >/dev/null 2>&1; then
        print_error "Failed to start the Docker daemon. See logs below:"
        # Print the last 10 lines of the log for immediate feedback
        tail -n 10 /var/log/dockerd.log
        exit 1
    else
        print_success "Docker daemon started successfully."
    fi
  else
      print_info "Docker daemon is already running and responsive."
  fi

  # Add user to docker group if not already added (skip if running as root)
  if [ "$TARGET_USER" != "root" ] && getent group docker > /dev/null; then
    if ! groups "$TARGET_USER" | grep -q docker; then
      print_info "Adding $TARGET_USER to docker group..."
      usermod -aG docker "$TARGET_USER"
      print_warn "User added to docker group. You may need to log out and back in for changes to take effect."
    fi
  elif [ "$TARGET_USER" = "root" ]; then
    print_warn "Running as root - Docker group membership not needed."
  else
    print_warn "Docker group not found - this may cause issues."
  fi

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

configure_system() {
  print_info "Configuring VNC, Audio, and Guacamole for $TARGET_USER..."
  local vnc_pass_file="$TARGET_HOME/.vnc/passwd"

  sudo -u "$TARGET_USER" mkdir -p "$TARGET_HOME/.vnc"
  if [ -z "$VNC_PASSWORD" ]; then
    print_warn "No VNC_PASSWORD env var set. A random one will be generated."
    VNC_PASSWORD=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)
    print_info "Generated VNC Password: $VNC_PASSWORD"
  fi
  VNC_PASS_CMD=$(command -v vncpasswd || echo "/usr/bin/vncpasswd")
  echo "$VNC_PASSWORD" | sudo -u "$TARGET_USER" "$VNC_PASS_CMD" -f > "$vnc_pass_file"

  chmod 600 "$vnc_pass_file"

  # --- Create Xstartup for VNC session ---
  # =========================================================================
  #   FIX: Add PULSE_SERVER environment variable.
  #   This tells applications inside VNC where to send their audio output.
  #   From the VNC session's perspective (running on the host), the
  #   PulseAudio server is on localhost at the specified port.
  # =========================================================================
  sudo -u "$TARGET_USER" bash -c "cat > '$TARGET_HOME/.vnc/xstartup' <<EOF
#!/bin/bash
export PULSE_SERVER=127.0.0.1:${PULSE_PORT}

unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
xterm &
# To debug audio, uncomment the line below to see the volume control panel
# pavucontrol &
google-chrome-stable \${CHROME_FLAGS} &
exec openbox
EOF"
  # Note: We need to escape ${CHROME_FLAGS} so it's interpreted when the
  #       script runs, not when the heredoc is created.
  sudo -u "$TARGET_USER" chmod +x "$TARGET_HOME/.vnc/xstartup"

  # --- Configure PulseAudio to accept network connections ---
  # Allow connections from Docker's network bridge as well as localhost.
  sudo -u "$TARGET_USER" mkdir -p "$TARGET_HOME/.config/pulse"
  sudo -u "$TARGET_USER" bash -c "cat > '$TARGET_HOME/.config/pulse/default.pa' <<'EOF'
.include /etc/pulse/default.pa
load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1;172.17.0.0/16 auth-anonymous=1
EOF"

  # --- Configure Guacamole ---
  print_info "Creating Guacamole configuration..."
  mkdir -p "${GUAC_CONFIG_DIR}"

  # Create guacamole.properties file
  cat > "${GUAC_CONFIG_DIR}/guacamole.properties" <<EOF
# Guacamole configuration
guacd-hostname: guacd
guacd-port: 4822
# Basic file authentication
basic-user-mapping: /etc/guacamole/user-mapping.xml
EOF

  # Create user-mapping.xml file
  cat > "${GUAC_CONFIG_DIR}/user-mapping.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<user-mapping>
    <authorize username="${GUAC_USER}" password="${GUAC_PASS}">
        <connection name="Chrome VNC Desktop">
            <protocol>vnc</protocol>
            <param name="hostname">host.docker.internal</param>
            <param name="port">${VNC_PORT}</param>
            <param name="password">${VNC_PASSWORD}</param>
            <param name="enable-audio">true</param>
            <param name="audio-servername">host.docker.internal:${PULSE_PORT}</param>
        </connection>
    </authorize>
</user-mapping>
EOF

  # Set proper permissions
  chmod 644 "${GUAC_CONFIG_DIR}/guacamole.properties"
  chmod 644 "${GUAC_CONFIG_DIR}/user-mapping.xml"

  print_info "Configuration files created:"
  ls -la "${GUAC_CONFIG_DIR}/"

  print_success "System configured for $TARGET_USER."
}

# Function to check if port is available
check_port() {
  local port=$1
  if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
    print_error "Port ${port} is already in use!"
    netstat -tuln | grep ":${port} "
    return 1
  fi
  return 0
}

# Function to debug configuration
debug_config() {
  print_info "=== Configuration Debug ==="
  echo "WEB_PORT: ${WEB_PORT}"
  echo "VNC_PORT: ${VNC_PORT}"
  echo "VNC_PASSWORD: ${VNC_PASSWORD}"
  echo "GUAC_USER: ${GUAC_USER}"
  echo "GUAC_PASS: ${GUAC_PASS}"
  echo "TARGET_USER: ${TARGET_USER}"
  echo "GUAC_CONFIG_DIR: ${GUAC_CONFIG_DIR}"
  
  if [ -f "${GUAC_CONFIG_DIR}/user-mapping.xml" ]; then
    echo "=== user-mapping.xml content ==="
    cat "${GUAC_CONFIG_DIR}/user-mapping.xml"
  fi
  
  if [ -f "${GUAC_CONFIG_DIR}/guacamole.properties" ]; then
    echo "=== guacamole.properties content ==="
    cat "${GUAC_CONFIG_DIR}/guacamole.properties"
  fi
  echo "=== End Debug ==="
}

# Function to test VNC connection
test_vnc_connection() {
  print_info "Testing VNC connection..."
  
  # Check if VNC server is running
  if pgrep -f "Xtigervnc.*:1" > /dev/null; then
    print_success "VNC server is running"
  else
    print_error "VNC server is not running"
    return 1
  fi
  
  # Check if VNC port is listening
  if netstat -tuln | grep -q ":${VNC_PORT} "; then
    print_success "VNC server is listening on port ${VNC_PORT}"
    echo "Listening interfaces:"
    netstat -tuln | grep ":${VNC_PORT} "
  else
    print_error "VNC server is not listening on port ${VNC_PORT}"
    netstat -tuln | grep ":59"
    return 1
  fi
  
  # Show VNC password file location
  local vnc_pass_file="$TARGET_HOME/.vnc/passwd"
  if [ -f "$vnc_pass_file" ]; then
    print_success "VNC password file exists: $vnc_pass_file"
    echo "File permissions: $(ls -l "$vnc_pass_file")"
  else
    print_error "VNC password file missing: $vnc_pass_file"
    return 1
  fi
}

# Function to wait for service to be ready
wait_for_service() {
  local host=$1
  local port=$2
  local service_name=$3
  local max_attempts=30
  local attempt=1

  print_info "Waiting for ${service_name} to be ready on ${host}:${port}..."
  
  while [ $attempt -le $max_attempts ]; do
    if curl -s --connect-timeout 2 "http://${host}:${port}/guacamole/" >/dev/null 2>&1; then
      print_success "${service_name} is ready!"
      return 0
    fi
    
    print_info "Attempt ${attempt}/${max_attempts}: ${service_name} not ready yet..."
    sleep 2
    attempt=$((attempt + 1))
  done
  
  print_error "${service_name} failed to start within expected time"
  return 1
}

# --- Start everything, stream logs, then wait for CTRL+C ---
start_services() {
  # Debug configuration
  debug_config

  # Check if port is available
  if ! check_port "$WEB_PORT"; then
    print_error "Cannot start service - port $WEB_PORT is in use"
    exit 1
  fi

  print_info "Starting PulseAudio for $TARGET_USER…"
  # The configuration is now handled entirely by the ~/.config/pulse/default.pa file
  sudo -u "$TARGET_USER" pulseaudio --start --log-target=syslog

  print_info "Starting VNC server (display $VNC_DISPLAY) as $TARGET_USER…"
  # Explicitly set the security type to basic VNC authentication to match
  # what the default Guacamole client expects. This disables TLS.
  # The "-localhost no" flag makes it listen on all network interfaces (0.0.0.0),
  # which is crucial for the Docker container to be able to reach it.
  sudo -u "$TARGET_USER" vncserver "$VNC_DISPLAY" \
    -geometry "$VNC_GEOMETRY" -depth "$VNC_DEPTH" -localhost no \
    -SecurityTypes VncAuth

  # Test VNC connection
  sleep 2
  test_vnc_connection

  print_info "Ensuring Docker network 'guacnet' exists…"
  docker network inspect guacnet &>/dev/null || \
    docker network create guacnet

  print_info "Pulling Guacamole images…"
  docker pull guacamole/guacd
  docker pull guacamole/guacamole

  print_info "Launching guacd daemon…"
  # =========================================================================
  #   FIX: Add --add-host here so guacd knows how to find the VNC server
  #   on the host machine.
  # =========================================================================
  docker run -d --rm --name guacd \
    --network guacnet \
    --add-host=host.docker.internal:host-gateway \
    guacamole/guacd

  # Wait for guacd to be ready
  sleep 3

  print_info "Launching Guacamole web interface..."
  # =========================================================================
  #   FIX: The --add-host flag is not needed here, it was moved to guacd.
  # =========================================================================
  docker run -d --rm --name guacamole \
    --network guacnet \
    -p "0.0.0.0:${WEB_PORT}:8080" \
    -v "${GUAC_CONFIG_DIR}:/etc/guacamole:ro" \
    -e "GUACAMOLE_HOME=/etc/guacamole" \
    -e "GUACD_HOSTNAME=guacd" \
    -e "GUACD_PORT=4822" \
    guacamole/guacamole

  # Wait for Guacamole to be ready
  if ! wait_for_service "localhost" "$WEB_PORT" "Guacamole"; then
    print_error "Guacamole failed to start properly"
    docker logs guacamole
    exit 1
  fi

  SERVER_IP=$(hostname -I | awk '{print $1}')

  print_success "Remote Desktop READY!"
  echo
  echo "  Access URL: http://${SERVER_IP}:${WEB_PORT}/guacamole/"
  echo "  Local URL:  http://localhost:${WEB_PORT}/guacamole/"
  echo
  echo "=== LOGIN CREDENTIALS ==="
  echo "  Guacamole Web Interface:"
  echo "    Username: ${GUAC_USER}"
  echo "    Password: ${GUAC_PASS}"
  echo
  echo "  VNC Server (internal use only):"
  echo "    VNC Password: ${VNC_PASSWORD}"
  echo "========================="
  echo

  print_info "Services listening on port ${WEB_PORT}:"
  netstat -tuln | grep ":${WEB_PORT} " || echo "No services found listening on port ${WEB_PORT}"

  print_warn "If you're in Codespaces, make sure port ${WEB_PORT} is forwarded/exposed."
  print_info "If you can't access the service, check your firewall settings."
  echo

  print_info "Streaming container logs (CTRL+C to stop & cleanup)…"
  echo "── guacd ─────────────────────────────────────────"
  docker logs --follow guacd &
  echo "── guacamole ────────────────────────────────────"
  docker logs --follow guacamole &

  wait
}

# --- Main Flow ---
# Ensure cleanup runs on script exit (e.g., CTRL+C)
trap cleanup EXIT

cleanup
# expand_system_resources # Often not needed/allowed in Codespaces
install_dependencies
configure_system
start_services