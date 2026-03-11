#!/system/bin/sh
# Magisk CA Installer - service.sh
# Runs after boot to install user CA certificates into system trust store

MODPATH=${0%/*}
LOG_FILE="/data/local/tmp/magisk_cert_install.log"
SYSTEM_CACERTS="/system/etc/security/cacerts"
KEYSTORE_DIR="/data/misc/keystore/user_0"
TEMP_CERT_DIR="/dev/tmp_cacerts"

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Improved notification function with proper Android requirements
notify() {
    local title="$1"
    local text="$2"
    local success="$3"
    
    # Method 1: Using Magisk's built-in notification helper (most reliable)
    if [ -f /data/adb/magisk/util_functions.sh ]; then
        # Try to use Magisk's notification system
        magisk --notification "Magisk CA Installer" "$text" 2>/dev/null
    fi
    
    # Method 2: Using cmd notification with proper channel (Android 8+)
    if [ "$success" = "1" ]; then
        # Success notification with checkmark emoji
        cmd notification post \
            -S bigtext \
            --tag "magisk_ca_installer" \
            --title "$title" \
            --text "$text" \
            --icon "perm_group_network" \
            --priority 2 \
            --category "status" \
            >/dev/null 2>&1
    else
        # Info notification
        cmd notification post \
            -S bigtext \
            --tag "magisk_ca_installer" \
            --title "$title" \
            --text "$text" \
            --icon "perm_group_network" \
            --priority 1 \
            --category "service" \
            >/dev/null 2>&1
    fi
    
    # Method 3: Write to system log (appears in logcat)
    log "NOTIFICATION: $title - $text"
    
    # Method 4: Try to use service call (legacy method)
    service call notification 1 i32 0 s16 "com.android.shell" s16 "$title" s16 "$text" >/dev/null 2>&1
    
    # Method 5: Create a toast notification
    su -c "am broadcast -a android.intent.action.USER_PRESENT --es toast_text \"$text\" --es toast_title \"$title\" com.android.systemui" >/dev/null 2>&1
}

# Function to verify certificate is properly installed and visible
verify_certificate() {
    local cert_path="$1"
    local hash="$2"
    
    # Check file exists
    if [ ! -f "$cert_path" ]; then
        log "  - ❌ Verification failed: File missing"
        return 1
    fi
    
    # Check permissions (should be 644)
    local perms=$(stat -c %a "$cert_path" 2>/dev/null || stat -f %A "$cert_path" 2>/dev/null)
    if [ "$perms" != "644" ]; then
        log "  - ⚠️ Fixing permissions: was $perms, setting to 644"
        chmod 644 "$cert_path"
    fi
    
    # Check ownership (should be root:root)
    local owner=$(stat -c %U:%G "$cert_path" 2>/dev/null || stat -f %Su:%Sg "$cert_path" 2>/dev/null)
    if [ "$owner" != "root:root" ]; then
        log "  - ⚠️ Fixing ownership: was $owner, setting to root:root"
        chown root:root "$cert_path"
    fi
    
    # Check SELinux context
    if command -v getenforce >/dev/null && [ "$(getenforce)" != "Disabled" ]; then
        local context=$(ls -Z "$cert_path" 2>/dev/null | awk '{print $1}')
        if ! echo "$context" | grep -q "system_security_cacerts_file"; then
            log "  - ⚠️ Fixing SELinux context"
            chcon u:object_r:system_security_cacerts_file:s0 "$cert_path" 2>/dev/null
        fi
    fi
    
    log "  - ✅ Verification passed: $hash.0"
    return 0
}

# Function to set proper permissions and SELinux context
set_cert_permissions() {
    local dir="$1"
    local cert_count=0
    
    log "  - Setting ownership (root:root)..."
    chown -R root:root "$dir" 2>> "$LOG_FILE"
    
    log "  - Setting file permissions (644)..."
    find "$dir" -type f -exec chmod 644 {} \; 2>> "$LOG_FILE"
    
    log "  - Setting directory permissions (755)..."
    find "$dir" -type d -exec chmod 755 {} \; 2>> "$LOG_FILE"
    
    # Set SELinux context - this is CRITICAL for Settings to show certificates
    log "  - Setting SELinux context..."
    if command -v chcon >/dev/null 2>&1; then
        chcon -R u:object_r:system_security_cacerts_file:s0 "$dir" 2>> "$LOG_FILE"
        log "    ✓ SELinux context applied"
    else
        # Try multiple paths for chcon
        /system/bin/chcon -R u:object_r:system_security_cacerts_file:s0 "$dir" 2>> "$LOG_FILE" || \
        /system/xbin/chcon -R u:object_r:system_security_cacerts_file:s0 "$dir" 2>> "$LOG_FILE" || \
        log "    ⚠️ Warning: Could not set SELinux context (chcon not found)"
    fi
    
    # Verify a sample file
    local sample_file=$(find "$dir" -type f -name "*.0" | head -1)
    if [ -n "$sample_file" ]; then
        verify_certificate "$sample_file" "sample"
    fi
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
log "Device: $(getprop ro.product.model)"
log "Android: $(getprop ro.build.version.release)"

# Check if system cacerts exists
if [ ! -d "$SYSTEM_CACERTS" ]; then
    log "ERROR: $SYSTEM_CACERTS does not exist"
    notify "Magisk CA Installer" "❌ Failed: system certs dir missing" "0"
    exit 1
fi

# Check if we have any certificates to process (only 1000_CACERT)
CERT_COUNT=$(find "$KEYSTORE_DIR" -type f -name '1000_CACERT*' 2>/dev/null | wc -l)
if [ "$CERT_COUNT" -eq 0 ]; then
    log "No 1000_CACERT certificates found to install"
    notify "Magisk CA Installer" "ℹ️ No user certificates found" "0"
    exit 0
fi

log "Found $CERT_COUNT certificate(s) to process"

# Create temporary directory in memory
log "Creating temporary directory: $TEMP_CERT_DIR"
rm -rf "$TEMP_CERT_DIR" 2>/dev/null
mkdir -p "$TEMP_CERT_DIR"

# Copy ALL existing system certificates to temp directory
log "Copying existing system certificates..."
if [ -d "$SYSTEM_CACERTS" ] && [ "$(ls -A $SYSTEM_CACERTS 2>/dev/null)" ]; then
    cp -f $SYSTEM_CACERTS/* "$TEMP_CERT_DIR/" 2>> "$LOG_FILE"
    system_count=$(ls -1 $SYSTEM_CACERTS | wc -l)
    log "  - Copied $system_count existing system certificates"
else
    log "  - No existing system certificates found"
fi

# Process user certificates
OPENSSL=$(check_openssl)
success=0
installed_certs=""
failed_certs=""

log "Processing user certificates..."

# Use null-delimited find to handle special characters
while IFS= read -r -d '' cert_file; do
    cert_name=$(basename "$cert_file")
    log "Processing: $cert_name"
    
    # Verify file exists and is readable
    if [ ! -f "$cert_file" ] || [ ! -r "$cert_file" ]; then
        log "  - ❌ ERROR: File not accessible"
        failed_certs="$failed_certs $cert_name"
        continue
    fi
    
    hash=""
    
    # Try openssl first
    if [ -n "$OPENSSL" ]; then
        temp_pem="/data/local/tmp/temp_cert.pem"
        # Try DER format first
        if "$OPENSSL" x509 -inform DER -in "$cert_file" -outform PEM -out "$temp_pem" 2>/dev/null; then
            hash=$("$OPENSSL" x509 -in "$temp_pem" -subject_hash -noout 2>/dev/null)
            rm -f "$temp_pem"
        # Try PEM format
        elif "$OPENSSL" x509 -inform PEM -in "$cert_file" -subject_hash -noout 2>/dev/null; then
            hash=$("$OPENSSL" x509 -in "$cert_file" -subject_hash -noout 2>/dev/null)
        else
            log "  - openssl could not parse certificate"
        fi
    fi
    
    # Fallback: extract hash from filename
    if [ -z "$hash" ]; then
        base=$(basename "$cert_file")
        # Look for Puser: or Psystem: followed by 8 hex digits
        hash=$(echo "$base" | grep -oE '(Puser|Psystem):[0-9a-f]{8}' | head -n1 | cut -d':' -f2)
        if [ -z "$hash" ]; then
            # Fallback to any 8 hex digits
            hash=$(echo "$base" | grep -oE '[0-9a-f]{8}' | head -n1)
        fi
    fi
    
    if [ -z "$hash" ]; then
        log "  - ❌ Could not determine hash, skipping"
        failed_certs="$failed_certs $cert_name"
        continue
    fi
    
    target="$TEMP_CERT_DIR/$hash.0"
    
    if [ -f "$target" ]; then
        log "  - ⚠️ $hash.0 already exists, skipping"
        continue
    fi
    
    # Copy to temp directory first
    if cp "$cert_file" "$target" 2>> "$LOG_FILE"; then
        log "  - ✅ Added to temp dir: $hash.0"
        success=$((success + 1))
        installed_certs="$installed_certs $hash.0"
    else
        log "  - ❌ Failed to copy certificate"
        ls -l "$cert_file" >> "$LOG_FILE" 2>&1
        failed_certs="$failed_certs $cert_name"
    fi
    
done < <(find "$KEYSTORE_DIR" -type f -name '1000_CACERT*' -print0 2>/dev/null)

# Only proceed if we added any certificates
if [ $success -gt 0 ]; then
    log "=== Setting permissions on temp directory ==="
    set_cert_permissions "$TEMP_CERT_DIR"
    
    # Check current mount
    log "Current mount at $SYSTEM_CACERTS:"
    mount | grep "$SYSTEM_CACERTS" >> "$LOG_FILE" 2>&1
    
    # Now mount tmpfs over system certificate directory
    log "Mounting tmpfs on $SYSTEM_CACERTS"
    mount -t tmpfs tmpfs "$SYSTEM_CACERTS" 2>> "$LOG_FILE"
    if [ $? -ne 0 ]; then
        log "❌ ERROR: Failed to mount tmpfs"
        notify "Magisk CA Installer" "❌ Failed: mount error" "0"
        rm -rf "$TEMP_CERT_DIR"
        exit 1
    fi
    log "✓ tmpfs mounted successfully"
    
    # Verify mount succeeded
    mount | grep "$SYSTEM_CACERTS" >> "$LOG_FILE" 2>&1
    
    # Copy ALL certificates from temp dir to mounted directory
    log "Copying certificates to system store..."
    cp -f $TEMP_CERT_DIR/* "$SYSTEM_CACERTS/" 2>> "$LOG_FILE"
    copy_result=$?
    if [ $copy_result -ne 0 ]; then
        log "⚠️ Warning: Some files may not have copied properly (error: $copy_result)"
    fi
    
    # Apply permissions and SELinux context to the mounted directory
    log "Applying final permissions to system store..."
    set_cert_permissions "$SYSTEM_CACERTS"
    
    # Verify each installed certificate
    log "=== Verifying installed certificates ==="
    verified=0
    for cert in $installed_certs; do
        if verify_certificate "$SYSTEM_CACERTS/$cert" "$cert"; then
            verified=$((verified + 1))
        fi
    done
    
    # Get final counts
    final_count=$(ls -1 $SYSTEM_CACERTS | wc -l)
    log "=== Installation Summary ==="
    log "  - New certificates installed: $success"
    log "  - Verified successfully: $verified"
    log "  - Total certificates in store: $final_count"
    
    # Force refresh of certificate store (multiple methods)
    log "Refreshing certificate store..."
    killall -HUP system_server 2>/dev/null
    killall -HUP keystore 2>/dev/null
    killall -HUP keystore2 2>/dev/null
    
    # Broadcast intent to refresh settings
    am broadcast -a android.security.STORAGE_CHANGED >/dev/null 2>&1
    
    # Clean up temp directory
    rm -rf "$TEMP_CERT_DIR"
    
    # Prepare notification message
    if [ $verified -eq $success ]; then
        status="✅ All certificates verified"
    else
        status="⚠️ $verified/$success verified"
    fi
    
    cert_list=$(echo "$installed_certs" | tr ' ' '\n' | head -3 | tr '\n' ', ' | sed 's/, $//')
    if [ $success -gt 3 ]; then
        cert_list="$cert_list and $(($success - 3)) more"
    fi
    
    # Send success notification
    notify "Magisk CA Installer" "✅ $success certs installed: $cert_list" "1"
    
    # Also create a permanent notification using different method
    su -lp 2000 -c "cmd notification post -S bigtext --tag magisk_ca_installer --priority 2 --title 'Magisk CA Installer' --text '$success certificates installed. Check Settings → Security → Certificates'" >/dev/null 2>&1
    
else
    log "No new certificates were added"
    rm -rf "$TEMP_CERT_DIR"
    notify "Magisk CA Installer" "ℹ️ No new certificates to install" "0"
fi

# Final check - verify a random certificate from system store
log "=== Final verification ==="
sample_cert=$(find "$SYSTEM_CACERTS" -type f -name "*.0" | head -1)
if [ -n "$sample_cert" ]; then
    sample_hash=$(basename "$sample_cert" .0)
    verify_certificate "$sample_cert" "$sample_hash"
fi

log "=== Magisk CA Installer finished ==="
exit 0