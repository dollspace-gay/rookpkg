#!/bin/bash
set -euo pipefail

# =============================================================================
# Rookery OS Live ISO Build Script
# Creates a bootable live ISO with Calamares installer
# Based on the Fedora-style live boot approach
# =============================================================================

export ROOKERY="${ROOKERY:-/rookery}"
export IMAGE_NAME="${IMAGE_NAME:-rookery-os-live-1.0}"
export DIST_DIR="${DIST_DIR:-/dist}"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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

# Create the live ISO
create_live_iso() {
    log_info "=========================================="
    log_info "Creating Rookery OS Live ISO with Calamares"
    log_info "=========================================="

    local iso_file="$DIST_DIR/${IMAGE_NAME}.iso"
    local iso_root="/tmp/iso-root"
    local iso_boot="$iso_root/boot"

    # Check for required tools
    for tool in xorriso mksquashfs; do
        if ! command -v $tool &>/dev/null; then
            log_error "$tool not found - cannot create ISO"
            return 1
        fi
    done

    # Clean up any previous build
    rm -rf "$iso_root"
    mkdir -p "$iso_boot/grub"
    mkdir -p "$iso_root/LiveOS"

    # =========================================================================
    # Step 1: Copy kernel to ISO
    # =========================================================================
    log_step "Setting up ISO boot files..."

    if [ -f "$ROOKERY/boot/vmlinuz" ]; then
        cp "$ROOKERY/boot/vmlinuz" "$iso_boot/"
        log_info "Copied kernel to ISO"
    else
        log_error "No kernel found at $ROOKERY/boot/vmlinuz"
        return 1
    fi

    # =========================================================================
    # Step 2: Create squashfs root filesystem for live boot
    # =========================================================================
    log_step "Creating squashfs root filesystem..."

    # SAFETY CHECK: Never operate on the root filesystem directly
    if [ "$ROOKERY" = "/" ] || [ "$ROOKERY" = "" ]; then
        log_error "SAFETY: ROOKERY cannot be '/' or empty!"
        log_error "Set ROOKERY to an isolated directory containing the target system."
        log_error "Example: ROOKERY=/tmp/rootfs ./build_live_iso.sh"
        return 1
    fi

    # Create a temporary copy for stripping (never modify source)
    # Use /var/tmp to avoid tmpfs space issues
    local strip_root="/var/tmp/iso-rootfs-$$"
    log_info "Creating temporary copy for stripping..."
    rm -rf "$strip_root"

    # Use rsync if available for efficiency, otherwise cp
    if command -v rsync &>/dev/null; then
        rsync -a --exclude='dev/*' --exclude='proc/*' --exclude='sys/*' \
              --exclude='run/*' --exclude='tmp/*' --exclude='sources/*' \
              --exclude='build/*' --exclude='tools/*' --exclude='.checkpoints' \
              --exclude='*.log' "$ROOKERY/" "$strip_root/"
    else
        cp -a "$ROOKERY" "$strip_root"
        rm -rf "$strip_root"/{dev,proc,sys,run,tmp,sources,build,tools}/* 2>/dev/null || true
    fi

    # Strip debug symbols on the COPY only (never the source)
    log_info "Stripping debug symbols from temporary copy..."
    find "$strip_root/usr/bin" "$strip_root/usr/sbin" "$strip_root/usr/libexec" -type f -executable 2>/dev/null | \
        xargs -r strip --strip-unneeded 2>/dev/null || true
    find "$strip_root/usr/lib" "$strip_root/lib" -name "*.so*" -type f 2>/dev/null | \
        xargs -r strip --strip-unneeded 2>/dev/null || true
    find "$strip_root/opt" -type f -executable 2>/dev/null | \
        xargs -r strip --strip-unneeded 2>/dev/null || true

    # =========================================================================
    # Create essential live system configuration
    # =========================================================================
    log_info "Configuring live system..."

    # Ensure /tmp exists with proper permissions (for when tmp.mount is masked)
    mkdir -p "$strip_root/tmp"
    chmod 1777 "$strip_root/tmp"

    # Mask problematic mount units that fail on overlay/grsec
    # These are not essential for a live system
    mkdir -p "$strip_root/etc/systemd/system"
    ln -sf /dev/null "$strip_root/etc/systemd/system/dev-hugepages.mount"
    ln -sf /dev/null "$strip_root/etc/systemd/system/dev-mqueue.mount"
    ln -sf /dev/null "$strip_root/etc/systemd/system/tmp.mount"

    # Also mask the corresponding services that might fail
    ln -sf /dev/null "$strip_root/etc/systemd/system/systemd-timesyncd.service"
    ln -sf /dev/null "$strip_root/etc/systemd/system/systemd-resolved.service"

    # Create required runtime directories for dbus and other services
    mkdir -p "$strip_root/run/dbus"
    mkdir -p "$strip_root/var/run"
    ln -sf ../run "$strip_root/var/run" 2>/dev/null || true

    # Create essential system users if passwd doesn't exist or is incomplete
    if ! grep -q "messagebus" "$strip_root/etc/passwd" 2>/dev/null; then
        log_info "Creating essential system users..."
        cat > "$strip_root/etc/passwd" << 'PASSWD_EOF'
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/sbin/nologin
daemon:x:2:2:daemon:/dev/null:/usr/sbin/nologin
nobody:x:65534:65534:Kernel Overflow User:/:/usr/sbin/nologin
messagebus:x:18:18:D-Bus Message Daemon:/run/dbus:/usr/sbin/nologin
systemd-journal:x:990:990:systemd Journal:/:/usr/sbin/nologin
systemd-network:x:991:991:systemd Network Management:/:/usr/sbin/nologin
systemd-resolve:x:992:992:systemd Resolver:/:/usr/sbin/nologin
systemd-timesync:x:993:993:systemd Time Synchronization:/:/usr/sbin/nologin
systemd-coredump:x:994:994:systemd Core Dumper:/:/usr/sbin/nologin
polkitd:x:27:27:PolicyKit Daemon:/var/lib/polkit-1:/usr/sbin/nologin
avahi:x:84:84:Avahi Daemon:/:/usr/sbin/nologin
sddm:x:995:995:SDDM Display Manager:/var/lib/sddm:/usr/sbin/nologin
live:x:1000:1000:Live User:/home/live:/bin/bash
PASSWD_EOF

        cat > "$strip_root/etc/group" << 'GROUP_EOF'
root:x:0:
bin:x:1:
daemon:x:2:
sys:x:3:
adm:x:4:live
tty:x:5:
disk:x:6:
lp:x:7:
mem:x:8:
kmem:x:9:
wheel:x:10:live
cdrom:x:11:live
dialout:x:18:live
floppy:x:19:
video:x:22:live
audio:x:25:live
users:x:100:live
nobody:x:65534:
messagebus:x:18:
systemd-journal:x:990:
systemd-network:x:991:
systemd-resolve:x:992:
systemd-timesync:x:993:
systemd-coredump:x:994:
input:x:996:
kvm:x:997:live
render:x:998:live
polkitd:x:27:
avahi:x:84:
sddm:x:995:
plugdev:x:46:live
netdev:x:47:live
live:x:1000:
GROUP_EOF

        # Create shadow with empty password for live user
        cat > "$strip_root/etc/shadow" << 'SHADOW_EOF'
root:!:19722:0:99999:7:::
messagebus:!:19722:0:99999:7:::
polkitd:!:19722:0:99999:7:::
avahi:!:19722:0:99999:7:::
sddm:!:19722:0:99999:7:::
live::19722:0:99999:7:::
SHADOW_EOF
        chmod 640 "$strip_root/etc/shadow"
    fi

    # Create home directory for live user
    mkdir -p "$strip_root/home/live"
    chown 1000:1000 "$strip_root/home/live"

    # Configure SDDM for live boot with autologin and no virtual keyboard
    mkdir -p "$strip_root/etc/sddm.conf.d"
    cat > "$strip_root/etc/sddm.conf.d/live.conf" << 'SDDM_CONF_EOF'
[General]
# Disable virtual keyboard for live session
InputMethod=

[Autologin]
# Auto-login to live user
User=live
# Use X11 session (more compatible with VMs)
Session=plasmax11
Relogin=false

[Theme]
# Use maldives theme (simpler, fewer dependencies)
Current=maldives

[Users]
# Hide system users
HideUsers=root,sddm,messagebus,polkitd,avahi
HideShells=/usr/sbin/nologin,/sbin/nologin
MinimumUid=1000
MaximumUid=60000
SDDM_CONF_EOF

    # Also create main sddm.conf as fallback
    cat > "$strip_root/etc/sddm.conf" << 'SDDM_MAIN_EOF'
[General]
InputMethod=

[Autologin]
User=live
Session=plasmax11
Relogin=false

[Theme]
Current=maldives
SDDM_MAIN_EOF

    # Create autologin group and add live user to it
    if ! grep -q "^autologin:" "$strip_root/etc/group" 2>/dev/null; then
        echo "autologin:x:1001:live" >> "$strip_root/etc/group"
    fi

    # Create a one-shot service to restart SDDM after boot
    # This is a known workaround for timing issues with autologin on live CDs
    cat > "$strip_root/etc/systemd/system/sddm-autologin-fix.service" << 'SDDM_FIX_EOF'
[Unit]
Description=SDDM Autologin Fix for Live Boot
After=sddm.service graphical.target
Requires=sddm.service

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/systemctl restart sddm.service
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
SDDM_FIX_EOF

    # Enable the fix service
    mkdir -p "$strip_root/etc/systemd/system/graphical.target.wants"
    ln -sf ../sddm-autologin-fix.service "$strip_root/etc/systemd/system/graphical.target.wants/sddm-autologin-fix.service"

    log_info "Configured SDDM with autologin for live user"
    log_info "Masked problematic systemd units for live boot"

    mksquashfs "$strip_root" "$iso_root/LiveOS/rootfs.img" \
        -e "dev/*" \
        -e "proc/*" \
        -e "sys/*" \
        -e "run/*" \
        -e "tmp/*" \
        -comp zstd \
        -Xcompression-level 19 \
        -b 1M \
        -no-recovery

    # Clean up the temporary copy
    rm -rf "$strip_root"

    if [ ! -f "$iso_root/LiveOS/rootfs.img" ]; then
        log_error "Failed to create squashfs filesystem"
        return 1
    fi

    local squashfs_size=$(du -h "$iso_root/LiveOS/rootfs.img" | cut -f1)
    log_info "Created squashfs root filesystem: $squashfs_size"

    # =========================================================================
    # Step 3: Create initramfs with overlayfs support
    # =========================================================================
    log_step "Creating initramfs with overlayfs support..."
    local initramfs_dir="/tmp/initramfs-live"
    rm -rf "$initramfs_dir"

    # Create directory structure
    mkdir -p "$initramfs_dir"/{bin,sbin,etc,proc,sys,dev,run,tmp,newroot,mnt}
    mkdir -p "$initramfs_dir"/lib64/modules
    mkdir -p "$initramfs_dir"/usr/{bin,sbin,lib,lib64}
    mkdir -p "$initramfs_dir"/run/rootfsbase
    ln -sf lib64 "$initramfs_dir/lib"
    rm -rf "$initramfs_dir/usr/lib"
    ln -sf ../lib64 "$initramfs_dir/usr/lib"

    # Copy the dynamic linker
    log_info "Copying dynamic linker..."
    local real_ld=""
    if [ -e "$ROOKERY/lib64/ld-linux-x86-64.so.2" ]; then
        real_ld=$(readlink -f "$ROOKERY/lib64/ld-linux-x86-64.so.2")
    elif [ -e "$ROOKERY/lib/ld-linux-x86-64.so.2" ]; then
        real_ld=$(readlink -f "$ROOKERY/lib/ld-linux-x86-64.so.2")
    elif [ -e "$ROOKERY/usr/lib/ld-linux-x86-64.so.2" ]; then
        real_ld=$(readlink -f "$ROOKERY/usr/lib/ld-linux-x86-64.so.2")
    fi
    if [ -n "$real_ld" ] && [ -f "$real_ld" ]; then
        cp "$real_ld" "$initramfs_dir/lib64/ld-linux-x86-64.so.2"
    else
        log_error "Dynamic linker not found!"
        return 1
    fi

    # Copy core glibc libraries
    log_info "Copying glibc libraries..."
    for lib in libc.so.6 libm.so.6 libresolv.so.2 libnss_files.so.2 libpthread.so.0 libdl.so.2 librt.so.1; do
        for search_dir in "$ROOKERY/lib64" "$ROOKERY/lib" "$ROOKERY/usr/lib"; do
            if [ -e "$search_dir/$lib" ]; then
                local real_lib=$(readlink -f "$search_dir/$lib")
                if [ -f "$real_lib" ]; then
                    cp "$real_lib" "$initramfs_dir/lib64/$lib" 2>/dev/null || true
                fi
                break
            fi
        done
    done

    # Copy essential binaries
    log_info "Copying essential binaries..."

    # Shell
    for shell_bin in bash sh; do
        for path in "$ROOKERY/usr/bin/$shell_bin" "$ROOKERY/bin/$shell_bin"; do
            if [ -f "$path" ] && [ ! -L "$path" ]; then
                copy_binary_with_libs "$path" "$initramfs_dir" "$ROOKERY"
                break
            elif [ -L "$path" ]; then
                local target=$(readlink -f "$path")
                if [ -f "$target" ]; then
                    copy_binary_with_libs "$target" "$initramfs_dir" "$ROOKERY"
                fi
                local rel_path="${path#$ROOKERY}"
                mkdir -p "$initramfs_dir$(dirname "$rel_path")"
                cp -a "$path" "$initramfs_dir$rel_path" 2>/dev/null || true
                break
            fi
        done
    done

    # Create /bin/sh symlink - always recreate to ensure relative path
    rm -f "$initramfs_dir/bin/sh"
    if [ -f "$initramfs_dir/usr/bin/bash" ]; then
        ln -sf ../usr/bin/bash "$initramfs_dir/bin/sh"
    elif [ -f "$initramfs_dir/bin/bash" ]; then
        ln -sf bash "$initramfs_dir/bin/sh"
    fi

    # Core utilities
    COREUTILS_BINS="cat ls mkdir mknod mount umount sleep echo ln cp mv rm chmod chown chroot stat head tail uname"
    for bin in $COREUTILS_BINS; do
        for path in "$ROOKERY/usr/bin/$bin" "$ROOKERY/bin/$bin"; do
            if [ -f "$path" ]; then
                copy_binary_with_libs "$path" "$initramfs_dir" "$ROOKERY"
                break
            fi
        done
    done

    # Util-linux binaries
    UTILLINUX_BINS="switch_root mount umount losetup blkid findmnt dmesg"
    for bin in $UTILLINUX_BINS; do
        for path in "$ROOKERY/usr/sbin/$bin" "$ROOKERY/usr/bin/$bin" "$ROOKERY/sbin/$bin" "$ROOKERY/bin/$bin"; do
            if [ -f "$path" ]; then
                copy_binary_with_libs "$path" "$initramfs_dir" "$ROOKERY"
                break
            fi
        done
    done

    # Kmod utilities
    KMOD_BINS="modprobe insmod lsmod depmod"
    for bin in $KMOD_BINS; do
        for path in "$ROOKERY/usr/sbin/$bin" "$ROOKERY/sbin/$bin" "$ROOKERY/usr/bin/$bin"; do
            if [ -f "$path" ]; then
                copy_binary_with_libs "$path" "$initramfs_dir" "$ROOKERY"
                break
            elif [ -L "$path" ]; then
                local target=$(readlink -f "$path")
                if [ -f "$target" ]; then
                    copy_binary_with_libs "$target" "$initramfs_dir" "$ROOKERY"
                fi
                local rel_path="${path#$ROOKERY}"
                mkdir -p "$initramfs_dir$(dirname "$rel_path")"
                cp -a "$path" "$initramfs_dir$rel_path" 2>/dev/null || true
                break
            fi
        done
    done

    # Additional libraries
    log_info "Copying additional libraries..."
    for lib in libblkid.so.1 libmount.so.1 libuuid.so.1 libreadline.so.8 libncursesw.so.6 \
               libtinfo.so.6 libz.so.1 liblzma.so.5 libzstd.so.1 libkmod.so.2 libcrypto.so.3; do
        for search_dir in "$ROOKERY/lib64" "$ROOKERY/lib" "$ROOKERY/usr/lib64" "$ROOKERY/usr/lib"; do
            if [ -e "$search_dir/$lib" ]; then
                local real_lib=$(readlink -f "$search_dir/$lib")
                if [ -f "$real_lib" ]; then
                    cp "$real_lib" "$initramfs_dir/lib64/$lib" 2>/dev/null || true
                fi
                break
            fi
        done
    done

    # DO NOT copy all .so files - that makes the initrd huge (500MB+)
    # Only copy the specific libraries needed for the binaries we've already added
    # The copy_binary_with_libs function handles library dependencies automatically

    # =========================================================================
    # Step 4: Copy kernel modules
    # =========================================================================
    log_step "Copying kernel modules..."

    local kernel_version=""
    if [ -d "$ROOKERY/lib/modules" ]; then
        kernel_version=$(ls -1 "$ROOKERY/lib/modules" | head -1)
    fi

    if [ -n "$kernel_version" ] && [ -d "$ROOKERY/lib/modules/$kernel_version" ]; then
        local mod_src="$ROOKERY/lib/modules/$kernel_version"
        local mod_dst="$initramfs_dir/lib/modules/$kernel_version"
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
            depmod -a -b "$initramfs_dir" "$kernel_version" 2>/dev/null || true
        fi

        log_info "Copied kernel modules for version: $kernel_version"
    else
        log_warn "Kernel modules not found"
    fi

    # =========================================================================
    # Step 5: Create the init script for live boot with Calamares
    # =========================================================================
    log_step "Creating init script..."

    cat > "$initramfs_dir/init" << 'INITEOF'
#!/bin/sh
# Rookery OS Live Boot Init Script
# Boots from ISO into KDE Plasma with Calamares installer

# Mount essential filesystems ONLY - let systemd handle the rest
# Critical: Do NOT mount /tmp here - systemd's tmp.mount unit handles it
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
INITEOF

    chmod +x "$initramfs_dir/init"

    # =========================================================================
    # Step 6: Create initramfs cpio archive
    # =========================================================================
    log_step "Creating initramfs archive..."

    # Use bsdcpio if available (from libarchive), otherwise try cpio
    if command -v bsdcpio &>/dev/null; then
        (cd "$initramfs_dir" && find . -print0 | bsdcpio --null -o -H newc 2>/dev/null | gzip -9 > "$iso_boot/initrd.img")
    elif command -v cpio &>/dev/null; then
        (cd "$initramfs_dir" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$iso_boot/initrd.img")
    else
        log_error "Neither bsdcpio nor cpio found - cannot create initramfs"
        return 1
    fi

    if [ ! -f "$iso_boot/initrd.img" ]; then
        log_error "Failed to create initramfs"
        return 1
    fi

    local initrd_size=$(du -h "$iso_boot/initrd.img" | cut -f1)
    log_info "Created initramfs: $initrd_size"

    # =========================================================================
    # Step 7: Create GRUB/ISOLINUX configuration
    # =========================================================================
    log_step "Creating boot configuration..."

    # GRUB config - serial console enabled for debugging
    cat > "$iso_boot/grub/grub.cfg" << 'EOF'
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

    # ISOLINUX config
    mkdir -p "$iso_root/boot/syslinux"

    # Find isolinux.bin in various locations
    local isolinux_bin=""
    for path in "/usr/lib/syslinux/bios/isolinux.bin" \
                "/usr/share/syslinux/isolinux.bin" \
                "/usr/lib/ISOLINUX/isolinux.bin" \
                "$ROOKERY/usr/lib/syslinux/bios/isolinux.bin" \
                "$ROOKERY/usr/share/syslinux/isolinux.bin"; do
        if [ -f "$path" ]; then
            isolinux_bin="$path"
            break
        fi
    done

    if [ -n "$isolinux_bin" ]; then
        cp "$isolinux_bin" "$iso_root/boot/syslinux/"
        log_info "Using ISOLINUX from: $isolinux_bin"
    else
        log_warn "ISOLINUX not found - using GRUB only"
    fi

    # Find syslinux modules
    local syslinux_mods=""
    for path in "/usr/lib/syslinux/bios" \
                "/usr/share/syslinux" \
                "/usr/lib/syslinux/modules/bios" \
                "$ROOKERY/usr/lib/syslinux/bios" \
                "$ROOKERY/usr/share/syslinux"; do
        if [ -d "$path" ]; then
            syslinux_mods="$path"
            break
        fi
    done

    if [ -n "$syslinux_mods" ]; then
        for mod in ldlinux.c32 menu.c32 libutil.c32 libcom32.c32; do
            if [ -f "$syslinux_mods/$mod" ]; then
                cp "$syslinux_mods/$mod" "$iso_root/boot/syslinux/"
            fi
        done
    fi

    cat > "$iso_root/boot/syslinux/syslinux.cfg" << 'SYSLINUX_CFG'
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
SYSLINUX_CFG

    # =========================================================================
    # Step 8: Build the ISO
    # =========================================================================
    log_step "Building ISO image..."

    # Find isohdpfx.bin for hybrid ISO
    local isohdpfx=""
    for path in "/usr/lib/syslinux/bios/isohdpfx.bin" \
                "/usr/share/syslinux/isohdpfx.bin" \
                "/usr/lib/ISOLINUX/isohdpfx.bin" \
                "$ROOKERY/usr/lib/syslinux/bios/isohdpfx.bin" \
                "$ROOKERY/usr/share/syslinux/isohdpfx.bin"; do
        if [ -f "$path" ]; then
            isohdpfx="$path"
            break
        fi
    done

    if [ -n "$isohdpfx" ] && [ -f "$iso_root/boot/syslinux/isolinux.bin" ]; then
        log_info "Creating hybrid ISO with BIOS boot support..."
        xorriso -as mkisofs \
            -o "$iso_file" \
            -isohybrid-mbr "$isohdpfx" \
            -c boot/syslinux/boot.cat \
            -b boot/syslinux/isolinux.bin \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -V "ROOKERY_LIVE" \
            "$iso_root"
    else
        log_info "Creating basic ISO..."
        xorriso -as mkisofs \
            -o "$iso_file" \
            -V "ROOKERY_LIVE" \
            "$iso_root"
    fi

    # Cleanup
    rm -rf "$initramfs_dir"

    if [ -f "$iso_file" ]; then
        local iso_size=$(du -h "$iso_file" | cut -f1)
        log_info ""
        log_info "=========================================="
        log_info "LIVE ISO CREATED SUCCESSFULLY"
        log_info "=========================================="
        log_info "File: $iso_file"
        log_info "Size: $iso_size"
        log_info ""
        log_info "To test with QEMU:"
        log_info "  qemu-system-x86_64 -m 4G -cdrom $iso_file -boot d"
        log_info ""
        log_info "The live system will boot into KDE Plasma."
        log_info "Run 'calamares' to install Rookery OS to disk."
        log_info ""
    else
        log_error "ISO creation failed"
        return 1
    fi
}

# Run
mkdir -p "$DIST_DIR"
create_live_iso
