#!/usr/bin/env python3
import pexpect
import sys
import time

# Start QEMU with emergency shell boot option
cmd = "qemu-system-x86_64 -m 4G -cdrom /mnt/c/Users/texas/rookpkg/dist/rookery-os-live.iso -boot d -nographic -serial mon:stdio -enable-kvm"
print("Starting QEMU - debugging getty/login")
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
        print(f"\nLogging in...")
        time.sleep(1)
        child.sendline("live")
        time.sleep(3)

        # Check for shell prompt
        result = child.expect(["root@", "bash-", "~]#", pexpect.TIMEOUT], timeout=15)
        if result < 3:
            print("\nGot shell! Debugging getty/login...")

            # Check getty process
            child.sendline("ps aux | grep -E 'getty|login|agetty'")
            time.sleep(2)

            # Check if systemd-logind is running (required for seat management)
            child.sendline("systemctl status systemd-logind")
            time.sleep(2)

            # Check journal for login errors
            child.sendline("journalctl -b | grep -iE 'login|pam|auth' | tail -30")
            time.sleep(3)

            # Check loginctl
            child.sendline("loginctl list-seats")
            time.sleep(1)
            child.sendline("loginctl list-sessions")
            time.sleep(1)

            # Try manually starting the getty
            child.sendline("systemctl start serial-getty@ttyS0.service")
            time.sleep(2)
            child.sendline("systemctl status serial-getty@ttyS0.service")
            time.sleep(2)

            try:
                child.expect([pexpect.TIMEOUT], timeout=5)
            except:
                pass

            buf = child.buffer if child.buffer else ""
            print(f"\nDebug output:\n{buf}")
        else:
            print(f"\nNo shell prompt")
    else:
        print(f"\nNo sulogin prompt")

except Exception as e:
    print(f"\nException: {e}")
finally:
    child.terminate()
    print("\nTest complete")
