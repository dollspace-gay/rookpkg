#!/usr/bin/env python3
import pexpect
import sys
import time

# Start QEMU with emergency shell boot option
cmd = "qemu-system-x86_64 -m 4G -cdrom /mnt/c/Users/texas/rookpkg/dist/rookery-os-live.iso -boot d -nographic -serial mon:stdio -enable-kvm"
print("Starting QEMU - debugging SDDM login failure")
sys.stdout.flush()

child = pexpect.spawn(cmd, encoding="utf-8", timeout=180)

try:
    # Wait for SYSLINUX boot prompt
    result = child.expect(["boot:", "ISOLINUX", pexpect.TIMEOUT], timeout=30)
    if result < 2:
        print("\nEntering emergency mode...")
        time.sleep(1)
        child.sendline("emergency")

    # Wait for sulogin password prompt
    result = child.expect(["Enter root password", "root password", pexpect.TIMEOUT], timeout=120)

    if result < 2:
        print(f"\nGot sulogin prompt, logging in...")
        time.sleep(1)
        child.sendline("live")
        time.sleep(3)

        # Check for shell prompt
        result = child.expect(["root@", "bash-", "~]#", "#", pexpect.TIMEOUT], timeout=15)
        if result < 4:
            print("\nGot shell! Checking SDDM and session issues...")

            # Check SDDM journal logs
            print("\n=== SDDM Journal Logs ===")
            child.sendline("journalctl -b -u sddm --no-pager | tail -50")
            time.sleep(3)

            # Check for session-related errors
            print("\n=== Session/Wayland Errors ===")
            child.sendline("journalctl -b | grep -iE 'sddm|wayland|plasma|kwin|session' | tail -30")
            time.sleep(3)

            # Check if XDG_RUNTIME_DIR exists for live user
            print("\n=== XDG Runtime Dir ===")
            child.sendline("ls -la /run/user/")
            time.sleep(1)

            # Check loginctl sessions
            print("\n=== Login Sessions ===")
            child.sendline("loginctl list-sessions")
            time.sleep(1)
            child.sendline("loginctl list-seats")
            time.sleep(1)

            # Check the plasma session file
            print("\n=== Plasma Session File ===")
            child.sendline("cat /usr/share/wayland-sessions/plasma.desktop")
            time.sleep(1)

            # Check if startplasma-wayland exists and what it does
            print("\n=== startplasma-wayland ===")
            child.sendline("file /usr/bin/startplasma-wayland")
            time.sleep(1)
            child.sendline("head -30 /usr/bin/startplasma-wayland 2>/dev/null || echo 'Binary file'")
            time.sleep(1)

            # Check SDDM config
            print("\n=== SDDM Config ===")
            child.sendline("cat /etc/sddm.conf")
            time.sleep(1)

            # Check for missing libraries or dependencies
            print("\n=== Check kwin_wayland ===")
            child.sendline("which kwin_wayland")
            time.sleep(1)
            child.sendline("ldd /usr/bin/kwin_wayland 2>&1 | grep -i 'not found'")
            time.sleep(2)

            # Check for GPU/DRM issues
            print("\n=== DRM/GPU Status ===")
            child.sendline("ls -la /dev/dri/")
            time.sleep(1)
            child.sendline("cat /sys/class/drm/*/status 2>/dev/null | head -10")
            time.sleep(1)

            # Check polkit status
            print("\n=== Polkit Status ===")
            child.sendline("systemctl status polkit --no-pager")
            time.sleep(2)

            # Check systemd-logind status
            print("\n=== systemd-logind Status ===")
            child.sendline("systemctl status systemd-logind --no-pager")
            time.sleep(2)

            # Try to read any sddm state files
            print("\n=== SDDM State ===")
            child.sendline("ls -la /var/lib/sddm/")
            time.sleep(1)
            child.sendline("cat /var/lib/sddm/state.conf 2>/dev/null || echo 'No state file'")
            time.sleep(1)

            try:
                child.expect([pexpect.TIMEOUT], timeout=3)
            except:
                pass

            buf = child.buffer if child.buffer else ""
            print(f"\n=== Debug Output ===\n{buf}")
        else:
            print(f"\nNo shell prompt")
            buf = child.buffer if child.buffer else ""
            print(f"Buffer: {buf[:500]}")
    else:
        print(f"\nNo sulogin prompt")
        buf = child.buffer if child.buffer else ""
        print(f"Buffer: {buf[:500]}")

except Exception as e:
    print(f"\nException: {e}")
finally:
    child.terminate()
    print("\nTest complete")
