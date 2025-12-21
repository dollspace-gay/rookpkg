#!/usr/bin/env python3
import pexpect
import sys
import time

# Start QEMU with normal boot
cmd = "qemu-system-x86_64 -m 4G -cdrom /mnt/c/Users/texas/rookpkg/dist/rookery-os-live.iso -boot d -nographic -serial mon:stdio -enable-kvm"
print("Starting QEMU - normal boot to test login")
sys.stdout.flush()

child = pexpect.spawn(cmd, encoding="utf-8", timeout=180)

try:
    # Let it boot normally (don't enter anything at boot prompt)
    result = child.expect(["login:", pexpect.TIMEOUT], timeout=120)
    if result >= 1:
        print("\nNo login prompt")
        sys.exit(1)

    print("\nGot login prompt! Sending root...")
    time.sleep(1)
    child.sendline("root")
    time.sleep(5)

    # The issue is no password prompt
    # Let's see what we get
    buf = child.buffer if child.buffer else ""
    print(f"\nAfter root username, buffer:\n{repr(buf)}")

    # Try to get rescue shell by sending some keys
    print("\nSending Ctrl+C to interrupt login...")
    child.sendcontrol('c')
    time.sleep(2)

    # Check if we can get to a shell somehow
    # Maybe login is hanging waiting for something?

    # Let's try keyboard input to see if it responds
    child.sendline("")
    time.sleep(1)
    buf = child.buffer if child.buffer else ""
    print(f"\nBuffer after empty line:\n{repr(buf)}")

except Exception as e:
    print(f"\nException: {e}")
finally:
    child.terminate()
    print("\nTest complete")
