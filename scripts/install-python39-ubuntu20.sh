#!/bin/bash
# Runs inside the Ubuntu 20.04 guest as root via ssh.
set -e

cloud-init status --wait || true
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3.9 python3.9-distutils python3.9-venv
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 100
update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.8 50
update-alternatives --set python3 /usr/bin/python3.9
python3 --version
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/log/cloud-init*.log
