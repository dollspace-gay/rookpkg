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

    # Strip debug symbols first to reduce size
    log_info "Stripping debug symbols..."
    find "$ROOKERY/usr/bin" "$ROOKERY/usr/sbin" "$ROOKERY/usr/libexec" -type f -executable 2>/dev/null | \
        xargs -r strip --strip-unneeded 2>/dev/null || true
    find "$ROOKERY/usr/lib" "$ROOKERY/lib" -name "*.so*" -type f 2>/dev/null | \
        xargs -r strip --strip-unneeded 2>/dev/null || true
    find "$ROOKERY/opt" -type f -executable 2>/dev/null | \
        xargs -r strip --strip-unneeded 2>/dev/null || true

    mksquashfs "$ROOKERY" "$iso_root/LiveOS/rootfs.img" \
        -e "dev/*" \
        -e "proc/*" \
        -e "sys/*" \
        -e "run/*" \
        -e "tmp/*" \
        -e "sources/*" \
        -e "build/*" \
        -e "tools/*" \
        -e ".checkpoints" \
        -e "*.log" \
        -comp zstd \
        -Xcompression-level 19 \
        -b 1M \
        -no-recovery

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

    # Create /bin/sh symlink
    if [ ! -e "$initramfs_dir/bin/sh" ]; then
        if [ -f "$initramfs_dir/usr/bin/bash" ]; then
            ln -sf ../usr/bin/bash "$initramfs_dir/bin/sh"
        elif [ -f "$initramfs_dir/bin/bash" ]; then
            ln -sf bash "$initramfs_dir/bin/sh"
        fi
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

    # Copy all .so files
    log_info "Copying shared library files..."
    for search_dir in "$ROOKERY/lib64" "$ROOKERY/lib" "$ROOKERY/usr/lib"; do
        if [ -d "$search_dir" ]; then
            find "$search_dir" -maxdepth 1 -name "*.so*" -type f -exec cp -n {} "$initramfs_dir/lib64/" \; 2>/dev/null || true
            find "$search_dir" -maxdepth 1 -name "*.so*" -type l -exec sh -c 'real=$(readlink -f "$1"); [ -f "$real" ] && cp -n "$real" "$2/lib64/"' _ {} "$initramfs_dir" \; 2>/dev/null || true
        fi
    done

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

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /dev/shm
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /tmp

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

if mount -t overlay overlay -o lowerdir=/run/rootfsbase,upperdir=/run/overlay/upper,workdir=/run/overlay/work /newroot 2>/dev/null; then
    echo "Overlay filesystem ready"
else
    echo "Overlay not available, using read-only root"
    mount --bind /run/rootfsbase /newroot
fi

# Prepare for switch_root
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

# Switch to the real root
if [ -x /newroot/usr/lib/systemd/systemd ]; then
    exec switch_root /newroot /usr/lib/systemd/systemd
elif [ -x /newroot/sbin/init ]; then
    exec switch_root /newroot /sbin/init
else
    echo "ERROR: No init found"
    exec switch_root /newroot /bin/sh
fi
INITEOF

    chmod +x "$initramfs_dir/init"

    # =========================================================================
    # Step 6: Create initramfs cpio archive
    # =========================================================================
    log_step "Creating initramfs archive..."

    (cd "$initramfs_dir" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$iso_boot/initrd.img")

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

    # GRUB config
    cat > "$iso_boot/grub/grub.cfg" << 'EOF'
set default=0
set timeout=10

insmod all_video
insmod gfxterm

menuentry "Rookery OS 1.0 - Live Desktop" {
    linux /boot/vmlinuz quiet splash
    initrd /boot/initrd.img
}

menuentry "Rookery OS 1.0 - Live Desktop (Safe Graphics)" {
    linux /boot/vmlinuz nomodeset
    initrd /boot/initrd.img
}

menuentry "Rookery OS 1.0 - Live Desktop (Verbose)" {
    linux /boot/vmlinuz loglevel=7 systemd.log_level=debug
    initrd /boot/initrd.img
}
EOF

    # ISOLINUX config
    mkdir -p "$iso_root/boot/syslinux"

    if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
        cp /usr/lib/ISOLINUX/isolinux.bin "$iso_root/boot/syslinux/"
    elif [ -f "$ROOKERY/usr/lib/ISOLINUX/isolinux.bin" ]; then
        cp "$ROOKERY/usr/lib/ISOLINUX/isolinux.bin" "$iso_root/boot/syslinux/"
    else
        log_warn "ISOLINUX not found - using GRUB only"
    fi

    local syslinux_mods="/usr/lib/syslinux/modules/bios"
    [ -d "$ROOKERY/usr/lib/syslinux/modules/bios" ] && syslinux_mods="$ROOKERY/usr/lib/syslinux/modules/bios"
    for mod in ldlinux.c32 menu.c32 libutil.c32 libcom32.c32; do
        if [ -f "$syslinux_mods/$mod" ]; then
            cp "$syslinux_mods/$mod" "$iso_root/boot/syslinux/"
        fi
    done

    cat > "$iso_root/boot/syslinux/syslinux.cfg" << 'SYSLINUX_CFG'
DEFAULT linux
TIMEOUT 50
PROMPT 1

MENU TITLE Rookery OS 1.0 Live

LABEL linux
    MENU LABEL Rookery OS - Live Desktop
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img quiet splash

LABEL safe
    MENU LABEL Rookery OS - Safe Graphics
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img nomodeset

LABEL verbose
    MENU LABEL Rookery OS - Verbose Boot
    KERNEL /boot/vmlinuz
    APPEND initrd=/boot/initrd.img loglevel=7
SYSLINUX_CFG

    # =========================================================================
    # Step 8: Build the ISO
    # =========================================================================
    log_step "Building ISO image..."

    xorriso -as mkisofs \
        -o "$iso_file" \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin 2>/dev/null || true \
        -c boot/syslinux/boot.cat \
        -b boot/syslinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        -V "ROOKERY_LIVE" \
        "$iso_root" 2>/dev/null || \
    xorriso -as mkisofs \
        -o "$iso_file" \
        -c boot/syslinux/boot.cat \
        -b boot/syslinux/isolinux.bin \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -V "ROOKERY_LIVE" \
        "$iso_root"

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
