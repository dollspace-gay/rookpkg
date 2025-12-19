#!/bin/bash
set -euo pipefail

# =============================================================================
# Rookery OS Build Kernel Script - Grsecurity Edition
# Compiles the Linux kernel with grsecurity patches for Rookery OS
# A custom Linux distribution for the Friendly Society of Corvids
# Duration: 30-90 minutes (grsec adds compile-time overhead)
# =============================================================================

export ROOKERY="${ROOKERY:-/rookery}"
export MAKEFLAGS="${MAKEFLAGS:--j$(nproc)}"
export KERNEL_VERSION="${KERNEL_VERSION:-6.6.102-grsec}"
export USE_LOCAL_KERNEL="${USE_LOCAL_KERNEL:-true}"

SOURCES_DIR="/sources"
KERNEL_SRC_DIR="/kernel-src"
BUILD_DIR="/tmp/kernel-build"

# Load common utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="/usr/local/lib/rookery-common"
if [ -d "$COMMON_DIR" ]; then
    source "$COMMON_DIR/logging.sh" 2>/dev/null || true
    source "$COMMON_DIR/checkpointing.sh" 2>/dev/null || true
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/../../common/logging.sh" 2>/dev/null || true
    source "$SCRIPT_DIR/../../common/checkpointing.sh" 2>/dev/null || true
fi

# Fallback logging functions if not loaded
if ! type log_info &>/dev/null; then
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    RED='\033[0;31m'
    NC='\033[0m'
    log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
    log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
    log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
fi

main() {
    log_info "=========================================="
    log_info "Rookery OS - Building Grsecurity Kernel $KERNEL_VERSION"
    log_info "=========================================="

    # Initialize checkpoint system
    init_checkpointing

    # Check if kernel already built (use global checkpoint - no source tarball)
    if should_skip_global_checkpoint "linux-grsec"; then
        log_info "Grsec kernel $KERNEL_VERSION already built - skipping"
        exit 0
    fi

    # Verify grsec kernel source exists
    if [ ! -d "$KERNEL_SRC_DIR" ]; then
        log_error "Grsec kernel source not found at $KERNEL_SRC_DIR"
        log_error "Ensure the linux-6.6.102 directory is mounted"
        exit 1
    fi

    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Copy grsec kernel source (read-only mount)
    log_step "Copying grsec kernel source..."
    cp -a "$KERNEL_SRC_DIR" ./linux-build
    cd linux-build

    # Verify this is a grsec kernel
    if [ ! -d "grsecurity" ]; then
        log_warn "grsecurity directory not found - this may not be a grsec kernel"
    fi

    # Clean build environment
    log_step "Preparing build environment..."
    make mrproper

    # =========================================================================
    # Configure kernel with grsecurity
    # =========================================================================
    log_step "Configuring kernel with grsecurity..."

    # Start with defconfig for x86_64
    make defconfig

    # =========================================================================
    # Grsecurity configuration (desktop profile, VM guest)
    # =========================================================================
    log_info "Enabling grsecurity with desktop profile for VM guest..."

    # Enable grsecurity with auto-configuration
    scripts/config --enable CONFIG_GRKERNSEC || log_warn "GRKERNSEC not available"
    scripts/config --enable CONFIG_GRKERNSEC_CONFIG_AUTO || true
    scripts/config --enable CONFIG_GRKERNSEC_CONFIG_DESKTOP || true
    scripts/config --enable CONFIG_GRKERNSEC_CONFIG_VIRT_GUEST || true
    scripts/config --enable CONFIG_GRKERNSEC_CONFIG_VIRT_KVM || true

    # =========================================================================
    # Disable SELinux (grsecurity provides its own RBAC)
    # =========================================================================
    log_info "Disabling SELinux (grsec provides RBAC)..."
    scripts/config --disable CONFIG_SECURITY_SELINUX

    # =========================================================================
    # Module support (distro-style: build drivers as modules)
    # =========================================================================
    log_info "Configuring module support..."
    scripts/config --enable CONFIG_MODULES
    scripts/config --enable CONFIG_MODULE_UNLOAD
    scripts/config --enable CONFIG_MODULE_FORCE_UNLOAD
    scripts/config --enable CONFIG_MODVERSIONS
    scripts/config --enable CONFIG_MODULE_SRCVERSION_ALL

    # =========================================================================
    # Firmware loading
    # =========================================================================
    log_info "Configuring firmware loading..."
    scripts/config --enable CONFIG_FW_LOADER
    scripts/config --disable CONFIG_FIRMWARE_IN_KERNEL
    scripts/config --set-str CONFIG_EXTRA_FIRMWARE ""

    # =========================================================================
    # Systemd requirements (built-in for boot)
    # =========================================================================
    log_info "Enabling systemd requirements..."
    scripts/config --enable CONFIG_DEVTMPFS
    scripts/config --enable CONFIG_DEVTMPFS_MOUNT
    scripts/config --enable CONFIG_CGROUPS
    scripts/config --enable CONFIG_CGROUP_SCHED
    scripts/config --enable CONFIG_CGROUP_PIDS
    scripts/config --enable CONFIG_CGROUP_FREEZER
    scripts/config --enable CONFIG_CGROUP_DEVICE
    scripts/config --enable CONFIG_CGROUP_CPUACCT
    scripts/config --enable CONFIG_CGROUP_PERF
    scripts/config --enable CONFIG_CGROUP_BPF
    scripts/config --enable CONFIG_NAMESPACES
    scripts/config --enable CONFIG_USER_NS
    scripts/config --enable CONFIG_PID_NS
    scripts/config --enable CONFIG_NET_NS
    scripts/config --enable CONFIG_UTS_NS
    scripts/config --enable CONFIG_IPC_NS
    scripts/config --enable CONFIG_INOTIFY_USER
    scripts/config --enable CONFIG_SIGNALFD
    scripts/config --enable CONFIG_TIMERFD
    scripts/config --enable CONFIG_EPOLL
    scripts/config --enable CONFIG_FHANDLE
    scripts/config --enable CONFIG_DMIID
    scripts/config --enable CONFIG_TMPFS
    scripts/config --enable CONFIG_TMPFS_POSIX_ACL
    scripts/config --enable CONFIG_TMPFS_XATTR
    scripts/config --enable CONFIG_SECCOMP
    scripts/config --enable CONFIG_SECCOMP_FILTER

    # =========================================================================
    # Serial console (built-in for QEMU -nographic)
    # =========================================================================
    log_info "Enabling serial console..."
    scripts/config --enable CONFIG_SERIAL_8250
    scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
    scripts/config --enable CONFIG_SERIAL_8250_PCI

    # =========================================================================
    # EXT4 filesystem (built-in for root)
    # =========================================================================
    log_info "Enabling EXT4 filesystem..."
    scripts/config --enable CONFIG_EXT4_FS
    scripts/config --enable CONFIG_EXT4_FS_POSIX_ACL
    scripts/config --enable CONFIG_EXT4_FS_SECURITY

    # =========================================================================
    # Core storage drivers (BUILT-IN for initramfs/ISO boot)
    # Without udev, we need these compiled in to detect boot devices
    # =========================================================================
    log_info "Enabling core storage drivers (built-in for boot)..."

    # --- SCSI subsystem (required for CD-ROM and disk) ---
    scripts/config --enable CONFIG_SCSI
    scripts/config --enable CONFIG_SCSI_MOD
    scripts/config --enable CONFIG_BLK_DEV_SD
    scripts/config --enable CONFIG_BLK_DEV_SR
    scripts/config --enable CONFIG_CHR_DEV_SG
    scripts/config --enable CONFIG_SCSI_CONSTANTS
    scripts/config --enable CONFIG_SCSI_SPI_ATTRS

    # --- ATA/SATA (required for CD-ROM drives) ---
    scripts/config --enable CONFIG_ATA
    scripts/config --enable CONFIG_SATA_AHCI
    scripts/config --enable CONFIG_ATA_PIIX
    scripts/config --enable CONFIG_ATA_GENERIC
    scripts/config --module CONFIG_PATA_AMD
    scripts/config --module CONFIG_PATA_OLDPIIX

    # --- CD-ROM support ---
    scripts/config --enable CONFIG_CDROM

    # --- ISO9660 filesystem (for ISO boot) ---
    scripts/config --enable CONFIG_ISO9660_FS
    scripts/config --enable CONFIG_JOLIET
    scripts/config --enable CONFIG_ZISOFS

    # --- Squashfs (for live boot) ---
    scripts/config --enable CONFIG_SQUASHFS
    scripts/config --enable CONFIG_SQUASHFS_ZLIB
    scripts/config --enable CONFIG_SQUASHFS_LZ4
    scripts/config --enable CONFIG_SQUASHFS_LZO
    scripts/config --enable CONFIG_SQUASHFS_XZ
    scripts/config --enable CONFIG_SQUASHFS_ZSTD

    # --- Loop device (for mounting squashfs) ---
    scripts/config --enable CONFIG_BLK_DEV_LOOP

    # --- NVMe storage ---
    scripts/config --enable CONFIG_NVME_CORE
    scripts/config --module CONFIG_BLK_DEV_NVME

    # --- VirtIO drivers (built-in for QEMU/KVM boot) ---
    scripts/config --enable CONFIG_VIRTIO
    scripts/config --enable CONFIG_VIRTIO_PCI
    scripts/config --enable CONFIG_VIRTIO_BLK
    scripts/config --enable CONFIG_VIRTIO_SCSI
    scripts/config --module CONFIG_VIRTIO_NET
    scripts/config --module CONFIG_VIRTIO_CONSOLE
    scripts/config --module CONFIG_VIRTIO_BALLOON
    scripts/config --module CONFIG_VIRTIO_INPUT
    scripts/config --module CONFIG_VIRTIO_MMIO

    # --- Network drivers ---
    # Vendor options are bool (y/n), individual drivers can be modules
    scripts/config --enable CONFIG_NET_VENDOR_INTEL
    scripts/config --module CONFIG_E1000
    scripts/config --module CONFIG_E1000E
    scripts/config --module CONFIG_IGB
    scripts/config --module CONFIG_IXGBE
    scripts/config --enable CONFIG_NET_VENDOR_REALTEK
    scripts/config --module CONFIG_8139TOO
    scripts/config --module CONFIG_8139CP
    scripts/config --module CONFIG_R8169
    scripts/config --enable CONFIG_NET_VENDOR_BROADCOM
    scripts/config --module CONFIG_BNX2
    scripts/config --module CONFIG_TIGON3

    # --- USB controllers and devices ---
    scripts/config --module CONFIG_USB
    scripts/config --module CONFIG_USB_XHCI_HCD
    scripts/config --module CONFIG_USB_XHCI_PCI
    scripts/config --module CONFIG_USB_EHCI_HCD
    scripts/config --module CONFIG_USB_EHCI_PCI
    scripts/config --module CONFIG_USB_UHCI_HCD
    scripts/config --module CONFIG_USB_OHCI_HCD
    scripts/config --module CONFIG_USB_STORAGE
    scripts/config --module CONFIG_USB_HID
    scripts/config --enable CONFIG_USB_HIDDEV

    # --- HID (input devices) ---
    scripts/config --module CONFIG_HID
    scripts/config --module CONFIG_HID_GENERIC
    scripts/config --enable CONFIG_INPUT_KEYBOARD
    scripts/config --enable CONFIG_INPUT_MOUSE
    scripts/config --module CONFIG_INPUT_EVDEV

    # --- Audio ---
    scripts/config --module CONFIG_SND
    scripts/config --enable CONFIG_SND_PCI
    scripts/config --module CONFIG_SND_HDA_INTEL
    scripts/config --module CONFIG_SND_HDA_CODEC_HDMI
    scripts/config --module CONFIG_SND_HDA_CODEC_REALTEK
    scripts/config --module CONFIG_SND_AC97_CODEC
    scripts/config --module CONFIG_SND_INTEL8X0

    # --- GPU/DRM ---
    scripts/config --module CONFIG_DRM
    scripts/config --module CONFIG_DRM_KMS_HELPER
    scripts/config --module CONFIG_DRM_I915
    scripts/config --module CONFIG_DRM_AMDGPU
    scripts/config --module CONFIG_DRM_NOUVEAU
    scripts/config --module CONFIG_DRM_VIRTIO_GPU
    scripts/config --module CONFIG_DRM_BOCHS
    scripts/config --module CONFIG_DRM_QXL
    scripts/config --enable CONFIG_FB
    scripts/config --enable CONFIG_FB_VESA

    # --- Wireless ---
    scripts/config --enable CONFIG_WLAN
    scripts/config --module CONFIG_CFG80211
    scripts/config --module CONFIG_MAC80211
    scripts/config --module CONFIG_IWLWIFI
    scripts/config --module CONFIG_IWLMVM
    scripts/config --module CONFIG_ATH9K
    scripts/config --module CONFIG_ATH10K
    scripts/config --module CONFIG_RTL8192CU
    scripts/config --module CONFIG_RTL8192CE
    scripts/config --module CONFIG_RTW88

    # --- Filesystems required for ISO/Live boot (built-in for reliability) ---
    scripts/config --enable CONFIG_BLK_DEV_LOOP
    scripts/config --enable CONFIG_ISO9660_FS
    scripts/config --enable CONFIG_JOLIET
    scripts/config --enable CONFIG_ZISOFS
    scripts/config --enable CONFIG_SQUASHFS
    scripts/config --enable CONFIG_SQUASHFS_XZ
    scripts/config --enable CONFIG_SQUASHFS_ZSTD
    scripts/config --enable CONFIG_SQUASHFS_LZO
    scripts/config --enable CONFIG_OVERLAY_FS

    # --- Other filesystems (as modules) ---
    scripts/config --module CONFIG_BTRFS_FS
    scripts/config --module CONFIG_XFS_FS
    scripts/config --module CONFIG_VFAT_FS
    scripts/config --module CONFIG_FAT_FS
    scripts/config --module CONFIG_MSDOS_FS
    scripts/config --module CONFIG_NTFS3_FS
    scripts/config --module CONFIG_UDF_FS
    scripts/config --module CONFIG_FUSE_FS
    scripts/config --module CONFIG_NFS_FS
    scripts/config --module CONFIG_NFSD
    scripts/config --module CONFIG_CIFS

    # --- Crypto acceleration ---
    scripts/config --module CONFIG_CRYPTO_AES_NI_INTEL
    scripts/config --module CONFIG_CRYPTO_SHA256_SSSE3
    scripts/config --module CONFIG_CRYPTO_SHA512_SSSE3

    # =========================================================================
    # Finalize configuration
    # =========================================================================
    log_step "Finalizing kernel configuration..."
    make olddefconfig

    # Display config summary
    log_info "Kernel configuration summary:"
    echo "  GRKERNSEC options:"
    grep -E "CONFIG_GRKERNSEC" .config 2>/dev/null | head -10 || echo "  (grsec not configured)"
    echo "  Security:"
    grep -E "CONFIG_SECURITY_SELINUX" .config || echo "  (SELinux status unknown)"
    echo "  Modules:"
    grep -E "CONFIG_MODULES=" .config || true
    echo "  Firmware loader:"
    grep -E "CONFIG_FW_LOADER=" .config || true

    # =========================================================================
    # Build kernel
    # =========================================================================
    log_step "Compiling kernel (this may take 30-90 minutes with grsec)..."
    log_info "Using MAKEFLAGS: $MAKEFLAGS"
    make $MAKEFLAGS

    # =========================================================================
    # Install modules
    # =========================================================================
    log_step "Installing kernel modules..."
    make INSTALL_MOD_PATH=$ROOKERY modules_install

    # Get the actual kernel version from the build
    ACTUAL_VERSION=$(make -s kernelrelease)
    log_info "Kernel version: $ACTUAL_VERSION"

    # Run depmod to generate module dependencies
    log_step "Running depmod..."
    depmod -a -b $ROOKERY "$ACTUAL_VERSION" || log_warn "depmod failed (may need to run after boot)"

    # =========================================================================
    # Install kernel
    # =========================================================================
    log_step "Installing kernel image..."
    mkdir -p $ROOKERY/boot

    cp -fv arch/x86/boot/bzImage $ROOKERY/boot/vmlinuz-$ACTUAL_VERSION
    cp -fv System.map $ROOKERY/boot/System.map-$ACTUAL_VERSION
    cp -fv .config $ROOKERY/boot/config-$ACTUAL_VERSION

    # Create symlinks
    rm -f $ROOKERY/boot/vmlinuz $ROOKERY/boot/System.map $ROOKERY/boot/config
    ln -sf vmlinuz-$ACTUAL_VERSION $ROOKERY/boot/vmlinuz
    ln -sf System.map-$ACTUAL_VERSION $ROOKERY/boot/System.map
    ln -sf config-$ACTUAL_VERSION $ROOKERY/boot/config

    # =========================================================================
    # Install linux-firmware
    # =========================================================================
    log_step "Installing linux-firmware..."
    # Support both .tar.gz and .tar.xz formats
    local firmware_tarball=""
    if ls $SOURCES_DIR/linux-firmware-*.tar.xz 1>/dev/null 2>&1; then
        firmware_tarball=$(ls $SOURCES_DIR/linux-firmware-*.tar.xz | head -1)
    elif ls $SOURCES_DIR/linux-firmware-*.tar.gz 1>/dev/null 2>&1; then
        firmware_tarball=$(ls $SOURCES_DIR/linux-firmware-*.tar.gz | head -1)
    fi

    if [ -n "$firmware_tarball" ]; then
        cd /tmp
        rm -rf linux-firmware-*
        tar -xf "$firmware_tarball"
        cd linux-firmware-*

        mkdir -p $ROOKERY/lib/firmware
        # Install all firmware files
        cp -a * $ROOKERY/lib/firmware/ 2>/dev/null || true

        FIRMWARE_SIZE=$(du -sh $ROOKERY/lib/firmware | cut -f1)
        log_info "Firmware installed to $ROOKERY/lib/firmware ($FIRMWARE_SIZE)"

        cd /tmp
        rm -rf linux-firmware-*
    else
        log_warn "linux-firmware tarball not found in $SOURCES_DIR"
        log_warn "Hardware drivers may not work without firmware"
    fi

    # =========================================================================
    # Configure automatic module loading
    # =========================================================================
    log_step "Configuring automatic module loading..."
    mkdir -p $ROOKERY/etc/modules-load.d

    cat > $ROOKERY/etc/modules-load.d/virtio.conf << "EOF"
# VirtIO modules for QEMU/KVM
virtio_pci
virtio_blk
virtio_net
virtio_console
EOF

    cat > $ROOKERY/etc/modules-load.d/usb.conf << "EOF"
# USB modules
xhci_hcd
ehci_hcd
uhci_hcd
usb_storage
EOF

    # =========================================================================
    # Cleanup
    # =========================================================================
    cd /
    rm -rf "$BUILD_DIR"

    # =========================================================================
    # Summary
    # =========================================================================
    log_info ""
    log_info "=========================================="
    log_info "Rookery OS Grsec Kernel Build Complete!"
    log_info "=========================================="
    log_info "Kernel:   $ROOKERY/boot/vmlinuz-$ACTUAL_VERSION"
    log_info "System.map: $ROOKERY/boot/System.map-$ACTUAL_VERSION"
    log_info "Config:   $ROOKERY/boot/config-$ACTUAL_VERSION"
    log_info "Modules:  $ROOKERY/lib/modules/$ACTUAL_VERSION"
    log_info "Firmware: $ROOKERY/lib/firmware"
    log_info ""
    log_info "Kernel size: $(du -h $ROOKERY/boot/vmlinuz-$ACTUAL_VERSION | cut -f1)"
    log_info "Modules size: $(du -sh $ROOKERY/lib/modules/$ACTUAL_VERSION 2>/dev/null | cut -f1 || echo 'N/A')"

    # Create global checkpoint (no source tarball to hash)
    create_global_checkpoint "linux-grsec" "kernel" "$KERNEL_VERSION"
    log_info "Kernel checkpoint created"

    exit 0
}

main "$@"
