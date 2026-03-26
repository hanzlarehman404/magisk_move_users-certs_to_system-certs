# Magisk CA Installer

> Automatically installs user CA certificates into the system trust store on every boot — making them trusted by all apps, including those with certificate pinning bypass.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Directory Reference](#directory-reference)
- [Notifications](#notifications)
- [Logs](#logs)
- [Troubleshooting](#troubleshooting)
- [Warning](#warning)

---

## Overview

On Android 7+, user-installed CA certificates are no longer trusted by most apps by default. This Magisk module solves that by mounting a `tmpfs` over the system certificate store on every boot and injecting your user certificates alongside the existing system ones — no permanent system modification required.

---

## How It Works

1. Waits for the device to fully boot
2. Reads new certificates from the Android user cert source directory
3. Backs them up to a persistent store so they survive across reboots
4. Merges system certs + backup certs + any new certs into a temp directory
5. Mounts a `tmpfs` over `/system/etc/security/cacerts`
6. Copies all merged certificates into the mounted directory with correct permissions and SELinux context
7. Sends a notification summarising what was installed

---

## Requirements

- Rooted device with **Magisk** installed
- Android 7.0 or higher
- ADB access recommended for first-time setup and troubleshooting

---

## Installation

1. Clone or download this repository
2. Zip the module folder in the standard Magisk module format
3. Open **Magisk Manager** → Modules → Install from storage
4. Select the zip file and flash it
5. Reboot your device

> Certificates must be placed (or already exist) in `/data/misc/user/0/cacerts-added` before or after installation. The module will pick them up on the next boot.

---

## Configuration

Open `service.sh` and edit the configuration block near the top:

```sh
# ----- CONFIGURATION -----
REMOVE_OLD_CERTS=1
# ------------------------
```

| Value | Behaviour |
|-------|-----------|
| `1` (default) | After a certificate is successfully copied and backed up, it is **deleted from the User Credentials**. This avoids presence of certs in both system credentials and user credentials which can confuse the apps. |
| `0` | Certificates are **left in the user credentials directory** after copying so you have to manually clear them with "clear credentials" options in settings. |

---

## Directory Reference

All paths are defined at the top of `service.sh`. If your device uses different paths, verify the correct paths first (see [Troubleshooting](#troubleshooting)), then update accordingly.

```sh
LOG_FILE="/data/local/tmp/magisk_cert_install.log"
SYSTEM_CACERTS="/system/etc/security/cacerts"
CERT_SOURCE="/data/misc/user/0/cacerts-added"
KEYSTORE_DIR="/data/misc/keystore/user_0"
TEMP_CERT_DIR="/dev/tmp_cacerts"
USER_CERT_STORE="/data/local/tmp/user_cacerts_store"
```

---

### `LOG_FILE`
**Default:** `/data/local/tmp/magisk_cert_install.log`

Where the module writes all its runtime logs. Every step — certificate discovery, copying, mounting, permissions, notifications — is recorded here with timestamps. Check this file first whenever something does not work as expected.

---

### `SYSTEM_CACERTS`
**Default:** `/system/etc/security/cacerts`

The system CA certificate store that Android trusts. This module mounts a `tmpfs` over this directory so it can inject certificates without permanently modifying the system partition. This is the standard path on AOSP and most OEM ROMs.

> If your ROM uses a different path, run `find /system -name "cacerts" -type d` via ADB to locate it.

---

### `CERT_SOURCE`
**Default:** `/data/misc/user/0/cacerts-added`

The directory where Android stores certificates that the user has manually installed via Settings → Security → Install certificate. This module reads new certificates from here. The `0` refers to user ID 0 (the primary user). On multi-user devices you may need to change this to match the correct user ID.

> To verify: `ls /data/misc/user/0/cacerts-added` — you should see files named like `a1b2c3d4.0`.

---

### `KEYSTORE_DIR`
**Default:** `/data/misc/keystore/user_0`

Android's keystore directory for the primary user. When `REMOVE_OLD_CERTS=1`, the module also cleans up any keystore entries whose filename matches the certificate hash, preventing stale references. If nothing matches the hash here, the module skips this step silently — it will not cause any errors.

---

### `TEMP_CERT_DIR`
**Default:** `/dev/tmp_cacerts`

A temporary working directory used during a single boot cycle. The module merges system certificates, backup certificates, and new certificates here before mounting. This directory is created fresh each boot and deleted once the mount is complete. `/dev` is used because it is a `tmpfs` mount itself and is always writable.

---

### `USER_CERT_STORE`
**Default:** `/data/local/tmp/user_cacerts_store`

A persistent backup of all user certificates that have been successfully processed by this module. Because `CERT_SOURCE` gets cleared (when `REMOVE_OLD_CERTS=1`), this directory ensures your certificates are not lost on the next reboot. On every boot, certificates from here are automatically re-injected into the system store.

> **To schedule a wipe of this store**, run the following via ADB and then reboot:
> ```sh
> adb shell touch /data/local/tmp/magisk_ca_clear_store
> ```
> The store will be cleared on the next boot before any certificates are processed.

---

## Notifications

The module sends a system notification on every boot summarising the result:

| Scenario | Notification |
|----------|-------------|
| New certs installed + backup loaded | ✅ `X new + Y from backup installed` |
| Only backup certs loaded (no new) | ℹ️ `Y certificate(s) loaded from backup` |
| Nothing to install | ℹ️ `No certificates to install` |
| Mount failed | ❌ `Mount failed` |

---

## Logs

To read the log via ADB:

```sh
adb shell cat /data/local/tmp/magisk_cert_install.log
```

To follow it live during testing:

```sh
adb shell tail -f /data/local/tmp/magisk_cert_install.log
```

To check only notification-related lines:

```sh
adb shell grep NOTIFICATION /data/local/tmp/magisk_cert_install.log
```

---

## Troubleshooting

**No certificates being detected**
```sh
adb shell ls /data/misc/user/0/cacerts-added
```
If empty, install a certificate manually via Settings first, then reboot.

**Mount failing**
```sh
adb shell cat /data/local/tmp/magisk_cert_install.log | grep -i "mount\|error"
```
Some ROMs protect `/system/etc/security/cacerts` with additional SELinux policies. Check logcat for denials: `adb logcat | grep avc`.

**Verify certificates are trusted after boot**
```sh
adb shell ls /system/etc/security/cacerts | wc -l
```
Count should be higher than the stock number of system certs.

**Find correct paths on your device**
```sh
# Find system cert store
adb shell find /system -name "cacerts" -type d

# Find user cert source
adb shell find /data/misc/user -name "*.0" 2>/dev/null

# Find keystore directory
adb shell ls /data/misc/keystore/
```

---

## Warning

> This module operates with root privileges and modifies the system certificate trust store at runtime. Only install certificates from sources you fully trust. A compromised CA certificate can allow silent interception of all TLS traffic on your device.
