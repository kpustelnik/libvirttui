#!/bin/bash

set -e

if [ $EUID -ne 0 ]; then
    echo "ERROR: Script must be run as root."
    exit 1
fi


if [[ ! "$0" == "/opt/libvirttui/setup.sh" ]]; then
    echo "ERROR: /opt/libvirttui does not exist - did you clone repository in this path?"
    exit 1
fi


if ! grep -q "Rocky Linux 10" /etc/os-release; then
    echo "ERROR: This software runs only on Rocky Linux 10."
    exit 1
fi


if ! which g++ &>/dev/null; then
    echo "ERROR: g++ is not installed."
    exit 1
fi


if ! which cargo &>/dev/null; then
    echo "ERROR: cargo is not installed."
    exit 1
fi


if ! rpm -q "libcap-ng-devel" &>/dev/null; then
    echo "ERROR: Package libcap-ng-devel is not installed."
    exit 1
fi


if ! rpm -q "libseccomp-devel" &>/dev/null; then
    echo "ERROR: Package libseccomp-devel is not installed."
    exit 1
fi

if [ ! -d "/opt/libvirttui/venv" ]; then
    echo "ERROR: Python virtual environment is not installed in /opt/libvirttui/venv."
    exit 1
fi


echo -n "Creating user... "
if ! grep -q "^libvirttui:" /etc/passwd; then
    useradd -d /opt/libvirttui --system libvirttui
    usermod -aG libvirt libvirttui
    echo "OK"
else
    usermod -aG libvirt libvirttui
    echo "ALREADY EXISTS"
fi


echo -n "SELinux module compilation... "

checkmodule -M -m -o /opt/libvirttui/assets/libvirttui.mod /opt/libvirttui/assets/libvirttui.te
semodule_package -o /opt/libvirttui/assets/libvirttui.pp -m /opt/libvirttui/assets/libvirttui.mod
semodule -X 300 -i /opt/libvirttui/assets/libvirttui.pp

echo "OK"


echo -n "Source code compilation... "

g++ /opt/libvirttui/assets/start_virtiofsd.cpp -o /opt/libvirttui/start_virtiofsd
g++ /opt/libvirttui/assets/libvirttui.cpp -o /usr/local/bin/libvirttui
g++ /opt/libvirttui/assets/fix_vnc.cpp -o /opt/libvirttui/fix_vnc
g++ /opt/libvirttui/assets/show_vnc.cpp -o /opt/libvirttui/show_vnc

echo "OK"

if ! which virtiofsd &>/dev/null; then
    echo -n "Virtiofsd not found. Downloading... "
    rm -r -f /opt/libvirttui/virtiofsd
    mkdir -p /opt/libvirttui/virtiofsd
    wget -q -P /opt/libvirttui/virtiofsd/ https://gitlab.com/virtio-fs/virtiofsd/-/archive/v1.10.1/virtiofsd-v1.10.1.tar.gz
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "ERROR: Cannot download virtiofsd from GitLab."
        exit 1
    fi
    tar -zxvf /opt/libvirttui/virtiofsd/virtiofsd-v1.10.1.tar.gz -C /opt/libvirttui/virtiofsd >/dev/null
    echo "OK"

    echo -n "Building virtiofsd... "
    cargo -q build --release --manifest-path /opt/libvirttui/virtiofsd/virtiofsd-v1.10.1/Cargo.toml --target-dir /opt/libvirttui/virtiofsd >/dev/null
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "ERROR: Cannot build virtiofsd."
        exit 1
    fi
    rm -f /usr/local/bin/virtiofsd
    cp /opt/libvirttui/virtiofsd/release/virtiofsd /usr/local/bin/
    echo "OK"
fi

echo -n "Creating files and directories... "

mkdir -p /opt/virt_data
mkdir -p /opt/virt_data/images
mkdir -p /opt/virt_data/vm

echo "" > /opt/libvirttui/debug.log

touch /opt/virt_data/images.json
touch /opt/virt_data/get_images_list.py
touch /opt/virt_data/get_images_list.log

/usr/bin/cp /opt/libvirttui/assets/vncviewer /usr/local/bin/vncviewer

echo "OK"


echo -n "Running chmods, chowns and selinux labels... "

chown -R libvirttui:libvirttui /opt/libvirttui
chown root:libvirttui /opt/libvirttui/start_virtiofsd
chown root:libvirttui /opt/libvirttui/fix_vnc
chown root:libvirttui /opt/libvirttui/show_vnc
chown libvirttui:qemu /opt/virt_data/vm
chown root:libvirttui /opt/virt_data/images.json
chown root:libvirttui /opt/virt_data/get_images_list.py
chown root:libvirttui /opt/virt_data/get_images_list.log
chown root:root /usr/local/bin/vncviewer

if grep -q "^uftp:" /etc/passwd; then
    chown uftp:libvirttui /opt/virt_data/images
else
    chown root:libvirttui /opt/virt_data/images
fi

chmod 700 /opt/libvirttui
chmod 4750 /opt/libvirttui/start_virtiofsd
chmod 4750 /opt/libvirttui/fix_vnc
chmod 4750 /opt/libvirttui/show_vnc
chmod -R 775 /opt/virt_data/images
chmod 775 /opt/virt_data/images.json
chmod 775 /opt/virt_data/get_images_list.py
chmod 770 /opt/virt_data/get_images_list.log
chmod 2770 /opt/virt_data/vm
chmod 4755 /usr/local/bin/libvirttui
chmod 755 /usr/local/bin/virtiofsd
chmod 755 /usr/local/bin/vncviewer

semanage fcontext -a -t virt_content_t "/opt/virt_data(/.*)?"
restorecon -R -v /opt/virt_data

echo "OK"


echo -n "Setting up crontab... "

if ! grep -q "remove_all_vms" /etc/crontab; then
    echo '@reboot libvirttui /opt/libvirttui/remove_all_vms.py > /opt/libvirttui/remove_all_vms.log' >> /etc/crontab
fi

if ! grep -q "rm -r -f /tmp/libvirttui_*" /etc/crontab; then
    echo '@reboot root sleep 10; rm -r -f /tmp/libvirttui_* > /dev/null' >> /etc/crontab
fi

if ! grep -q "get_images_list" /etc/crontab; then
    echo '@reboot libvirttui /opt/virt_data/get_images_list.py > /dev/null' >> /etc/crontab
fi

echo "OK"
