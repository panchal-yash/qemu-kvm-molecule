#!/bin/bash
# Linux / Jenkins agent setup for the molecule + qemu harness.
# Run as the Jenkins user — apt-install steps invoke sudo internally so the
# venv and $HOME/qemu-images end up owned by the Jenkins user, not root.
# For macOS Apple Silicon use ./setup-arm.sh instead.

set -e

[ "$(uname)" = "Linux" ] || { echo "setup.sh is for Linux. On macOS use ./setup-arm.sh"; exit 1; }

VENV_DIR="${HOME}/.venv/molecule_qemu"
IMG_DIR="${HOME}/qemu-images"

echo "→ Installing OS packages (requires sudo)"
sudo apt-get update -y
sudo apt-get install -y qemu-system qemu-system-arm qemu-efi-aarch64 \
    python3 python3-venv python3-pip genisoimage wget git

if [ ! -f /usr/share/AAVMF/AAVMF_CODE.fd ] && [ ! -f /usr/share/qemu-efi-aarch64/QEMU_EFI.fd ]; then
    echo "ERROR: no arm64 UEFI firmware found after install"
    exit 1
fi

echo "→ Python venv at ${VENV_DIR}"
# Recreate if our pin floor changed (drops stale ansible-core 2.20+ from older runs)
if [ -f "${VENV_DIR}/bin/ansible" ]; then
    if "${VENV_DIR}/bin/python" -c \
        "import importlib.metadata as m; v=m.version('ansible-core'); raise SystemExit(0 if v.startswith('2.16') or v.startswith('2.17') else 1)" \
        2>/dev/null; then
        echo "  existing venv already on supported ansible-core, keeping"
    else
        echo "  existing venv has unsupported ansible-core, recreating"
        rm -rf "${VENV_DIR}"
    fi
fi
python3 -m venv "${VENV_DIR}"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip
pip install \
    "ansible-core>=2.16,<2.18" \
    "ansible-compat>=3,<4" \
    "molecule>=24.0,<25" \
    "molecule-plugins>=23.7.0,<24"
ansible-galaxy collection install ansible.posix community.general

if [ ! -f "${HOME}/.ssh/id_rsa" ]; then
    echo "→ Generating SSH key"
    ssh-keygen -t rsa -b 4096 -f "${HOME}/.ssh/id_rsa" -N ""
fi

echo "→ Preparing ${IMG_DIR}"
mkdir -p "${IMG_DIR}"
cd "${IMG_DIR}"

IMAGES=(
  "https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2 debian-11-genericcloud-amd64"
  "https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-arm64.qcow2 debian-11-genericcloud-arm64"
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2 debian-12-genericcloud-amd64"
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2 debian-12-genericcloud-arm64"
  "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 debian-13-genericcloud-amd64"
  "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2 debian-13-genericcloud-arm64"
  "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-amd64.img focal-server-cloudimg-amd64"
  "https://cloud-images.ubuntu.com/focal/current/focal-server-cloudimg-arm64.img focal-server-cloudimg-arm64"
  "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img jammy-server-cloudimg-amd64"
  "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img jammy-server-cloudimg-arm64"
  "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img noble-server-cloudimg-amd64"
  "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img noble-server-cloudimg-arm64"
  "https://download.rockylinux.org/pub/rocky/8/images/x86_64/Rocky-8-GenericCloud.latest.x86_64.qcow2 Rocky-8-GenericCloud.latest.x86_64"
  "https://download.rockylinux.org/pub/rocky/8/images/aarch64/Rocky-8-GenericCloud.latest.aarch64.qcow2 Rocky-8-GenericCloud.latest.aarch64"
  "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2 Rocky-9-GenericCloud.latest.x86_64"
  "https://download.rockylinux.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud.latest.aarch64.qcow2 Rocky-9-GenericCloud.latest.aarch64"
  "https://download.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2 Rocky-10-GenericCloud.latest.x86_64"
  "https://download.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-GenericCloud-Base.latest.aarch64.qcow2 Rocky-10-GenericCloud.latest.aarch64"
)

echo "→ Downloading and converting cloud images"
for entry in "${IMAGES[@]}"; do
    # shellcheck disable=SC2086
    set -- $entry
    url=$1
    base=$2
    src="${base}.qcow2"
    raw="${base}.raw"

    if [ ! -f "${raw}" ]; then
        if [ ! -f "${src}" ]; then
            echo "  downloading ${url}"
            wget -q --show-progress "${url}" -O "${src}"
        fi
        echo "  converting ${src} -> ${raw}"
        qemu-img convert -f qcow2 -O raw "${src}" "${raw}"
        # Conversion done — drop the .qcow2 source to save disk
        rm -f "${src}"
    else
        echo "  already present: ${raw}"
    fi
done

echo
echo "Setup complete."
echo "  source ${VENV_DIR}/bin/activate"
echo "  molecule test -s <scenario>"
