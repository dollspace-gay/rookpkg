#!/usr/bin/env python3
import pexpect
import sys
import time

# Start QEMU with emergency shell boot option
cmd = "qemu-system-x86_64 -m 4G -cdrom /mnt/c/Users/texas/rookpkg/dist/rookery-os-live.iso -boot d -nographic -serial mon:stdio -enable-kvm"
print("Starting QEMU - trying to get shell via emergency mode")
sys.stdout.flush()

child = pexpect.spawn(cmd, encoding="utf-8", timeout=180)

try:
    # Wait for SYSLINUX boot prompt
    result = child.expect(["boot:", "ISOLINUX", pexpect.TIMEOUT], timeout=30)
    if result < 2:
        print("\nGot boot prompt! Entering emergency mode...")
        time.sleep(1)
        child.sendline("emergency")

    # Wait for sulogin password prompt
    result = child.expect(["Enter root password", "root password", "password for", pexpect.TIMEOUT], timeout=120)

    if result < 3:
        print(f"\nGot sulogin password prompt!")
        time.sleep(1)
        # Send password
        child.sendline("live")
        time.sleep(3)

        # Check for shell prompt (after sulogin)
        result = child.expect(["root@", "bash-", ":/#", "# $", pexpect.TIMEOUT], timeout=15)
        if result < 4:
            print("\nGOT ROOT SHELL!")
            child.sendline("id")
            time.sleep(1)
            child.sendline("ls -la /etc/shadow")
            time.sleep(1)
            child.sendline("cat /etc/shadow | head -3")
            time.sleep(1)
            child.sendline("cat /etc/pam.d/login")
            time.sleep(2)
            try:
                child.expect([pexpect.TIMEOUT], timeout=3)
            except:
                pass
            buf = child.buffer if child.buffer else ""
            print(f"\nShell output:\n{buf}")
        else:
            print(f"\nNo shell prompt after password")
            buf = child.buffer if child.buffer else ""
            print(f"Buffer: {buf[:500]}")
    else:
        print(f"\nTimeout waiting for sulogin prompt")
        buf = child.buffer if child.buffer else ""
        print(f"Buffer: {buf[:500]}")

except Exception as e:
    print(f"\nException: {e}")
finally:
    child.terminate()
    print("\nTest complete")
