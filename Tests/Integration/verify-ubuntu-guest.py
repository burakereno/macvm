#!/usr/bin/env python3
"""Verify an owned disposable VM. Credentials are read from a private file, never argv."""
import ctypes, ipaddress, json, pathlib, shlex, subprocess, sys

root = pathlib.Path(sys.argv[1]).resolve()
machine = pathlib.Path((root / "MachinePath").read_text()).resolve()
assert machine.parent == root and machine.suffix == ".macvm"
status = json.loads((machine / "Provisioning" / "Status.json").read_text())
address = ipaddress.ip_address(status["ipv4"])
assert address in ipaddress.ip_network("192.168.64.0/24")
base = ["ssh", "-i", str(root / "test-key"), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=" + str(root / "known_hosts"), "macvmtest@" + str(address)]

def remote(command, data=None):
    result = subprocess.run(base + ["set -eu; " + command], input=data, text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise RuntimeError("Guest check failed: " + result.stdout[-2000:] + result.stderr[-1000:])
    print(result.stdout.strip())
    return result.stdout

remote("cloud-init status --wait; test $(id -un) = macvmtest; test $(id -u) -ge 1000; test -d /home/macvmtest; df -h /; test $(df -B1 --output=size / | tail -1) -ge 25000000000; systemctl is-active ssh; dpkg-query -W spice-vdagent")
credential = (root / "TestCredential").read_text()
verification = """import ctypes,sys
password=sys.stdin.readline().strip().encode()
entry=next(x.split(':')[1] for x in open('/etc/shadow') if x.startswith('macvmtest:'))
lib=ctypes.CDLL('libcrypt.so.1');lib.crypt.argtypes=[ctypes.c_char_p,ctypes.c_char_p];lib.crypt.restype=ctypes.c_char_p
assert lib.crypt(password,entry.encode()).decode()==entry
assert entry.startswith('$6$rounds=500000$')
print('PASS: requested password verifies against the guest shadow hash; password sudo works')
"""
remote("sudo -S -p '' python3 -c " + shlex.quote(verification), credential + "\n" + credential + "\n")
print("PASS: account, cloud-init, disk growth, SSH and guest tools")
