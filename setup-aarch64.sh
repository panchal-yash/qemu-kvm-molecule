#!/bin/bash
# Linux aarch64 Jenkins agent setup for the molecule + qemu harness.
# Downloads only the arm64 cloud images. Installs AAVMF (UEFI) firmware.
#
# For Linux amd64: use ./setup.sh
# For macOS Apple Silicon: use ./setup-arm.sh

set -e

[ "$(uname)" = "Linux" ]    || { echo "setup-aarch64.sh is for Linux."; exit 1; }
[ "$(uname -m)" = "aarch64" ] || { echo "setup-aarch64.sh is for aarch64 Linux; found $(uname -m). Use ./setup.sh on amd64."; exit 1; }

VENV_DIR="${HOME}/.venv/molecule_qemu"
IMG_DIR="${HOME}/qemu-images"

echo "→ Installing OS packages (requires sudo)"
sudo apt-get update -y
sudo apt-get install -y qemu-system-arm qemu-efi-aarch64 qemu-utils \
    python3 python3-venv python3-pip genisoimage wget git \
    apt-cacher-ng

# apt-cacher-ng listens on 0.0.0.0:3142. Guests reach it at 10.0.2.2:3142
# via SLIRP. Adds request-coalescing across parallel VMs hitting the same
# package URLs (apt + dnf — content-agnostic HTTP cache).
sudo systemctl enable --now apt-cacher-ng

# Cache HTTPS Percona repos by remapping client HTTP requests to HTTPS upstream.
# Without this, apt-cacher tunnels TLS without caching and the parallel-VM
# request-coalescing win is lost for percona-xtrabackup downloads.
if ! grep -q '^Remap-percona:' /etc/apt-cacher-ng/acng.conf 2>/dev/null; then
    echo "→ Adding Remap-percona rule to apt-cacher-ng"
    echo 'Remap-percona: http://repo.percona.com ; https://repo.percona.com' \
        | sudo tee -a /etc/apt-cacher-ng/acng.conf > /dev/null
fi

# Allow HTTPS CONNECT pass-through. Default apt-cacher policy returns 403
# for any HTTPS host not explicitly allowed, which breaks dnf on Rocky
# (mirrors.rockylinux.org is HTTPS). Pass-through is uncached but at
# least functional — Percona stays cached via the Remap rule above.
if ! grep -q '^PassThroughPattern:' /etc/apt-cacher-ng/acng.conf 2>/dev/null; then
    echo "→ Adding PassThroughPattern to apt-cacher-ng"
    echo 'PassThroughPattern: .*' \
        | sudo tee -a /etc/apt-cacher-ng/acng.conf > /dev/null
fi

sudo systemctl reload apt-cacher-ng || sudo systemctl restart apt-cacher-ng
echo "→ apt-cacher-ng status: $(systemctl is-active apt-cacher-ng)"

# tmpfs for per-VM disk overlays. Combined with qcow2-with-backing-file
# in create.yml, this means: read-only base image is shared across all
# VMs (one disk read serves 21 page-cache hits), and per-VM scratch
# writes go to RAM. Host disk is no longer the cliff for parallel runs.
TMPFS_DIR=/tmp/vm-overlays
TMPFS_SIZE=64G
sudo mkdir -p "${TMPFS_DIR}"
if ! mountpoint -q "${TMPFS_DIR}"; then
    echo "→ Mounting tmpfs at ${TMPFS_DIR} (${TMPFS_SIZE})"
    sudo mount -t tmpfs -o size=${TMPFS_SIZE},mode=1777 tmpfs "${TMPFS_DIR}"
else
    echo "→ tmpfs already mounted at ${TMPFS_DIR}"
fi

if [ ! -f /usr/share/AAVMF/AAVMF_CODE.fd ] && [ ! -f /usr/share/qemu-efi-aarch64/QEMU_EFI.fd ]; then
    echo "ERROR: no arm64 UEFI firmware found after install"
    exit 1
fi

echo "→ Python venv at ${VENV_DIR}"
python3 -m venv "${VENV_DIR}"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip
pip install "molecule>=25.6.0" "molecule-plugins>=23.7.0" "ansible-core>=2.20.0"
ansible-galaxy collection install ansible.posix community.general

if [ ! -f "${HOME}/.ssh/id_rsa" ]; then
    echo "→ Generating SSH key"
    ssh-keygen -t rsa -b 4096 -f "${HOME}/.ssh/id_rsa" -N ""
fi

echo "→ Preparing ${IMG_DIR}"
mkdir -p "${IMG_DIR}"
cd "${IMG_DIR}"

IMAGES=(
  "https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-arm64.qcow2 debian-11-genericcloud-arm64"
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2 debian-12-genericcloud-arm64"
  "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2 debian-13-genericcloud-arm64"
  "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-arm64.img jammy-server-cloudimg-arm64"
  "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64.img noble-server-cloudimg-arm64"
  "https://download.rockylinux.org/pub/rocky/9/images/aarch64/Rocky-9-GenericCloud.latest.aarch64.qcow2 Rocky-9-GenericCloud.latest.aarch64"
  "https://download.rockylinux.org/pub/rocky/10/images/aarch64/Rocky-10-GenericCloud-Base.latest.aarch64.qcow2 Rocky-10-GenericCloud.latest.aarch64"
)

echo "→ Downloading and converting arm64 cloud images"
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
        rm -f "${src}"
    else
        echo "  already present: ${raw}"
    fi
done

echo
echo "Setup complete (aarch64)."
echo "  source ${VENV_DIR}/bin/activate"
echo "  molecule test -s ubuntu24-arm64"
