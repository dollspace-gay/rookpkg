#!/usr/bin/env python3
import pexpect
import sys
import time

# Start QEMU with emergency shell boot option
cmd = "qemu-system-x86_64 -m 4G -cdrom /mnt/c/Users/texas/rookpkg/dist/rookery-os-live.iso -boot d -nographic -serial mon:stdio -enable-kvm"
print("Starting QEMU - getting shell to debug login")
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
        result = child.expect(["root@", "bash-", "~]#", pexpect.TIMEOUT], timeout=15)
        if result < 3:
            print("\nGot shell! Now debugging login...")

            # Check login binary
            child.sendline("ls -la /usr/bin/login")
            time.sleep(1)
            child.sendline("file /usr/bin/login")
            time.sleep(1)

            # Check if login is linked properly
            child.sendline("ldd /usr/bin/login 2>&1 | head -20")
            time.sleep(2)

            # Check PAM
            child.sendline("cat /etc/pam.d/login")
            time.sleep(1)

            # Check PAM modules exist
            child.sendline("ls -la /usr/lib/security/pam_unix.so")
            time.sleep(1)

            # Check getent
            child.sendline("getent passwd root")
            time.sleep(1)
            child.sendline("getent passwd live")
            time.sleep(1)

            # Try running login directly
            child.sendline("echo 'Testing login binary directly...'")
            time.sleep(1)

            # Check agetty status
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
