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
echo "Rootfs size: $(du -sh $ROOTFS | cut -f1)"
ls -la $ROOTFS/boot/vmlinuz* 2>/dev/null || echo "No kernel found!"
