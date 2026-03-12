#!/system/bin/sh
# Magisk CA Installer - service.sh
# Installs user CA certificates from modern Android location

MODPATH=${0%/*}
LOG_FILE="/data/local/tmp/magisk_cert_install.log"
SYSTEM_CACERTS="/system/etc/security/cacerts"
CERT_SOURCE="/data/misc/user/0/cacerts-added"
KEYSTORE_DIR="/data/misc/keystore/user_0"
TEMP_CERT_DIR="/dev/tmp_cacerts"
USER_CERT_STORE="/data/local/tmp/user_cacerts_store"   # Persistent backup

# ----- CONFIGURATION -----
REMOVE_OLD_CERTS=1   # 1 = remove from source after successful copy, 0 = keep
success=0
installed=""
failed=""
# ------------------------

# Wait for system to fully boot
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
done

# Extra delay for NotificationManager and UI
sleep 5

# Logging function
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Fixed notification function (Android 8+ compatible)
notify() {
    local title="$1"
    local text="$2"
    local success="$3"
    
    # Magisk's built-in notification
    if [ -f /data/adb/magisk/util_functions.sh ]; then
        magisk --notification "Magisk CA Installer" "$text" 2>/dev/null
    fi
    
    # Proper cmd notification syntax with channel ID
    su -lp 2000 -c "cmd notification post -S bigtext -t '$title' 'magisk_ca_installer' '$text'" 2>> "$LOG_FILE"

    # Fallback to service call
    service call notification 1 i32 0 s16 "com.android.shell" s16 "$title" s16 "$text" >/dev/null 2>&1
    
    log "NOTIFICATION: $title - $text"
}

# Function to set proper permissions and SELinux context
set_cert_permissions() {
    local dir="$1"
    
    chown -R root:root "$dir" 2>> "$LOG_FILE"
    find "$dir" -type f -exec chmod 644 {} \; 2>> "$LOG_FILE"
    find "$dir" -type d -exec chmod 755 {} \; 2>> "$LOG_FILE"
    
    # SELinux context - critical for Settings visibility
    if command -v chcon >/dev/null 2>&1; then
        chcon -R u:object_r:system_security_cacerts_file:s0 "$dir" 2>> "$LOG_FILE"
    else
        /system/bin/chcon -R u:object_r:system_security_cacerts_file:s0 "$dir" 2>> "$LOG_FILE" || \
        /system/xbin/chcon -R u:object_r:system_security_cacerts_file:s0 "$dir" 2>> "$LOG_FILE"
    fi
}

# Start logging
log "=== Magisk CA Installer started ==="

# Create persistent user certificate store if not exists
if [ ! -d "$USER_CERT_STORE" ]; then
    mkdir -p "$USER_CERT_STORE"
    chown root:root "$USER_CERT_STORE"
    chmod 755 "$USER_CERT_STORE"
    log "Created persistent store: $USER_CERT_STORE"
fi

# Create temp directory and preserve existing system certs
log "Creating temporary directory"
rm -rf "$TEMP_CERT_DIR" 2>/dev/null
mkdir -p "$TEMP_CERT_DIR"

# Copy existing system certificates
if [ -d "$SYSTEM_CACERTS" ] && [ "$(ls -A $SYSTEM_CACERTS 2>/dev/null)" ]; then
    cp -f $SYSTEM_CACERTS/* "$TEMP_CERT_DIR/" 2>> "$LOG_FILE"
    log "  - Preserved $(ls -1 $SYSTEM_CACERTS | wc -l) system certificates"
fi

# Copy any previously backed up user certificates from persistent store
if [ -d "$USER_CERT_STORE" ] && [ "$(ls -A $USER_CERT_STORE 2>/dev/null)" ]; then
    cp -f $USER_CERT_STORE/* "$TEMP_CERT_DIR/" 2>> "$LOG_FILE"
    backup_count=$(ls -1 $USER_CERT_STORE | wc -l) 
    log "  - Restored $(ls -1 $USER_CERT_STORE | wc -l) user certificates from persistent store"
fi

# Check for new certificates in source directory
if [ -d "$CERT_SOURCE" ]; then
    CERT_FILES=$(find "$CERT_SOURCE" -maxdepth 1 -type f -name "*.0" 2>/dev/null)
    if [ -n "$CERT_FILES" ]; then
        total=$(echo "$CERT_FILES" | wc -l)
        log "Found $total new certificate(s) in $CERT_SOURCE"
        
        success=0
        installed=""
        failed=""
        
        for cert_file in $CERT_FILES; do
            base=$(basename "$cert_file")
            hash="${base%.0}"
            log "Processing: $base (hash: $hash)"
            
            # Validate hash format (8 hex digits)
            if ! echo "$hash" | grep -qE '^[0-9a-f]{8}$'; then
                log "  - Invalid hash format, skipping"
                failed="$failed $base"
                continue
            fi
            
            # Check if already in temp (should not happen because source is new)
            target_temp="$TEMP_CERT_DIR/$base"
            if [ -f "$target_temp" ]; then
                log "  - Already present in temp, skipping duplicate"
                continue
            fi
            
            # Copy to temp
            if cp "$cert_file" "$target_temp" 2>> "$LOG_FILE"; then
                log "  - Copied to temp"
                
                # Also copy to persistent store (overwrite if exists)
                cp "$cert_file" "$USER_CERT_STORE/$base" 2>> "$LOG_FILE"
                log "  - Backed up to persistent store"
                
                success=$((success + 1))
                installed="$installed $base"
                
                # If removal enabled, delete source file and keystore entries
                if [ "$REMOVE_OLD_CERTS" = "1" ]; then
                    rm -f "$cert_file" 2>> "$LOG_FILE"
                    log "  - Removed from source: $base"
                    
                    if [ -d "$KEYSTORE_DIR" ]; then
                        find "$KEYSTORE_DIR" -type f -name "*$hash*" -exec rm -f {} \; 2>> "$LOG_FILE"
                        log "  - Cleaned up keystore entries for hash $hash"
                    fi
                fi
            else
                log "  - Failed to copy"
                failed="$failed $base"
            fi
        done
        
        if [ $success -gt 0 ]; then
            log "Successfully processed $success new certificate(s)"
        fi
    else
        log "No new certificates in $CERT_SOURCE"
    fi
fi

# Count total certificates in temp
total_temp=$(ls -1 $TEMP_CERT_DIR | wc -l)
if [ $total_temp -eq 0 ]; then
    log "No certificates to install (temp is empty)"
    rm -rf "$TEMP_CERT_DIR"
    notify "Magisk CA Installer" "ℹ️ No certificates to install" "0"
    exit 0
fi

log "Total certificates to install: $total_temp"

# Set permissions on temp directory
log "Setting permissions on temp directory"
set_cert_permissions "$TEMP_CERT_DIR"

# Mount tmpfs over system certificate directory
log "Mounting tmpfs on $SYSTEM_CACERTS"
mount -t tmpfs tmpfs "$SYSTEM_CACERTS" 2>> "$LOG_FILE"
if [ $? -ne 0 ]; then
    log "ERROR: Failed to mount tmpfs"
    notify "Magisk CA Installer" "❌ Mount failed" "0"
    rm -rf "$TEMP_CERT_DIR"
    exit 1
fi

# Copy all certificates to the mounted directory
cp -f $TEMP_CERT_DIR/* "$SYSTEM_CACERTS/" 2>> "$LOG_FILE"

# Apply final permissions
set_cert_permissions "$SYSTEM_CACERTS"

# Clean up temp
rm -rf "$TEMP_CERT_DIR"

# Refresh certificate store
log "Refreshing certificate store"
killall -HUP system_server 2>/dev/null
killall -HUP keystore 2>/dev/null
killall -HUP keystore2 2>/dev/null
am broadcast -a android.security.STORAGE_CHANGED >/dev/null 2>&1

# Summary
final_count=$(ls -1 $SYSTEM_CACERTS | wc -l)
log "Installation summary: system store now contains $final_count certificates"

# Build notification text
new_installed="${installed:-none}"
if [ "$success" -gt 0 ]; then
    notify "Magisk CA Installer" "✅ $success new + $backup_count from backup installed" "1"
else
    notify "Magisk CA Installer" "ℹ️ $backup_count certificate(s) loaded from backup" "0"
fi

log "=== Magisk CA Installer finished ==="
exit 0