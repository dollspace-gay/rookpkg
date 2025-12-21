#!/usr/bin/env python3
import pexpect
import sys
import time

# Start QEMU with serial console
cmd = "qemu-system-x86_64 -m 4G -cdrom /mnt/c/Users/texas/rookpkg/dist/rookery-os-live.iso -boot d -nographic -serial mon:stdio -enable-kvm"
print("Starting QEMU - testing login")
sys.stdout.flush()

child = pexpect.spawn(cmd, encoding="utf-8", timeout=120)

try:
    # Wait for login prompt
    result = child.expect(["login:", pexpect.TIMEOUT], timeout=100)
    if result >= 1:
        print("\nNo login prompt found")
        child.terminate()
        sys.exit(1)

    print("\nGot login prompt!")
    time.sleep(1)

    # Try root login
    print("Testing root login...")
    child.sendline("root")
    time.sleep(3)

    # Wait for password prompt
    result = child.expect(["assword:", "Password:", pexpect.TIMEOUT], timeout=10)
    if result >= 2:
        print("NO PASSWORD PROMPT - login failing before password!")
        # Lets see what we got
        buf = child.buffer if child.buffer else ""
        print(f"Buffer: {repr(buf[:500])}")
    else:
        print("Got password prompt!")
        child.sendline("live")
        time.sleep(3)

        # Check for shell
        result = child.expect(["#", "incorrect", pexpect.TIMEOUT], timeout=10)
        if result == 0:
            print("\nROOT LOGIN SUCCESS!")
            child.sendline("id")
            time.sleep(1)
            try:
                child.expect([pexpect.TIMEOUT], timeout=2)
            except:
                pass
            buf = child.buffer if child.buffer else ""
            print(f"id output: {buf[:200]}")
        elif result == 1:
            print("\nLogin incorrect - password wrong?")
        else:
            print("\nTimeout after password")
            buf = child.buffer if child.buffer else ""
            print(f"Buffer: {repr(buf[:200])}")

except Exception as e:
    print(f"\nException: {e}")
finally:
    child.terminate()
    print("\nTest complete")
