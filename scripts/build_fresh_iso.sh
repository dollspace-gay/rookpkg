#!/bin/bash
set -euo pipefail

# =============================================================================
# Rookery OS Live ISO Build Script (Fresh Install)
# Creates a bootable live ISO from packages in /home/rookery/specs/
# =============================================================================

# Configuration
BUILD="/tmp/rookery-iso-$$"
SPECS_DIR="/home/rookery/specs"
KERNEL="/boot/vmlinuz-6.6.102-grsec"
MODULES_DIR="/lib/modules/6.6.102-grsec"
SYSLINUX_DIR="/usr/lib/syslinux/bios"
OUTPUT_DIR="/home/rookery/dist"
ISO_NAME="rookery-os-live.iso"
VOLUME_ID="ROOKERY_LIVE"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
    log_info "Cleaning up build directory..."
    rm -rf "$BUILD"
}

# Trap for cleanup on exit
trap cleanup EXIT

# =============================================================================
# Step 0: Cleanup Old Builds
# =============================================================================
cleanup_old_builds() {
    log_step "Cleaning up old build directories and ISOs..."

    # Remove old build directories from /tmp (keep only the most recent one if any)
    local old_builds=$(find /tmp -maxdepth 1 -type d -name "rookery-iso-*" 2>/dev/null)
    if [ -n "$old_builds" ]; then
        local count=$(echo "$old_builds" | wc -l)
        log_info "Removing $count old build directories from /tmp..."
        rm -rf /tmp/rookery-iso-*
        log_info "Freed $(du -sh /tmp 2>/dev/null | cut -f1) in /tmp"
    fi

    # Remove old pkg-extract directories
    if ls /tmp/pkg-extract-* 1>/dev/null 2>&1; then
        log_info "Removing old pkg-extract directories..."
        rm -rf /tmp/pkg-extract-*
    fi

    # Remove old ISOs from home directory (not from dist/)
    if ls /home/*.iso 1>/dev/null 2>&1; then
        log_info "Removing old ISOs from /home/..."
        rm -f /home/*.iso
    fi

    # Check available disk space
    local avail_gb=$(df -BG /tmp | tail -1 | awk '{print $4}' | tr -d 'G')
    if [ "$avail_gb" -lt 20 ]; then
        log_warn "Low disk space: ${avail_gb}GB available. Build may fail."
        log_warn "Consider running: rm -rf /tmp/rookery-iso-* /home/*.iso"
    else
        log_info "Disk space OK: ${avail_gb}GB available"
    fi
}

# =============================================================================
# Step 1: Setup Build Environment
# =============================================================================
setup_build_env() {
    log_step "Setting up build environment..."

    rm -rf "$BUILD"
    mkdir -p "$BUILD"/{rootfs,iso/boot/syslinux,iso/LiveOS,initramfs}
    mkdir -p "$OUTPUT_DIR"

    # Verify required tools
    for tool in mksquashfs xorriso; do
        if ! command -v $tool &>/dev/null; then
            log_error "Required tool not found: $tool"
            exit 1
        fi
    done

    # Check for cpio (prefer bsdcpio if available)
    if command -v bsdcpio &>/dev/null; then
        CPIO_CMD="bsdcpio"
    elif command -v cpio &>/dev/null; then
        CPIO_CMD="cpio"
    else
        log_error "Required tool not found: cpio or bsdcpio"
        exit 1
    fi
    log_info "Using $CPIO_CMD for initramfs creation"

    # Verify kernel exists
    if [ ! -f "$KERNEL" ]; then
        log_error "Kernel not found: $KERNEL"
        exit 1
    fi

    # Verify syslinux files exist
    if [ ! -f "$SYSLINUX_DIR/isolinux.bin" ]; then
        log_error "ISOLINUX not found: $SYSLINUX_DIR/isolinux.bin"
        exit 1
    fi

    log_info "Build environment ready at $BUILD"
}

# =============================================================================
# Step 2: Install Packages to Fresh Rootfs
# =============================================================================
install_packages() {
    log_step "Installing packages to fresh rootfs..."

    local rootfs="$BUILD/rootfs"
    local pkg_count=0
    local total_pkgs=$(ls -1 "$SPECS_DIR"/*.x86_64.rookpkg 2>/dev/null | wc -l)

    if [ "$total_pkgs" -eq 0 ]; then
        log_error "No packages found in $SPECS_DIR"
        exit 1
    fi

    log_info "Found $total_pkgs packages to install"

    # Create basic directory structure first
    mkdir -p "$rootfs"/{bin,sbin,lib,lib64,usr/{bin,sbin,lib,lib64},etc,var,tmp,root,home,boot,dev,proc,sys,run}

    # Install each package
    # Package format: outer tar contains .PKGINFO, .FILES, and data.tar.zst
    # We need to extract data.tar.zst and then decompress/extract it
    local tmp_extract="/tmp/pkg-extract-$$"
    mkdir -p "$tmp_extract"

    for pkg in "$SPECS_DIR"/*.x86_64.rookpkg; do
        pkg_count=$((pkg_count + 1))
        local pkg_name=$(basename "$pkg" .x86_64.rookpkg)

        if [ $((pkg_count % 50)) -eq 0 ] || [ "$pkg_count" -eq "$total_pkgs" ]; then
            log_info "Installing package $pkg_count/$total_pkgs: $pkg_name"
        fi

        # Extract the outer tar to get data.tar.zst
        tar -xf "$pkg" -C "$tmp_extract" data.tar.zst 2>/dev/null || continue

        # Extract the inner zstd-compressed tar
        if [ -f "$tmp_extract/data.tar.zst" ]; then
            zstd -d -c "$tmp_extract/data.tar.zst" 2>/dev/null | tar -xf - -C "$rootfs" 2>/dev/null || true
            rm -f "$tmp_extract/data.tar.zst"
        fi
    done

    rm -rf "$tmp_extract"

    log_info "Installed $pkg_count packages"

    # Fix legacy /opt/qt6 installations - move to /usr
    if [ -d "$rootfs/opt/qt6" ]; then
        log_info "Moving /opt/qt6 contents to /usr..."
        # Move libraries
        if [ -d "$rootfs/opt/qt6/lib" ]; then
            cp -a "$rootfs/opt/qt6/lib"/* "$rootfs/usr/lib/" 2>/dev/null || true
        fi
        # Move plugins
        if [ -d "$rootfs/opt/qt6/plugins" ]; then
            mkdir -p "$rootfs/usr/lib/qt6/plugins"
            cp -a "$rootfs/opt/qt6/plugins"/* "$rootfs/usr/lib/qt6/plugins/" 2>/dev/null || true
        fi
        # Move qml modules
        if [ -d "$rootfs/opt/qt6/qml" ]; then
            mkdir -p "$rootfs/usr/lib/qt6/qml"
            cp -a "$rootfs/opt/qt6/qml"/* "$rootfs/usr/lib/qt6/qml/" 2>/dev/null || true
        fi
        # Move translations
        if [ -d "$rootfs/opt/qt6/translations" ]; then
            mkdir -p "$rootfs/usr/share/qt6/translations"
            cp -a "$rootfs/opt/qt6/translations"/* "$rootfs/usr/share/qt6/translations/" 2>/dev/null || true
        fi
        # Move resources
        if [ -d "$rootfs/opt/qt6/resources" ]; then
            mkdir -p "$rootfs/usr/lib/qt6/resources"
            cp -a "$rootfs/opt/qt6/resources"/* "$rootfs/usr/lib/qt6/resources/" 2>/dev/null || true
        fi
        # Move libexec
        if [ -d "$rootfs/opt/qt6/libexec" ]; then
            mkdir -p "$rootfs/usr/lib/qt6/libexec"
            cp -a "$rootfs/opt/qt6/libexec"/* "$rootfs/usr/lib/qt6/libexec/" 2>/dev/null || true
        fi
        # Move binaries
        if [ -d "$rootfs/opt/qt6/bin" ]; then
            cp -a "$rootfs/opt/qt6/bin"/* "$rootfs/usr/bin/" 2>/dev/null || true
        fi
        # Remove /opt/qt6 entirely
        rm -rf "$rootfs/opt/qt6"
        log_info "Moved /opt/qt6 to /usr and removed /opt/qt6"

        # Fix any files that still reference /opt/qt6 (e.g., systemd service files)
        log_info "Fixing /opt/qt6 references in config files..."
        local fixed_count=0
        for file in $(grep -rl "/opt/qt6" "$rootfs/usr/lib/systemd" "$rootfs/etc" 2>/dev/null); do
            sed -i 's|/opt/qt6/bin|/usr/bin|g; s|/opt/qt6/lib|/usr/lib|g; s|/opt/qt6|/usr|g' "$file"
            fixed_count=$((fixed_count + 1))
        done
        if [ $fixed_count -gt 0 ]; then
            log_info "Fixed /opt/qt6 references in $fixed_count files"
        fi
    fi
}

# =============================================================================
# Step 2b: Fix Library Symlinks
# =============================================================================
fix_lib_symlinks() {
    log_step "Fixing library symlinks..."

    local rootfs="$BUILD/rootfs"

    # The problem: packages install with symlinks like:
    #   /lib64/ld-linux-x86-64.so.2 -> ../lib/ld-linux-x86-64.so.2
    # But /lib is a symlink to usr/lib, so the relative path ../lib from /lib64 breaks.
    #
    # Solution: Make /lib64 a symlink to usr/lib (like modern distros)
    # This matches the FHS 3.0 spec where /lib64 should contain the 64-bit dynamic linker

    # First, check if we have the dynamic linker in usr/lib
    if [ -f "$rootfs/usr/lib/ld-linux-x86-64.so.2" ]; then
        log_info "Dynamic linker found at /usr/lib/ld-linux-x86-64.so.2"
    elif [ -d "$rootfs/lib64" ] && [ ! -L "$rootfs/lib64" ]; then
        # If lib64 is a real directory, find the actual linker
        if [ -e "$rootfs/lib64/ld-linux-x86-64.so.2" ]; then
            local real_ld=$(readlink -f "$rootfs/lib64/ld-linux-x86-64.so.2" 2>/dev/null)
            if [ -f "$real_ld" ]; then
                log_info "Dynamic linker resolves to: $real_ld"
            fi
        fi
    fi

    # Fix /lib if it's not a symlink
    if [ -d "$rootfs/lib" ] && [ ! -L "$rootfs/lib" ]; then
        log_info "Moving /lib contents to /usr/lib..."
        mkdir -p "$rootfs/usr/lib"
        cp -a "$rootfs/lib"/* "$rootfs/usr/lib/" 2>/dev/null || true
        rm -rf "$rootfs/lib"
        ln -sf usr/lib "$rootfs/lib"
        log_info "Created /lib -> usr/lib symlink"
    fi

    # Fix /lib64 - this is the critical one for the dynamic linker
    if [ -d "$rootfs/lib64" ] && [ ! -L "$rootfs/lib64" ]; then
        log_info "Moving /lib64 contents to /usr/lib..."
        mkdir -p "$rootfs/usr/lib"
        # Copy all files from lib64 to usr/lib
        for f in "$rootfs/lib64"/*; do
            if [ -e "$f" ]; then
                local fname=$(basename "$f")
                # If it's a symlink, resolve it and copy the target file
                if [ -L "$f" ]; then
                    local target=$(readlink -f "$f" 2>/dev/null)
                    if [ -f "$target" ]; then
                        cp -n "$target" "$rootfs/usr/lib/$fname" 2>/dev/null || true
                    fi
                elif [ -f "$f" ]; then
                    cp -n "$f" "$rootfs/usr/lib/$fname" 2>/dev/null || true
                fi
            fi
        done
        rm -rf "$rootfs/lib64"
        ln -sf usr/lib "$rootfs/lib64"
        log_info "Created /lib64 -> usr/lib symlink"
    fi

    # Ensure the dynamic linker exists and is a real file
    if [ ! -f "$rootfs/usr/lib/ld-linux-x86-64.so.2" ]; then
        log_error "Dynamic linker /usr/lib/ld-linux-x86-64.so.2 not found after symlink fix!"
        # Try to find it anywhere
        local found_ld=$(find "$rootfs" -name "ld-linux-x86-64.so.2" -type f 2>/dev/null | head -1)
        if [ -n "$found_ld" ]; then
            log_info "Found dynamic linker at: $found_ld"
            cp "$found_ld" "$rootfs/usr/lib/ld-linux-x86-64.so.2"
            log_info "Copied to /usr/lib/ld-linux-x86-64.so.2"
        else
            log_error "Cannot find dynamic linker anywhere in rootfs!"
            exit 1
        fi
    fi

    # Verify symlinks are correct
    log_info "Verifying library symlinks..."
    ls -la "$rootfs/lib" 2>/dev/null || true
    ls -la "$rootfs/lib64" 2>/dev/null || true
    ls -la "$rootfs/usr/lib/ld-linux-x86-64.so.2" 2>/dev/null || true

    log_info "Library symlinks fixed"
}

# =============================================================================
# Step 3: Configure Live System
# =============================================================================
configure_live_system() {
    log_step "Configuring live system..."

    local rootfs="$BUILD/rootfs"

    # Create essential directories
    mkdir -p "$rootfs"/{etc/systemd/system,home/live,run/dbus,var/run,var/lib/sddm}
    chmod 1777 "$rootfs/tmp"

    # Set proper ownership for sddm directory (UID 995, GID 995)
    chown 995:995 "$rootfs/var/lib/sddm"
    chmod 750 "$rootfs/var/lib/sddm"

    # Create passwd - use /usr/bin/bash since /bin may not have bash
    cat > "$rootfs/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/usr/bin/bash
bin:x:1:1:bin:/dev/null:/usr/sbin/nologin
daemon:x:2:2:daemon:/dev/null:/usr/sbin/nologin
nobody:x:65534:65534:Nobody:/:/usr/sbin/nologin
messagebus:x:18:18:D-Bus Message Daemon:/run/dbus:/usr/sbin/nologin
systemd-journal:x:990:990:systemd Journal:/:/usr/sbin/nologin
systemd-network:x:991:991:systemd Network Management:/:/usr/sbin/nologin
polkitd:x:27:27:PolicyKit Daemon:/var/lib/polkit-1:/usr/sbin/nologin
sddm:x:995:995:SDDM Display Manager:/var/lib/sddm:/usr/sbin/nologin
live:x:1000:1000:Live User:/home/live:/usr/bin/bash
EOF

    # Create /bin and /sbin symlinks to /usr/bin and /usr/sbin for compatibility
    # Many tools (including Calamares chroot operations) expect commands in /bin
    if [ -d "$rootfs/bin" ] && [ ! -L "$rootfs/bin" ]; then
        # /bin exists as directory, move contents and replace with symlink
        cp -a "$rootfs/bin/"* "$rootfs/usr/bin/" 2>/dev/null || true
        rm -rf "$rootfs/bin"
        ln -sf usr/bin "$rootfs/bin"
        log_info "Created /bin -> usr/bin symlink"
    elif [ ! -e "$rootfs/bin" ]; then
        ln -sf usr/bin "$rootfs/bin"
        log_info "Created /bin -> usr/bin symlink"
    fi

    if [ -d "$rootfs/sbin" ] && [ ! -L "$rootfs/sbin" ]; then
        # /sbin exists as directory, move contents and replace with symlink
        cp -a "$rootfs/sbin/"* "$rootfs/usr/sbin/" 2>/dev/null || true
        rm -rf "$rootfs/sbin"
        ln -sf usr/sbin "$rootfs/sbin"
        log_info "Created /sbin -> usr/sbin symlink"
    elif [ ! -e "$rootfs/sbin" ]; then
        ln -sf usr/sbin "$rootfs/sbin"
        log_info "Created /sbin -> usr/sbin symlink"
    fi

    # Create group - include shadow and utmp groups for login to work
    cat > "$rootfs/etc/group" << 'EOF'
root:x:0:
bin:x:1:
daemon:x:2:
sys:x:3:
adm:x:4:live
tty:x:5:sddm
disk:x:6:
wheel:x:10:live
cdrom:x:11:live
shadow:x:15:
utmp:x:13:
video:x:22:live,sddm
audio:x:25:live
users:x:100:live
nobody:x:65534:
messagebus:x:18:
systemd-journal:x:990:
input:x:996:sddm
kvm:x:997:live
render:x:998:live,sddm
polkitd:x:27:
sddm:x:995:
autologin:x:1001:live,sddm
live:x:1000:
EOF

    # Create shadow (password "live" for live user)
    cat > "$rootfs/etc/shadow" << 'EOF'
root:!:19722:0:99999:7:::
messagebus:!:19722:0:99999:7:::
polkitd:!:19722:0:99999:7:::
sddm:!:19722:0:99999:7:::
live:$6$xyz$FZdeWWOx8j1RIJpolCHQ5yiYyTzlgffE4D5dB0ip66lHh4ynb9QOnrAzvzL4Dog6iuURvKRcHWi4zvAdJ8B2f1:19722:0:99999:7:::
EOF
    chmod 640 "$rootfs/etc/shadow"
    chown root:15 "$rootfs/etc/shadow"  # 15 = shadow group

    # Set home directory ownership
    chown 1000:1000 "$rootfs/home/live"

    # Create /etc/shells - /usr/bin/bash first since that's what we use in passwd
    cat > "$rootfs/etc/shells" << 'EOF'
/usr/bin/bash
/bin/bash
/bin/sh
/usr/bin/sh
/usr/sbin/nologin
EOF

    # Create hostname
    echo "rookery-live" > "$rootfs/etc/hostname"

    # Create hosts file
    cat > "$rootfs/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   rookery-live
::1         localhost
EOF

    # ==========================================================================
    # CRITICAL: Configure UTF-8 locale for Qt/KDE/Plasma
    # ==========================================================================
    # Qt and KDE absolutely require UTF-8 locale. Without this, Plasma crashes.
    log_info "Configuring UTF-8 locale..."

    # Create locale.conf with UTF-8 locale
    cat > "$rootfs/etc/locale.conf" << 'EOF'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

    # Create /etc/default/locale (some programs look here)
    mkdir -p "$rootfs/etc/default"
    cat > "$rootfs/etc/default/locale" << 'EOF'
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF

    # Create /etc/locale.gen if localedef is available
    cat > "$rootfs/etc/locale.gen" << 'EOF'
en_US.UTF-8 UTF-8
EOF

    # Generate locale if localedef exists in the rootfs
    if [ -f "$rootfs/usr/bin/localedef" ]; then
        mkdir -p "$rootfs/usr/lib/locale"
        # Run localedef in chroot context
        chroot "$rootfs" /usr/bin/localedef -i en_US -f UTF-8 en_US.UTF-8 2>/dev/null || true
        log_info "Generated en_US.UTF-8 locale"
    else
        log_warn "localedef not found - will try to copy locale from host"
        # Copy the en_US.UTF-8 locale from host system if available
        if [ -d "/usr/lib/locale/en_US.utf8" ]; then
            mkdir -p "$rootfs/usr/lib/locale"
            cp -a /usr/lib/locale/en_US.utf8 "$rootfs/usr/lib/locale/" 2>/dev/null || true
            log_info "Copied en_US.UTF-8 locale from host"
        elif [ -d "/usr/lib/locale/locale-archive" ]; then
            mkdir -p "$rootfs/usr/lib/locale"
            cp /usr/lib/locale/locale-archive "$rootfs/usr/lib/locale/" 2>/dev/null || true
            log_info "Copied locale-archive from host"
        fi
    fi

    # Set environment variables for the live session
    cat > "$rootfs/etc/profile.d/locale.sh" << 'EOF'
# Set UTF-8 locale for all users
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
EOF
    chmod 644 "$rootfs/etc/profile.d/locale.sh"

    # Note: /etc/environment settings are configured later in the script
    # to ensure they're not overwritten by other configuration steps

    # Create profile.d script for Wayland/Qt environment in VMs
    cat > "$rootfs/etc/profile.d/desktop-vm.sh" << 'EOF'
# Desktop environment for live session
# Helps with software rendering fallback in VMs without proper GPU

# If no render node exists, use software rendering for Qt/Mesa
if [ ! -e /dev/dri/renderD128 ]; then
    export LIBGL_ALWAYS_SOFTWARE=1
    export QT_QUICK_BACKEND=software
    export MESA_GL_VERSION_OVERRIDE=3.3
fi

# Set proper DISPLAY for X11 sessions if not already set
if [ -z "$DISPLAY" ] && [ -n "$XDG_SESSION_TYPE" ] && [ "$XDG_SESSION_TYPE" = "x11" ]; then
    export DISPLAY=:0
fi
EOF
    chmod 644 "$rootfs/etc/profile.d/desktop-vm.sh"

    log_info "UTF-8 locale configured"

    # Create machine-id (empty for live boot, systemd will generate)
    touch "$rootfs/etc/machine-id"

    # Configure SDDM autologin
    mkdir -p "$rootfs/etc/sddm.conf.d"

    # Use X11 session for VM compatibility (Wayland DRM backend doesn't work in QEMU without GPU passthrough)
    # Check for X11 sessions first
    local plasma_session=""
    local session_type=""
    for session_name in plasmax11 plasma; do
        if [ -f "$rootfs/usr/share/xsessions/${session_name}.desktop" ]; then
            plasma_session="$session_name"
            session_type="x11"
            log_info "Using Plasma X11 session: $session_name (best VM compatibility)"
            break
        fi
    done

    # Fallback to Wayland session if no X11 session found
    if [ -z "$plasma_session" ]; then
        for session_name in plasma-wayland plasmawayland plasma; do
            if [ -f "$rootfs/usr/share/wayland-sessions/${session_name}.desktop" ]; then
                plasma_session="$session_name"
                session_type="wayland"
                log_info "Found Plasma Wayland session: $session_name"
                break
            fi
        done
    fi

    # Default to plasmax11 if nothing found
    if [ -z "$plasma_session" ]; then
        plasma_session="plasmax11"
        session_type="x11"
        log_warn "No Plasma session file found, using default: plasmax11"
    fi

    # Configure SDDM to use X11 display server (not Wayland compositor mode)
    cat > "$rootfs/etc/sddm.conf.d/autologin.conf" << EOF
[Autologin]
User=live
Session=$plasma_session
Relogin=false

[General]
InputMethod=
DisplayServer=x11
EOF

    # Create proper PAM configuration files per LFS/BLFS
    mkdir -p "$rootfs/etc/pam.d"

    # system-auth - core authentication (LFS style)
    cat > "$rootfs/etc/pam.d/system-auth" << 'EOF'
# Begin /etc/pam.d/system-auth
# Standard authentication - requires valid password
auth      required    pam_unix.so
# End /etc/pam.d/system-auth
EOF

    # system-account
    cat > "$rootfs/etc/pam.d/system-account" << 'EOF'
# Begin /etc/pam.d/system-account
account   required    pam_unix.so
# End /etc/pam.d/system-account
EOF

    # system-session
    cat > "$rootfs/etc/pam.d/system-session" << 'EOF'
# Begin /etc/pam.d/system-session
session   required    pam_unix.so
# End /etc/pam.d/system-session
EOF

    # system-password
    cat > "$rootfs/etc/pam.d/system-password" << 'EOF'
# Begin /etc/pam.d/system-password
password  required    pam_unix.so sha512 shadow try_first_pass
# End /etc/pam.d/system-password
EOF

    # Fix sddm-autologin PAM - pam_systemd is REQUIRED for XDG_RUNTIME_DIR
    cat > "$rootfs/etc/pam.d/sddm-autologin" << 'EOF'
auth     required       pam_env.so
auth     required       pam_succeed_if.so uid >= 1000 quiet
auth     required       pam_permit.so
account  include        system-account
password required       pam_deny.so
session  required       pam_limits.so
session  required       pam_unix.so
session  optional       pam_loginuid.so
session  optional       pam_keyinit.so force revoke
session  required       pam_systemd.so
EOF

    # SDDM main PAM config (for password login)
    cat > "$rootfs/etc/pam.d/sddm" << 'EOF'
auth     required       pam_env.so
auth     required       pam_unix.so
account  include        system-account
password include        system-password
session  required       pam_limits.so
session  required       pam_unix.so
session  optional       pam_loginuid.so
session  optional       pam_keyinit.so force revoke
session  required       pam_systemd.so
EOF

    # SDDM greeter PAM config
    cat > "$rootfs/etc/pam.d/sddm-greeter" << 'EOF'
auth     required       pam_env.so
auth     required       pam_permit.so
account  required       pam_permit.so
password required       pam_deny.so
session  required       pam_unix.so
-session optional       pam_systemd.so
EOF

    # Mask problematic systemd units
    for unit in dev-hugepages.mount dev-mqueue.mount tmp.mount systemd-timesyncd.service; do
        ln -sf /dev/null "$rootfs/etc/systemd/system/$unit"
    done

    # Enable essential services
    mkdir -p "$rootfs/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$rootfs/etc/systemd/system/graphical.target.wants"
    mkdir -p "$rootfs/etc/systemd/system/sysinit.target.wants"

    # CRITICAL: Enable systemd-user-sessions.service - this removes /run/nologin to allow logins!
    if [ -f "$rootfs/usr/lib/systemd/system/systemd-user-sessions.service" ]; then
        ln -sf /usr/lib/systemd/system/systemd-user-sessions.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
        log_info "Enabled systemd-user-sessions.service"
    fi

    # Link dbus if exists
    if [ -f "$rootfs/usr/lib/systemd/system/dbus.service" ]; then
        ln -sf /usr/lib/systemd/system/dbus.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
    fi

    # Enable dbus.socket for early D-Bus activation
    if [ -f "$rootfs/usr/lib/systemd/system/dbus.socket" ]; then
        mkdir -p "$rootfs/etc/systemd/system/sockets.target.wants"
        ln -sf /usr/lib/systemd/system/dbus.socket "$rootfs/etc/systemd/system/sockets.target.wants/"
    fi

    # Link sddm if exists
    if [ -f "$rootfs/usr/lib/systemd/system/sddm.service" ]; then
        ln -sf /usr/lib/systemd/system/sddm.service "$rootfs/etc/systemd/system/graphical.target.wants/"
    fi

    # Set graphical target as default
    ln -sf /usr/lib/systemd/system/graphical.target "$rootfs/etc/systemd/system/default.target" 2>/dev/null || true

    # Create /etc/profile for shell initialization
    cat > "$rootfs/etc/profile" << 'EOF'
# /etc/profile - System-wide .profile file for the Bourne shell (sh(1))
# and Bourne compatible shells (bash(1), ksh(1), ash(1), ...).

# Set PATH
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# Set default umask
umask 022

# Set terminal type if not set
if [ -z "$TERM" ]; then
    export TERM=linux
fi

# Source profile.d scripts
if [ -d /etc/profile.d ]; then
    for script in /etc/profile.d/*.sh; do
        [ -r "$script" ] && . "$script"
    done
    unset script
fi
EOF

    # Create /etc/bashrc
    cat > "$rootfs/etc/bashrc" << 'EOF'
# /etc/bashrc - System-wide bash configuration

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Set prompt
PS1='[\u@\h \W]\$ '

# History settings
HISTSIZE=1000
HISTFILESIZE=2000
HISTCONTROL=ignoreboth

# Aliases
alias ls='ls --color=auto'
alias ll='ls -la'
alias grep='grep --color=auto'
EOF

    # Create root's bash configuration
    mkdir -p "$rootfs/root"
    cat > "$rootfs/root/.bashrc" << 'EOF'
# ~/.bashrc: executed by bash(1) for non-login shells
[[ $- != *i* ]] && return
. /etc/bashrc 2>/dev/null || true
EOF
    cat > "$rootfs/root/.bash_profile" << 'EOF'
# ~/.bash_profile: executed by bash(1) for login shells
[ -f /etc/profile ] && . /etc/profile
[ -f ~/.bashrc ] && . ~/.bashrc
EOF

    # Create live user's bash configuration
    cat > "$rootfs/home/live/.bashrc" << 'EOF'
# ~/.bashrc: executed by bash(1) for non-login shells
[[ $- != *i* ]] && return
. /etc/bashrc 2>/dev/null || true
EOF
    cat > "$rootfs/home/live/.bash_profile" << 'EOF'
# ~/.bash_profile: executed by bash(1) for login shells
[ -f /etc/profile ] && . /etc/profile
[ -f ~/.bashrc ] && . ~/.bashrc
EOF
    chown 1000:1000 "$rootfs/home/live/.bashrc" "$rootfs/home/live/.bash_profile"

    # Create /etc/issue for login prompt
    cat > "$rootfs/etc/issue" << 'EOF'
Rookery OS 1.0 - Live Desktop
Kernel \r on \m (\l)

EOF

    # Create /etc/issue.net
    cat > "$rootfs/etc/issue.net" << 'EOF'
Rookery OS 1.0 - Live Desktop
EOF

    # Create wtmp, utmp, btmp, and lastlog files for login tracking (CRITICAL!)
    mkdir -p "$rootfs/var/log"
    mkdir -p "$rootfs/run"

    # utmp - MUST exist for login to work
    touch "$rootfs/run/utmp"
    chmod 664 "$rootfs/run/utmp"
    chown root:13 "$rootfs/run/utmp"  # 13 = utmp group

    # wtmp - login history
    touch "$rootfs/var/log/wtmp"
    chmod 664 "$rootfs/var/log/wtmp"
    chown root:13 "$rootfs/var/log/wtmp"  # 13 = utmp group

    # btmp - failed login attempts
    touch "$rootfs/var/log/btmp"
    chmod 600 "$rootfs/var/log/btmp"
    chown root:13 "$rootfs/var/log/btmp"  # 13 = utmp group

    # lastlog
    touch "$rootfs/var/log/lastlog"
    chmod 644 "$rootfs/var/log/lastlog"

    # Create /var/run as symlink to /run if not exists
    rm -rf "$rootfs/var/run" 2>/dev/null || true
    ln -sf ../run "$rootfs/var/run"

    # Create profile.d directory
    mkdir -p "$rootfs/etc/profile.d"

    # Create /etc/environment with all necessary settings
    # (This is the final version - do not duplicate elsewhere in the script)
    cat > "$rootfs/etc/environment" << 'EOF'
PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"

# Rookery OS Live settings
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8

# Qt/KDE plugin paths - CRITICAL for Plasma Wayland
# Qt plugins are installed at /usr/plugins (not /usr/lib/qt6/plugins)
QT_PLUGIN_PATH=/usr/plugins:/usr/lib/plugins
QML_IMPORT_PATH=/usr/lib/qml
QML2_IMPORT_PATH=/usr/lib/qml

# Software rendering fallback - helps in VMs without proper GPU acceleration
KWIN_COMPOSE=O2
EOF

    # Fix /etc/pam.d/login - remove pam_nologin for live ISO (blocks login until boot complete)
    cat > "$rootfs/etc/pam.d/login" << 'EOF'
# Begin /etc/pam.d/login

# Set failure delay before next prompt to 3 seconds
auth      optional    pam_faildelay.so  delay=3000000

# Check to make sure that root is allowed to login
# Disabled for live ISO - causes issues during boot
# auth      requisite   pam_nologin.so

# Include system auth settings
auth      include     system-auth

# Include system account settings
account   include     system-account

# Set default environment variables for the user
session   required    pam_env.so

# Set resource limits for the user
session   required    pam_limits.so

# Include system session settings
session   include     system-session

# Include system password settings
password  include     system-password

# End /etc/pam.d/login
EOF

    # Create /etc/security/access.conf with permissive defaults
    mkdir -p "$rootfs/etc/security"
    cat > "$rootfs/etc/security/access.conf" << 'EOF'
# Allow all users from all sources
+:ALL:ALL
EOF

    # Create /etc/security/limits.conf
    cat > "$rootfs/etc/security/limits.conf" << 'EOF'
# /etc/security/limits.conf
# Default limits for users
*               soft    core            0
*               hard    nofile          65536
*               soft    nofile          8192
EOF

    # Create /etc/security/pam_env.conf (empty but required)
    touch "$rootfs/etc/security/pam_env.conf"

    # Create /etc/securetty to allow root login on consoles
    cat > "$rootfs/etc/securetty" << 'EOF'
console
tty1
tty2
tty3
tty4
tty5
tty6
tty7
tty8
ttyS0
ttyS1
hvc0
xvc0
EOF

    # Create /etc/gshadow (required for group authentication)
    cat > "$rootfs/etc/gshadow" << 'EOF'
root:::
bin:::
daemon:::
sys:::
adm:::live
tty:::sddm
disk:::
wheel:::live
cdrom:::live
shadow:::
utmp:::
video:::live,sddm
audio:::live
users:::live
nobody:::
messagebus:::
systemd-journal:::
input:::sddm
kvm:::live
render:::live,sddm
polkitd:::
sddm:::
autologin:::live,sddm
live:::
EOF
    chmod 640 "$rootfs/etc/gshadow"
    chown root:15 "$rootfs/etc/gshadow"  # 15 = shadow group

    # ==========================================================================
    # Create live user account
    # ==========================================================================
    log_info "Creating live user account..."

    # Add live user to /etc/passwd (uid 1000, gid 1000)
    # live:x:1000:1000:Live User:/home/live:/bin/bash
    if ! grep -q "^live:" "$rootfs/etc/passwd" 2>/dev/null; then
        echo "live:x:1000:1000:Live User:/home/live:/bin/bash" >> "$rootfs/etc/passwd"
    fi

    # Add live group to /etc/group (gid 1000)
    if ! grep -q "^live:" "$rootfs/etc/group" 2>/dev/null; then
        echo "live:x:1000:" >> "$rootfs/etc/group"
    fi

    # Add live user to /etc/shadow with password "live"
    # Password hash for "live": $6$xyz$FZdeWWOx8j1RIJpolCHQ5yiYyTzlgffE4D5dB0ip66lHh4ynb9QOnrAzvzL4Dog6iuURvKRcHWi4zvAdJ8B2f1
    if ! grep -q "^live:" "$rootfs/etc/shadow" 2>/dev/null; then
        echo 'live:$6$xyz$FZdeWWOx8j1RIJpolCHQ5yiYyTzlgffE4D5dB0ip66lHh4ynb9QOnrAzvzL4Dog6iuURvKRcHWi4zvAdJ8B2f1:19000:0:99999:7:::' >> "$rootfs/etc/shadow"
    fi

    # Create live user home directory
    mkdir -p "$rootfs/home/live"
    chown 1000:1000 "$rootfs/home/live"
    chmod 755 "$rootfs/home/live"

    # Add live user to necessary groups (wheel, video, audio, input, etc.)
    # Group format: name:x:GID:member1,member2,...
    for group in wheel audio video input render kvm cdrom adm autologin; do
        if grep -q "^${group}:" "$rootfs/etc/group" 2>/dev/null; then
            # Check if live user is already a member
            if ! grep "^${group}:" "$rootfs/etc/group" | grep -qE ":live(,|$)|,live(,|$)"; then
                # Get the current line
                current_line=$(grep "^${group}:" "$rootfs/etc/group")
                # Check if line ends with a colon (no members) or has members
                if [[ "$current_line" =~ :$ ]]; then
                    # No members yet, just append live
                    sed -i "s/^${group}:.*\$/&live/" "$rootfs/etc/group"
                else
                    # Has members, append ,live
                    sed -i "s/^${group}:.*\$/&,live/" "$rootfs/etc/group"
                fi
            fi
        fi
    done

    log_info "Live user account created"

    # ==========================================================================
    # Configure SDDM for autologin
    # ==========================================================================
    log_info "Configuring SDDM autologin..."

    mkdir -p "$rootfs/etc/sddm.conf.d"

    # Use X11 session for VM compatibility (Wayland DRM backend doesn't work in QEMU without GPU passthrough)
    # Check for X11 sessions FIRST
    local plasma_session=""
    for session_name in plasmax11 plasma; do
        if [ -f "$rootfs/usr/share/xsessions/${session_name}.desktop" ]; then
            plasma_session="$session_name"
            log_info "Using Plasma X11 session: $session_name (best VM compatibility)"
            break
        fi
    done
    # Fallback to Wayland session if no X11 session found
    if [ -z "$plasma_session" ]; then
        for session_name in plasma-wayland plasmawayland plasma; do
            if [ -f "$rootfs/usr/share/wayland-sessions/${session_name}.desktop" ]; then
                plasma_session="$session_name"
                log_info "Found Plasma Wayland session: $session_name"
                break
            fi
        done
    fi
    # Default to plasmax11 if nothing found
    if [ -z "$plasma_session" ]; then
        plasma_session="plasmax11"
        log_warn "No Plasma session file found, defaulting to: plasmax11"
        # List available session files for debugging
        log_info "Available X11 sessions:"
        ls -la "$rootfs/usr/share/xsessions/"*.desktop 2>/dev/null || log_warn "  (none found)"
        log_info "Available Wayland sessions:"
        ls -la "$rootfs/usr/share/wayland-sessions/"*.desktop 2>/dev/null || log_warn "  (none found)"
    fi

    # Verify startplasma-x11 exists
    if [ -f "$rootfs/usr/bin/startplasma-x11" ]; then
        log_info "Found startplasma-x11: /usr/bin/startplasma-x11"
    else
        log_warn "startplasma-x11 not found - Plasma X11 session may fail!"
    fi

    # Main SDDM configuration with autologin - use X11 display server
    cat > "$rootfs/etc/sddm.conf.d/autologin.conf" << EOF
[General]
InputMethod=
Numlock=none
DisplayServer=x11

[Autologin]
User=live
Session=$plasma_session
Relogin=false

[Theme]
Current=breeze

[Users]
MinimumUid=1000
MaximumUid=60000
EOF

    # Also create /etc/sddm.conf as backup
    cat > "$rootfs/etc/sddm.conf" << EOF
[General]
InputMethod=
Numlock=none
DisplayServer=x11

[Autologin]
User=live
Session=$plasma_session
Relogin=false

[Theme]
Current=breeze

[Users]
MinimumUid=1000
MaximumUid=60000
EOF

    log_info "SDDM autologin configured for user 'live' with session '$plasma_session'"

    # ==========================================================================
    # Create sulogin symlink for emergency/recovery shell
    # ==========================================================================
    if [ -f "$rootfs/sbin/sulogin" ] && [ ! -e "$rootfs/usr/sbin/sulogin" ]; then
        mkdir -p "$rootfs/usr/sbin"
        ln -sf /sbin/sulogin "$rootfs/usr/sbin/sulogin"
        log_info "Created sulogin symlink"
    elif [ -f "$rootfs/usr/bin/sulogin" ] && [ ! -e "$rootfs/usr/sbin/sulogin" ]; then
        mkdir -p "$rootfs/usr/sbin"
        ln -sf /usr/bin/sulogin "$rootfs/usr/sbin/sulogin"
        log_info "Created sulogin symlink from /usr/bin"
    fi

    # Create /etc/resolv.conf to prevent DNS lookup hangs
    cat > "$rootfs/etc/resolv.conf" << 'EOF'
# Localhost resolver (systemd-resolved or fallback)
nameserver 127.0.0.53
options edns0 trust-ad
EOF

    # Create /etc/host.conf
    cat > "$rootfs/etc/host.conf" << 'EOF'
order hosts,bind
multi on
EOF

    # Fix nsswitch.conf to avoid DNS lookups for users
    cat > "$rootfs/etc/nsswitch.conf" << 'EOF'
# Local files only - no network lookups
passwd:     files
group:      files
shadow:     files
hosts:      files dns
networks:   files
protocols:  files
services:   files
ethers:     files
rpc:        files
EOF

    # Set a password for root (same as live user: "live")
    # This allows emergency console access
    sed -i 's|^root:!:|root:$6$xyz$FZdeWWOx8j1RIJpolCHQ5yiYyTzlgffE4D5dB0ip66lHh4ynb9QOnrAzvzL4Dog6iuURvKRcHWi4zvAdJ8B2f1:|' "$rootfs/etc/shadow"

    # CRITICAL: Fix shadow file permissions - must be readable by shadow group
    # The login binary runs as root (setuid) and reads /etc/shadow directly
    chmod 640 "$rootfs/etc/shadow"
    # Ensure shadow group exists (GID 42 is conventional)
    if ! grep -q "^shadow:" "$rootfs/etc/group" 2>/dev/null; then
        echo "shadow:x:42:" >> "$rootfs/etc/group"
    fi
    # Set ownership - root:shadow
    chown 0:42 "$rootfs/etc/shadow"
    log_info "Fixed shadow file permissions"

    # CRITICAL: Set login binary to setuid root so it can read /etc/shadow
    # Without this, login cannot authenticate users!
    if [ -f "$rootfs/usr/bin/login" ]; then
        chmod u+s "$rootfs/usr/bin/login"
        log_info "Set login binary to setuid root"
        # Create /bin/login symlink so agetty can find it
        # agetty looks for "login" in PATH, which includes /bin
        if [ ! -e "$rootfs/bin/login" ]; then
            ln -sf /usr/bin/login "$rootfs/bin/login"
            log_info "Created /bin/login symlink"
        fi
    fi

    # Also set su and other authentication binaries to setuid
    for bin in su passwd chsh chfn; do
        if [ -f "$rootfs/usr/bin/$bin" ]; then
            chmod u+s "$rootfs/usr/bin/$bin"
        fi
    done

    # ==========================================================================
    # CRITICAL: Configure PAM for systemd/Wayland (XDG_RUNTIME_DIR)
    # ==========================================================================
    # The pam_systemd.so module is ESSENTIAL for Wayland - it:
    # - Creates XDG_RUNTIME_DIR (/run/user/UID)
    # - Registers user sessions with systemd-logind
    # - Provides seat management for Wayland compositors

    log_info "Configuring PAM for systemd and Wayland..."

    # Update system-session to include pam_systemd.so
    cat > "$rootfs/etc/pam.d/system-session" << 'EOF'
# Begin /etc/pam.d/system-session
session   required    pam_unix.so
session   required    pam_loginuid.so
session   optional    pam_systemd.so
# End /etc/pam.d/system-session
EOF

    # Update system-auth for proper auth chain
    cat > "$rootfs/etc/pam.d/system-auth" << 'EOF'
# Begin /etc/pam.d/system-auth
auth      required    pam_unix.so
# End /etc/pam.d/system-auth
EOF

    # Update system-account
    cat > "$rootfs/etc/pam.d/system-account" << 'EOF'
# Begin /etc/pam.d/system-account
account   required    pam_unix.so
# End /etc/pam.d/system-account
EOF

    # Update system-password
    cat > "$rootfs/etc/pam.d/system-password" << 'EOF'
# Begin /etc/pam.d/system-password
password  required    pam_unix.so sha512
# End /etc/pam.d/system-password
EOF

    # Configure SDDM PAM for autologin with pam_systemd
    # pam_systemd MUST be required for XDG_RUNTIME_DIR to be set up properly
    cat > "$rootfs/etc/pam.d/sddm-autologin" << 'EOF'
# SDDM autologin PAM configuration
auth     optional       pam_env.so
auth     required       pam_permit.so

account  required       pam_unix.so

password required       pam_deny.so

session  optional       pam_env.so
session  optional       pam_limits.so
session  required       pam_unix.so
session  optional       pam_loginuid.so
session  optional       pam_keyinit.so force revoke
session  required       pam_systemd.so
EOF

    # Configure SDDM main PAM (for password login)
    cat > "$rootfs/etc/pam.d/sddm" << 'EOF'
# SDDM PAM configuration
auth     optional       pam_env.so
auth     required       pam_unix.so

account  required       pam_unix.so

password required       pam_unix.so

session  optional       pam_env.so
session  optional       pam_limits.so
session  required       pam_unix.so
session  optional       pam_loginuid.so
session  optional       pam_keyinit.so force revoke
session  required       pam_systemd.so
EOF

    # Configure SDDM greeter PAM (BLFS-style)
    cat > "$rootfs/etc/pam.d/sddm-greeter" << 'EOF'
# Begin /etc/pam.d/sddm-greeter
auth     required       pam_env.so
auth     required       pam_permit.so
account  required       pam_permit.so
password required       pam_deny.so
session  required       pam_unix.so
-session optional       pam_systemd.so
# End /etc/pam.d/sddm-greeter
EOF

    # Configure login PAM (for console login)
    # Note: Using optional for pam_env.so and pam_limits.so to prevent failures
    # when config files don't exist
    cat > "$rootfs/etc/pam.d/login" << 'EOF'
# Login PAM configuration
auth     optional       pam_env.so
auth     required       pam_unix.so

account  required       pam_unix.so

password required       pam_unix.so

session  optional       pam_env.so
session  optional       pam_limits.so
session  required       pam_unix.so
session  optional       pam_loginuid.so
session  optional       pam_systemd.so
session  optional       pam_lastlog.so
EOF

    log_info "PAM configured for systemd/Wayland"

    # ==========================================================================
    # Enable essential systemd services for graphical boot
    # ==========================================================================

    # Create target directories
    mkdir -p "$rootfs/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$rootfs/etc/systemd/system/graphical.target.wants"
    mkdir -p "$rootfs/etc/systemd/system/sockets.target.wants"

    # CRITICAL: Enable systemd-logind - required for Wayland seat/session management
    if [ -f "$rootfs/usr/lib/systemd/system/systemd-logind.service" ]; then
        ln -sf /usr/lib/systemd/system/systemd-logind.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
        log_info "Enabled systemd-logind.service"
    fi

    # Enable systemd-user-sessions.service - removes /run/nologin to allow logins
    if [ -f "$rootfs/usr/lib/systemd/system/systemd-user-sessions.service" ]; then
        ln -sf /usr/lib/systemd/system/systemd-user-sessions.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
        log_info "Enabled systemd-user-sessions.service"
    fi

    # Enable D-Bus service
    if [ -f "$rootfs/usr/lib/systemd/system/dbus.service" ]; then
        ln -sf /usr/lib/systemd/system/dbus.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
    fi

    # Enable D-Bus socket for early activation
    if [ -f "$rootfs/usr/lib/systemd/system/dbus.socket" ]; then
        ln -sf /usr/lib/systemd/system/dbus.socket "$rootfs/etc/systemd/system/sockets.target.wants/"
    fi

    # Enable SDDM display manager
    if [ -f "$rootfs/usr/lib/systemd/system/sddm.service" ]; then
        ln -sf /usr/lib/systemd/system/sddm.service "$rootfs/etc/systemd/system/graphical.target.wants/"
        log_info "Enabled sddm.service"
    fi

    # Enable polkit daemon - required for session management and authorization
    if [ -f "$rootfs/usr/lib/systemd/system/polkit.service" ]; then
        ln -sf /usr/lib/systemd/system/polkit.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
        log_info "Enabled polkit.service"
    fi

    # Enable UPower - required for powerdevil (Plasma power management)
    # Note: upower.service has WantedBy=graphical.target, so enable it there
    if [ -f "$rootfs/usr/lib/systemd/system/upower.service" ]; then
        ln -sf /usr/lib/systemd/system/upower.service "$rootfs/etc/systemd/system/graphical.target.wants/"
        log_info "Enabled upower.service"
    fi

    # Enable power-profiles-daemon if available
    # Note: power-profiles-daemon has WantedBy=graphical.target
    if [ -f "$rootfs/usr/lib/systemd/system/power-profiles-daemon.service" ]; then
        ln -sf /usr/lib/systemd/system/power-profiles-daemon.service "$rootfs/etc/systemd/system/graphical.target.wants/"
        log_info "Enabled power-profiles-daemon.service"
    fi

    # Enable NetworkManager for network connectivity
    if [ -f "$rootfs/usr/lib/systemd/system/NetworkManager.service" ]; then
        ln -sf /usr/lib/systemd/system/NetworkManager.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
        log_info "Enabled NetworkManager.service"
    fi

    # Enable ModemManager for mobile broadband support
    if [ -f "$rootfs/usr/lib/systemd/system/ModemManager.service" ]; then
        ln -sf /usr/lib/systemd/system/ModemManager.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
        log_info "Enabled ModemManager.service"
    fi

    # Enable Bluetooth service
    if [ -f "$rootfs/usr/lib/systemd/system/bluetooth.service" ]; then
        ln -sf /usr/lib/systemd/system/bluetooth.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
        log_info "Enabled bluetooth.service"
    fi

    # Enable Avahi for mDNS/DNS-SD (network discovery)
    if [ -f "$rootfs/usr/lib/systemd/system/avahi-daemon.service" ]; then
        ln -sf /usr/lib/systemd/system/avahi-daemon.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
        log_info "Enabled avahi-daemon.service"
    fi

    # Enable ALSA sound restore service
    if [ -f "$rootfs/usr/lib/systemd/system/alsa-restore.service" ]; then
        ln -sf /usr/lib/systemd/system/alsa-restore.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
        log_info "Enabled alsa-restore.service"
    fi

    # Enable accounts-daemon for user account management
    if [ -f "$rootfs/usr/lib/systemd/system/accounts-daemon.service" ]; then
        ln -sf /usr/lib/systemd/system/accounts-daemon.service "$rootfs/etc/systemd/system/multi-user.target.wants/"
        log_info "Enabled accounts-daemon.service"
    fi

    # Enable CUPS printing service (socket activation)
    if [ -f "$rootfs/usr/lib/systemd/system/cups.socket" ]; then
        ln -sf /usr/lib/systemd/system/cups.socket "$rootfs/etc/systemd/system/sockets.target.wants/"
        log_info "Enabled cups.socket"
    fi

    # Create polkit rule to allow sddm to manage sessions
    mkdir -p "$rootfs/etc/polkit-1/rules.d"
    cat > "$rootfs/etc/polkit-1/rules.d/50-sddm.rules" << 'EOF'
/* Allow SDDM to manage sessions and seats */
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.reboot" ||
         action.id == "org.freedesktop.login1.power-off" ||
         action.id == "org.freedesktop.login1.suspend" ||
         action.id == "org.freedesktop.login1.hibernate") &&
        subject.user == "sddm") {
        return polkit.Result.YES;
    }
});
EOF
    chmod 644 "$rootfs/etc/polkit-1/rules.d/50-sddm.rules"

    # ==========================================================================
    # Create systemd drop-in for SDDM to set QML import paths
    # ==========================================================================
    # The breeze theme requires org.kde.kirigami and org.kde.breeze.components
    # which are installed in /usr/lib/qml but SDDM doesn't find them by default
    mkdir -p "$rootfs/etc/systemd/system/sddm.service.d"
    cat > "$rootfs/etc/systemd/system/sddm.service.d/qml-paths.conf" << 'EOF'
[Service]
Environment="QML_IMPORT_PATH=/usr/lib/qml"
Environment="QML2_IMPORT_PATH=/usr/lib/qml"
Environment="QT_PLUGIN_PATH=/usr/plugins:/usr/lib/plugins"
# Software rendering fallback for VMs without GPU passthrough
Environment="LIBGL_ALWAYS_SOFTWARE=1"
Environment="QT_QUICK_BACKEND=software"
Environment="KWIN_COMPOSE=Q"
# Enable debug logging for SDDM
Environment="QT_LOGGING_RULES=sddm.*=true;kwin.*=true"
EOF
    log_info "Created SDDM QML import path configuration"

    # ==========================================================================
    # Create SDDM configuration file with autologin and debugging
    # Note: This is intentionally named 00-live.conf so it's processed first,
    # and autologin.conf (processed later) takes precedence for session settings
    # ==========================================================================
    mkdir -p "$rootfs/etc/sddm.conf.d"
    cat > "$rootfs/etc/sddm.conf.d/00-live.conf" << 'EOF'
[General]
# Enable debug logging to journald
EnableHiDPI=true
HaltCommand=/usr/bin/systemctl poweroff
RebootCommand=/usr/bin/systemctl reboot
# Force X11 display server for VM compatibility
DisplayServer=x11

[Users]
DefaultPath=/usr/local/bin:/usr/bin:/bin
MaximumUid=60513
MinimumUid=1000

[X11]
# Session directory for X11 - check this FIRST
SessionDir=/usr/share/xsessions

[Wayland]
# Session directory for Wayland (fallback)
SessionDir=/usr/share/wayland-sessions

[Autologin]
# Autologin the live user with X11 Plasma session
User=live
Session=plasmax11
Relogin=false

[Theme]
# Use breeze theme
Current=breeze
EOF
    chmod 644 "$rootfs/etc/sddm.conf.d/00-live.conf"
    log_info "Created SDDM configuration with autologin"

    # ==========================================================================
    # Create global Qt/KDE environment for all sessions
    # ==========================================================================
    # The Qt plugins are installed in /usr/plugins, not /usr/lib/qt6/plugins
    # This is critical for Plasma Wayland to find the wayland platform plugin
    cat > "$rootfs/etc/profile.d/qt-kde.sh" << 'EOF'
# Qt/KDE environment configuration for Rookery OS
# Qt plugins are at /usr/plugins (not /usr/lib/qt6/plugins)
export QT_PLUGIN_PATH=/usr/plugins:/usr/lib/plugins
export QML_IMPORT_PATH=/usr/lib/qml
export QML2_IMPORT_PATH=/usr/lib/qml

# KDE plugin path
export QT_QPA_PLATFORMTHEME=kde

# Ensure Qt can find the wayland platform
if [ "$XDG_SESSION_TYPE" = "wayland" ]; then
    export QT_QPA_PLATFORM=wayland
fi

# Software rendering fallback for VMs
# Detect if we're in a VM (no render node available)
if [ ! -e /dev/dri/renderD128 ]; then
    export LIBGL_ALWAYS_SOFTWARE=1
    export QT_QUICK_BACKEND=software
    export KWIN_COMPOSE=Q
fi
EOF
    chmod 644 "$rootfs/etc/profile.d/qt-kde.sh"
    log_info "Created Qt/KDE environment configuration"

    # ==========================================================================
    # Create user service drop-in for powerdevil to handle VM environments
    # ==========================================================================
    # In VMs, powerdevil may crash due to missing power hardware. Make it more tolerant.
    mkdir -p "$rootfs/etc/systemd/user/plasma-powerdevil.service.d"
    cat > "$rootfs/etc/systemd/user/plasma-powerdevil.service.d/vm-tolerant.conf" << 'EOF'
[Unit]
# Wait a bit longer for DBus services like UPower to be ready
After=dbus.socket

[Service]
# Give it time to start up - VMs can be slow
TimeoutStartSec=30s
# Delay restart to avoid rapid crash loops
RestartSec=3s
# Limit restart attempts to avoid endless loops
StartLimitIntervalSec=60s
StartLimitBurst=3
EOF
    log_info "Created powerdevil VM-tolerant configuration"

    # Create polkit localauthority for live session (simpler format, more compatible)
    mkdir -p "$rootfs/etc/polkit-1/localauthority/50-local.d"
    cat > "$rootfs/etc/polkit-1/localauthority/50-local.d/50-allow-live.pkla" << 'EOF'
[Allow Live User All Actions]
Identity=unix-user:live
Action=*
ResultActive=yes
EOF

    # Set graphical target as default
    ln -sf /usr/lib/systemd/system/graphical.target "$rootfs/etc/systemd/system/default.target" 2>/dev/null || true

    # Mask problematic systemd units for live boot
    for unit in systemd-timesyncd.service; do
        ln -sf /dev/null "$rootfs/etc/systemd/system/$unit"
    done

    # Create a wrapper script for Plasma Wayland session startup if needed
    # This ensures proper environment is set for Wayland
    mkdir -p "$rootfs/usr/local/bin"
    cat > "$rootfs/usr/local/bin/plasma-wayland-wrapper" << 'EOF'
#!/bin/bash
# Wrapper script for Plasma Wayland session
# Ensures proper environment for Wayland

# Set Wayland-specific environment
export XDG_SESSION_TYPE=wayland
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland
export MOZ_ENABLE_WAYLAND=1

# Force software rendering for VMs
# kwin needs this BEFORE it starts to avoid trying DRM backend
export LIBGL_ALWAYS_SOFTWARE=1
export QT_QUICK_BACKEND=software
export KWIN_COMPOSE=Q
export MESA_GL_VERSION_OVERRIDE=3.3

# CRITICAL: Tell kwin to use X11 backend instead of DRM
# DRM backend requires direct GPU access which fails in VMs without proper passthrough
# The X11 backend runs kwin as a nested compositor under the X server that SDDM started
export KWIN_FORCE_SW_CURSOR=1

# Ensure XDG_RUNTIME_DIR exists (should be set by pam_systemd)
if [ -z "$XDG_RUNTIME_DIR" ]; then
    export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
fi

# Log environment for debugging
echo "plasma-wayland-wrapper: Starting Plasma with software rendering" >&2
echo "  KWIN_COMPOSE=$KWIN_COMPOSE" >&2
echo "  QT_QUICK_BACKEND=$QT_QUICK_BACKEND" >&2
echo "  XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" >&2

# Start Plasma X11 session instead of Wayland - more compatible with VMs
# Wayland+DRM doesn't work well in QEMU without GPU passthrough
exec /usr/bin/startplasma-x11 "$@"
EOF
    chmod 755 "$rootfs/usr/local/bin/plasma-wayland-wrapper"

    # Patch the plasma.desktop session file to use our wrapper
    # The actual Exec line may include plasma-dbus-run-session-if-needed wrapper
    if [ -f "$rootfs/usr/share/wayland-sessions/plasma.desktop" ]; then
        # Try both patterns - direct startplasma-wayland or via dbus wrapper
        sed -i 's|Exec=.*startplasma-wayland.*|Exec=/usr/local/bin/plasma-wayland-wrapper|' \
            "$rootfs/usr/share/wayland-sessions/plasma.desktop"
        log_info "Patched plasma.desktop to use wrapper script"
    fi

    # ==========================================================================
    # Create systemd user environment.d file for Plasma/kwin
    # ==========================================================================
    # IMPORTANT: Named zz-rookery-vm.conf to override package defaults (99-environment.conf)
    # Files are processed in alphabetical order, so zz comes after 99
    mkdir -p "$rootfs/etc/environment.d"
    cat > "$rootfs/etc/environment.d/zz-rookery-vm.conf" << 'EOF'
# Rookery OS VM compatibility settings
# Force virtual/software backend for kwin when no GPU available
# This file is named zz-* to override 99-environment.conf from packages
KWIN_COMPOSE=Q
QT_QUICK_BACKEND=software
LIBGL_ALWAYS_SOFTWARE=1
EOF
    chmod 644 "$rootfs/etc/environment.d/zz-rookery-vm.conf"
    log_info "Created systemd environment.d for VM compatibility (zz-rookery-vm.conf)"

    # Also create in the user location that systemd reads
    mkdir -p "$rootfs/usr/lib/environment.d"
    cat > "$rootfs/usr/lib/environment.d/zz-rookery-vm.conf" << 'EOF'
# Rookery OS VM compatibility settings
# Force virtual/software backend for kwin when no GPU available
# This file is named zz-* to override 99-environment.conf from packages
KWIN_COMPOSE=Q
QT_QUICK_BACKEND=software
LIBGL_ALWAYS_SOFTWARE=1
EOF
    chmod 644 "$rootfs/usr/lib/environment.d/zz-rookery-vm.conf"

    # Create a systemd user service drop-in for plasma-kwin_wayland for software rendering
    # Note: We do NOT use --virtual as it breaks input in QEMU. Let kwin detect the display.
    mkdir -p "$rootfs/etc/systemd/user/plasma-kwin_wayland.service.d"
    cat > "$rootfs/etc/systemd/user/plasma-kwin_wayland.service.d/vm-backend.conf" << 'EOF'
[Service]
# Force software rendering environment for VM compatibility
# Do NOT use --virtual flag as it breaks mouse/keyboard input
Environment="KWIN_COMPOSE=Q"
Environment="QT_QUICK_BACKEND=software"
Environment="LIBGL_ALWAYS_SOFTWARE=1"
Environment="MESA_GL_VERSION_OVERRIDE=3.3"
EOF
    chmod 644 "$rootfs/etc/systemd/user/plasma-kwin_wayland.service.d/vm-backend.conf"
    log_info "Created kwin_wayland service drop-in for software rendering"

    # Create SDDM debug script for troubleshooting
    cat > "$rootfs/usr/local/bin/debug-sddm" << 'EOF'
#!/bin/bash
echo "=== SDDM Debug Info ==="
echo ""
echo "=== SDDM Service Status ==="
systemctl status sddm --no-pager 2>&1 | head -30
echo ""
echo "=== UPower Service Status ==="
systemctl status upower --no-pager 2>&1 | head -15
echo ""
echo "=== Power-Profiles-Daemon Status ==="
systemctl status power-profiles-daemon --no-pager 2>&1 | head -15
echo ""
echo "=== SDDM Journal (last 50 lines) ==="
journalctl -b -u sddm --no-pager 2>&1 | tail -50
echo ""
echo "=== Session/Wayland/Plasma Errors ==="
journalctl -b 2>&1 | grep -iE 'sddm|wayland|plasma|kwin|session|powerdevil|upower|error' | tail -30
echo ""
echo "=== XDG Runtime Dirs ==="
ls -la /run/user/ 2>&1
echo ""
echo "=== Login Sessions ==="
loginctl list-sessions 2>&1
loginctl list-seats 2>&1
echo ""
echo "=== Plasma Session File ==="
cat /usr/share/wayland-sessions/plasma.desktop 2>&1
echo ""
echo "=== SDDM Config ==="
cat /etc/sddm.conf 2>&1
echo ""
echo "=== DRI/GPU Devices ==="
ls -la /dev/dri/ 2>&1
echo "Render node check:"
[ -e /dev/dri/renderD128 ] && echo "  renderD128: present" || echo "  renderD128: MISSING (software rendering will be used)"
echo ""
echo "=== Environment ==="
cat /etc/environment 2>&1
echo ""
echo "=== Polkit Status ==="
systemctl status polkit --no-pager 2>&1 | head -15
echo ""
echo "=== systemd-logind Status ==="
systemctl status systemd-logind --no-pager 2>&1 | head -15
echo ""
echo "=== kwin_wayland check ==="
which kwin_wayland 2>&1
ldd /usr/bin/kwin_wayland 2>&1 | grep -i 'not found'
echo ""
echo "=== SDDM user info ==="
id sddm 2>&1
groups sddm 2>&1
EOF
    chmod 755 "$rootfs/usr/local/bin/debug-sddm"

    # ==========================================================================
    # Fix XDG menu system for KDE application launcher
    # ==========================================================================
    # KDE Plasma uses plasma-applications.menu but kbuildsycoca6 looks for
    # applications.menu. Create a symlink to make the app menu work.
    if [ -f "$rootfs/etc/xdg/menus/plasma-applications.menu" ]; then
        ln -sf plasma-applications.menu "$rootfs/etc/xdg/menus/applications.menu"
        log_info "Created XDG menu symlink: applications.menu -> plasma-applications.menu"
    elif [ -d "$rootfs/etc/xdg/menus" ]; then
        log_warn "plasma-applications.menu not found - app menu may not work"
    fi

    # ==========================================================================
    # Configure Calamares installer for live installation
    # ==========================================================================
    log_info "Configuring Calamares installer..."

    # Create Calamares directories if they don't exist
    mkdir -p "$rootfs/etc/calamares/modules"
    mkdir -p "$rootfs/etc/calamares/branding/rookeryos"

    # Fix unpackfs config to point to correct squashfs location
    # The ISO is mounted at /run/rootfsbase, squashfs is at LiveOS/rootfs.img
    # Using unpackfs (Python version) with nested config format
    cat > "$rootfs/etc/calamares/modules/unpackfs-rootfs.conf" << 'EOF'
---
unpack:
    - source: "/run/rootfsbase/LiveOS/rootfs.img"
      sourcefs: "squashfs"
      destination: ""
EOF

    # Create proper settings.conf with correct module names
    cat > "$rootfs/etc/calamares/settings.conf" << 'EOF'
---
modules-search: [ local, /usr/lib/calamares/modules ]

instances:
- id:       rootfs
  module:   unpackfs
  config:   unpackfs-rootfs.conf
  weight:   50

sequence:
- show:
  - welcome
  - locale
  - keyboard
  - partition
  - users
  - summary
- exec:
  - partition
  - mount
  - unpackfs@rootfs
  - machineid
  - fstab
  - locale
  - keyboard
  - localecfg
  - users
  - displaymanager
  - networkcfg
  - hwclock
  - services-systemd
  - bootloader
  - grubcfg
  - umount
- show:
  - finished

branding: rookeryos
prompt-install: true
dont-chroot: false
EOF

    # Create bootloader module config
    cat > "$rootfs/etc/calamares/modules/bootloader.conf" << 'EOF'
---
efiBootLoader: "grub"
kernel: "/boot/vmlinuz"
img: "/boot/initramfs.img"
fallback: "/boot/initramfs.img"
timeout: 5
grubInstall: "grub-install"
grubMkconfig: "grub-mkconfig"
grubCfg: "/boot/grub/grub.cfg"
grubProbe: "grub-probe"
efiBootMgr: "efibootmgr"
installEFIFallback: true
EOF

    # Create machineid module config
    # Based on Calamares upstream defaults and Manjaro configuration
    # Using systemd-style: blank so systemd generates UUID on first boot
    # dbus: false because modern systemd handles this automatically
    # This avoids chroot issues with finding dbus-uuidgen
    cat > "$rootfs/etc/calamares/modules/machineid.conf" << 'EOF'
---
# Write /etc/machine-id as empty file, systemd will populate on first boot
systemd: true
systemd-style: blank

# Don't create separate dbus machine-id (systemd handles it)
dbus: false
dbus-symlink: false

# Create entropy files for random seed
entropy-copy: false
entropy-files:
    - /var/lib/systemd/random-seed
EOF

    # Create services-systemd module config
    cat > "$rootfs/etc/calamares/modules/services-systemd.conf" << 'EOF'
---
services:
  - name: "NetworkManager"
    mandatory: false
  - name: "sddm"
    mandatory: false
  - name: "systemd-timesyncd"
    mandatory: false

targets:
  - name: "graphical"
    mandatory: true
EOF

    # Create mount module config
    cat > "$rootfs/etc/calamares/modules/mount.conf" << 'EOF'
---
extraMounts:
    - device: proc
      fs: proc
      mountPoint: /proc
    - device: sys
      fs: sysfs
      mountPoint: /sys
    - device: /dev
      mountPoint: /dev
      options: bind
    - device: tmpfs
      fs: tmpfs
      mountPoint: /run
    - device: /run/udev
      mountPoint: /run/udev
      options: bind
btrfsSubvolumes:
    - mountPoint: /
      subvolume: /@
    - mountPoint: /home
      subvolume: /@home
    - mountPoint: /var/log
      subvolume: /@log
    - mountPoint: /var/cache
      subvolume: /@cache
btrfsSwapSubvol: /@swap
EOF

    # Create partition module config
    cat > "$rootfs/etc/calamares/modules/partition.conf" << 'EOF'
---
efiSystemPartition: "/boot/efi"
efiSystemPartitionSize: 512M
efiSystemPartitionName: "EFI"
userSwapChoices:
    - none
    - small
    - suspend
    - file
drawNestedPartitions: false
alwaysShowPartitionLabels: true
allowManualPartitioning: true
initialPartitioningChoice: erase
initialSwapChoice: small
defaultFileSystemType: "ext4"
availableFileSystemTypes:
    - ext4
    - btrfs
    - xfs
EOF

    # Create displaymanager module config
    cat > "$rootfs/etc/calamares/modules/displaymanager.conf" << 'EOF'
---
displaymanagers:
    - sddm
basicSetup: false
EOF

    # Create users module config
    cat > "$rootfs/etc/calamares/modules/users.conf" << 'EOF'
---
defaultGroups:
    - users
    - wheel
    - audio
    - video
    - input
    - storage
    - optical
    - network
    - lp
    - scanner
autologinGroup: autologin
sudoersGroup: wheel
setRootPassword: true
doAutologin: false
EOF

    # Create welcome module config
    cat > "$rootfs/etc/calamares/modules/welcome.conf" << 'EOF'
---
showSupportUrl: true
showKnownIssuesUrl: true
showReleaseNotesUrl: true
showDonateUrl: false

requirements:
    requiredStorage: 10.0
    requiredRam: 2.0
    internetCheckUrl: https://rookeryos.dev
    check:
        - storage
        - ram
        - root
    required:
        - storage
        - ram
        - root
EOF

    # Create finished module config
    cat > "$rootfs/etc/calamares/modules/finished.conf" << 'EOF'
---
restartNowEnabled: true
restartNowChecked: true
restartNowCommand: "systemctl reboot"
notifyOnFinished: true
EOF

    # Create locale module config
    cat > "$rootfs/etc/calamares/modules/locale.conf" << 'EOF'
---
region: "America"
zone: "New_York"
localeGenPath: /etc/locale.gen
geoip:
    style: "none"
EOF

    # Create keyboard module config
    cat > "$rootfs/etc/calamares/modules/keyboard.conf" << 'EOF'
---
xOrgConfFileName: "/etc/X11/xorg.conf.d/00-keyboard.conf"
convertedKeymapPath: "/lib/kbd/keymaps/xkb"
writeEtcDefaultKeyboard: true
EOF

    # Create fstab module config
    cat > "$rootfs/etc/calamares/modules/fstab.conf" << 'EOF'
---
mountOptions:
    default: defaults,noatime
    btrfs: defaults,noatime,compress=zstd:1
    ext4: defaults,noatime
    xfs: defaults,noatime
efiMountOptions: umask=0077
EOF

    # Create grubcfg module config
    cat > "$rootfs/etc/calamares/modules/grubcfg.conf" << 'EOF'
---
grubInstall: "grub-install"
grubMkconfig: "grub-mkconfig"
grubCfg: "/boot/grub/grub.cfg"
grubProbe: "grub-probe"
efiBootMgr: "efibootmgr"
installEFIFallback: true
EOF

    # Create branding if it doesn't exist
    if [ ! -f "$rootfs/etc/calamares/branding/rookeryos/branding.desc" ]; then
        cat > "$rootfs/etc/calamares/branding/rookeryos/branding.desc" << 'EOF'
---
componentName: rookeryos

welcomeStyleCalamares: true
welcomeExpandingLogo: true

strings:
    productName:         "Rookery OS"
    shortProductName:    "Rookery"
    version:             "1.0"
    shortVersion:        "1.0"
    versionedName:       "Rookery OS 1.0"
    shortVersionedName:  "Rookery 1.0"
    bootloaderEntryName: "Rookery OS"
    productUrl:          "https://rookeryos.dev"
    supportUrl:          "https://rookeryos.dev/support"
    knownIssuesUrl:      "https://rookeryos.dev/issues"
    releaseNotesUrl:     "https://rookeryos.dev/releases"
    donateUrl:           "https://rookeryos.dev/donate"

images:
    productLogo:         "logo.png"
    productIcon:         "icon.png"
    productWelcome:      "welcome.png"

slideshowAPI: 2
slideshow:
    - "slide1.qml"

style:
    sidebarBackground:    "#2a2a2a"
    sidebarText:          "#ffffff"
    sidebarTextSelect:    "#4da6ff"
    sidebarTextHighlight: "#ffffff"
EOF

        # Create simple slideshow
        cat > "$rootfs/etc/calamares/branding/rookeryos/slide1.qml" << 'EOF'
import QtQuick 2.0

Rectangle {
    color: "#2a2a2a"

    Text {
        anchors.centerIn: parent
        text: "Welcome to Rookery OS"
        color: "white"
        font.pixelSize: 32
    }
}
EOF

        # Create placeholder images
        touch "$rootfs/etc/calamares/branding/rookeryos/logo.png"
        touch "$rootfs/etc/calamares/branding/rookeryos/icon.png"
        touch "$rootfs/etc/calamares/branding/rookeryos/welcome.png"
    fi

    # Allow live user full passwordless sudo (for live ISO only)
    mkdir -p "$rootfs/etc/sudoers.d"
    cat > "$rootfs/etc/sudoers.d/live-user" << 'EOF'
# Allow live user passwordless sudo for live ISO
live ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 440 "$rootfs/etc/sudoers.d/live-user"

    # Override the desktop entry to use sudo instead of pkexec
    mkdir -p "$rootfs/usr/share/applications"
    cat > "$rootfs/usr/share/applications/calamares.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Version=1.0
Name=Install Rookery OS
GenericName=System Installer
Comment=Install Rookery OS to your computer
Exec=sudo /usr/bin/calamares
Icon=calamares
Terminal=false
Categories=System;
Keywords=installer;calamares;system;
EOF

    log_info "Calamares installer configured"

    # Create python symlink (some tools expect 'python' not 'python3')
    if [ -f "$rootfs/usr/bin/python3" ] && [ ! -e "$rootfs/usr/bin/python" ]; then
        ln -s python3 "$rootfs/usr/bin/python"
        log_info "Created python -> python3 symlink"
    fi

    log_info "Live system configured"
}

# =============================================================================
# Step 3b: Set PaX Flags for grsecurity Compatibility
# =============================================================================
set_pax_flags() {
    log_step "Setting PaX flags on ALL ELF binaries and libraries..."

    local rootfs="$BUILD/rootfs"

    # The grsec kernel has BOTH CONFIG_PAX_PT_PAX_FLAGS=y AND CONFIG_PAX_XATTR_PAX_FLAGS=y
    # When both are enabled, PaX requires the SAME flags in BOTH locations!
    # We use BOTH paxctl (for PT_PAX ELF header) AND setfattr (for xattr).
    #
    # SECURITY MODEL:
    # - All binaries in the rootfs are built by us and trusted
    # - Any malware introduced later would NOT have PaX flags
    # - grsec will kill any binary without proper PaX flags
    # - This gives us defense-in-depth: trusted binaries run, untrusted die

    local have_paxctl=false
    local have_setfattr=false

    if [ -x "$rootfs/usr/sbin/paxctl" ]; then
        have_paxctl=true
    fi
    if command -v setfattr &>/dev/null; then
        have_setfattr=true
    fi

    if [ "$have_paxctl" = false ] && [ "$have_setfattr" = false ]; then
        log_warn "Neither paxctl nor setfattr available - PaX flags cannot be set"
        log_warn "Binaries may fail with grsecurity kernel"
        return 0
    fi

    log_info "Setting PaX flags on all ELF files in rootfs"
    log_info "  paxctl available: $have_paxctl"
    log_info "  setfattr available: $have_setfattr"

    # The flags string for xattr:
    #   UPPERCASE = enable protection
    #   lowercase = disable protection
    # pemRS = disable PAGEEXEC, EMUTRAMP, MPROTECT; enable RANDMMAP and SEGMEXEC
    # This MUST match the PT_PAX flags (-cpme) which also disables P, E, M
    local pax_flags="pemRS"

    local marked=0
    local failed=0

    # Helper function to set PaX flags on a file (BOTH xattr AND ELF header)
    set_pax_flags_on_file() {
        local file="$1"
        local binary_path="$2"  # Path relative to rootfs for paxctl chroot
        local xattr_ok=false
        local pt_pax_ok=false

        # Method 1: Set xattr (user.pax.flags)
        if [ "$have_setfattr" = true ]; then
            if setfattr -n user.pax.flags -v "$pax_flags" "$file" 2>/dev/null; then
                xattr_ok=true
            fi
        fi

        # Method 2: Set PT_PAX ELF header via paxctl (run in chroot)
        # paxctl flags: -c create PT_PAX, -p PAGEEXEC off, -m MPROTECT off, -e EMUTRAMP off
        if [ "$have_paxctl" = true ] && [ -n "$binary_path" ]; then
            if chroot "$rootfs" /usr/sbin/paxctl -cpme "$binary_path" 2>/dev/null; then
                pt_pax_ok=true
            fi
        fi

        # Success if at least one method worked
        if [ "$xattr_ok" = true ] || [ "$pt_pax_ok" = true ]; then
            return 0
        else
            return 1
        fi
    }

    # Process ALL ELF executables in common binary directories
    # Using for loop with glob to avoid subshell issues
    log_info "Processing ALL executables and libraries with PaX flags..."

    # Create a temporary file list to avoid subshell issues
    local tmplist=$(mktemp)

    # Find all executables in standard bin directories
    find "$rootfs/usr/bin" "$rootfs/usr/sbin" "$rootfs/usr/libexec" \
         "$rootfs/bin" "$rootfs/sbin" \
         -type f -executable 2>/dev/null >> "$tmplist" || true

    # Find all shared libraries in /usr/lib
    find "$rootfs/usr/lib" -name "*.so*" -type f 2>/dev/null >> "$tmplist" || true

    # Find ALL executables anywhere in /usr/lib (polkit, dbus helpers, etc)
    find "$rootfs/usr/lib" -type f -executable 2>/dev/null >> "$tmplist" || true

    # Process each file
    local total=0
    local success=0

    while IFS= read -r file; do
        # Skip if not an ELF file
        if ! file "$file" 2>/dev/null | grep -q "ELF"; then
            continue
        fi

        total=$((total + 1))
        local rel_path="${file#$rootfs}"

        # Set xattr flags
        local xattr_ok=false
        if [ "$have_setfattr" = true ]; then
            if setfattr -n user.pax.flags -v "$pax_flags" "$file" 2>/dev/null; then
                xattr_ok=true
            fi
        fi

        # Set PT_PAX flags via paxctl in chroot
        local pt_pax_ok=false
        if [ "$have_paxctl" = true ]; then
            if chroot "$rootfs" /usr/sbin/paxctl -cpme "$rel_path" 2>/dev/null; then
                pt_pax_ok=true
            fi
        fi

        if [ "$xattr_ok" = true ] || [ "$pt_pax_ok" = true ]; then
            success=$((success + 1))
        fi

        # Progress indicator every 500 files
        if [ $((total % 500)) -eq 0 ]; then
            log_info "  Processed $total files..."
        fi
    done < "$tmplist"

    rm -f "$tmplist"

    log_info "PaX flags (xattr: $pax_flags, PT_PAX: -cpme) set on $success of $total ELF files"
}

# =============================================================================
# Rebuild Library Cache (ldconfig)
# =============================================================================
rebuild_library_cache() {
    log_step "Rebuilding dynamic linker cache (ldconfig)..."

    local rootfs="$BUILD/rootfs"

    # Create ld.so.conf if it doesn't exist
    if [ ! -f "$rootfs/etc/ld.so.conf" ]; then
        log_info "Creating /etc/ld.so.conf..."
        cat > "$rootfs/etc/ld.so.conf" << 'EOF'
# Include standard library paths
include /etc/ld.so.conf.d/*.conf
/usr/lib
/lib
/usr/local/lib
EOF
    fi

    # Create ld.so.conf.d directory if it doesn't exist
    mkdir -p "$rootfs/etc/ld.so.conf.d"

    # Ensure /usr/lib is in the search path
    if [ ! -f "$rootfs/etc/ld.so.conf.d/usr-lib.conf" ]; then
        echo "/usr/lib" > "$rootfs/etc/ld.so.conf.d/usr-lib.conf"
    fi

    # Run ldconfig in the chroot to rebuild the library cache
    # This creates /etc/ld.so.cache with all shared libraries indexed
    if [ -x "$rootfs/sbin/ldconfig" ]; then
        log_info "Running ldconfig via chroot (using /sbin/ldconfig)..."
        chroot "$rootfs" /sbin/ldconfig -v 2>&1 | tail -20
    elif [ -x "$rootfs/usr/sbin/ldconfig" ]; then
        log_info "Running ldconfig via chroot (using /usr/sbin/ldconfig)..."
        chroot "$rootfs" /usr/sbin/ldconfig -v 2>&1 | tail -20
    else
        # Fall back to running host ldconfig with rootfs as root
        log_warn "No ldconfig in rootfs, using host ldconfig..."
        ldconfig -r "$rootfs" -v 2>&1 | tail -20
    fi

    # Verify the cache was created
    if [ -f "$rootfs/etc/ld.so.cache" ]; then
        local cache_size=$(du -h "$rootfs/etc/ld.so.cache" | cut -f1)
        local lib_count=$(ldconfig -r "$rootfs" -p 2>/dev/null | wc -l)
        log_info "Library cache created: $cache_size ($lib_count libraries)"
    else
        log_warn "Library cache may not have been created properly"
    fi
}

# =============================================================================
# Step 3d: Create initramfs for installed system
# =============================================================================
create_installed_initramfs() {
    log_step "Creating initramfs for installed system..."

    local rootfs="$BUILD/rootfs"
    local kver=$(ls "$rootfs/lib/modules" 2>/dev/null | head -1)

    if [ -z "$kver" ]; then
        log_warn "No kernel modules found, skipping initramfs creation"
        return
    fi

    log_info "Creating initramfs for kernel $kver"

    # Create minimal initramfs using util-linux and coreutils from the rootfs
    local initrd_dir=$(mktemp -d)
    mkdir -p "$initrd_dir"/{bin,sbin,etc,proc,sys,dev,lib,lib64,usr/lib,usr/bin,run,newroot}

    # Copy dynamic linker first
    cp "$rootfs/usr/lib/ld-linux-x86-64.so.2" "$initrd_dir/lib64/"
    ln -sf ../lib64/ld-linux-x86-64.so.2 "$initrd_dir/lib/ld-linux-x86-64.so.2"

    # Copy essential glibc libraries
    for lib in libc.so.6 libm.so.6 libpthread.so.0 libdl.so.2 librt.so.1 libresolv.so.2; do
        cp "$rootfs/usr/lib/$lib" "$initrd_dir/lib/" 2>/dev/null || true
    done

    # Copy util-linux binaries (mount, switch_root, etc.)
    for bin in mount umount switch_root blkid; do
        if [ -f "$rootfs/usr/bin/$bin" ]; then
            cp "$rootfs/usr/bin/$bin" "$initrd_dir/bin/"
        fi
    done

    # Copy coreutils binaries
    for bin in sh cat ls mkdir mknod sleep; do
        if [ -f "$rootfs/usr/bin/$bin" ]; then
            cp "$rootfs/usr/bin/$bin" "$initrd_dir/bin/"
        fi
    done

    # Copy additional libraries needed by util-linux
    for lib in libblkid.so.1 libuuid.so.1 libmount.so.1; do
        cp "$rootfs/usr/lib/$lib" "$initrd_dir/lib/" 2>/dev/null || true
    done

    # Copy kernel modules (essential ones for disk access)
    if [ -d "$rootfs/lib/modules/$kver" ]; then
        mkdir -p "$initrd_dir/lib/modules/$kver/kernel/drivers"
        # Copy disk drivers
        cp -a "$rootfs/lib/modules/$kver/kernel/drivers/ata" "$initrd_dir/lib/modules/$kver/kernel/drivers/" 2>/dev/null || true
        cp -a "$rootfs/lib/modules/$kver/kernel/drivers/scsi" "$initrd_dir/lib/modules/$kver/kernel/drivers/" 2>/dev/null || true
        cp -a "$rootfs/lib/modules/$kver/kernel/drivers/virtio" "$initrd_dir/lib/modules/$kver/kernel/drivers/" 2>/dev/null || true
        cp -a "$rootfs/lib/modules/$kver/kernel/drivers/block" "$initrd_dir/lib/modules/$kver/kernel/drivers/" 2>/dev/null || true
        # Copy filesystem modules
        mkdir -p "$initrd_dir/lib/modules/$kver/kernel/fs"
        cp -a "$rootfs/lib/modules/$kver/kernel/fs/ext4" "$initrd_dir/lib/modules/$kver/kernel/fs/" 2>/dev/null || true
        cp -a "$rootfs/lib/modules/$kver/kernel/fs/btrfs" "$initrd_dir/lib/modules/$kver/kernel/fs/" 2>/dev/null || true
        cp -a "$rootfs/lib/modules/$kver/kernel/fs/xfs" "$initrd_dir/lib/modules/$kver/kernel/fs/" 2>/dev/null || true
        # Copy modules.* files
        cp "$rootfs/lib/modules/$kver/modules."* "$initrd_dir/lib/modules/$kver/" 2>/dev/null || true
    fi

    # Create init script
    cat > "$initrd_dir/init" << 'INIT'
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

# Load essential modules
for mod in virtio_pci virtio_blk virtio_scsi sd_mod ahci; do
    modprobe $mod 2>/dev/null || true
done

# Wait for devices
sleep 1

# Find and mount root filesystem
root=""
rootfstype=""
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        root=*) root="${arg#root=}" ;;
        rootfstype=*) rootfstype="${arg#rootfstype=}" ;;
    esac
done

# Handle root=UUID=xxx
if [ "${root#UUID=}" != "$root" ]; then
    uuid="${root#UUID=}"
    root=$(blkid -U "$uuid" 2>/dev/null)
fi

if [ -n "$root" ]; then
    if [ -n "$rootfstype" ]; then
        mount -t "$rootfstype" "$root" /newroot
    else
        mount "$root" /newroot
    fi

    if [ -d /newroot/sbin ]; then
        umount /proc /sys /dev 2>/dev/null
        exec switch_root /newroot /sbin/init
    fi
fi

echo "Failed to mount root filesystem: $root"
echo "Dropping to shell..."
exec /bin/sh
INIT
    chmod +x "$initrd_dir/init"

    # Create initramfs using cpio
    (cd "$initrd_dir" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$rootfs/boot/initramfs.img")
    rm -rf "$initrd_dir"

    if [ -f "$rootfs/boot/initramfs.img" ]; then
        log_info "Created initramfs: $(du -h "$rootfs/boot/initramfs.img" | cut -f1)"
    else
        log_warn "Failed to create initramfs"
    fi
}

# =============================================================================
# Step 4: Create SquashFS Image
# =============================================================================
create_squashfs() {
    log_step "Creating SquashFS image..."

    local rootfs="$BUILD/rootfs"
    local squashfs="$BUILD/iso/LiveOS/rootfs.img"

    mksquashfs "$rootfs" "$squashfs" \
        -comp zstd \
        -Xcompression-level 19 \
        -b 1M \
        -no-recovery \
        -xattrs \
        -e 'dev/*' \
        -e 'proc/*' \
        -e 'sys/*' \
        -e 'run/*' \
        -e 'tmp/*'

    local size=$(du -h "$squashfs" | cut -f1)
    log_info "Created SquashFS: $size"
}

# Helper function to copy a binary and its library dependencies
copy_binary_with_libs() {
    local binary="$1"
    local dest_root="$2"
    local source_root="${3:-}"

    [ -f "$binary" ] || return 0

    # Determine destination path
    local rel_path="${binary#$source_root}"
    local dest_dir="$dest_root$(dirname "$rel_path")"
    mkdir -p "$dest_dir"
    cp -n "$binary" "$dest_root$rel_path" 2>/dev/null || true

    # Copy library dependencies
    local libs=$(ldd "$binary" 2>/dev/null | grep -o '/[^ ]*' | sort -u)
    for lib in $libs; do
        if [ -f "$lib" ]; then
            local real_lib=$(readlink -f "$lib")
            if [ -f "$real_lib" ]; then
                cp -n "$real_lib" "$dest_root/lib64/$(basename "$lib")" 2>/dev/null || true
            fi
        fi
    done
}

# =============================================================================
# Step 5: Build Initramfs
# =============================================================================
build_initramfs() {
    log_step "Building initramfs..."

    local initrd="$BUILD/initramfs"
    local rootfs="$BUILD/rootfs"

    # Create directory structure
    mkdir -p "$initrd"/{bin,sbin,etc,proc,sys,dev,run,tmp,newroot,mnt}
    mkdir -p "$initrd"/lib64/modules
    mkdir -p "$initrd"/usr/{bin,sbin,lib,lib64}
    mkdir -p "$initrd"/run/rootfsbase
    ln -sf lib64 "$initrd/lib"
    rm -rf "$initrd/usr/lib"
    ln -sf ../lib64 "$initrd/usr/lib"

    # Copy the dynamic linker
    log_info "Copying dynamic linker..."
    local real_ld=""
    if [ -e "$rootfs/lib64/ld-linux-x86-64.so.2" ]; then
        real_ld=$(readlink -f "$rootfs/lib64/ld-linux-x86-64.so.2")
    elif [ -e "$rootfs/lib/ld-linux-x86-64.so.2" ]; then
        real_ld=$(readlink -f "$rootfs/lib/ld-linux-x86-64.so.2")
    elif [ -e "$rootfs/usr/lib/ld-linux-x86-64.so.2" ]; then
        real_ld=$(readlink -f "$rootfs/usr/lib/ld-linux-x86-64.so.2")
    fi
    if [ -n "$real_ld" ] && [ -f "$real_ld" ]; then
        cp "$real_ld" "$initrd/lib64/ld-linux-x86-64.so.2"
    else
        log_error "Dynamic linker not found!"
        exit 1
    fi

    # Copy core glibc libraries
    log_info "Copying glibc libraries..."
    for lib in libc.so.6 libm.so.6 libresolv.so.2 libnss_files.so.2 libpthread.so.0 libdl.so.2 librt.so.1; do
        for search_dir in "$rootfs/lib64" "$rootfs/lib" "$rootfs/usr/lib"; do
            if [ -e "$search_dir/$lib" ]; then
                local real_lib=$(readlink -f "$search_dir/$lib")
                if [ -f "$real_lib" ]; then
                    cp "$real_lib" "$initrd/lib64/$lib" 2>/dev/null || true
                fi
                break
            fi
        done
    done

    # Copy essential binaries
    log_info "Copying essential binaries..."

    # Shell
    for shell_bin in bash sh; do
        for path in "$rootfs/usr/bin/$shell_bin" "$rootfs/bin/$shell_bin"; do
            if [ -f "$path" ] && [ ! -L "$path" ]; then
                copy_binary_with_libs "$path" "$initrd" "$rootfs"
                break
            elif [ -L "$path" ]; then
                local target=$(readlink -f "$path")
                if [ -f "$target" ]; then
                    copy_binary_with_libs "$target" "$initrd" "$rootfs"
                fi
                local rel_path="${path#$rootfs}"
                mkdir -p "$initrd$(dirname "$rel_path")"
                cp -a "$path" "$initrd$rel_path" 2>/dev/null || true
                break
            fi
        done
    done

    # Create /bin/sh symlink
    rm -f "$initrd/bin/sh"
    if [ -f "$initrd/usr/bin/bash" ]; then
        ln -sf ../usr/bin/bash "$initrd/bin/sh"
    elif [ -f "$initrd/bin/bash" ]; then
        ln -sf bash "$initrd/bin/sh"
    fi

    # Core utilities
    COREUTILS_BINS="cat ls mkdir mknod mount umount sleep echo ln cp mv rm chmod chown chroot stat head tail uname"
    for bin in $COREUTILS_BINS; do
        for path in "$rootfs/usr/bin/$bin" "$rootfs/bin/$bin"; do
            if [ -f "$path" ]; then
                copy_binary_with_libs "$path" "$initrd" "$rootfs"
                break
            fi
        done
    done

    # Util-linux binaries
    UTILLINUX_BINS="switch_root mount umount losetup blkid findmnt dmesg"
    for bin in $UTILLINUX_BINS; do
        for path in "$rootfs/usr/sbin/$bin" "$rootfs/usr/bin/$bin" "$rootfs/sbin/$bin" "$rootfs/bin/$bin"; do
            if [ -f "$path" ]; then
                copy_binary_with_libs "$path" "$initrd" "$rootfs"
                break
            fi
        done
    done

    # Kmod utilities
    KMOD_BINS="modprobe insmod lsmod depmod"
    for bin in $KMOD_BINS; do
        for path in "$rootfs/usr/sbin/$bin" "$rootfs/sbin/$bin" "$rootfs/usr/bin/$bin"; do
            if [ -f "$path" ]; then
                copy_binary_with_libs "$path" "$initrd" "$rootfs"
                break
            elif [ -L "$path" ]; then
                local target=$(readlink -f "$path")
                if [ -f "$target" ]; then
                    copy_binary_with_libs "$target" "$initrd" "$rootfs"
                fi
                local rel_path="${path#$rootfs}"
                mkdir -p "$initrd$(dirname "$rel_path")"
                cp -a "$path" "$initrd$rel_path" 2>/dev/null || true
                break
            fi
        done
    done

    # Additional libraries
    log_info "Copying additional libraries..."
    for lib in libblkid.so.1 libmount.so.1 libuuid.so.1 libreadline.so.8 libncursesw.so.6 \
               libtinfo.so.6 libz.so.1 liblzma.so.5 libzstd.so.1 libkmod.so.2 libcrypto.so.3; do
        for search_dir in "$rootfs/lib64" "$rootfs/lib" "$rootfs/usr/lib64" "$rootfs/usr/lib"; do
            if [ -e "$search_dir/$lib" ]; then
                local real_lib=$(readlink -f "$search_dir/$lib")
                if [ -f "$real_lib" ]; then
                    cp "$real_lib" "$initrd/lib64/$lib" 2>/dev/null || true
                fi
                break
            fi
        done
    done

    # Copy kernel modules from rootfs
    log_step "Copying kernel modules..."
    local kernel_version=""
    if [ -d "$rootfs/lib/modules" ]; then
        kernel_version=$(ls -1 "$rootfs/lib/modules" | head -1)
    fi

    if [ -n "$kernel_version" ] && [ -d "$rootfs/lib/modules/$kernel_version" ]; then
        local mod_src="$rootfs/lib/modules/$kernel_version"
        local mod_dst="$initrd/lib/modules/$kernel_version"
        mkdir -p "$mod_dst/kernel/fs" "$mod_dst/kernel/drivers/block" "$mod_dst/kernel/drivers/scsi" "$mod_dst/kernel/drivers/cdrom" "$mod_dst/kernel/drivers/ata"

        # Copy required modules
        find "$mod_src" -name "isofs.ko*" -exec cp {} "$mod_dst/kernel/fs/" \; 2>/dev/null || true
        find "$mod_src" -name "iso9660.ko*" -exec cp {} "$mod_dst/kernel/fs/" \; 2>/dev/null || true
        find "$mod_src" -name "squashfs.ko*" -exec cp {} "$mod_dst/kernel/fs/" \; 2>/dev/null || true
        find "$mod_src" -name "overlay.ko*" -exec cp {} "$mod_dst/kernel/fs/" \; 2>/dev/null || true
        find "$mod_src" -name "loop.ko*" -exec cp {} "$mod_dst/kernel/drivers/block/" \; 2>/dev/null || true
        find "$mod_src" -name "sr_mod.ko*" -exec cp {} "$mod_dst/kernel/drivers/scsi/" \; 2>/dev/null || true
        find "$mod_src" -name "cdrom.ko*" -exec cp {} "$mod_dst/kernel/drivers/cdrom/" \; 2>/dev/null || true
        find "$mod_src" -name "scsi_mod.ko*" -exec cp {} "$mod_dst/kernel/drivers/scsi/" \; 2>/dev/null || true
        find "$mod_src" -name "sd_mod.ko*" -exec cp {} "$mod_dst/kernel/drivers/scsi/" \; 2>/dev/null || true
        find "$mod_src" -name "ata_piix.ko*" -exec cp {} "$mod_dst/kernel/drivers/ata/" \; 2>/dev/null || true
        find "$mod_src" -name "ata_generic.ko*" -exec cp {} "$mod_dst/kernel/drivers/ata/" \; 2>/dev/null || true
        find "$mod_src" -name "ahci.ko*" -exec cp {} "$mod_dst/kernel/drivers/ata/" \; 2>/dev/null || true
        find "$mod_src" -name "libahci.ko*" -exec cp {} "$mod_dst/kernel/drivers/ata/" \; 2>/dev/null || true
        find "$mod_src" -name "libata.ko*" -exec cp {} "$mod_dst/kernel/drivers/ata/" \; 2>/dev/null || true
        find "$mod_src" -name "virtio*.ko*" -exec cp {} "$mod_dst/kernel/drivers/block/" \; 2>/dev/null || true
        find "$mod_src" -name "virtio_scsi.ko*" -exec cp {} "$mod_dst/kernel/drivers/scsi/" \; 2>/dev/null || true

        cp "$mod_src"/modules.* "$mod_dst/" 2>/dev/null || true

        if command -v depmod &>/dev/null; then
            depmod -a -b "$initrd" "$kernel_version" 2>/dev/null || true
        fi

        log_info "Copied kernel modules for version: $kernel_version"
    else
        log_warn "Kernel modules not found in rootfs"
    fi

    # Create init script (matching build_live_iso.sh style)
    cat > "$initrd/init" << 'INIT_EOF'
#!/bin/sh
# Rookery OS Live Boot Init Script
# Boots from ISO into KDE Plasma with Calamares installer

# Mount essential filesystems ONLY - let systemd handle the rest
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /dev/shm

# Mount run as tmpfs - this gets moved to newroot
mount -t tmpfs -o mode=755 tmpfs /run

# Enable kernel messages on console
echo 1 > /proc/sys/kernel/printk

echo ""
echo "=========================================="
echo "  Rookery OS 1.0 - Live Desktop"
echo "  Friendly Society of Corvids"
echo "=========================================="
echo ""

# Load required kernel modules
echo "Loading kernel modules..."
KERNEL_VERSION=$(uname -r)

modprobe scsi_mod 2>/dev/null || true
modprobe cdrom 2>/dev/null || true
modprobe sr_mod 2>/dev/null || true
modprobe libata 2>/dev/null || true
modprobe ata_piix 2>/dev/null || true
modprobe ata_generic 2>/dev/null || true
modprobe ahci 2>/dev/null || true
modprobe sd_mod 2>/dev/null || true

for mod in loop squashfs isofs iso9660 overlay; do
    modprobe $mod 2>/dev/null || true
done

for mod in virtio virtio_pci virtio_blk virtio_scsi; do
    modprobe $mod 2>/dev/null || true
done

# Wait for devices
echo "Waiting for devices..."
sleep 3

# Find the boot media
echo "Searching for boot media..."
ISO_DEV=""
MOUNT_POINT="/mnt/iso"
mkdir -p "$MOUNT_POINT"

for dev in /dev/sr0 /dev/sr1 /dev/cdrom /dev/dvd; do
    if [ -b "$dev" ]; then
        if mount -t iso9660 -o ro "$dev" "$MOUNT_POINT" 2>/dev/null; then
            if [ -f "$MOUNT_POINT/LiveOS/rootfs.img" ]; then
                ISO_DEV="$dev"
                echo "Found boot media at $dev"
                break
            fi
            umount "$MOUNT_POINT" 2>/dev/null
        fi
    fi
done

if [ -z "$ISO_DEV" ]; then
    for dev in /dev/sd* /dev/vd* /dev/nvme*; do
        [ -b "$dev" ] || continue
        if mount -t iso9660 -o ro "$dev" "$MOUNT_POINT" 2>/dev/null; then
            if [ -f "$MOUNT_POINT/LiveOS/rootfs.img" ]; then
                ISO_DEV="$dev"
                echo "Found boot media at $dev"
                break
            fi
            umount "$MOUNT_POINT" 2>/dev/null
        fi
    done
fi

if [ -z "$ISO_DEV" ]; then
    echo "ERROR: Could not find boot media"
    echo "Dropping to emergency shell..."
    exec /bin/sh
fi

# Mount squashfs
echo "Mounting squashfs root filesystem..."
mkdir -p /run/rootfsbase
if ! mount -t squashfs -o ro,loop "$MOUNT_POINT/LiveOS/rootfs.img" /run/rootfsbase; then
    echo "ERROR: Failed to mount squashfs"
    exec /bin/sh
fi

# Create overlay for writable live system
echo "Setting up overlay filesystem..."
mkdir -p /run/overlay/upper /run/overlay/work

mount -t tmpfs -o size=4G tmpfs /run/overlay

mkdir -p /run/overlay/upper /run/overlay/work

mkdir -p /newroot

if mount -t overlay overlay -o lowerdir=/run/rootfsbase,upperdir=/run/overlay/upper,workdir=/run/overlay/work /newroot; then
    echo "Overlay filesystem ready"
else
    echo "Overlay failed, trying bind mount..."
    if ! mount --bind /run/rootfsbase /newroot; then
        echo "ERROR: Could not mount root filesystem"
        exec /bin/sh
    fi
    echo "Read-only root mounted"
fi

# Verify the mount worked
if [ ! -d /newroot/usr ]; then
    echo "ERROR: /newroot/usr not found after mount!"
    echo "Contents of /newroot:"
    ls -la /newroot/
    echo "Contents of /run/rootfsbase:"
    ls -la /run/rootfsbase/
    exec /bin/sh
fi
echo "Root filesystem verified: /newroot/usr exists"

# Prepare for switch_root - create mount points if missing
mkdir -p /newroot/proc /newroot/sys /newroot/dev /newroot/run /newroot/tmp
mkdir -p /newroot/run/rootfsbase /newroot/run/initramfs

# Move mounts to new root
mount --move /proc /newroot/proc
mount --move /sys /newroot/sys
mount --move /dev /newroot/dev
mount --move /run /newroot/run

# Keep ISO mounted for Calamares to access
mount --move "$MOUNT_POINT" /newroot/run/rootfsbase 2>/dev/null || true

echo ""
echo "Switching to live desktop..."
echo ""

# Debug: verify init exists
echo "Checking for init..."
ls -la /newroot/usr/lib/systemd/systemd 2>/dev/null || echo "systemd not found"
ls -la /newroot/sbin/init 2>/dev/null || echo "/sbin/init not found"
ls -la /newroot/bin/sh 2>/dev/null || echo "/bin/sh not found"

# Switch to the real root
if [ -x /newroot/usr/lib/systemd/systemd ]; then
    echo "Using systemd as init"
    exec switch_root /newroot /usr/lib/systemd/systemd
elif [ -x /newroot/sbin/init ]; then
    echo "Using /sbin/init"
    exec switch_root /newroot /sbin/init
else
    echo "ERROR: No init found, dropping to shell"
    echo "Contents of /newroot/usr/lib/systemd/:"
    ls -la /newroot/usr/lib/systemd/ 2>/dev/null || echo "dir not found"
    exec switch_root /newroot /bin/sh
fi
INIT_EOF

    chmod +x "$initrd/init"

    # Create initramfs archive
    log_info "Creating initramfs archive..."
    (cd "$initrd" && find . -print0 | $CPIO_CMD --null -o -H newc 2>/dev/null | gzip -9 > "$BUILD/iso/boot/initrd.img")

    local size=$(du -h "$BUILD/iso/boot/initrd.img" | cut -f1)
    log_info "Created initramfs: $size"
}

# =============================================================================
# Step 6: Setup Boot Files
# =============================================================================
setup_boot() {
    log_step "Setting up boot files..."

    local rootfs="$BUILD/rootfs"

    # Copy kernel from rootfs (not from host system)
    if [ -f "$rootfs/boot/vmlinuz" ]; then
        cp "$rootfs/boot/vmlinuz" "$BUILD/iso/boot/"
        log_info "Copied kernel from rootfs"
    elif [ -f "$KERNEL" ]; then
        cp "$KERNEL" "$BUILD/iso/boot/vmlinuz"
        log_info "Copied kernel from $KERNEL"
    else
        log_error "No kernel found"
        exit 1
    fi

    # Create GRUB directory and config
    mkdir -p "$BUILD/iso/boot/grub"
    cat > "$BUILD/iso/boot/grub/grub.cfg" << 'EOF'
# GRUB configuration for Rookery OS 1.0 Live
# Serial console compatible (QEMU -nographic)

# Configure serial port (115200 baud, 8N1)
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1

# Use both serial and console terminals for compatibility
terminal_input serial console
terminal_output serial console

set default=0
set timeout=5
set timeout_style=menu

insmod all_video
insmod gfxterm

menuentry "Rookery OS 1.0 - Live Desktop" {
    linux /boot/vmlinuz rw init=/usr/lib/systemd/systemd net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8 systemd.log_level=debug
    initrd /boot/initrd.img
}

menuentry "Rookery OS 1.0 - Live Desktop (Verbose)" {
    linux /boot/vmlinuz ro init=/usr/lib/systemd/systemd net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8 systemd.log_level=debug systemd.log_target=console loglevel=7
    initrd /boot/initrd.img
}

menuentry "Rookery OS 1.0 - Live Desktop (Safe Graphics)" {
    linux /boot/vmlinuz ro init=/usr/lib/systemd/systemd net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8 nomodeset
    initrd /boot/initrd.img
}

menuentry "Rookery OS 1.0 - Recovery" {
    linux /boot/vmlinuz rw init=/usr/lib/systemd/systemd systemd.unit=rescue.target net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8
    initrd /boot/initrd.img
}

menuentry "Rookery OS 1.0 - Emergency Shell" {
    linux /boot/vmlinuz rw init=/usr/lib/systemd/systemd systemd.unit=emergency.target net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8
    initrd /boot/initrd.img
}
EOF

    # Copy syslinux files
    for file in isolinux.bin ldlinux.c32 menu.c32 libutil.c32 libcom32.c32; do
        if [ -f "$SYSLINUX_DIR/$file" ]; then
            cp "$SYSLINUX_DIR/$file" "$BUILD/iso/boot/syslinux/"
        fi
    done
    log_info "Copied syslinux files"

    # Create syslinux config (matching build_live_iso.sh)
    cat > "$BUILD/iso/boot/syslinux/syslinux.cfg" << 'EOF'
SERIAL 0 115200
DEFAULT linux
TIMEOUT 50
PROMPT 1

MENU TITLE Rookery OS 1.0 Live

LABEL linux
    MENU LABEL Rookery OS - Live Desktop
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img rw init=/usr/lib/systemd/systemd net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8 systemd.log_level=debug

LABEL verbose
    MENU LABEL Rookery OS - Verbose Boot
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img ro init=/usr/lib/systemd/systemd net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8 systemd.log_level=debug systemd.log_target=console loglevel=7

LABEL safe
    MENU LABEL Rookery OS - Safe Graphics
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img ro init=/usr/lib/systemd/systemd net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8 nomodeset

LABEL recovery
    MENU LABEL Rookery OS - Recovery
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img rw init=/usr/lib/systemd/systemd systemd.unit=rescue.target net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8

LABEL emergency
    MENU LABEL Rookery OS - Emergency Shell
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img rw init=/usr/lib/systemd/systemd systemd.unit=emergency.target net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8
EOF

    log_info "Created boot configuration"
}

# =============================================================================
# Step 7: Create EFI Boot Image
# =============================================================================
create_efi_boot_image() {
    log_step "Creating EFI boot image..."

    local efi_dir="$BUILD/iso/EFI/BOOT"
    local efi_img="$BUILD/iso/boot/efi.img"

    mkdir -p "$efi_dir"
    mkdir -p "$BUILD/iso/boot/grub"

    # Check if GRUB EFI modules are available
    if [ ! -d "/usr/lib/grub/x86_64-efi" ]; then
        log_warn "GRUB x86_64-efi modules not found, skipping EFI boot support"
        return 1
    fi

    # Create grub.cfg for EFI boot
    # Using console terminal instead of gfxterm to avoid font issues
    cat > "$BUILD/iso/boot/grub/grub.cfg" << 'GRUBCFG'
# Search for the ISO filesystem by label
search --no-floppy --set=root --label ROOKERY_LIVE

set default=0
set timeout=5

# Use text console - no fonts required
terminal_output console
terminal_input console

menuentry "Rookery OS Live" {
    linux /boot/vmlinuz rw init=/usr/lib/systemd/systemd net.ifnames=0 biosdevname=0 console=tty0
    initrd /boot/initrd.img
}

menuentry "Rookery OS Live (Verbose)" {
    linux /boot/vmlinuz rw init=/usr/lib/systemd/systemd systemd.log_level=debug systemd.log_target=console net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8
    initrd /boot/initrd.img
}

menuentry "Rookery OS - Recovery" {
    linux /boot/vmlinuz rw init=/usr/lib/systemd/systemd systemd.unit=rescue.target net.ifnames=0 biosdevname=0 console=tty0
    initrd /boot/initrd.img
}
GRUBCFG

    # Create GRUB EFI binary (following Arch Linux archiso approach)
    # Full module list from archiso for maximum compatibility
    log_info "Building GRUB EFI bootloader..."
    grub-mkstandalone \
        -O x86_64-efi \
        -o "$efi_dir/BOOTX64.EFI" \
        --locales="en@quot" \
        --themes="" \
        --modules="all_video at_keyboard boot btrfs cat chain configfile echo efifwsetup efinet ext2 fat font gfxmenu gfxterm gzio halt hfsplus iso9660 jpeg keylayouts linux loadenv loopback lsefi lsefimmap minicmd normal ntfs part_apple part_gpt part_msdos png read reboot regexp search search_fs_file search_fs_uuid search_label serial sleep usb usbserial_common video xfs zstd" \
        "boot/grub/grub.cfg=$BUILD/iso/boot/grub/grub.cfg"

    # Create FAT EFI image using mtools
    log_info "Creating EFI FAT image..."
    local efi_file_size=$(stat -c %s "$efi_dir/BOOTX64.EFI")
    local efi_img_size=$(( (efi_file_size / 1024) + 512 ))  # File size + overhead in KB
    dd if=/dev/zero of="$efi_img" bs=1024 count=$efi_img_size 2>/dev/null
    mformat -i "$efi_img" ::
    mmd -i "$efi_img" ::EFI
    mmd -i "$efi_img" ::EFI/BOOT
    mcopy -i "$efi_img" "$efi_dir/BOOTX64.EFI" ::EFI/BOOT/

    log_info "EFI boot image created successfully"
    return 0
}

# =============================================================================
# Step 8: Create ISO
# =============================================================================
create_iso() {
    log_step "Creating ISO image..."

    local iso_path="$OUTPUT_DIR/$ISO_NAME"
    local efi_img="$BUILD/iso/boot/efi.img"

    # Check if EFI boot image exists
    if [ -f "$efi_img" ]; then
        log_info "Creating hybrid BIOS/EFI bootable ISO..."
        xorriso -as mkisofs \
            -o "$iso_path" \
            -isohybrid-mbr "$SYSLINUX_DIR/isohdpfx.bin" \
            -c boot/syslinux/boot.cat \
            -b boot/syslinux/isolinux.bin \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -eltorito-alt-boot \
            -e boot/efi.img \
            -no-emul-boot \
            -isohybrid-gpt-basdat \
            -V "$VOLUME_ID" \
            "$BUILD/iso/"
    else
        log_info "Creating BIOS-only bootable ISO..."
        xorriso -as mkisofs \
            -o "$iso_path" \
            -isohybrid-mbr "$SYSLINUX_DIR/isohdpfx.bin" \
            -c boot/syslinux/boot.cat \
            -b boot/syslinux/isolinux.bin \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -V "$VOLUME_ID" \
            "$BUILD/iso/"
    fi

    if [ -f "$iso_path" ]; then
        local size=$(du -h "$iso_path" | cut -f1)
        echo ""
        log_info "=========================================="
        log_info "ISO CREATED SUCCESSFULLY"
        log_info "=========================================="
        log_info "File: $iso_path"
        log_info "Size: $size"
        echo ""
        log_info "To test with QEMU (BIOS):"
        log_info "  qemu-system-x86_64 -m 4G -cdrom $iso_path -boot d"
        echo ""
        if [ -f "$efi_img" ]; then
            log_info "To test with QEMU (EFI):"
            log_info "  qemu-system-x86_64 -m 4G -cdrom $iso_path -boot d -bios /usr/share/edk2/ovmf/OVMF_CODE.fd"
            echo ""
        fi
    else
        log_error "ISO creation failed"
        exit 1
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    log_info "=========================================="
    log_info "Rookery OS Live ISO Builder"
    log_info "=========================================="
    echo ""

    cleanup_old_builds
    setup_build_env
    install_packages
    fix_lib_symlinks
    configure_live_system
    set_pax_flags
    rebuild_library_cache
    create_installed_initramfs
    create_squashfs
    build_initramfs
    setup_boot
    create_efi_boot_image || log_warn "EFI boot support not available"
    create_iso

    # Don't cleanup on success - let user inspect if needed
    trap - EXIT
    log_info "Build directory retained at: $BUILD"
}

main "$@"
