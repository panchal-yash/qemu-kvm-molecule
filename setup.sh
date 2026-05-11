#!/bin/bash
# Provision the host for the molecule + qemu test harness.
#
#   ./setup.sh             — Jenkins/Linux agent setup (apt, libvirt-images path, all 9+1 OS images)
#   ./setup.sh --local     — local Apple Silicon macOS setup (brew, only debian12-arm64 image)
#
# After setup:
#   source ~/.venv/molecule_qemu/bin/activate
#   molecule create  -s <scenario>
#   molecule converge -s <scenario>
#   molecule destroy -s <scenario>

set -e

MODE="jenkins"
case "${1:-}" in
    --local|local) MODE="local" ;;
    "") MODE="jenkins" ;;
    *) echo "Usage: $0 [--local]"; exit 1 ;;
esac

VENV_DIR="${HOME}/.venv/molecule_qemu"
IMG_DIR=/var/lib/libvirt/images

ALL_IMAGES=(
  "https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2 debian-11-genericcloud-amd64"
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2 debian-12-genericcloud-amd64"
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2 debian-12-genericcloud-arm64"
  "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2 debian-13-genericcloud-amd64"
  "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img jammy-server-cloudimg-amd64"
  "https://cloud-images.ubuntu.com/releases/mantic/release/ubuntu-23.10-server-cloudimg-amd64.img mantic-server-cloudimg-amd64"
  "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img noble-server-cloudimg-amd64"
  "https://download.rockylinux.org/pub/rocky/8/images/x86_64/Rocky-8-GenericCloud.latest.x86_64.qcow2 Rocky-8-GenericCloud.latest.x86_64"
  "https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud.latest.x86_64.qcow2 Rocky-9-GenericCloud.latest.x86_64"
  "https://download.rockylinux.org/pub/rocky/10/images/x86_64/Rocky-10-GenericCloud-Base.latest.x86_64.qcow2 Rocky-10-GenericCloud.latest.x86_64"
)

LOCAL_IMAGES=(
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2 debian-12-genericcloud-arm64"
)

download_images() {
    # Usage: download_images <sudo_cmd_or_empty> <entry1> <entry2> ...
    # Each entry is "URL  raw_basename" (whitespace-separated single string).
    local sudo_cmd="$1"; shift
    $sudo_cmd mkdir -p "${IMG_DIR}"
    cd "${IMG_DIR}"

    local entry url base src raw
    for entry in "$@"; do
        # shellcheck disable=SC2086
        set -- $entry
        url=$1
        base=$2
        src="${base}.qcow2"
        raw="${base}.raw"

        if [ ! -f "${raw}" ]; then
            if [ ! -f "${src}" ]; then
                echo "Downloading ${url}"
                $sudo_cmd wget -q --show-progress "${url}" -O "${src}"
            fi
            echo "Converting ${src} -> ${raw}"
            $sudo_cmd qemu-img convert -f qcow2 -O raw "${src}" "${raw}"
        else
            echo "Already present: ${raw}"
        fi
    done
}

# ─── Jenkins / Linux path ─────────────────────────────────────────────────────
if [ "$MODE" = "jenkins" ]; then
    [ "$(uname)" = "Linux" ] || { echo "Default mode requires Linux. Use --local on macOS."; exit 1; }

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

    download_images "" "${ALL_IMAGES[@]}"

    echo
    echo "Jenkins setup complete."
    echo "  source ${VENV_DIR}/bin/activate"
    echo "  molecule test -s ubuntu22"
    exit 0
fi

# ─── Local macOS (Apple Silicon) path ─────────────────────────────────────────
[ "$(uname)" = "Darwin" ]    || { echo "--local mode requires macOS"; exit 1; }
[ "$(uname -m)" = "arm64" ]  || { echo "--local mode requires Apple Silicon (arm64); found $(uname -m)"; exit 1; }
command -v brew >/dev/null   || { echo "Homebrew required — see https://brew.sh"; exit 1; }

echo "→ Installing dependencies via Homebrew"
for pkg in qemu cdrtools wget python@3.12; do
    if brew list --versions "$pkg" >/dev/null 2>&1; then
        echo "  $pkg already installed"
    else
        brew install "$pkg"
    fi
done

# Provide a `genisoimage` symlink for parity with Linux create.yml
if ! command -v genisoimage >/dev/null 2>&1; then
    BREW_BIN="$(brew --prefix)/bin"
    if [ -x "${BREW_BIN}/mkisofs" ]; then
        ln -sf "${BREW_BIN}/mkisofs" "${BREW_BIN}/genisoimage"
        echo "  symlinked genisoimage -> mkisofs"
    fi
fi

echo "→ Python venv at ${VENV_DIR}"
PY="$(brew --prefix)/bin/python3.12"
[ -x "$PY" ] || PY="$(command -v python3)"
"$PY" -m venv "${VENV_DIR}"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip
pip install "molecule>=25.6.0" "molecule-plugins>=23.7.0" "ansible-core>=2.20.0"
ansible-galaxy collection install ansible.posix community.general

if [ ! -f "${HOME}/.ssh/id_rsa" ]; then
    echo "→ Generating SSH key"
    ssh-keygen -t rsa -b 4096 -f "${HOME}/.ssh/id_rsa" -N ""
fi

echo "→ Preparing ${IMG_DIR} (requires sudo)"
sudo mkdir -p "${IMG_DIR}"
# Owner stays root; user needs write access to drop the image
sudo chown "$(id -u):$(id -g)" "${IMG_DIR}"

echo "→ Downloading arm64 cloud images"
download_images "" "${LOCAL_IMAGES[@]}"

echo
echo "Local setup complete."
echo "  source ${VENV_DIR}/bin/activate"
echo "  molecule create  -s debian12-arm64"
echo "  molecule converge -s debian12-arm64"
echo "  molecule destroy -s debian12-arm64"
