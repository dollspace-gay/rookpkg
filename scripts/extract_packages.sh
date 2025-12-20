#!/bin/bash
set -e

ROOTFS=/home/rookery/rootfs
rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"

cd /home/rookery/specs

count=0
total=$(ls -1 *.rookpkg 2>/dev/null | wc -l)

echo "Extracting $total packages to $ROOTFS..."

for pkg in *.rookpkg; do
    if [ -f "$pkg" ] && tar -tf "$pkg" data.tar.zst >/dev/null 2>&1; then
        tar -xf "$pkg" -O data.tar.zst | zstd -d | tar -xf - -C "$ROOTFS" 2>/dev/null || true
        count=$((count + 1))
        if [ $((count % 50)) -eq 0 ]; then
            echo "  Progress: $count / $total"
        fi
    fi
done

echo ""
echo "Extracted $count packages"

# Create /lib64 with symlinks to the dynamic linker
# Required for binaries that expect ld-linux at /lib64/
echo "Creating /lib64 symlinks..."
mkdir -p "$ROOTFS/lib64"
ln -sf ../usr/lib/ld-linux-x86-64.so.2 "$ROOTFS/lib64/ld-linux-x86-64.so.2"
ln -sf ../usr/lib/ld-linux-x86-64.so.2 "$ROOTFS/lib64/ld-lsb-x86-64.so.3"

echo "Rootfs size: $(du -sh $ROOTFS | cut -f1)"
ls -la $ROOTFS/boot/vmlinuz* 2>/dev/null || echo "No kernel found!"
ls -la $ROOTFS/lib64/ 2>/dev/null || echo "No /lib64 directory!"
