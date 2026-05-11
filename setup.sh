#!/bin/bash
# Linux / Jenkins agent setup for the molecule + qemu harness.
# Installs apt deps, builds python venv with molecule, downloads cloud images.
# For macOS Apple Silicon use ./setup-arm.sh instead.

set -e

[ "$(uname)" = "Linux" ] || { echo "setup.sh is for Linux. On macOS use ./setup-arm.sh"; exit 1; }

VENV_DIR="${HOME}/.venv/molecule_qemu"
IMG_DIR=/var/lib/libvirt/images

apt-get update -y
apt-get install -y qemu-system qemu-system-arm qemu-efi-aarch64 \
    python3 python3-venv python3-pip genisoimage \
    libvirt-clients libvirt-daemon-system wget

if [ ! -f /usr/share/AAVMF/AAVMF_CODE.fd ] && [ ! -f /usr/share/qemu-efi-aarch64/QEMU_EFI.fd ]; then
    echo "ERROR: no arm64 UEFI firmware found after install"
    exit 1
fi

systemctl enable --now libvirtd

python3 -m venv "${VENV_DIR}"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip
pip install "molecule>=25.6.0" "molecule-plugins>=23.7.0" "ansible-core>=2.20.0"
ansible-galaxy collection install ansible.posix community.general

if [ ! -f "${HOME}/.ssh/id_rsa" ]; then
    ssh-keygen -t rsa -b 4096 -f "${HOME}/.ssh/id_rsa" -N ""
fi

mkdir -p "${IMG_DIR}"
cd "${IMG_DIR}"

IMAGES=(
  "https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2 debian-11-genericcloud-amd64"
  "https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-arm64.qcow2 debian-11-genericcloud-arm64"
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2 debian-12-genericcloud-amd64"
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2 debian-12-genericcloud-arm64"
  "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 debian-13-genericcloud-amd64"
  "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2 debian-13-genericcloud-arm64"
  "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img jammy-server-cloudimg-amd64"
  "https://cloud-images.ubuntu.com/releases/mantic/release/ubuntu-23.10-server-cloudimg-amd64.img mantic-server-cloudimg-amd64"
  "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img noble-server-cloudimg-amd64"
  "https://download.rockylinux.org/pub/rocky/8/images/x86_64/Rocky-8-GenericCloud.latest.x86_64.qcow2 Rocky-8-GenericCloud.latest.x86_64"
  "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2 Rocky-9-GenericCloud.latest.x86_64"
  "https://download.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2 Rocky-10-GenericCloud.latest.x86_64"
)

for entry in "${IMAGES[@]}"; do
    # shellcheck disable=SC2086
    set -- $entry
    url=$1
    base=$2
    src="${base}.qcow2"
    raw="${base}.raw"

    if [ ! -f "${raw}" ]; then
        if [ ! -f "${src}" ]; then
            echo "Downloading ${url}"
            wget -q --show-progress "${url}" -O "${src}"
        fi
        echo "Converting ${src} -> ${raw}"
        qemu-img convert -f qcow2 -O raw "${src}" "${raw}"
    else
        echo "Already present: ${raw}"
    fi
done

echo
echo "Setup complete."
echo "  source ${VENV_DIR}/bin/activate"
echo "  molecule test -s ubuntu22"
