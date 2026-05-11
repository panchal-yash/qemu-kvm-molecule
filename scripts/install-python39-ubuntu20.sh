#!/bin/bash
# Runs inside the Ubuntu 20.04 guest as root via ssh.
#
# Important: we DO NOT switch /usr/bin/python3 to 3.9 via update-alternatives.
# Ubuntu's apt post-update hook (cnf-update-db) is `#!/usr/bin/python3` and
# depends on apt_pkg, which only exists as a C extension for 3.8. Switching
# the default breaks every subsequent apt operation. Instead we install 3.9
# side-by-side and let molecule point ansible_python_interpreter at it.
set -e

# Repair preflight: if a prior (broken) bake left /usr/bin/python3 pointing at
# 3.9 via update-alternatives, undo it so apt's hooks work again.
if [ -L /etc/alternatives/python3 ]; then
    target="$(readlink -f /etc/alternatives/python3 2>/dev/null || true)"
    if [ "$target" != "/usr/bin/python3.8" ] && [ -x /usr/bin/python3.8 ]; then
        echo "Repairing /usr/bin/python3 → 3.8 (was ${target})"
        update-alternatives --remove-all python3 2>/dev/null || true
        ln -sf /usr/bin/python3.8 /usr/bin/python3
    fi
fi
# Sanity: is apt's python3 importable for apt_pkg?
/usr/bin/python3 -c "import apt_pkg" 2>/dev/null \
    || { echo "WARNING: /usr/bin/python3 cannot import apt_pkg"; /usr/bin/python3 --version; }

cloud-init status --wait || true
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3.9 python3.9-distutils python3.9-venv
/usr/bin/python3.9 --version
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/log/cloud-init*.log
