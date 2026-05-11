#!/bin/bash
# Local Apple Silicon (macOS arm64) setup for the molecule + qemu harness.
# Provisions: brew tools, python venv with molecule, SSH key, arm64 cloud images.
#
#   ./setup-arm.sh
#
# After setup:
#   source ~/.venv/molecule_qemu/bin/activate
#   cd molecule
#   molecule create  -s debian12-arm64
#   molecule converge -s debian12-arm64
#   molecule destroy -s debian12-arm64

set -e

VENV_DIR="${HOME}/.venv/molecule_qemu"
IMG_DIR="${HOME}/qemu-images"

IMAGES=(
  "https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-arm64.qcow2 debian-11-genericcloud-arm64"
  "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2 debian-12-genericcloud-arm64"
  "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-arm64.qcow2 debian-13-genericcloud-arm64"
)

# ─── Preconditions ────────────────────────────────────────────────────────────
[ "$(uname)" = "Darwin" ]    || { echo "macOS only"; exit 1; }
[ "$(uname -m)" = "arm64" ]  || { echo "Apple Silicon only; found $(uname -m)"; exit 1; }
command -v brew >/dev/null   || { echo "Homebrew required — see https://brew.sh"; exit 1; }

# ─── Brew deps ────────────────────────────────────────────────────────────────
echo "→ Installing Homebrew dependencies"
for pkg in qemu cdrtools wget python@3.12; do
    if brew list --versions "$pkg" >/dev/null 2>&1; then
        echo "  $pkg already installed"
    else
        brew install "$pkg"
    fi
done

# Provide `genisoimage` symlink for parity with Linux create.yml
if ! command -v genisoimage >/dev/null 2>&1; then
    BREW_BIN="$(brew --prefix)/bin"
    if [ -x "${BREW_BIN}/mkisofs" ]; then
        ln -sf "${BREW_BIN}/mkisofs" "${BREW_BIN}/genisoimage"
        echo "  symlinked genisoimage -> mkisofs"
    fi
fi

# ─── Python venv ──────────────────────────────────────────────────────────────
echo "→ Python venv at ${VENV_DIR}"
PY="$(brew --prefix)/bin/python3.12"
[ -x "$PY" ] || PY="$(command -v python3)"
"$PY" -m venv "${VENV_DIR}"
# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"
pip install --upgrade pip
pip install "molecule>=25.6.0" "molecule-plugins>=23.7.0" "ansible-core>=2.20.0"
ansible-galaxy collection install ansible.posix community.general

# ─── SSH key ──────────────────────────────────────────────────────────────────
if [ ! -f "${HOME}/.ssh/id_rsa" ]; then
    echo "→ Generating SSH key"
    ssh-keygen -t rsa -b 4096 -f "${HOME}/.ssh/id_rsa" -N ""
fi

# ─── Image directory (under $HOME — no sudo, persistent across reboots) ──────
mkdir -p "${IMG_DIR}"
echo "→ Using image directory ${IMG_DIR}"

# ─── Download cloud images ────────────────────────────────────────────────────
echo "→ Downloading arm64 cloud images"
cd "${IMG_DIR}"
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
    else
        echo "  already present: ${raw}"
    fi
done

echo
echo "Local arm64 setup complete."
echo "  source ${VENV_DIR}/bin/activate"
echo "  cd molecule"
echo "  molecule create  -s debian12-arm64    # or debian11-arm64 / debian13-arm64"
