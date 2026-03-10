#!/system/bin/sh
# Magisk CA Installer - service.sh
# Runs after boot to install user CA certificates into system trust store

MODPATH=${0%/*}
LOG_FILE="/data/local/tmp/magisk_cert_install.log"
SYSTEM_CACERTS="/system/etc/security/cacerts"
KEYSTORE_DIR="/data/misc/keystore/user_0"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Notification function
notify() {
    local title="$1"
    local text="$2"
    cmd notification post \
        --tag "magisk_ca_installer" \
        --title "$title" \
        --text "$text" \
        >/dev/null 2>&1
}

# Check for openssl
check_openssl() {
    if command -v openssl >/dev/null 2>&1; then
        echo "openssl"
    elif [ -f "/system/bin/openssl" ]; then
        echo "/system/bin/openssl"
    else
        echo ""
    fi
}

# Start logging
log "=== Magisk CA Installer started ==="

# Check if system cacerts exists
if [ ! -d "$SYSTEM_CACERTS" ]; then
    log "ERROR: $SYSTEM_CACERTS does not exist"
    notify "Magisk CA Installer" "Installation failed - system certs dir missing"
    exit 1
fi

# Mount tmpfs over system cacerts
log "Mounting tmpfs on $SYSTEM_CACERTS"
mount -t tmpfs tmpfs "$SYSTEM_CACERTS" 2>> "$LOG_FILE"
if [ $? -ne 0 ]; then
    log "ERROR: Failed to mount tmpfs"
    notify "Magisk CA Installer" "Installation failed - mount error"
    exit 1
fi
log "tmpfs mounted successfully"

# Process certificates
total=0
success=0
OPENSSL=$(check_openssl)

if [ -d "$KEYSTORE_DIR" ]; then
    # Use null-delimited find to handle special characters and avoid subshell
    while IFS= read -r -d '' cert_file; do
        total=$((total + 1))
        log "Processing: $cert_file"
        
        # Debug: check if file exists
        if [ ! -f "$cert_file" ]; then
            log "  - ERROR: File does not exist (even though find returned it)"
            continue
        fi
        
        hash=""
        
        # Try openssl first
        if [ -n "$OPENSSL" ]; then
            temp_pem="/data/local/tmp/temp_cert.pem"
            # Attempt to convert DER to PEM
            if "$OPENSSL" x509 -inform DER -in "$cert_file" -outform PEM -out "$temp_pem" 2>/dev/null; then
                hash=$("$OPENSSL" x509 -in "$temp_pem" -subject_hash -noout 2>/dev/null)
                rm -f "$temp_pem"
            else
                # Maybe it's already PEM
                if "$OPENSSL" x509 -inform PEM -in "$cert_file" -subject_hash -noout 2>/dev/null; then
                    hash=$("$OPENSSL" x509 -in "$cert_file" -subject_hash -noout 2>/dev/null)
                else
                    log "  - openssl could not parse certificate"
                fi
            fi
        fi
        
        # Fallback: extract hash from filename
        if [ -z "$hash" ]; then
            base=$(basename "$cert_file")
            # Look for Puser: or Psystem: followed by 8 hex digits
            hash=$(echo "$base" | grep -oE '(Puser|Psystem):[0-9a-f]{8}' | head -n1 | cut -d':' -f2)
            if [ -z "$hash" ]; then
                # Fallback to any 8 hex digits (original method)
                hash=$(echo "$base" | grep -oE '[0-9a-f]{8}' | head -n1)
            fi
        fi
        
        if [ -z "$hash" ]; then
            log "  - Could not determine hash, skipping"
            continue
        fi
        
        target="$SYSTEM_CACERTS/$hash.0"
        
        if [ -f "$target" ]; then
            log "  - $target already exists, skipping"
            continue
        fi
        
        # Copy with explicit error logging
        if cp "$cert_file" "$target" 2>> "$LOG_FILE"; then
            chmod 644 "$target"
            chown root:root "$target"
            log "  - Installed: $target"
            success=$((success + 1))
        else
            log "  - Failed to copy certificate (cp error)"
            # Additional debug: try ls -l on source
            ls -l "$cert_file" >> "$LOG_FILE" 2>&1
        fi
    done < <(find "$KEYSTORE_DIR" -type f -name '1000_CACERT*' -print0 2>/dev/null)
    # Note: -name '1000_CACERT*' ensures only UID 1000 certificates are processed
fi

# Summary
log "Certificates installed: $success / $total"
if [ $success -gt 0 ]; then
    notify "Magisk CA Installer" "$success certificate(s) installed successfully"
elif [ $total -eq 0 ]; then
    notify "Magisk CA Installer" "No 1000_CACERT certificates found"
else
    notify "Magisk CA Installer" "Certificate installation failed"
fi

log "=== Magisk CA Installer finished ==="
exit 0