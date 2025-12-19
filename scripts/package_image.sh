#!/bin/bash
set -euo pipefail

# =============================================================================
# Rookery OS Package Image Script
# Creates bootable disk image and ISO (systemd + grsecurity)
# A custom Linux distribution for the Friendly Society of Corvids
# Duration: 15-30 minutes
# =============================================================================

export ROOKERY="${ROOKERY:-/rookery}"
export IMAGE_NAME="${IMAGE_NAME:-rookery-os-1.0}"
export IMAGE_SIZE="${IMAGE_SIZE:-25600}"  # Size in MB (25GB for full Rookery Extended system)

DIST_DIR="/dist"

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load common utilities
COMMON_DIR="/usr/local/lib/rookery-common"
if [ -d "$COMMON_DIR" ]; then
    source "$COMMON_DIR/logging.sh" 2>/dev/null || true
    source "$COMMON_DIR/checkpointing.sh" 2>/dev/null || true
else
    # Fallback for development/local testing
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/../../common/logging.sh" 2>/dev/null || true
    source "$SCRIPT_DIR/../../common/checkpointing.sh" 2>/dev/null || true
fi

# Fallback logging functions if not loaded
if ! type log_info &>/dev/null; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
    log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
    log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
    log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
fi

# Create disk image
create_disk_image() {
    log_info "=========================================="
    log_info "Creating Bootable Disk Image"
    log_info "=========================================="

    # Create loop devices if they don't exist (Docker containers often lack them)
    log_step "Ensuring loop devices exist..."
    for i in $(seq 0 7); do
        if [ ! -b /dev/loop$i ]; then
            mknod -m 660 /dev/loop$i b 7 $i 2>/dev/null || true
        fi
    done

    local image_file="$DIST_DIR/${IMAGE_NAME}.img"

    log_step "Creating sparse disk image file (${IMAGE_SIZE}MB)..."
    truncate -s "${IMAGE_SIZE}M" "$image_file"

    log_step "Partitioning disk image..."

    # Create partition table
    # Note: Suppress udevadm warnings from parted (not available in containers)
    parted -s "$image_file" mklabel msdos 2>/dev/null
    parted -s "$image_file" mkpart primary ext4 1MiB 100% 2>/dev/null
    parted -s "$image_file" set 1 boot on 2>/dev/null

    log_step "Setting up loop device with offset..."

    # In containers, partition devices often don't work properly
    # Use offset-based mounting instead (partition starts at 1MiB)
    local partition_offset=$((1024 * 1024))  # 1MiB in bytes

    # Format the partition area directly in the image file
    log_step "Formatting partition..."
    # Create a loop device for the partition area only
    local loop_dev=$(losetup -f)
    losetup -o $partition_offset "$loop_dev" "$image_file"

    mkfs.ext4 -L "ROOKERY" "$loop_dev"

    # Detach all loop devices to avoid conflicts
    losetup -d "$loop_dev"
    losetup -D 2>/dev/null || true  # Detach all loop devices
    sleep 2  # Give kernel time to release devices

    # Mount the partition
    # NOTE: Using /mnt instead of /tmp because /tmp may be a tmpfs with limited space
    log_step "Mounting partition..."
    local mount_point="/mnt/rookery-mount"
    mkdir -p "$mount_point"
    mount -o loop,offset=$partition_offset "$image_file" "$mount_point"

    # Strip debug symbols from binaries to reduce size (~1-2GB savings)
    log_step "Stripping debug symbols from binaries..."
    find "$ROOKERY/usr/bin" "$ROOKERY/usr/sbin" "$ROOKERY/usr/libexec" -type f -executable 2>/dev/null | \
        xargs -r strip --strip-unneeded 2>/dev/null || true
    find "$ROOKERY/usr/lib" "$ROOKERY/lib" -name "*.so*" -type f 2>/dev/null | \
        xargs -r strip --strip-unneeded 2>/dev/null || true
    find "$ROOKERY/opt" -type f -executable 2>/dev/null | \
        xargs -r strip --strip-unneeded 2>/dev/null || true

    # Copy Rookery system
    log_step "Copying Rookery system to image..."
    rsync -aAX \
        --exclude=/dev/* \
        --exclude=/proc/* \
        --exclude=/sys/* \
        --exclude=/run/* \
        --exclude=/tmp/* \
        --exclude=/sources/* \
        --exclude=/build/* \
        --exclude=/tools/* \
        --exclude=/.checkpoints \
        --exclude='*.log' \
        --exclude='*.a' \
        --exclude=/usr/share/doc/* \
        --exclude=/usr/share/man/* \
        --exclude=/usr/share/info/* \
        --exclude=/usr/share/locale/* \
        --exclude=/usr/share/gtk-doc/* \
        --exclude=/opt/rustc-*-src/* \
        --exclude=/opt/rustc-*/share/doc/* \
        --exclude='*.la' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='*.pyo' \
        "$ROOKERY/" "$mount_point/"

    # Create essential directories
    mkdir -p $mount_point/{dev,proc,sys,run,tmp}
    chmod 1777 $mount_point/tmp

    # Verify systemd init system is present in the mounted image
    log_step "Verifying systemd init system in image..."

    if [ -f "$mount_point/usr/lib/systemd/systemd" ]; then
        log_info "Found /usr/lib/systemd/systemd binary"

        # Verify it's executable
        if [ -x "$mount_point/usr/lib/systemd/systemd" ]; then
            log_info "✓ systemd is executable"
        else
            log_warn "ERROR: /usr/lib/systemd/systemd exists but is not executable"
            exit 1
        fi

        # Verify /sbin/init symlink exists and points to systemd
        if [ -L "$mount_point/sbin/init" ]; then
            local init_target=$(readlink "$mount_point/sbin/init")
            log_info "✓ /sbin/init symlink found -> $init_target"
        else
            log_warn "WARNING: /sbin/init symlink missing, creating..."
            ln -sf /usr/lib/systemd/systemd "$mount_point/sbin/init"
        fi

        # Verify default.target exists
        if [ -L "$mount_point/etc/systemd/system/default.target" ]; then
            log_info "✓ default.target configured"
        else
            log_warn "WARNING: default.target missing (created by configure-system)"
        fi

        # Verify systemd-networkd configuration
        if [ -f "$mount_point/etc/systemd/network/10-eth-static.network" ]; then
            log_info "✓ systemd-networkd configured"
        else
            log_warn "WARNING: network configuration missing"
        fi

        log_info "✓ systemd verified in disk image"
    else
        log_warn "ERROR: /usr/lib/systemd/systemd does not exist in disk image"
        log_warn "This should have been created during systemd installation (build-basesystem)"
        exit 1
    fi

    # Verify grsec kernel and modules
    log_step "Verifying grsec kernel..."
    if ls "$mount_point/boot/vmlinuz-"*grsec* 1>/dev/null 2>&1; then
        local kernel_file=$(ls "$mount_point/boot/vmlinuz-"*grsec* | head -1)
        log_info "✓ Grsec kernel found: $(basename $kernel_file)"
    else
        log_warn "WARNING: Grsec kernel not found, checking for any kernel..."
        if [ -f "$mount_point/boot/vmlinuz" ]; then
            log_info "✓ Kernel symlink found"
        else
            log_warn "ERROR: No kernel found!"
        fi
    fi

    # Verify modules directory
    if ls -d "$mount_point/lib/modules/"* 1>/dev/null 2>&1; then
        local modules_dir=$(ls -d "$mount_point/lib/modules/"* | head -1)
        local modules_size=$(du -sh "$modules_dir" 2>/dev/null | cut -f1)
        log_info "✓ Kernel modules found: $(basename $modules_dir) ($modules_size)"
    else
        log_warn "WARNING: Kernel modules not found"
    fi

    # Verify firmware
    if [ -d "$mount_point/lib/firmware" ] && [ "$(ls -A $mount_point/lib/firmware 2>/dev/null)" ]; then
        local firmware_size=$(du -sh "$mount_point/lib/firmware" 2>/dev/null | cut -f1)
        log_info "✓ Firmware installed ($firmware_size)"
    else
        log_warn "WARNING: Firmware not found"
    fi

    # Create poweroff/reboot utilities using SysRq
    log_step "Creating poweroff/reboot utilities..."

    cat > $mount_point/usr/sbin/poweroff << 'EOF'
#!/bin/sh
echo "System is going down for power off..."
sync
echo o > /proc/sysrq-trigger
EOF

    cat > $mount_point/usr/sbin/reboot << 'EOF'
#!/bin/sh
echo "System is going down for reboot..."
sync
echo b > /proc/sysrq-trigger
EOF

    chmod +x $mount_point/usr/sbin/poweroff
    chmod +x $mount_point/usr/sbin/reboot
    log_info "Power management utilities created"

    # Install GRUB
    log_step "Installing GRUB bootloader..."

    # Create a loop device for the ENTIRE disk image (needed for GRUB MBR installation)
    log_info "Creating loop device for full disk image..."
    local grub_loop_dev=$(losetup -f --show "$image_file")
    log_info "Loop device created: $grub_loop_dev"

    # Mount virtual filesystems for GRUB
    mount --bind /dev $mount_point/dev
    mount -t devpts devpts $mount_point/dev/pts
    mount -t proc proc $mount_point/proc
    mount -t sysfs sysfs $mount_point/sys

    # Install GRUB to MBR using chroot (LFS method)
    log_info "Installing GRUB to disk MBR via chroot..."

    # Remove load.cfg if it exists (prevents UUID search issues)
    rm -f $mount_point/boot/grub/i386-pc/load.cfg

    # Install GRUB from within the Rookery system using chroot
    chroot $mount_point /usr/bin/env -i \
        HOME=/root \
        TERM="$TERM" \
        PATH=/usr/bin:/usr/sbin \
        /usr/sbin/grub-install --target=i386-pc \
                               --boot-directory=/boot \
                               --modules="part_msdos ext2 biosdisk search" \
                               --no-floppy \
                               --recheck \
                               "$grub_loop_dev" || log_warn "GRUB installation completed with warnings"

    # Remove the problematic load.cfg that grub-install creates
    # This file causes UUID search issues during boot
    rm -f $mount_point/boot/grub/i386-pc/load.cfg
    log_info "Removed load.cfg to prevent UUID search issues"

    # Create GRUB configuration with serial console support
    log_info "Creating GRUB configuration with serial console support..."
    mkdir -p $mount_point/boot/grub

    cat > $mount_point/boot/grub/grub.cfg << 'EOF'
# GRUB configuration for Rookery OS 1.0
# A custom Linux distribution for the Friendly Society of Corvids
# Serial console compatible (QEMU -nographic)

# Configure serial port (115200 baud, 8N1)
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1

# Use both serial and console terminals for compatibility
terminal_input serial console
terminal_output serial console

set default=0
set timeout=5
set timeout_style=menu

insmod ext2
set root=(hd0,1)

menuentry "Rookery OS 1.0" {
    linux /boot/vmlinuz root=/dev/sda1 ro init=/usr/lib/systemd/systemd net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8
}

menuentry "Rookery OS 1.0 (Verbose Boot)" {
    linux /boot/vmlinuz root=/dev/sda1 ro init=/usr/lib/systemd/systemd net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8 systemd.log_level=debug systemd.log_target=console loglevel=7
}

menuentry "Rookery OS 1.0 (Recovery)" {
    linux /boot/vmlinuz root=/dev/sda1 rw init=/usr/lib/systemd/systemd systemd.unit=rescue.target net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8
}

menuentry "Rookery OS 1.0 (Emergency Shell)" {
    linux /boot/vmlinuz root=/dev/sda1 rw init=/usr/lib/systemd/systemd systemd.unit=emergency.target net.ifnames=0 biosdevname=0 console=tty0 console=ttyS0,115200n8
}
EOF

    log_info "GRUB installation complete"

    # Cleanup mounts
    log_step "Cleaning up..."
    umount $mount_point/dev/pts 2>/dev/null || true
    umount $mount_point/dev 2>/dev/null || true
    umount $mount_point/proc 2>/dev/null || true
    umount $mount_point/sys 2>/dev/null || true
    umount $mount_point

    # Detach loop devices
    log_info "Detaching loop device for GRUB: $grub_loop_dev"
    losetup -d "$grub_loop_dev" 2>/dev/null || log_warn "Failed to detach $grub_loop_dev"

    log_info "Disk image created: $image_file"
    log_info "Image size: $(du -h $image_file | cut -f1)"

    # Compress image with xz (better compression than gzip, ~20% smaller)
    log_step "Compressing image with xz (this may take a while)..."
    xz -T0 -6 -c "$image_file" > "${image_file}.xz"
    log_info "Compressed image: ${image_file}.xz ($(du -h ${image_file}.xz | cut -f1))"
}

# Create simple tarball (alternative method)
create_tarball() {
    log_step "Creating system tarball..."

    local tarball="$DIST_DIR/${IMAGE_NAME}.tar.gz"

    tar -czf "$tarball" \
        --exclude=$ROOKERY/dev/* \
        --exclude=$ROOKERY/proc/* \
        --exclude=$ROOKERY/sys/* \
        --exclude=$ROOKERY/run/* \
        --exclude=$ROOKERY/tmp/* \
        --exclude=$ROOKERY/sources/* \
        --exclude=$ROOKERY/build/* \
        --exclude=$ROOKERY/tools/* \
        -C "$ROOKERY" .

    log_info "Tarball created: $tarball"
    log_info "Size: $(du -h $tarball | cut -f1)"
}

# Helper function to copy a binary and all its library dependencies
copy_binary_with_libs() {
    local binary="$1"
    local initramfs_dir="$2"
    local lfs_root="$3"

    if [ ! -f "$binary" ]; then
        log_warn "Binary not found: $binary"
        return 1
    fi

    # Determine destination path (preserve usr structure)
    local rel_path="${binary#$lfs_root}"
    local dest_dir="$initramfs_dir$(dirname "$rel_path")"
    mkdir -p "$dest_dir"
    cp -a "$binary" "$dest_dir/" 2>/dev/null || return 1

    # Find and copy library dependencies using objdump (available in LFS)
    # We parse the NEEDED entries from the dynamic section
    local libs
    libs=$(objdump -p "$binary" 2>/dev/null | grep NEEDED | awk '{print $2}')

    for lib in $libs; do
        # Search for library in standard paths (use -e to match symlinks too)
        local lib_path=""
        for search_dir in "$lfs_root/lib64" "$lfs_root/lib" "$lfs_root/usr/lib64" "$lfs_root/usr/lib"; do
            if [ -e "$search_dir/$lib" ]; then
                lib_path="$search_dir/$lib"
                break
            fi
        done

        if [ -n "$lib_path" ] && [ -e "$lib_path" ]; then
            # Always resolve to the real file to avoid dangling symlinks
            local real_lib=$(readlink -f "$lib_path")
            if [ -f "$real_lib" ]; then
                # Copy to lib64 in initramfs with the expected name
                if [ ! -f "$initramfs_dir/lib64/$lib" ]; then
                    cp "$real_lib" "$initramfs_dir/lib64/$lib" 2>/dev/null
                fi
            fi
        fi
    done

    return 0
}

# Create bootable ISO image
create_iso() {
    log_info "=========================================="
    log_info "Creating Bootable ISO Image"
    log_info "=========================================="

    local iso_file="$DIST_DIR/${IMAGE_NAME}.iso"
    local iso_root="/tmp/iso-root"
    local iso_boot="$iso_root/boot"

    # Check for required tools
    if ! command -v xorriso &>/dev/null; then
        log_error "xorriso not found - cannot create ISO"
        log_error "Install xorriso package to enable ISO creation"
        return 1
    fi

    if ! command -v mksquashfs &>/dev/null; then
        log_error "mksquashfs not found - cannot create ISO"
        log_error "Install squashfs-tools package to enable ISO creation"
        return 1
    fi

    # Clean up any previous ISO build
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
        -comp xz \
        -Xbcj x86 \
        -b 1M \
        -no-recovery

    if [ ! -f "$iso_root/LiveOS/rootfs.img" ]; then
        log_error "Failed to create squashfs filesystem"
        return 1
    fi

    local squashfs_size=$(du -h "$iso_root/LiveOS/rootfs.img" | cut -f1)
    log_info "Created squashfs root filesystem: $squashfs_size"

    # =========================================================================
    # Step 3: Create initramfs with full coreutils/util-linux (no busybox)
    # =========================================================================
    log_step "Creating initramfs with full system utilities..."
    local initramfs_dir="/tmp/initramfs-iso"
    rm -rf "$initramfs_dir"

    # Create directory structure
    mkdir -p "$initramfs_dir"/{bin,sbin,etc,proc,sys,dev,run,tmp,newroot}
    mkdir -p "$initramfs_dir"/lib64/modules
    mkdir -p "$initramfs_dir"/usr/{bin,sbin,lib,lib64}
    # Create /lib symlink to /lib64 for library path compatibility
    # This ensures the dynamic linker finds libraries regardless of which path is searched
    ln -sf lib64 "$initramfs_dir/lib"
    # Also link /usr/lib to /lib64 for additional compatibility
    rm -rf "$initramfs_dir/usr/lib"
    ln -sf ../lib64 "$initramfs_dir/usr/lib"

    # Copy the dynamic linker first (required for all dynamically linked binaries)
    # Note: In LFS, lib64/ld-linux-x86-64.so.2 is a symlink to ../lib/ld-linux-x86-64.so.2
    # We need to copy the actual file, not the symlink
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
    fi

    # Copy core glibc libraries (resolve symlinks to get actual files)
    log_info "Copying glibc libraries..."
    for lib in libc.so.6 libm.so.6 libresolv.so.2 libnss_files.so.2; do
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

    # Essential binaries for initramfs (using full coreutils, not busybox)
    log_info "Copying essential binaries..."

    # Shell - bash (required for init script)
    for shell_bin in bash sh; do
        for path in "$ROOKERY/usr/bin/$shell_bin" "$ROOKERY/bin/$shell_bin"; do
            if [ -f "$path" ] && [ ! -L "$path" ]; then
                copy_binary_with_libs "$path" "$initramfs_dir" "$ROOKERY"
                break
            elif [ -L "$path" ]; then
                # Copy symlink and target
                local target=$(readlink -f "$path")
                if [ -f "$target" ]; then
                    copy_binary_with_libs "$target" "$initramfs_dir" "$ROOKERY"
                fi
                local rel_path="${path#$ROOKERY}"
                mkdir -p "$initramfs_dir$(dirname "$rel_path")"
                cp -a "$path" "$initramfs_dir$rel_path" 2>/dev/null
                break
            fi
        done
    done

    # Create /bin/sh symlink if it doesn't exist
    if [ ! -e "$initramfs_dir/bin/sh" ]; then
        if [ -f "$initramfs_dir/usr/bin/bash" ]; then
            ln -sf ../usr/bin/bash "$initramfs_dir/bin/sh"
        elif [ -f "$initramfs_dir/bin/bash" ]; then
            ln -sf bash "$initramfs_dir/bin/sh"
        fi
    fi

    # Core utilities from coreutils
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

    # Kmod utilities (for loading kernel modules)
    KMOD_BINS="modprobe insmod lsmod depmod"
    for bin in $KMOD_BINS; do
        for path in "$ROOKERY/usr/sbin/$bin" "$ROOKERY/sbin/$bin" "$ROOKERY/usr/bin/$bin"; do
            if [ -f "$path" ]; then
                copy_binary_with_libs "$path" "$initramfs_dir" "$ROOKERY"
                break
            elif [ -L "$path" ]; then
                # kmod uses symlinks - copy the actual kmod binary
                local target=$(readlink -f "$path")
                if [ -f "$target" ]; then
                    copy_binary_with_libs "$target" "$initramfs_dir" "$ROOKERY"
                fi
                local rel_path="${path#$ROOKERY}"
                mkdir -p "$initramfs_dir$(dirname "$rel_path")"
                cp -a "$path" "$initramfs_dir$rel_path" 2>/dev/null
                break
            fi
        done
    done

    # Additional libraries that may be needed (resolve symlinks)
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

    # Copy all .so files to ensure we don't miss dependencies (resolve symlinks)
    log_info "Copying shared library files..."
    for search_dir in "$ROOKERY/lib64" "$ROOKERY/lib" "$ROOKERY/usr/lib"; do
        if [ -d "$search_dir" ]; then
            find "$search_dir" -maxdepth 1 -name "*.so*" -type f -exec cp -n {} "$initramfs_dir/lib64/" \; 2>/dev/null || true
            # Also copy targets of symlinks
            find "$search_dir" -maxdepth 1 -name "*.so*" -type l -exec sh -c 'real=$(readlink -f "$1"); [ -f "$real" ] && cp -n "$real" "$2/lib64/"' _ {} "$initramfs_dir" \; 2>/dev/null || true
        fi
    done

    # =========================================================================
    # Step 4: Copy kernel modules for ISO boot (iso9660, squashfs, loop)
    # =========================================================================
    log_step "Copying kernel modules..."

    # Find the kernel version
    local kernel_version=""
    if [ -d "$ROOKERY/lib/modules" ]; then
        kernel_version=$(ls -1 "$ROOKERY/lib/modules" | head -1)
    fi

    if [ -n "$kernel_version" ] && [ -d "$ROOKERY/lib/modules/$kernel_version" ]; then
        local mod_src="$ROOKERY/lib/modules/$kernel_version"
        local mod_dst="$initramfs_dir/lib/modules/$kernel_version"
        mkdir -p "$mod_dst/kernel/fs" "$mod_dst/kernel/drivers/block" "$mod_dst/kernel/drivers/scsi" "$mod_dst/kernel/drivers/cdrom" "$mod_dst/kernel/drivers/ata"

        # Copy required modules for ISO boot
        # Filesystem modules
        find "$mod_src" -name "isofs.ko*" -exec cp {} "$mod_dst/kernel/fs/" \; 2>/dev/null
        find "$mod_src" -name "iso9660.ko*" -exec cp {} "$mod_dst/kernel/fs/" \; 2>/dev/null
        find "$mod_src" -name "squashfs.ko*" -exec cp {} "$mod_dst/kernel/fs/" \; 2>/dev/null
        find "$mod_src" -name "overlay.ko*" -exec cp {} "$mod_dst/kernel/fs/" \; 2>/dev/null
        find "$mod_src" -name "loop.ko*" -exec cp {} "$mod_dst/kernel/drivers/block/" \; 2>/dev/null

        # SCSI and CD-ROM modules (required for ISO boot in VMs and bare metal)
        find "$mod_src" -name "sr_mod.ko*" -exec cp {} "$mod_dst/kernel/drivers/scsi/" \; 2>/dev/null
        find "$mod_src" -name "cdrom.ko*" -exec cp {} "$mod_dst/kernel/drivers/cdrom/" \; 2>/dev/null
        find "$mod_src" -name "scsi_mod.ko*" -exec cp {} "$mod_dst/kernel/drivers/scsi/" \; 2>/dev/null
        find "$mod_src" -name "sd_mod.ko*" -exec cp {} "$mod_dst/kernel/drivers/scsi/" \; 2>/dev/null
        # ATA/AHCI modules for SATA CD-ROM drives
        find "$mod_src" -name "ata_piix.ko*" -exec cp {} "$mod_dst/kernel/drivers/ata/" \; 2>/dev/null
        find "$mod_src" -name "ata_generic.ko*" -exec cp {} "$mod_dst/kernel/drivers/ata/" \; 2>/dev/null
        find "$mod_src" -name "ahci.ko*" -exec cp {} "$mod_dst/kernel/drivers/ata/" \; 2>/dev/null
        find "$mod_src" -name "libahci.ko*" -exec cp {} "$mod_dst/kernel/drivers/ata/" \; 2>/dev/null
        find "$mod_src" -name "libata.ko*" -exec cp {} "$mod_dst/kernel/drivers/ata/" \; 2>/dev/null
        # Virtio modules for QEMU/KVM
        find "$mod_src" -name "virtio*.ko*" -exec cp {} "$mod_dst/kernel/drivers/block/" \; 2>/dev/null
        find "$mod_src" -name "virtio_scsi.ko*" -exec cp {} "$mod_dst/kernel/drivers/scsi/" \; 2>/dev/null

        # Copy modules.* files for modprobe
        cp "$mod_src"/modules.* "$mod_dst/" 2>/dev/null || true

        # Generate modules.dep if depmod is available
        if command -v depmod &>/dev/null; then
            depmod -a -b "$initramfs_dir" "$kernel_version" 2>/dev/null || true
        fi

        log_info "Copied kernel modules for version: $kernel_version"
    else
        log_warn "Kernel modules not found - ISO may not boot on all systems"
    fi

    # =========================================================================
    # Step 5: Create the init script for live boot
    # =========================================================================
    log_step "Creating init script..."

    cat > "$initramfs_dir/init" << 'INITEOF'
#!/bin/sh
# Rookery OS Live Boot Init Script
# Boots from ISO by mounting squashfs root filesystem

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /dev/shm
mount -t tmpfs tmpfs /run
mount -t tmpfs tmpfs /tmp

# Enable kernel messages on console
echo 1 > /proc/sys/kernel/printk

echo ""
echo "=========================================="
echo "  Rookery OS 1.0 - Live Boot"
echo "  Friendly Society of Corvids"
echo "=========================================="
echo ""

# Parse kernel command line
INSTALL_MODE=0
for arg in $(cat /proc/cmdline); do
    case "$arg" in
        rookery_install=1) INSTALL_MODE=1 ;;
    esac
done

# Load required kernel modules
echo "Loading kernel modules..."
KERNEL_VERSION=$(uname -r)

# Show available modules for debugging
echo "  Kernel version: $KERNEL_VERSION"
echo "  Module directory: /lib/modules/$KERNEL_VERSION"
ls /lib/modules/$KERNEL_VERSION/kernel/drivers/ 2>/dev/null || echo "  (no module directory found)"

# Load SCSI core first (required for sr_mod)
echo "  Loading SCSI subsystem..."
modprobe scsi_mod 2>/dev/null && echo "    scsi_mod: OK" || echo "    scsi_mod: failed or built-in"

# Load CDROM support
echo "  Loading CD-ROM support..."
modprobe cdrom 2>/dev/null && echo "    cdrom: OK" || echo "    cdrom: failed or built-in"

# Load SCSI CD-ROM driver
echo "  Loading SCSI CD-ROM driver..."
modprobe sr_mod 2>/dev/null && echo "    sr_mod: OK" || echo "    sr_mod: failed or built-in"

# Load ATA/IDE support for the CD-ROM controller
echo "  Loading ATA/IDE support..."
modprobe libata 2>/dev/null && echo "    libata: OK" || echo "    libata: failed or built-in"
modprobe ata_piix 2>/dev/null && echo "    ata_piix: OK" || echo "    ata_piix: failed or built-in"
modprobe ata_generic 2>/dev/null && echo "    ata_generic: OK" || echo "    ata_generic: failed or built-in"
modprobe ahci 2>/dev/null && echo "    ahci: OK" || echo "    ahci: failed or built-in"

# Load SCSI disk driver (for disk devices)
modprobe sd_mod 2>/dev/null && echo "    sd_mod: OK" || echo "    sd_mod: failed or built-in"

# Load filesystem modules
echo "  Loading filesystem modules..."
for mod in loop squashfs isofs iso9660 overlay; do
    modprobe $mod 2>/dev/null && echo "    $mod: OK" || echo "    $mod: failed or built-in"
done

# Load virtio modules for QEMU/KVM
echo "  Loading virtio modules..."
for mod in virtio virtio_pci virtio_blk virtio_scsi; do
    modprobe $mod 2>/dev/null && echo "    $mod: OK" || echo "    $mod: failed or built-in"
done

# Wait for devices to settle (udev would normally handle this)
echo "Waiting for devices to settle..."
sleep 3

# Show what block devices we have now
echo "Block devices after module loading:"
ls -la /dev/sr* /dev/sd* /dev/vd* /dev/hd* 2>/dev/null || echo "  (none)"

# Find the ISO/CD-ROM device
echo "Searching for boot media..."
ISO_DEV=""
MOUNT_POINT="/mnt/iso"
mkdir -p "$MOUNT_POINT"

# Try common CD-ROM devices first
for dev in /dev/sr0 /dev/sr1 /dev/cdrom /dev/dvd; do
    if [ -b "$dev" ]; then
        echo "  Trying $dev..."
        if mount -t iso9660 -o ro "$dev" "$MOUNT_POINT" 2>/dev/null; then
            if [ -f "$MOUNT_POINT/LiveOS/rootfs.img" ]; then
                ISO_DEV="$dev"
                echo "  Found boot media at $dev"
                break
            fi
            umount "$MOUNT_POINT" 2>/dev/null
        fi
    fi
done

# If not found, scan all block devices
if [ -z "$ISO_DEV" ]; then
    echo "  Scanning block devices..."
    for dev in /dev/sd* /dev/vd* /dev/nvme*; do
        [ -b "$dev" ] || continue
        # Skip if it's a partition that's too small (< 100MB)
        if mount -t iso9660 -o ro "$dev" "$MOUNT_POINT" 2>/dev/null; then
            if [ -f "$MOUNT_POINT/LiveOS/rootfs.img" ]; then
                ISO_DEV="$dev"
                echo "  Found boot media at $dev"
                break
            fi
            umount "$MOUNT_POINT" 2>/dev/null
        fi
    done
fi

if [ -z "$ISO_DEV" ]; then
    echo ""
    echo "ERROR: Could not find boot media with LiveOS/rootfs.img"
    echo ""
    echo "Available block devices:"
    ls -la /dev/sd* /dev/sr* /dev/vd* 2>/dev/null || echo "  (none found)"
    echo ""
    echo "Dropping to emergency shell..."
    exec /bin/sh
fi

# Mount the squashfs root filesystem
echo "Mounting squashfs root filesystem..."
mkdir -p /mnt/squash
if ! mount -t squashfs -o ro,loop "$MOUNT_POINT/LiveOS/rootfs.img" /mnt/squash; then
    echo "ERROR: Failed to mount squashfs filesystem"
    echo "Dropping to emergency shell..."
    exec /bin/sh
fi

# Create overlay for writable live system
echo "Setting up overlay filesystem..."
mkdir -p /mnt/overlay/upper /mnt/overlay/work /mnt/overlay/merged

mount -t tmpfs tmpfs /mnt/overlay

mkdir -p /mnt/overlay/upper /mnt/overlay/work

if mount -t overlay overlay -o lowerdir=/mnt/squash,upperdir=/mnt/overlay/upper,workdir=/mnt/overlay/work /newroot 2>/dev/null; then
    echo "Overlay filesystem ready (changes will not persist)"
else
    # Fallback: mount squashfs directly (read-only)
    echo "Overlay not available, using read-only root"
    mount --move /mnt/squash /newroot
fi

# Prepare for switch_root
mkdir -p /newroot/mnt/iso /newroot/run

# Move mounts to new root
mount --move /proc /newroot/proc
mount --move /sys /newroot/sys
mount --move /dev /newroot/dev
mount --move /run /newroot/run

# Keep ISO mounted for access to additional files
mount --move "$MOUNT_POINT" /newroot/mnt/iso 2>/dev/null || true

echo ""
echo "Switching to root filesystem..."
echo ""

# Switch to the real root and exec init
if [ -x /newroot/usr/lib/systemd/systemd ]; then
    exec switch_root /newroot /usr/lib/systemd/systemd
elif [ -x /newroot/sbin/init ]; then
    exec switch_root /newroot /sbin/init
else
    echo "ERROR: No init found in root filesystem"
    echo "Dropping to shell in new root..."
    exec switch_root /newroot /bin/sh
fi
INITEOF

    chmod +x "$initramfs_dir/init"

    # Create /bin/sh -> init fallback
    ln -sf ../init "$initramfs_dir/bin/init" 2>/dev/null || true

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
    # Step 7: Include disk image for installation option
    # =========================================================================
    log_step "Including disk image for installation..."
    mkdir -p "$iso_root/images"
    local img_file="$DIST_DIR/${IMAGE_NAME}.img"
    if [ -f "${img_file}.xz" ]; then
        cp "${img_file}.xz" "$iso_root/images/"
        log_info "Included xz-compressed disk image in ISO"
    elif [ -f "$img_file" ]; then
        xz -T0 -6 -c "$img_file" > "$iso_root/images/${IMAGE_NAME}.img.xz"
        log_info "Included xz-compressed disk image in ISO"
    fi

    # =========================================================================
    # Step 8: Create GRUB configuration for ISO
    # =========================================================================
    log_step "Creating GRUB configuration..."

    cat > "$iso_boot/grub/grub.cfg" << 'EOF'
# GRUB configuration for Rookery OS 1.0 ISO
# A custom Linux distribution for the Friendly Society of Corvids

set default=0
set timeout=10
set timeout_style=menu

# Serial console support for headless operation
serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1
terminal_input serial console
terminal_output serial console

insmod all_video
insmod gfxterm

menuentry "Rookery OS 1.0 (Live)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8
    initrd /boot/initrd.img
}

menuentry "Rookery OS 1.0 (Live - Verbose Boot)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 loglevel=7 systemd.log_level=debug
    initrd /boot/initrd.img
}

menuentry "Rookery OS 1.0 (Install to Disk)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200n8 rookery_install=1
    initrd /boot/initrd.img
}

menuentry "Boot from first hard disk" {
    set root=(hd0)
    chainloader +1
}
EOF

    # =========================================================================
    # Step 9: Build the ISO image (using ISOLINUX like major distros)
    # =========================================================================
    log_step "Building hybrid ISO image with ISOLINUX..."

    # Use ISOLINUX directly - grub-mkrescue fails on files >4GB
    # This is how Arch, Debian, Ubuntu, and Fedora create their ISOs
    create_iso_xorriso "$iso_file" "$iso_root"

    # =========================================================================
    # Step 10: Verify and cleanup
    # =========================================================================
    rm -rf "$initramfs_dir"

    if [ -f "$iso_file" ]; then
        local iso_size=$(du -h "$iso_file" | cut -f1)
        log_info ""
        log_info "=========================================="
        log_info "ISO IMAGE CREATED SUCCESSFULLY"
        log_info "=========================================="
        log_info "File: $iso_file"
        log_info "Size: $iso_size"
        log_info ""
        log_info "To test with QEMU:"
        log_info "  qemu-system-x86_64 -m 2G -cdrom $iso_file -boot d -nographic -serial mon:stdio"
        log_info ""
    else
        log_error "ISO creation failed - no output file"
        return 1
    fi
}

# Helper function to create ISO with xorriso directly (using ISOLINUX like major distros)
create_iso_xorriso() {
    local iso_file="$1"
    local iso_root="$2"

    log_info "Creating ISO with xorriso (ISOLINUX boot)..."

    # Set up ISOLINUX for BIOS boot (this is how major distros do it)
    mkdir -p "$iso_root/boot/syslinux"

    # Copy ISOLINUX files
    if [ -f "/usr/lib/ISOLINUX/isolinux.bin" ]; then
        cp /usr/lib/ISOLINUX/isolinux.bin "$iso_root/boot/syslinux/"
    else
        log_error "Missing /usr/lib/ISOLINUX/isolinux.bin"
        return 1
    fi

    # Copy required syslinux modules
    local syslinux_mods="/usr/lib/syslinux/modules/bios"
    for mod in ldlinux.c32 menu.c32 libutil.c32 libcom32.c32; do
        if [ -f "$syslinux_mods/$mod" ]; then
            cp "$syslinux_mods/$mod" "$iso_root/boot/syslinux/"
        else
            log_warn "Optional syslinux module not found: $mod"
        fi
    done

    # Create ISOLINUX config
    cat > "$iso_root/boot/syslinux/syslinux.cfg" << 'SYSLINUX_CFG'
DEFAULT linux
TIMEOUT 50
PROMPT 1

SAY Rookery OS Live - Press ENTER to boot or wait 5 seconds...

LABEL linux
    KERNEL /boot/vmlinuz
    INITRD /boot/initrd.img
    APPEND root=live:LABEL=ROOKERY_OS rd.live.image rd.live.dir=/LiveOS console=tty0 console=ttyS0,115200n8
SYSLINUX_CFG

    log_info "ISOLINUX boot configured"

    # Get the isohdpfx.bin for hybrid boot (USB/CD)
    local isohdpfx=""
    if [ -f "/usr/lib/ISOLINUX/isohdpfx.bin" ]; then
        isohdpfx="/usr/lib/ISOLINUX/isohdpfx.bin"
    elif [ -f "/usr/share/syslinux/isohdpfx.bin" ]; then
        isohdpfx="/usr/share/syslinux/isohdpfx.bin"
    else
        log_error "Missing isohdpfx.bin for hybrid boot"
        return 1
    fi

    # Create the ISO with xorriso (using ISOLINUX like Arch/Debian/Ubuntu)
    # Use -iso-level 3 to support files larger than 4GB (squashfs rootfs.img)
    log_info "Running xorriso..."
    if ! xorriso -as mkisofs \
        -r -J -joliet-long \
        -iso-level 3 \
        -full-iso9660-filenames \
        -V "ROOKERY_OS" \
        -isohybrid-mbr "$isohdpfx" \
        -eltorito-boot boot/syslinux/isolinux.bin \
        -eltorito-catalog boot/syslinux/boot.cat \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -o "$iso_file" \
        "$iso_root" 2>&1 | tee /tmp/xorriso.log; then

        log_error "xorriso failed. Log:"
        cat /tmp/xorriso.log
        return 1
    fi

    log_info "ISO created with xorriso (ISOLINUX boot)"
}

# Main
main() {
    log_info "=========================================="
    log_info "Rookery OS Package Image"
    log_info "=========================================="

    # Initialize checkpoint system
    init_checkpointing

    # Check if image already created
    if should_skip_global_checkpoint "image-${IMAGE_NAME}"; then
        log_info "Image ${IMAGE_NAME} already created - skipping"
        exit 0
    fi

    # Verify Rookery system exists
    if [ ! -d "$ROOKERY" ] || [ ! -f "$ROOKERY/boot/vmlinuz" ]; then
        log_warn "Rookery system incomplete!"
        log_warn "Boot kernel not found: $ROOKERY/boot/vmlinuz"
    fi

    # Create output directory
    mkdir -p "$DIST_DIR"

    # Create disk image
    create_disk_image

    # Also create tarball for convenience
    create_tarball

    # Create bootable ISO
    create_iso

    # Create README
    cat > "$DIST_DIR/README.txt" << EOF
Rookery OS 1.0
A custom Linux distribution for the Friendly Society of Corvids
Generated: $(date)

Files:
- ${IMAGE_NAME}.img.xz: Bootable disk image (xz compressed)
- ${IMAGE_NAME}.iso: Bootable ISO image (hybrid - works on CD/DVD and USB)
- ${IMAGE_NAME}.tar.gz: System tarball

Usage:

== Disk Image (Recommended for VMs) ==
1. Decompress the image:
   unxz ${IMAGE_NAME}.img.xz

2. Boot with QEMU (serial console):
   qemu-system-x86_64 -m 2G -smp 2 \\
       -drive file=${IMAGE_NAME}.img,format=raw \\
       -boot c \\
       -nographic \\
       -serial mon:stdio

   Or with graphical display:
   qemu-system-x86_64 -m 2G -smp 2 -drive file=${IMAGE_NAME}.img,format=raw

3. Or write to USB drive:
   dd if=${IMAGE_NAME}.img of=/dev/sdX bs=4M status=progress
   (Replace /dev/sdX with your USB device)

== ISO Image (For CD/DVD or USB boot) ==
1. Boot with QEMU from ISO:
   qemu-system-x86_64 -m 2G -smp 2 \\
       -cdrom ${IMAGE_NAME}.iso \\
       -boot d \\
       -nographic \\
       -serial mon:stdio

2. Write to USB (hybrid ISO):
   dd if=${IMAGE_NAME}.iso of=/dev/sdX bs=4M status=progress

3. Burn to CD/DVD using your preferred burning software

   The ISO includes the compressed disk image in /images/ for installation.

== Tarball (For manual installation) ==
Extract tarball:
   tar -xzf ${IMAGE_NAME}.tar.gz -C /path/to/rootfs

System Info:
- Rookery OS Version: 1.0 (based on LFS 12.4)
- Init System: systemd
- Kernel: grsecurity-hardened ($(ls $ROOKERY/boot/vmlinuz-* 2>/dev/null | head -1 | xargs basename || echo "Unknown"))
- Root Password: rookery (CHANGE AFTER FIRST LOGIN!)

Features:
- systemd init system with journald logging
- Grsecurity kernel hardening (desktop profile, VM guest)
- All hardware drivers as loadable modules
- Linux-firmware for hardware support
- systemd-networkd for network configuration

Default Network:
- Static IP: 10.0.2.15/24 (QEMU default)
- Gateway: 10.0.2.2
- DNS: 10.0.2.3, 8.8.8.8

Useful Commands:
- systemctl status              # Check system status
- journalctl -b                 # View boot log
- systemctl list-units --failed # Check failed units
- lsmod                         # List loaded kernel modules

Built with love for the Friendly Society of Corvids
Based on Linux From Scratch: https://www.linuxfromscratch.org
EOF

    log_info ""
    log_info "=========================================="
    log_info "Packaging Complete!"
    log_info "=========================================="
    log_info "Output directory: $DIST_DIR"
    log_info ""
    log_info "Files created:"
    ls -lh "$DIST_DIR"

    # Create global checkpoint
    # Use DIST_DIR as checkpoint location since image is the final output
    export CHECKPOINT_DIR="$DIST_DIR/.checkpoints"
    create_global_checkpoint "image-${IMAGE_NAME}" "package"

    exit 0
}

main "$@"
