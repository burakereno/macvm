import Foundation

public enum UbuntuSeed {
    public static func userData(record: VirtualMachineRecord, passwordHash: String, sshPublicKey: String? = nil) throws -> Data {
        guard let setup = record.ubuntuSetup else { throw VMError.message("Choose an Ubuntu setup profile.") }
        try setup.validate(record: record)
        try UbuntuSetup.validatePublicKey(sshPublicKey)
        guard passwordHash.range(of: #"^\$6\$rounds=[0-9]{4,7}\$[./A-Za-z0-9]{1,16}\$[./A-Za-z0-9]{86}$"#, options: .regularExpression) != nil else {
            throw VMError.message("Invalid account password hash.")
        }
        var user: [String: Any] = [
            "name": setup.username, "gecos": setup.username, "groups": ["adm", "sudo"], "shell": "/bin/bash",
            "lock_passwd": false, "hashed_passwd": passwordHash, "sudo": ["ALL=(ALL) ALL"]
        ]
        if let sshPublicKey, !sshPublicKey.isEmpty { user["ssh_authorized_keys"] = [sshPublicKey] }
        let files: [[String: Any]] = [
            ["path": "/usr/local/lib/macvm/setup.sh", "permissions": "0700", "content": script(record)],
            ["path": "/etc/systemd/system/mnt-macvmsetup.mount", "permissions": "0644", "content": mountUnit],
            ["path": "/etc/systemd/system/macvm-setup.service", "permissions": "0644", "content": setupUnit],
            ["path": "/usr/local/lib/macvm/retry.sh", "permissions": "0700", "content": retryScript],
            ["path": "/etc/systemd/system/macvm-retry.service", "permissions": "0644", "content": retryUnit]
        ]
        let data: [String: Any] = [
            "users": [user], "disable_root": true, "ssh_pwauth": false, "chpasswd": ["expire": false],
            "hostname": "macvm-" + record.id.uuidString.prefix(8).lowercased(), "preserve_hostname": false,
            "manage_etc_hosts": true, "locale": "en_US.UTF-8",
            "growpart": ["mode": "auto", "devices": ["/"], "ignore_growroot_disabled": true], "resize_rootfs": true,
            "write_files": files,
            "runcmd": [
                ["mkdir", "-p", "/mnt/macvmsetup"],
                ["systemctl", "daemon-reload"],
                ["systemctl", "enable", "mnt-macvmsetup.mount", "macvm-retry.service", "macvm-setup.service"],
                ["systemctl", "start", "mnt-macvmsetup.mount", "macvm-retry.service"],
                ["systemctl", "start", "--no-block", "macvm-setup.service"]
            ]
        ]
        return Data("#cloud-config\n".utf8) + (try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]))
    }

    public static func create(record: VirtualMachineRecord, directory: URL, passwordHash: String, sshPublicKey: String? = nil) throws {
        let manager = FileManager.default
        let seed = directory.appendingPathComponent(".seed-" + UUID().uuidString)
        try manager.createDirectory(at: seed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: seed) }
        try userData(record: record, passwordHash: passwordHash, sshPublicKey: sshPublicKey).write(to: seed.appendingPathComponent("user-data"), options: .atomic)
        let meta = try JSONSerialization.data(withJSONObject: ["instance-id": UbuntuProvisioning.instanceID(record)])
        try meta.write(to: seed.appendingPathComponent("meta-data"), options: .atomic)
        // Match the virtual Ethernet interface by name so a duplicated machine
        // can receive DHCP with its independently generated MAC address.
        let network: [String: Any] = ["version": 2, "ethernets": ["primary": ["match": ["name": "e*"], "dhcp4": true, "dhcp6": true]]]
        try JSONSerialization.data(withJSONObject: network).write(to: seed.appendingPathComponent("network-config"), options: .atomic)
        for name in ["user-data", "meta-data", "network-config"] {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seed.appendingPathComponent(name).path)
        }
        _ = try UbuntuImage.output("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "CIDATA", "-o", directory.appendingPathComponent("NoCloud.iso").path, seed.path])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("NoCloud.iso").path)
        try manager.createDirectory(at: UbuntuProvisioning.folder(in: directory), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    static let mountUnit = """
    [Unit]
    Description=MacVM setup status share
    Before=macvm-setup.service macvm-retry.service
    [Mount]
    What=macvm-setup
    Where=/mnt/macvmsetup
    Type=virtiofs
    Options=rw,nosuid,nodev,noexec
    [Install]
    WantedBy=multi-user.target
    """
    static let setupUnit = """
    [Unit]
    Description=MacVM Ubuntu setup
    Requires=mnt-macvmsetup.mount
    After=mnt-macvmsetup.mount network-online.target
    Wants=network-online.target
    [Service]
    Type=oneshot
    ExecStart=/usr/local/lib/macvm/setup.sh
    TimeoutStartSec=3600
    StandardOutput=append:/mnt/macvmsetup/Setup.log
    StandardError=append:/mnt/macvmsetup/Setup.log
    [Install]
    WantedBy=multi-user.target
    """
    static let retryScript = #"""
    #!/bin/sh
    while [ ! -f /var/lib/macvm/ready ]; do
      if [ -f /mnt/macvmsetup/Retry ]; then
        rm -f /mnt/macvmsetup/Retry
        systemctl reset-failed macvm-setup.service
        systemctl start --no-block macvm-setup.service
      fi
      sleep 3
    done
    """#
    static let retryUnit = """
    [Unit]
    Description=Retry MacVM Ubuntu setup
    Requires=mnt-macvmsetup.mount
    After=mnt-macvmsetup.mount
    [Service]
    Type=simple
    ExecStart=/usr/local/lib/macvm/retry.sh
    Restart=on-failure
    [Install]
    WantedBy=multi-user.target
    """

    static func script(_ record: VirtualMachineRecord) -> String {
        let setup = record.ubuntuSetup!
        return """
        #!/bin/bash
        set -euo pipefail
        ACCOUNT='\(setup.username)'
        PROFILE='\(setup.profile.rawValue)'
        DEVELOPMENT='\(setup.developmentTools ? "yes" : "no")'
        INSTANCE='\(UbuntuProvisioning.instanceID(record))'
        """ + "\n" + #"""
        export DEBIAN_FRONTEND=noninteractive
        STATE=/var/lib/macvm
        HOST=/mnt/macvmsetup
        mkdir -p "$STATE"
        status() {
          python3 - "$HOST" "$INSTANCE" "$1" <<'PY'
        import json, os, subprocess, sys, time
        folder, instance, stage = sys.argv[1:]
        ip = next((x for x in subprocess.getoutput('hostname -I').split() if '.' in x), None)
        value = dict(version=1, instanceID=instance, stage=stage, updatedAt=time.time(), ipv4=ip,
                     osVersion=subprocess.getoutput('lsb_release -ds').strip('"')[:80])
        temp = os.path.join(folder, 'Status.tmp')
        with open(temp, 'w') as f: json.dump(value, f)
        os.replace(temp, os.path.join(folder, 'Status.json'))
        PY
        }
        finished() {
          code=$?
          if [ "$code" -ne 0 ]; then
            echo "MacVM setup failed with exit code $code. Retry resumes completed steps."
            status failed || true
          fi
        }
        trap finished EXIT
        if [ -f "$STATE/ready" ]; then status ready; exit 0; fi
        status account
        test "$(id -u "$ACCOUNT")" -ge 1000
        test -d "/home/$ACCOUNT"
        test "$(getent passwd "$ACCOUNT" | cut -d: -f7)" = /bin/bash
        touch "$STATE/account.done"
        status packages
        if [ ! -f "$STATE/packages.done" ]; then
          dpkg --configure -a
          apt-get -o Acquire::Retries=3 update
          apt-get -o Acquire::Retries=3 install -y spice-vdagent openssh-server
          systemctl enable --now ssh
          touch "$STATE/packages.done"
        fi
        status desktop
        if [ ! -f "$STATE/desktop.done" ]; then
          dpkg --configure -a
          case "$PROFILE" in
            gnome)
              apt-get -o Acquire::Retries=3 install -y ubuntu-desktop-minimal
              mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
              printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
              printf '[org/gnome/desktop/interface]\nscaling-factor=uint32 2\n' > /etc/dconf/db/local.d/00-macvm-retina
              dconf update
              systemctl set-default graphical.target
              systemctl enable --now gdm3
              ;;
            xfce)
              printf 'lightdm shared/default-x-display-manager select lightdm\n' | debconf-set-selections
              apt-get -o Acquire::Retries=3 install -y xfce4 xfce4-terminal lightdm lightdm-gtk-greeter xserver-xorg dbus-x11
              mkdir -p "/home/$ACCOUNT/.config/autostart"
              cat > /usr/local/bin/macvm-display-settings <<'SCRIPT'
        #!/bin/sh
        marker="$HOME/.config/macvm-display-configured"
        if [ ! -e "$marker" ]; then
          xfconf-query -c xsettings -p /Gdk/WindowScalingFactor -n -t int -s 2
          touch "$marker"
        fi
        SCRIPT
              chmod 755 /usr/local/bin/macvm-display-settings
              printf '[Desktop Entry]\nType=Application\nName=MacVM display defaults\nExec=/usr/local/bin/macvm-display-settings\n' > "/home/$ACCOUNT/.config/autostart/macvm-display.desktop"
              chown -R "$ACCOUNT:$ACCOUNT" "/home/$ACCOUNT/.config"
              printf '/usr/sbin/lightdm\n' > /etc/X11/default-display-manager
              systemctl set-default graphical.target
              systemctl enable --now lightdm
              ;;
            server) systemctl set-default multi-user.target ;;
            *) exit 2 ;;
          esac
          touch "$STATE/desktop.done"
        fi
        status development
        if [ "$DEVELOPMENT" = yes ] && [ ! -f "$STATE/development.done" ]; then
          dpkg --configure -a
          apt-get -o Acquire::Retries=3 install -y git build-essential python3-venv nodejs npm docker.io docker-compose-v2
          systemctl enable --now docker
          touch "$STATE/development.done"
        fi
        status verification
        systemctl is-active --quiet ssh
        if [ "$PROFILE" = gnome ]; then systemctl is-active --quiet gdm3; fi
        if [ "$PROFILE" = xfce ]; then systemctl is-active --quiet lightdm; fi
        if [ "$DEVELOPMENT" = yes ]; then
          git --version; gcc --version; python3 --version; node --version; docker --version
          systemctl is-active --quiet docker
        fi
        apt-get clean
        touch "$STATE/ready"
        status ready
        echo 'MacVM Ubuntu setup completed.'
        """# + "\n"
    }
}
