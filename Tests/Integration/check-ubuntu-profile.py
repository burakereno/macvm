#!/usr/bin/env python3
"""Profile checks and optional graphical fixture login, only in owned test VMs."""
import ipaddress, json, pathlib, shlex, subprocess, sys
root = pathlib.Path(sys.argv[1]).resolve()
machine = pathlib.Path((root / "MachinePath").read_text()).resolve()
assert machine.parent == root and machine.suffix == ".macvm"
record = json.loads((machine / "Config.json").read_text())
setup = record["ubuntuSetup"]
status = json.loads((machine / "Provisioning/Status.json").read_text())
assert status["stage"] == "ready"
address = ipaddress.ip_address(status["ipv4"])
assert address in ipaddress.ip_network("192.168.64.0/24")
base = ["ssh", "-i", str(root / "test-key"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=" + str(root / "known_hosts"),
        "macvmtest@" + str(address)]
credential = (root / "TestCredential").read_text()

def remote(command, sudo=False):
    command = ("sudo -S -p '' bash -eu -c " + shlex.quote(command)) if sudo else "set -eu; " + command
    result = subprocess.run(base + [command], input=(credential + "\n") if sudo else None,
                            text=True, capture_output=True, timeout=180)
    if result.returncode: raise RuntimeError(result.stdout[-3000:] + result.stderr[-1000:])
    print(result.stdout.strip())

if setup["profile"] == "gnome":
    remote("systemctl is-active gdm3; dpkg-query -W ubuntu-desktop-minimal; test \"$(dbus-run-session -- gsettings get org.gnome.desktop.interface scaling-factor)\" = 'uint32 2'; uname -r")
    if "--autologin" in sys.argv:
        remote("cp /etc/gdm3/custom.conf /etc/gdm3/custom.conf.macvm-test; printf '[daemon]\\nAutomaticLoginEnable=true\\nAutomaticLogin=macvmtest\\n' > /etc/gdm3/custom.conf; systemctl restart gdm3", sudo=True)
elif setup["profile"] == "xfce":
    remote("systemctl is-active lightdm; dpkg-query -W xfce4; test -f ~/.config/autostart/macvm-display.desktop; uname -r")
    if "--autologin" in sys.argv:
        remote("mkdir -p /etc/lightdm/lightdm.conf.d; printf '[Seat:*]\\nautologin-user=macvmtest\\nautologin-user-timeout=0\\n' > /etc/lightdm/lightdm.conf.d/90-macvm-disposable-test.conf; systemctl restart lightdm", sudo=True)
if setup["developmentTools"]:
    remote("git --version; gcc --version; python3 -m venv /tmp/macvm-venv-test; /tmp/macvm-venv-test/bin/python -c 'print(1+1)'; rm -rf /tmp/macvm-venv-test; node -e 'console.log(1+1)'; npm --version")
    remote("docker info --format '{{.Architecture}}'; docker compose version; docker run --rm hello-world", sudo=True)
print("PASS: selected profile, display defaults and requested development tools")
