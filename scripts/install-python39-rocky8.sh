#!/bin/bash
# Runs inside the Rocky 8 guest as root via ssh.
set -e

cloud-init status --wait || true
dnf install -y python39 python3-libselinux
alternatives --set python3 /usr/bin/python3.9 || true
python3 --version
dnf clean all
rm -rf /var/cache/dnf /tmp/* /var/tmp/* /var/log/cloud-init*.log
