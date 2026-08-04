#!/data/data/com.termux/files/usr/bin/bash
#############################################
# Moto G 5G (2022) Austin - Automated Flash Script
# Device: XT2213-3 (RETUS, Unlocked)
# Bootloader: MBM-2.1-austin_g-61c726540b-250415
# Target Build: T1SAS33.73-40-0-12-20
#
# Functions:
# 1. Configure WiFi proxy (10.60.69.208:8387)
# 2. Scan firmware cache for matching firmware
# 3. Extract boot.img and vbmeta.img selectively
# 4. Validate OrangeFox recovery image
# 5. Monitor ADB/Fastboot connection over WiFi
# 6. Flash OrangeFox recovery to vendor_boot
#
# Termux port of Moto-G5G-AutoFlash-WiFi.ps1
# Requires: android-tools, curl, jq, unzip
#############################################

set -euo pipefail

# ============================================
# DEFAULT PARAMETERS (override via args)
# ============================================

PROXY_SERVER="${PROXY_SERVER:-10.60.69.208:8387}"
WORKING_DIR="${WORKING_DIR:-$HOME/MotoG5G_Flash}"
FIRMWARE_SEARCH_PATTERN="${FIRMWARE_SEARCH_PATTERN:-*XT2213-3_AUSTIN_RETUS_13_T1SAS33.73*}"
ORANGEFOX_FILE="${ORANGEFOX_FILE:-orangefox.img}"
DEVICE_IP_ADDRESS="${DEVICE_IP_ADDRESS:-}"
ADB_PORT="${ADB_PORT:-5555}"
FASTBOOT_TIMEOUT_SECONDS="${FASTBOOT_TIMEOUT_SECONDS:-120}"
FASTBOOT_POLL_INTERVAL_S="${FASTBOOT_POLL_INTERVAL_S:-2}"
PLATFORM_TOOLS_PATH="${PLATFORM_TOOLS_PATH:-}"
MANUAL_FIRMWARE_PATH="${MANUAL_FIRMWARE_PATH:-}"
DOWNLOAD_RETRY_COUNT="${DOWNLOAD_RETRY_COUNT:-3}"
DOWNLOAD_TIMEOUT_SECONDS="${DOWNLOAD_TIMEOUT_SECONDS:-300}"
SKIP_PROXY_CONFIG="${SKIP_PROXY_CONFIG:-false}"
SKIP_FIRMWARE_DOWNLOAD="${SKIP_FIRMWARE_DOWNLOAD:-false}"
SKIP_MAGISK_DOWNLOAD="${SKIP_MAGISK_DOWNLOAD:-false}"
SKIP_ORANGEFOX_DOWNLOAD="${SKIP_ORANGEFOX_DOWNLOAD:-false}"

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --skip-proxy)           SKIP_PROXY_CONFIG=true ;;
        --skip-firmware-dl)     SKIP_FIRMWARE_DOWNLOAD=true ;;
        --skip-magisk-dl)       SKIP_MAGISK_DOWNLOAD=true ;;
        --skip-orangefox-dl)    SKIP_ORANGEFOX_DOWNLOAD=true ;;
        --proxy=*)              PROXY_SERVER="${arg#*=}" ;;
        --device-ip=*)          DEVICE_IP_ADDRESS="${arg#*=}" ;;
        --working-dir=*)        WORKING_DIR="${arg#*=}" ;;
        --manual-firmware=*)    MANUAL_FIRMWARE_PATH="${arg#*=}" ;;
        --orangefox-file=*)     ORANGEFOX_FILE="${arg#*=}" ;;
        --platform-tools=*)     PLATFORM_TOOLS_PATH="${arg#*=}" ;;
        --adb-port=*)           ADB_PORT="${arg#*=}" ;;
        --fastboot-timeout=*)   FASTBOOT_TIMEOUT_SECONDS="${arg#*=}" ;;
        --retry-count=*)        DOWNLOAD_RETRY_COUNT="${arg#*=}" ;;
        --dl-timeout=*)         DOWNLOAD_TIMEOUT_SECONDS="${arg#*=}" ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --proxy=HOST:PORT           Proxy server (default: 10.60.69.208:8387)"
            echo "  --device-ip=IP              Device IP for WiFi ADB/Fastboot"
            echo "  --working-dir=PATH          Working directory (default: ~/MotoG5G_Flash)"
            echo "  --manual-firmware=PATH      Path to firmware ZIP"
            echo "  --orangefox-file=NAME       OrangeFox image filename (default: orangefox.img)"
            echo "  --platform-tools=PATH       Path to platform-tools directory"
            echo "  --adb-port=PORT             ADB TCP port (default: 5555)"
            echo "  --fastboot-timeout=SECS     Fastboot wait timeout (default: 120)"
            echo "  --retry-count=N             Download retry count (default: 3)"
            echo "  --dl-timeout=SECS           Download timeout (default: 300)"
            echo "  --skip-proxy                Skip proxy configuration"
            echo "  --skip-firmware-dl          Skip firmware download"
            echo "  --skip-magisk-dl            Skip Magisk download"
            echo "  --skip-orangefox-dl         Skip OrangeFox download"
            exit 0
            ;;
    esac
done

# ============================================
# CONFIGURATION & CONSTANTS
# ============================================

TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOG_FILE="$WORKING_DIR/flash_log_$TIMESTAMP.txt"
EXTRACTION_DIR="$WORKING_DIR/extracted_firmware"
DOWNLOADS_DIR="$WORKING_DIR/downloads"
BOOT_IMG="boot.img"
VBMETA_IMG="vbmeta.img"

# ADB / Fastboot tool paths
if [[ -n "$PLATFORM_TOOLS_PATH" ]]; then
    ADB_EXE="$PLATFORM_TOOLS_PATH/adb"
    FASTBOOT_EXE="$PLATFORM_TOOLS_PATH/fastboot"
else
    ADB_EXE="adb"
    FASTBOOT_EXE="fastboot"
fi

# Firmware details
FIRMWARE_BUILD="T1SAS33.73-40-0-12-20"
FIRMWARE_FILENAME="XT2213-3_AUSTIN_RETUS_13_${FIRMWARE_BUILD}.zip"

FIRMWARE_SOURCES=(
    "https://mirrors.lolinet.com/firmware/motorola/austin/official/RETUS/$FIRMWARE_FILENAME"
    "https://softwarecenter.motorola.com/api/firmware/link/msi/$FIRMWARE_FILENAME"
    "https://dl.xda-cdn.com/motorola/austin/$FIRMWARE_FILENAME"
)

# GitHub API endpoints
MAGISK_API_URL="https://api.github.com/repos/topjohnwu/Magisk/releases/latest"
ORANGEFOX_API_URL="https://api.github.com/repos/OrangeFox/Recovery/releases"
ORANGEFOX_DEVICE="austin"

# ============================================
# LOGGING FUNCTIONS
# ============================================

_log() {
    local level="$1"
    local color_code="$2"
    local message="$3"
    local timestamp
    timestamp=$(date +"%H:%M:%S")
    local log_line="[$timestamp] [$level] $message"
    echo -e "\e[${color_code}m${log_line}\e[0m"
    echo "$log_line" >> "$LOG_FILE" 2>/dev/null || true
}

log_info()    { _log "INFO"    "36" "$1"; }
log_success() { _log "SUCCESS" "32" "$1"; }
log_warning() { _log "WARNING" "33" "$1"; }
log_error()   { _log "ERROR"   "31" "$1"; }

write_section() {
    local title="$1"
    echo ""
    echo -e "\e[36m$(printf '=%.0s' {1..60})\e[0m"
    echo -e "\e[36m$title\e[0m"
    echo -e "\e[36m$(printf '=%.0s' {1..60})\e[0m"
    echo ""
}

# ============================================
# DEPENDENCY CHECK
# ============================================

check_dependencies() {
    write_section "Checking Dependencies"
    local missing=()

    for cmd in curl jq unzip "$ADB_EXE" "$FASTBOOT_EXE"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        echo ""
        log_info "Install with Termux:"
        log_info "  pkg install android-tools curl jq unzip"
        log_info ""
        log_info "Note: adb/fastboot require android-tools package."
        log_info "      curl, jq, unzip are also required."
        return 1
    fi

    log_success "All required tools are available."
    return 0
}

# ============================================
# PROXY CONFIGURATION
# ============================================

set_wifi_proxy() {
    local proxy_address="$1"
    write_section "Configuring WiFi Proxy"

    local proxy_host proxy_port
    proxy_host="${proxy_address%%:*}"
    proxy_port="${proxy_address##*:}"

    if [[ -z "$proxy_host" || -z "$proxy_port" || "$proxy_host" == "$proxy_port" ]]; then
        log_error "Invalid proxy format. Expected 'host:port', got: $proxy_address"
        return 1
    fi

    log_info "Proxy Host: $proxy_host"
    log_info "Proxy Port: $proxy_port"

    # Set environment variables for this session (used by curl etc.)
    export http_proxy="http://$proxy_address"
    export https_proxy="http://$proxy_address"
    export HTTP_PROXY="http://$proxy_address"
    export HTTPS_PROXY="http://$proxy_address"
    log_success "Session proxy environment variables set: http_proxy=http://$proxy_address"

    # Configure Android WiFi proxy via ADB (if device is available)
    if "$ADB_EXE" devices 2>/dev/null | grep -qE 'device$'; then
        log_info "Android device detected via ADB — configuring WiFi proxy on device..."
        if "$ADB_EXE" shell settings put global http_proxy "$proxy_address" 2>/dev/null; then
            log_success "Android WiFi proxy configured on device: $proxy_address"
        else
            log_warning "Could not set Android WiFi proxy via ADB (non-fatal)."
        fi
    else
        log_info "No ADB device connected yet — skipping Android WiFi proxy setup."
        log_info "To set Android proxy later, run:"
        log_info "  adb shell settings put global http_proxy $proxy_address"
    fi

    return 0
}

test_proxy_connectivity() {
    write_section "Testing Proxy Connectivity"
    log_info "Testing connectivity through proxy: $PROXY_SERVER"
    local test_url="http://www.google.com"
    log_info "Attempting connection to: $test_url"

    if curl -s --proxy "http://$PROXY_SERVER" --max-time 10 -o /dev/null -w "%{http_code}" "$test_url" \
        | grep -qE '^[23]'; then
        log_success "Proxy connectivity test PASSED"
        return 0
    else
        log_warning "Proxy connectivity test FAILED"
        log_warning "Continuing anyway, but network operations may fail"
        return 1
    fi
}

# ============================================
# DOWNLOAD FUNCTIONS (WITH RETRY & RESUME)
# ============================================

_curl_opts() {
    # Build common curl options
    local opts=("-L" "--user-agent" "Mozilla/5.0 (Linux; Android 13) Termux/0.1")
    if [[ "$SKIP_PROXY_CONFIG" != "true" && -n "$PROXY_SERVER" ]]; then
        opts+=(--proxy "http://$PROXY_SERVER")
    fi
    echo "${opts[@]}"
}

download_with_retry() {
    local url="$1"
    local destination="$2"
    local description="${3:-file}"
    local retry_count="${4:-$DOWNLOAD_RETRY_COUNT}"
    local timeout_seconds="${5:-$DOWNLOAD_TIMEOUT_SECONDS}"

    log_info "Downloading $description from: $url"
    log_info "Destination: $destination"

    local attempt=0
    while (( attempt < retry_count )); do
        (( attempt++ )) || true
        log_info "Attempt $attempt / $retry_count ..."

        # Build curl command; -C - enables resume for partial downloads
        local curl_resume_flag=""
        if [[ -f "$destination" ]]; then
            local partial_size
            partial_size=$(stat -c%s "$destination" 2>/dev/null || echo 0)
            log_info "Partial file detected ($(( partial_size / 1024 / 1024 )) MB). Attempting resume..."
            curl_resume_flag="-C -"
        fi

        # shellcheck disable=SC2086
        if curl -f $curl_resume_flag \
            $(_curl_opts) \
            --max-time "$timeout_seconds" \
            --connect-timeout 30 \
            --progress-bar \
            -o "$destination" \
            "$url"; then
            local final_size
            final_size=$(stat -c%s "$destination" 2>/dev/null || echo 0)
            log_success "$description downloaded successfully ($(( final_size / 1024 / 1024 )) MB)"
            return 0
        fi

        log_warning "Download attempt $attempt failed."
        if (( attempt < retry_count )); then
            local wait=$(( 2 ** attempt ))
            log_info "Retrying in $wait seconds..."
            sleep "$wait"
        fi
    done

    log_error "All $retry_count download attempts failed for: $url"
    return 1
}

# ============================================
# FIRMWARE FUNCTIONS
# ============================================

find_existing_firmware() {
    local search_dirs=("$DOWNLOADS_DIR" "$WORKING_DIR")
    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        # Use glob; sort by modification time (newest first via ls -t)
        local found
        found=$(find "$dir" -maxdepth 1 -name "$FIRMWARE_SEARCH_PATTERN" -type f \
                    2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            log_success "Found existing firmware: $found"
            echo "$found"
            return 0
        fi
    done
    echo ""
    return 1
}

download_firmware_with_fallback() {
    write_section "Downloading Motorola Firmware"
    mkdir -p "$DOWNLOADS_DIR"

    local dest_path="$DOWNLOADS_DIR/$FIRMWARE_FILENAME"

    # Auto-detect: firmware already downloaded
    local existing
    existing=$(find_existing_firmware) || true
    if [[ -n "$existing" ]]; then
        log_success "Firmware already present — skipping download."
        echo "$existing"
        return 0
    fi

    for url in "${FIRMWARE_SOURCES[@]}"; do
        log_info "Trying source: $url"
        if download_with_retry "$url" "$dest_path" "Motorola firmware"; then
            echo "$dest_path"
            return 0
        fi
        log_warning "Source failed, trying next fallback..."
    done

    log_error "All automated firmware sources failed."
    log_warning "Options:"
    log_info "  1. Place the firmware ZIP manually in: $DOWNLOADS_DIR"
    log_info "     Expected filename: $FIRMWARE_FILENAME"
    log_info "  2. Re-run with --manual-firmware=<path_to_zip>"
    log_info "  3. Re-run with --skip-firmware-dl to skip download"

    if [[ -n "$MANUAL_FIRMWARE_PATH" && -f "$MANUAL_FIRMWARE_PATH" ]]; then
        log_success "Using manually specified firmware: $MANUAL_FIRMWARE_PATH"
        echo "$MANUAL_FIRMWARE_PATH"
        return 0
    fi

    echo ""
    return 1
}

find_firmware_zip() {
    write_section "Searching for Firmware"

    if [[ -n "$MANUAL_FIRMWARE_PATH" && -f "$MANUAL_FIRMWARE_PATH" ]]; then
        log_success "Using manually specified firmware: $MANUAL_FIRMWARE_PATH"
        echo "$MANUAL_FIRMWARE_PATH"
        return 0
    fi

    local found
    found=$(find_existing_firmware) || true
    if [[ -n "$found" ]]; then
        echo "$found"
        return 0
    fi

    log_error "No firmware found."
    echo ""
    return 1
}

# ============================================
# FIRMWARE EXTRACTION
# ============================================

extract_firmware_images() {
    local firmware_zip_path="$1"
    write_section "Extracting Firmware Images"

    if [[ ! -f "$firmware_zip_path" ]]; then
        log_error "Firmware ZIP not found: $firmware_zip_path"
        return 1
    fi

    mkdir -p "$EXTRACTION_DIR"
    log_info "Opening firmware archive: $firmware_zip_path"

    # List archive contents
    log_info "Archive contents (first 20 entries):"
    unzip -l "$firmware_zip_path" 2>/dev/null | head -24 | while read -r line; do
        log_info "  $line"
    done

    # Extract boot.img
    log_info "Extracting $BOOT_IMG..."
    if unzip -p "$firmware_zip_path" "$BOOT_IMG" > "$EXTRACTION_DIR/$BOOT_IMG" 2>/dev/null; then
        local boot_size
        boot_size=$(stat -c%s "$EXTRACTION_DIR/$BOOT_IMG" 2>/dev/null || echo 0)
        log_success "$BOOT_IMG extracted successfully: $EXTRACTION_DIR/$BOOT_IMG"
        log_info "Size: $(( boot_size / 1024 / 1024 )) MB"
    else
        log_error "$BOOT_IMG not found in archive"
        return 1
    fi

    # Extract vbmeta.img
    log_info "Extracting $VBMETA_IMG..."
    if unzip -p "$firmware_zip_path" "$VBMETA_IMG" > "$EXTRACTION_DIR/$VBMETA_IMG" 2>/dev/null; then
        local vbmeta_size
        vbmeta_size=$(stat -c%s "$EXTRACTION_DIR/$VBMETA_IMG" 2>/dev/null || echo 0)
        log_success "$VBMETA_IMG extracted successfully: $EXTRACTION_DIR/$VBMETA_IMG"
        log_info "Size: $(( vbmeta_size / 1024 / 1024 )) MB"
    else
        log_error "$VBMETA_IMG not found in archive"
        return 1
    fi

    log_success "Firmware extraction completed successfully"
    return 0
}

# ============================================
# MAGISK DOWNLOAD
# ============================================

download_magisk_apk() {
    write_section "Downloading Magisk (Latest Release)"
    mkdir -p "$DOWNLOADS_DIR"
    local dest_path="$DOWNLOADS_DIR/Magisk.apk"

    if [[ -f "$dest_path" ]]; then
        log_success "Magisk APK already present: $dest_path"
        echo "$dest_path"
        return 0
    fi

    log_info "Querying GitHub for latest Magisk release..."
    local release_json
    # shellcheck disable=SC2086
    release_json=$(curl -sf $(_curl_opts) "$MAGISK_API_URL") || {
        log_error "Failed to query Magisk GitHub API."
        echo ""
        return 1
    }

    local apk_url apk_name tag_name
    apk_url=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("Magisk-v.*\\.apk$")) | .browser_download_url' | head -1)
    apk_name=$(echo "$release_json" | jq -r '.assets[] | select(.name | test("Magisk-v.*\\.apk$")) | .name' | head -1)
    tag_name=$(echo "$release_json" | jq -r '.tag_name')

    if [[ -z "$apk_url" || "$apk_url" == "null" ]]; then
        log_error "Could not locate Magisk APK asset in release."
        echo ""
        return 1
    fi

    log_info "Magisk version: $tag_name — $apk_name"
    if download_with_retry "$apk_url" "$dest_path" "Magisk APK"; then
        echo "$dest_path"
        return 0
    fi

    echo ""
    return 1
}

# ============================================
# ORANGEFOX DOWNLOAD
# ============================================

download_orangefox_recovery() {
    write_section "Downloading OrangeFox Recovery ($ORANGEFOX_DEVICE)"
    mkdir -p "$DOWNLOADS_DIR"
    local dest_path="$WORKING_DIR/$ORANGEFOX_FILE"

    if [[ -f "$dest_path" ]]; then
        log_success "OrangeFox image already present: $dest_path"
        echo "$dest_path"
        return 0
    fi

    log_info "Querying OrangeFox releases API for device: $ORANGEFOX_DEVICE ..."
    local releases_json img_url img_name release_tag
    # shellcheck disable=SC2086
    releases_json=$(curl -sf $(_curl_opts) "$ORANGEFOX_API_URL") || {
        log_error "Failed to query OrangeFox GitHub API."
        echo ""
        return 1
    }

    img_url=$(echo "$releases_json" | jq -r \
        --arg dev "$ORANGEFOX_DEVICE" \
        '[.[].assets[] | select(.name | test("OrangeFox.*" + $dev + ".*\\.(img|zip)$"; "i"))] | first | .browser_download_url' \
        2>/dev/null || echo "")
    img_name=$(echo "$releases_json" | jq -r \
        --arg dev "$ORANGEFOX_DEVICE" \
        '[.[].assets[] | select(.name | test("OrangeFox.*" + $dev + ".*\\.(img|zip)$"; "i"))] | first | .name' \
        2>/dev/null || echo "")
    release_tag=$(echo "$releases_json" | jq -r \
        --arg dev "$ORANGEFOX_DEVICE" \
        '[.[] | select(.assets[].name | test("OrangeFox.*" + $dev + ".*\\.(img|zip)$"; "i"))] | first | .tag_name' \
        2>/dev/null || echo "")

    if [[ -z "$img_url" || "$img_url" == "null" ]]; then
        log_warning "No OrangeFox asset found for device '$ORANGEFOX_DEVICE' via GitHub API."
        log_info "Trying OrangeFox download portal fallback..."

        local fallback_url="https://orangefox.download/api/v1/releases/get?codename=$ORANGEFOX_DEVICE&type=stable"
        # shellcheck disable=SC2086
        local of_data
        of_data=$(curl -sf $(_curl_opts) "$fallback_url" 2>/dev/null || echo "")
        local dl_url
        dl_url=$(echo "$of_data" | jq -r '.data.downloads.full.url' 2>/dev/null || echo "")

        if [[ -n "$dl_url" && "$dl_url" != "null" ]]; then
            log_info "OrangeFox portal URL: $dl_url"
            local temp_path="$DOWNLOADS_DIR/OrangeFox_austin.zip"
            if download_with_retry "$dl_url" "$temp_path" "OrangeFox recovery (zip)"; then
                if [[ "$temp_path" == *.zip ]]; then
                    log_info "Extracting OrangeFox image from ZIP..."
                    local extracted_img
                    extracted_img=$(unzip -l "$temp_path" 2>/dev/null | grep -oE '[^ ]+\.img$' | head -1)
                    if [[ -n "$extracted_img" ]]; then
                        if unzip -p "$temp_path" "$extracted_img" > "$dest_path"; then
                            log_success "OrangeFox image extracted to: $dest_path"
                            echo "$dest_path"
                            return 0
                        fi
                    fi
                fi
            fi
        fi

        log_error "OrangeFox portal fallback also failed."
        log_warning "Please download OrangeFox manually for '$ORANGEFOX_DEVICE' and place as: $dest_path"
        echo ""
        return 1
    fi

    log_info "Found OrangeFox release: $release_tag — $img_name"
    if download_with_retry "$img_url" "$dest_path" "OrangeFox recovery image"; then
        echo "$dest_path"
        return 0
    fi

    echo ""
    return 1
}

# ============================================
# ORANGEFOX VALIDATION
# ============================================

validate_orangefox_image() {
    write_section "Validating OrangeFox Recovery Image"
    local orangefox_path="$WORKING_DIR/$ORANGEFOX_FILE"

    if [[ ! -f "$orangefox_path" ]]; then
        log_error "OrangeFox image not found at: $orangefox_path"
        log_warning "Please place '$ORANGEFOX_FILE' in: $WORKING_DIR"
        return 1
    fi

    local file_size
    file_size=$(stat -c%s "$orangefox_path" 2>/dev/null || echo 0)
    log_info "OrangeFox image size: $(( file_size / 1024 / 1024 )) MB"

    if (( file_size < 10 * 1024 * 1024 )); then
        log_warning "OrangeFox image appears unusually small (< 10 MB)"
        return 1
    fi

    log_success "OrangeFox image validation passed"
    return 0
}

# ============================================
# ADB / FASTBOOT FUNCTIONS
# ============================================

test_adb_available() {
    write_section "Checking ADB Availability"
    local adb_version
    if adb_version=$("$ADB_EXE" version 2>&1); then
        log_success "ADB is available: $(echo "$adb_version" | head -1)"
        return 0
    else
        log_error "ADB not found or failed: $ADB_EXE"
        log_info "Install with: pkg install android-tools"
        return 1
    fi
}

test_fastboot_available() {
    write_section "Checking Fastboot Availability"
    local fb_version
    if fb_version=$("$FASTBOOT_EXE" --version 2>&1); then
        log_success "Fastboot is available: $(echo "$fb_version" | head -1)"
        return 0
    else
        log_error "Fastboot not found or failed: $FASTBOOT_EXE"
        log_info "Install with: pkg install android-tools"
        return 1
    fi
}

get_adb_devices() {
    "$ADB_EXE" devices 2>/dev/null | tail -n +2 | grep -v '^$' || true
}

get_fastboot_devices() {
    "$FASTBOOT_EXE" devices 2>/dev/null | grep -v '^$' || true
}

connect_adb_wifi() {
    local ip_address="$1"
    local port="${2:-$ADB_PORT}"
    write_section "Establishing WiFi ADB Connection"
    log_info "Connecting to device at $ip_address:$port"

    local output
    output=$("$ADB_EXE" connect "$ip_address:$port" 2>&1) || true
    log_info "Connection output: $output"

    if echo "$output" | grep -q "connected"; then
        log_success "Successfully connected to device via WiFi"
        return 0
    else
        log_error "Failed to connect to device at $ip_address:$port"
        return 1
    fi
}

disconnect_adb_wifi() {
    local ip_address="$1"
    local port="${2:-$ADB_PORT}"
    log_info "Disconnecting from device at $ip_address:$port"
    "$ADB_EXE" disconnect "$ip_address:$port" &>/dev/null || true
    log_success "Disconnected from WiFi ADB"
}

enable_adb_wifi_mode() {
    local ip_address="$1"
    write_section "Enabling WiFi ADB Mode on Device"
    log_info "Attempting to enable WiFi ADB mode via USB connection..."
    log_warning "This requires the device to be connected via USB with ADB enabled"

    local usb_devices
    usb_devices=$(get_adb_devices)
    if [[ -z "$usb_devices" ]]; then
        log_error "No device connected via USB. Cannot enable WiFi mode."
        return 1
    fi

    log_info "Connected device(s) found via USB:"
    echo "$usb_devices" | while read -r line; do log_info "  $line"; done

    log_info "Enabling TCP/IP ADB on port $ADB_PORT..."
    local output
    output=$("$ADB_EXE" tcpip "$ADB_PORT" 2>&1) || {
        log_error "Failed to enable WiFi ADB mode."
        log_info "Output: $output"
        return 1
    }

    log_info "Command output: $output"
    log_success "WiFi ADB mode enabled successfully"
    sleep 2
    return 0
}

wait_for_fastboot_device() {
    local timeout_seconds="${1:-$FASTBOOT_TIMEOUT_SECONDS}"
    local poll_interval="${2:-$FASTBOOT_POLL_INTERVAL_S}"
    write_section "Waiting for Device in Fastboot Mode"

    log_info "Waiting for USB Fastboot connection"
    log_warning "Ensure device is in Fastboot mode:"
    log_info "  1. Power off the device completely"
    log_info "  2. Press and hold Volume Down + Power until Fastboot mode appears"
    log_info "  3. Device will display 'FASTBOOT' on screen"
    echo ""

    local elapsed=0
    local poll_count=0

    while (( elapsed < timeout_seconds )); do
        (( poll_count++ )) || true
        local devices
        devices=$(get_fastboot_devices)
        if [[ -n "$devices" ]]; then
            log_success "Device detected in Fastboot mode!"
            log_info "Devices found:"
            echo "$devices" | while read -r line; do log_info "  $line"; done
            return 0
        fi

        if (( poll_count % 5 == 0 )); then
            log_warning "No device detected. Waiting... ($elapsed / $timeout_seconds seconds)"
        fi

        sleep "$poll_interval"
        (( elapsed += poll_interval )) || true
    done

    log_error "Timeout reached. No Fastboot device detected within $timeout_seconds seconds."
    return 1
}

wait_for_adb_device() {
    local ip_address="$1"
    local port="${2:-$ADB_PORT}"
    local timeout_seconds="${3:-60}"
    write_section "Waiting for WiFi ADB Device"

    log_info "Waiting for device at $ip_address:$port"
    log_warning "Ensure device has USB debugging enabled in Developer Options"
    echo ""

    local elapsed=0
    local poll_count=0

    while (( elapsed < timeout_seconds )); do
        (( poll_count++ )) || true
        local devices
        devices=$(get_adb_devices)
        if [[ -n "$devices" ]]; then
            log_success "Device detected via ADB!"
            log_info "Devices found:"
            echo "$devices" | while read -r line; do log_info "  $line"; done
            return 0
        fi

        if (( poll_count % 5 == 0 )); then
            log_warning "No device detected. Waiting... ($elapsed / $timeout_seconds seconds)"
        fi

        sleep 2
        (( elapsed += 2 )) || true
    done

    log_error "Timeout reached. No ADB device detected within $timeout_seconds seconds."
    return 1
}

# ============================================
# FASTBOOT FLASHING
# ============================================

flash_orangefox_recovery() {
    local image_path="$1"
    write_section "Flashing OrangeFox Recovery to vendor_boot"

    if [[ ! -f "$image_path" ]]; then
        log_error "OrangeFox image not found: $image_path"
        return 1
    fi

    log_info "Flashing: fastboot flash vendor_boot $image_path"
    log_info "This may take 30-60 seconds..."
    echo ""

    local output exit_code=0
    output=$("$FASTBOOT_EXE" flash vendor_boot "$image_path" 2>&1) || exit_code=$?
    echo "$output"
    log_info "Fastboot exit code: $exit_code"

    if (( exit_code == 0 )); then
        log_success "OrangeFox recovery flashed successfully!"
        return 0
    else
        log_error "Fastboot flash command failed with exit code: $exit_code"
        log_error "Output: $output"
        return 1
    fi
}

# ============================================
# POST-FLASH VERIFICATION
# ============================================

verify_post_flash_state() {
    write_section "Verifying Post-Flash State"
    log_info "Checking device connection..."

    local devices
    devices=$(get_fastboot_devices)
    if [[ -n "$devices" ]]; then
        log_info "Device still in Fastboot mode:"
        echo "$devices" | while read -r line; do log_info "  $line"; done
        log_warning "Next steps:"
        log_info "  1. Restart device: fastboot reboot"
        log_info "  2. Device will boot into OrangeFox recovery"
    else
        log_info "No devices detected. Device may have rebooted."
    fi
}

# ============================================
# SUMMARY
# ============================================

write_execution_summary() {
    local proxy_configured="$1"
    local proxy_connectivity="$2"
    local firmware_downloaded="$3"
    local firmware_found="$4"
    local extraction_success="$5"
    local magisk_downloaded="$6"
    local orangefox_downloaded="$7"
    local orangefox_valid="$8"
    local wifi_adb_connected="$9"
    local device_detected="${10}"
    local flash_success="${11}"

    write_section "Execution Summary"
    log_info "Proxy Configuration:    $proxy_configured"
    log_info "Proxy Connectivity:     $proxy_connectivity"
    log_info "Firmware Downloaded:    $firmware_downloaded"
    log_info "Firmware Found:         $firmware_found"
    log_info "Extraction Successful:  $extraction_success"
    log_info "Magisk Downloaded:      $magisk_downloaded"
    log_info "OrangeFox Downloaded:   $orangefox_downloaded"
    log_info "OrangeFox Validated:    $orangefox_valid"
    log_info "WiFi ADB Connected:     $wifi_adb_connected"
    log_info "Device Detected:        $device_detected"
    log_info "Flash Successful:       $flash_success"

    echo ""
    log_info "Log file:             $LOG_FILE"
    log_info "Working directory:    $WORKING_DIR"
    log_info "Downloads directory:  $DOWNLOADS_DIR"
    log_info "Extraction directory: $EXTRACTION_DIR"

    echo ""
    if [[ "$flash_success" == "true" ]]; then
        log_success "OPERATION COMPLETED SUCCESSFULLY!"
    else
        log_warning "OPERATION COMPLETED WITH ERRORS. See log file for details."
    fi
}

# ============================================
# MAIN WORKFLOW
# ============================================

main() {
    # Ensure working directory and log file are available before anything else
    mkdir -p "$WORKING_DIR" "$EXTRACTION_DIR" "$DOWNLOADS_DIR"
    touch "$LOG_FILE"

    # Result tracking
    local proxy_configured=false
    local proxy_connectivity=false
    local firmware_downloaded=false
    local firmware_found=false
    local extraction_success=false
    local magisk_downloaded=false
    local orangefox_downloaded=false
    local orangefox_valid=false
    local wifi_adb_connected=false
    local device_detected=false
    local flash_success=false

    # Header
    echo ""
    echo -e "\e[36m╔════════════════════════════════════════════════════════════╗\e[0m"
    echo -e "\e[36m║   MOTO G 5G (2022) AUTOMATED FLASH AUTOMATION SCRIPT      ║\e[0m"
    echo -e "\e[36m║   Device: XT2213-3 AUSTIN (RETUS, Unlocked)               ║\e[0m"
    echo -e "\e[36m║   Target: OrangeFox Recovery via vendor_boot              ║\e[0m"
    echo -e "\e[36m║   Connection: WiFi + Proxy Support (Termux)               ║\e[0m"
    echo -e "\e[36m╚════════════════════════════════════════════════════════════╝\e[0m"
    echo ""
    echo -e "\e[33mParameters:\e[0m"
    echo -e "\e[33m  Proxy Server:          $PROXY_SERVER\e[0m"
    echo -e "\e[33m  Platform Tools:        ${PLATFORM_TOOLS_PATH:-system PATH}\e[0m"
    echo -e "\e[33m  Working Directory:     $WORKING_DIR\e[0m"
    echo -e "\e[33m  Downloads Directory:   $DOWNLOADS_DIR\e[0m"
    echo -e "\e[33m  Firmware Pattern:      $FIRMWARE_SEARCH_PATTERN\e[0m"
    echo -e "\e[33m  Manual Firmware Path:  ${MANUAL_FIRMWARE_PATH:-Not specified}\e[0m"
    echo -e "\e[33m  OrangeFox File:        $ORANGEFOX_FILE\e[0m"
    echo -e "\e[33m  Device IP (WiFi):      ${DEVICE_IP_ADDRESS:-Not specified (USB mode)}\e[0m"
    echo -e "\e[33m  ADB Port:              $ADB_PORT\e[0m"
    echo -e "\e[33m  Fastboot Timeout:      $FASTBOOT_TIMEOUT_SECONDS seconds\e[0m"
    echo -e "\e[33m  Download Retry Count:  $DOWNLOAD_RETRY_COUNT\e[0m"
    echo -e "\e[33m  Download Timeout:      $DOWNLOAD_TIMEOUT_SECONDS seconds\e[0m"
    echo -e "\e[33m  Skip Firmware DL:      $SKIP_FIRMWARE_DOWNLOAD\e[0m"
    echo -e "\e[33m  Skip Magisk DL:        $SKIP_MAGISK_DOWNLOAD\e[0m"
    echo -e "\e[33m  Skip OrangeFox DL:     $SKIP_ORANGEFOX_DOWNLOAD\e[0m"
    echo ""

    # Dependency check
    if ! check_dependencies; then
        log_error "Dependency check failed. Please install missing tools and re-run."
        exit 1
    fi

    # Confirmation
    read -r -p "Continue with flash operation? (yes/no): " user_confirm
    if [[ "$user_confirm" != "yes" ]]; then
        log_warning "User cancelled operation"
        exit 0
    fi
    echo ""

    # Log header to file
    {
        echo "$(printf '=%.0s' {1..60})"
        echo "MOTO G 5G (2022) AUTOMATED FLASH SESSION"
        echo "Timestamp: $TIMESTAMP"
        echo "Proxy: $PROXY_SERVER"
        echo "$(printf '=%.0s' {1..60})"
    } >> "$LOG_FILE"

    # Step 0: Configure Proxy
    if [[ "$SKIP_PROXY_CONFIG" != "true" ]]; then
        if set_wifi_proxy "$PROXY_SERVER"; then
            proxy_configured=true
            if test_proxy_connectivity; then
                proxy_connectivity=true
            fi
        else
            log_warning "Failed to configure proxy. Continuing with local network only."
        fi
    else
        log_info "Proxy configuration skipped by user"
    fi

    # Step 1a: Download Magisk
    if [[ "$SKIP_MAGISK_DOWNLOAD" != "true" ]]; then
        local magisk_path
        magisk_path=$(download_magisk_apk) || true
        if [[ -n "$magisk_path" ]]; then
            magisk_downloaded=true
        else
            log_warning "Magisk download failed — continuing without it."
        fi
    else
        log_info "Magisk download skipped."
    fi

    # Step 1b: Download OrangeFox
    if [[ "$SKIP_ORANGEFOX_DOWNLOAD" != "true" ]]; then
        local of_path
        of_path=$(download_orangefox_recovery) || true
        if [[ -n "$of_path" ]]; then
            orangefox_downloaded=true
        else
            log_warning "OrangeFox download failed — will check for manually placed file."
        fi
    else
        log_info "OrangeFox download skipped."
    fi

    # Step 1c: Download firmware
    local firmware_path=""
    if [[ "$SKIP_FIRMWARE_DOWNLOAD" != "true" ]]; then
        firmware_path=$(download_firmware_with_fallback) || true
        if [[ -n "$firmware_path" ]]; then
            firmware_downloaded=true
        else
            log_warning "Automated firmware download failed. Falling back to local search..."
        fi
    else
        log_info "Firmware download skipped — searching local cache."
    fi

    # Step 2: Find firmware (local fallback)
    if [[ -z "$firmware_path" ]]; then
        firmware_path=$(find_firmware_zip) || true
    fi

    if [[ -n "$firmware_path" ]]; then
        firmware_found=true
    else
        log_error "Firmware not found via download or local cache."
        log_warning "You can still proceed if OrangeFox is present and images already extracted."
        log_info "To continue without firmware extraction, ensure boot.img & vbmeta.img"
        log_info "are already present in: $EXTRACTION_DIR"

        if [[ -f "$EXTRACTION_DIR/$BOOT_IMG" && -f "$EXTRACTION_DIR/$VBMETA_IMG" ]]; then
            log_success "Previously extracted images found — skipping extraction step."
            extraction_success=true
        else
            log_error "No pre-extracted images found. Firmware is required to continue."
            write_execution_summary "$proxy_configured" "$proxy_connectivity" \
                "$firmware_downloaded" "$firmware_found" "$extraction_success" \
                "$magisk_downloaded" "$orangefox_downloaded" "$orangefox_valid" \
                "$wifi_adb_connected" "$device_detected" "$flash_success"
            exit 1
        fi
    fi

    # Step 3: Extract firmware images
    if [[ -n "$firmware_path" && "$extraction_success" != "true" ]]; then
        if extract_firmware_images "$firmware_path"; then
            extraction_success=true
        else
            log_error "Firmware extraction failed. Aborting."
            write_execution_summary "$proxy_configured" "$proxy_connectivity" \
                "$firmware_downloaded" "$firmware_found" "$extraction_success" \
                "$magisk_downloaded" "$orangefox_downloaded" "$orangefox_valid" \
                "$wifi_adb_connected" "$device_detected" "$flash_success"
            exit 1
        fi
    fi

    # Step 4: Validate OrangeFox
    if validate_orangefox_image; then
        orangefox_valid=true
    else
        log_error "OrangeFox validation failed. Aborting."
        write_execution_summary "$proxy_configured" "$proxy_connectivity" \
            "$firmware_downloaded" "$firmware_found" "$extraction_success" \
            "$magisk_downloaded" "$orangefox_downloaded" "$orangefox_valid" \
            "$wifi_adb_connected" "$device_detected" "$flash_success"
        exit 1
    fi

    # Step 5: Check ADB & Fastboot
    if ! test_adb_available || ! test_fastboot_available; then
        log_error "ADB or Fastboot not available. Aborting."
        write_execution_summary "$proxy_configured" "$proxy_connectivity" \
            "$firmware_downloaded" "$firmware_found" "$extraction_success" \
            "$magisk_downloaded" "$orangefox_downloaded" "$orangefox_valid" \
            "$wifi_adb_connected" "$device_detected" "$flash_success"
        exit 1
    fi

    # Step 6: WiFi or USB connection
    if [[ -n "$DEVICE_IP_ADDRESS" ]]; then
        write_section "WiFi Connection Mode Selected"
        log_warning "First, connect device via USB and enable WiFi ADB mode..."

        if enable_adb_wifi_mode "$DEVICE_IP_ADDRESS"; then
            if connect_adb_wifi "$DEVICE_IP_ADDRESS" "$ADB_PORT"; then
                wifi_adb_connected=true
                if wait_for_adb_device "$DEVICE_IP_ADDRESS" "$ADB_PORT"; then
                    device_detected=true
                else
                    log_error "Device not detected via WiFi ADB. Aborting."
                    disconnect_adb_wifi "$DEVICE_IP_ADDRESS"
                    write_execution_summary "$proxy_configured" "$proxy_connectivity" \
                        "$firmware_downloaded" "$firmware_found" "$extraction_success" \
                        "$magisk_downloaded" "$orangefox_downloaded" "$orangefox_valid" \
                        "$wifi_adb_connected" "$device_detected" "$flash_success"
                    exit 1
                fi
            else
                log_error "Failed to connect via WiFi. Aborting."
                write_execution_summary "$proxy_configured" "$proxy_connectivity" \
                    "$firmware_downloaded" "$firmware_found" "$extraction_success" \
                    "$magisk_downloaded" "$orangefox_downloaded" "$orangefox_valid" \
                    "$wifi_adb_connected" "$device_detected" "$flash_success"
                exit 1
            fi
        else
            log_error "Failed to enable WiFi ADB mode. Aborting."
            write_execution_summary "$proxy_configured" "$proxy_connectivity" \
                "$firmware_downloaded" "$firmware_found" "$extraction_success" \
                "$magisk_downloaded" "$orangefox_downloaded" "$orangefox_valid" \
                "$wifi_adb_connected" "$device_detected" "$flash_success"
            exit 1
        fi
    else
        if wait_for_fastboot_device "$FASTBOOT_TIMEOUT_SECONDS"; then
            device_detected=true
        else
            log_error "No device detected in Fastboot mode. Aborting."
            write_execution_summary "$proxy_configured" "$proxy_connectivity" \
                "$firmware_downloaded" "$firmware_found" "$extraction_success" \
                "$magisk_downloaded" "$orangefox_downloaded" "$orangefox_valid" \
                "$wifi_adb_connected" "$device_detected" "$flash_success"
            exit 1
        fi
    fi

    # Step 7: Flash OrangeFox recovery
    local orangefox_path="$WORKING_DIR/$ORANGEFOX_FILE"
    if flash_orangefox_recovery "$orangefox_path"; then
        flash_success=true
    fi

    # Step 8: Cleanup WiFi if needed
    if [[ -n "$DEVICE_IP_ADDRESS" ]]; then
        disconnect_adb_wifi "$DEVICE_IP_ADDRESS"
    fi

    # Step 9: Post-flash verification
    verify_post_flash_state

    # Summary
    write_execution_summary "$proxy_configured" "$proxy_connectivity" \
        "$firmware_downloaded" "$firmware_found" "$extraction_success" \
        "$magisk_downloaded" "$orangefox_downloaded" "$orangefox_valid" \
        "$wifi_adb_connected" "$device_detected" "$flash_success"
}

main "$@"
