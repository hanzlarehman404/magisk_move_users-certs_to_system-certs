#!/system/bin/sh
# Magisk CA Installer - service.sh
# Runs after boot completion to install user CA certificates into system trust store.

MODPATH=${0%/*}  # module directory, provided by Magisk
LOG_FILE="/data/local/tmp/magisk_cert_install.log"
SYSTEM_CACERTS="/system/etc/security/cacerts"
KEYSTORE_DIR="/data/misc/keystore/user_0"

# -------------------------------------------------------------------
# Logging function
# -------------------------------------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# -------------------------------------------------------------------
# Notification function
# -------------------------------------------------------------------
notify() {
    local title="$1"
    local text="$2"
    local extra="$3"
    # Use cmd notification post (available on Android 8+)
    cmd notification post \
        --tag "magisk_ca_installer" \
        --title "$title" \
        --text "$text" \
        --extra "$extra" \
        >/dev/null 2>&1
}

# -------------------------------------------------------------------
# Check for required tools
# -------------------------------------------------------------------
check_openssl() {
    if command -v openssl >/dev/null 2>&1; then
        echo "openssl"
    elif [ -f "/system/bin/openssl" ] && [ -x "/system/bin/openssl" ]; then
        echo "/system/bin/openssl"
    elif [ -f "/system/xbin/openssl" ] && [ -x "/system/xbin/openssl" ]; then
        echo "/system/xbin/openssl"
    else
        echo ""
    fi
}

OPENSSL=$(check_openssl)
if [ -z "$OPENSSL" ]; then
    log "WARNING: openssl not found. Will rely on filename hash extraction (may be less reliable)."
fi

# -------------------------------------------------------------------
# Start logging
# -------------------------------------------------------------------
log "=== Magisk CA Installer started ==="

# Ensure target directory exists
if [ ! -d "$SYSTEM_CACERTS" ]; then
    log "ERROR: $SYSTEM_CACERTS does not exist. Exiting."
    notify "Magisk CA Installer" "Certificate installation failed" "error"
    exit 1
fi

# -------------------------------------------------------------------
# Mount tmpfs over system cacerts
# -------------------------------------------------------------------
log "Mounting tmpfs on $SYSTEM_CACERTS"
mount -t tmpfs tmpfs "$SYSTEM_CACERTS" 2>> "$LOG_FILE"
if [ $? -ne 0 ]; then
    log "ERROR: Failed to mount tmpfs. Check if already mounted or permissions."
    notify "Magisk CA Installer" "Certificate installation failed" "error"
    exit 1
fi
log "tmpfs mounted successfully."

# -------------------------------------------------------------------
# Process user CA certificates
# -------------------------------------------------------------------
# Use find to locate files containing "CACERT" (case‑sensitive, as per observed pattern)
# We use -print0 to handle any special characters in filenames.
CERT_FILES=$(find "$KEYSTORE_DIR" -type f -name '*CACERT*' -print0 2>/dev/null)
if [ -z "$CERT_FILES" ]; then
    log "No CACERT files found in $KEYSTORE_DIR."
    notify "Magisk CA Installer" "No certificates to install" "info"
    # Unmount? No, leave tmpfs empty; system will have no certs – but that's intended.
    exit 0
fi

# Counters for logging
total=0
success=0
failed=0
skipped=0
installed_certs=""

# Process each file (handle spaces and newlines safely)
find "$KEYSTORE_DIR" -type f -name '*CACERT*' -print0 | while IFS= read -r -d '' cert_file; do
    total=$((total + 1))
    log "Processing: $cert_file"
    
    # Extract certificate hash (target filename)
    hash=""
    
    # Method 1: Use openssl to compute subject hash (most reliable)
    if [ -n "$OPENSSL" ]; then
        # Create a temporary file for PEM conversion
        temp_pem="${TMPDIR:-/data/local/tmp}/temp_cert.pem"
        # Attempt to convert from DER (most likely) to PEM
        if "$OPENSSL" x509 -inform DER -in "$cert_file" -outform PEM -out "$temp_pem" 2>/dev/null; then
            # Get the subject hash
            hash=$("$OPENSSL" x509 -in "$temp_pem" -subject_hash -noout 2>/dev/null | head -n1)
            rm -f "$temp_pem"
        else
            # Maybe it's already PEM? Try reading directly
            if "$OPENSSL" x509 -inform PEM -in "$cert_file" -subject_hash -noout 2>/dev/null; then
                hash=$("$OPENSSL" x509 -in "$cert_file" -subject_hash -noout 2>/dev/null | head -n1)
            else
                log "  - openssl could not parse certificate; will try filename extraction."
            fi
        fi
    fi
    
    # Method 2: Extract hash from filename (fallback)
    if [ -z "$hash" ]; then
        # Look for an 8‑character hex string immediately followed by +^0 at the end of the filename
        # Example: ...system:9a5ba575+^0
        base=$(basename "$cert_file")
        # Use grep to find a pattern: 8 hex chars, then +^0 (optional + before ^0)
        # We capture the hex part.
        possible_hash=$(echo "$base" | grep -oE '[0-9a-f]{8}\+?\^0' | sed 's/[+^0]//g')
        if [ -n "$possible_hash" ]; then
            hash="$possible_hash"
            log "  - Extracted hash '$hash' from filename."
        else
            log "  - Could not determine hash from filename."
        fi
    fi
    
    if [ -z "$hash" ]; then
        log "  - Skipping: unable to obtain hash."
        failed=$((failed + 1))
        continue
    fi
    
    target="$SYSTEM_CACERTS/$hash.0"
    
    # Check for duplicate (if file already exists)
    if [ -f "$target" ]; then
        log "  - Skipping: $target already exists (duplicate)."
        skipped=$((skipped + 1))
        continue
    fi
    
    # Copy the certificate content to the target
    # We keep the original format (DER or PEM) – Android can handle both.
    if cp "$cert_file" "$target" 2>> "$LOG_FILE"; then
        chmod 644 "$target"
        chown root:root "$target"
        log "  - Installed: $target"
        success=$((success + 1))
        installed_certs="$installed_certs $hash.0"
    else
        log "  - Failed to copy certificate."
        failed=$((failed + 1))
    fi
done

# -------------------------------------------------------------------
# Summary and notification
# -------------------------------------------------------------------
log "Total processed: $total, Installed: $success, Skipped: $skipped, Failed: $failed"
if [ $success -gt 0 ]; then
    notify "Magisk CA Installer" "Certificates installed successfully" "$installed_certs"
elif [ $total -eq 0 ]; then
    notify "Magisk CA Installer" "No certificates found" "info"
else
    notify "Magisk CA Installer" "Certificate installation failed" "error"
fi

log "=== Magisk CA Installer finished ==="
exit 0