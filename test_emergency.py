#!/usr/bin/env python3
import pexpect
import sys
import time

# Start QEMU with emergency shell boot option
# We'll interrupt boot and select emergency
cmd = "qemu-system-x86_64 -m 4G -cdrom /mnt/c/Users/texas/rookpkg/dist/rookery-os-live.iso -boot d -nographic -serial mon:stdio -enable-kvm"
print("Starting QEMU - trying to get shell via emergency mode")
sys.stdout.flush()

child = pexpect.spawn(cmd, encoding="utf-8", timeout=180)
child.logfile = sys.stdout

try:
    # Wait for SYSLINUX boot prompt
    result = child.expect(["boot:", "ISOLINUX", pexpect.TIMEOUT], timeout=30)
    if result < 2:
        print("\nGot boot prompt! Entering emergency mode...")
        time.sleep(1)
        # Type emergency boot option
        child.sendline("emergency")

    # Now wait for sulogin/shell prompt
    result = child.expect(["sulogin", "Give root password", "emergency", "maintenance", "#", pexpect.TIMEOUT], timeout=120)

    if result < 5:
        print(f"\nGot emergency prompt (match {result})!")
        # Try sending password
        child.sendline("live")
        time.sleep(3)

        # Check for shell
        result = child.expect(["#", pexpect.TIMEOUT], timeout=10)
        if result == 0:
            print("\nGOT ROOT SHELL!")
            child.sendline("id")
            time.sleep(1)
            child.sendline("cat /etc/shadow | head -2")
            time.sleep(1)
            child.sendline("ls -la /etc/shadow")
            time.sleep(1)
            try:
                child.expect([pexpect.TIMEOUT], timeout=3)
            except:
                pass
            print(f"\nOutput: {child.buffer[:500] if child.buffer else '(empty)'}")
        else:
            print(f"\nNo shell after password. Buffer: {child.buffer[:300] if child.buffer else ''}")
    else:
        print(f"\nTimeout waiting for emergency prompt")
        print(f"Buffer: {child.buffer[:500] if child.buffer else ''}")

except Exception as e:
    print(f"\nException: {e}")
finally:
    child.terminate()
    print("\nTest complete")
