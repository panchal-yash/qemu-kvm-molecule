#!/bin/bash
# Boot an aarch64 cloud image under native KVM, ssh in, run an install script
# as root, shut down cleanly, and replace the source .raw in ~/qemu-images.
#
# Uses the same proven flags as molecule/shared/create.yml — pflash code+vars,
# bootindex on the disk, cidata seed as a virtio-blk-device. This is what works
# reliably on aarch64 + AAVMF; Packer's qemu builder defaults do not.
#
# Usage:
#   bake-aarch64.sh <image_basename> <ssh_user> <ssh_port> <install_script>
#
# where <image_basename> is e.g. "Rocky-8-GenericCloud.latest.aarch64" and the
# pristine source must already exist at $IMG_DIR/<image_basename>.qcow2 (Jenkins
# pipeline downloads it before calling this script).

set -euo pipefail

IMAGE_BASENAME="$1"
SSH_USER="$2"
SSH_PORT="$3"
INSTALL_SCRIPT="$4"

IMG_DIR="${IMG_DIR:-${HOME}/qemu-images}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"

SOURCE_QCOW2="${IMG_DIR}/${IMAGE_BASENAME}.qcow2"
NAME="bake-${IMAGE_BASENAME}"
WORK_DISK="/tmp/${NAME}.raw"
SEED_ISO="/tmp/${NAME}-seed.iso"
SEED_DIR="/tmp/${NAME}-seed"
VARS_FD="/tmp/${NAME}-vars.fd"
PIDFILE="/tmp/${NAME}.pid"
SERIAL_LOG="/tmp/${NAME}-serial.log"
STDERR_LOG="/tmp/${NAME}-stderr.log"

log()  { printf '\033[1;34m[bake]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[bake]\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$SOURCE_QCOW2" ] || die "missing $SOURCE_QCOW2 (download first)"
[ -f "${SSH_KEY}.pub" ] || die "missing ${SSH_KEY}.pub"

# Locate AAVMF firmware
if [ -f /usr/share/AAVMF/AAVMF_CODE.fd ]; then
    AAVMF_CODE=/usr/share/AAVMF/AAVMF_CODE.fd
    AAVMF_VARS=/usr/share/AAVMF/AAVMF_VARS.fd
elif [ -f /usr/share/qemu-efi-aarch64/QEMU_EFI.fd ]; then
    AAVMF_CODE=/usr/share/qemu-efi-aarch64/QEMU_EFI.fd
    AAVMF_VARS=/usr/share/qemu-efi-aarch64/QEMU_VARS.fd
else
    die "AAVMF firmware not found"
fi

cleanup() {
    if [ -f "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE" 2>/dev/null || true)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null || true
            sleep 2
            kill -9 "$PID" 2>/dev/null || true
        fi
    fi
    rm -f "$WORK_DISK" "$SEED_ISO" "$VARS_FD" "$PIDFILE" "$SERIAL_LOG" "$STDERR_LOG"
    rm -rf "$SEED_DIR"
}
trap cleanup EXIT

# ─── Stage writable disk ──────────────────────────────────────────────────────
log "Converting ${SOURCE_QCOW2} → ${WORK_DISK} (raw)"
qemu-img convert -f qcow2 -O raw "$SOURCE_QCOW2" "$WORK_DISK"
qemu-img resize -f raw "$WORK_DISK" 12G

# ─── Stage cloud-init seed ────────────────────────────────────────────────────
log "Generating cloud-init seed for ${SSH_USER}"
rm -rf "$SEED_DIR" && mkdir -p "$SEED_DIR"
PUBKEY="$(cat "${SSH_KEY}.pub")"
{
    printf '#cloud-config\n'
    printf 'users:\n'
    printf '  - name: %s\n' "$SSH_USER"
    printf '    sudo: ALL=(ALL) NOPASSWD:ALL\n'
    printf '    shell: /bin/bash\n'
    printf '    ssh_authorized_keys:\n'
    printf '      - %s\n' "$PUBKEY"
} > "$SEED_DIR/user-data"
{
    printf 'instance-id: %s\n' "$NAME"
    printf 'local-hostname: %s\n' "$NAME"
} > "$SEED_DIR/meta-data"
genisoimage -output "$SEED_ISO" -volid cidata -joliet -rock "$SEED_DIR" 2>/dev/null

# ─── Stage NVRAM ──────────────────────────────────────────────────────────────
cp -f "$AAVMF_VARS" "$VARS_FD"

# ─── Boot ─────────────────────────────────────────────────────────────────────
log "Booting ${NAME} on port ${SSH_PORT}"
qemu-system-aarch64 \
    -name "$NAME" \
    -M virt -enable-kvm -cpu host -m 2048 -smp 2 \
    -drive if=pflash,format=raw,readonly=on,file="$AAVMF_CODE" \
    -drive if=pflash,format=raw,file="$VARS_FD" \
    -drive file="$WORK_DISK",format=raw,if=none,id=disk0,cache=unsafe,aio=threads \
    -device virtio-blk-device,drive=disk0,bootindex=0 \
    -drive file="$SEED_ISO",format=raw,if=none,id=cdrom0,readonly=on \
    -device virtio-blk-device,drive=cdrom0,bootindex=1 \
    -netdev user,id=net0,hostfwd=tcp::"${SSH_PORT}"-:22 \
    -device virtio-net-device,netdev=net0 \
    -serial "file:${SERIAL_LOG}" \
    -daemonize -display none \
    -pidfile "$PIDFILE" \
    2> "$STDERR_LOG"

# ─── Wait for guest sshd ─────────────────────────────────────────────────────
log "Waiting up to 10 min for guest sshd banner"
deadline=$(( $(date +%s) + 600 ))
while (( $(date +%s) < deadline )); do
    banner=$(timeout 2 bash -c "cat </dev/tcp/127.0.0.1/${SSH_PORT}" 2>/dev/null | head -c 40 || true)
    if [[ "$banner" == SSH-* ]]; then
        log "Guest sshd up: $banner"
        break
    fi
    sleep 5
done
[[ "$banner" == SSH-* ]] || { log "stderr:"; cat "$STDERR_LOG" >&2; die "timeout waiting for sshd"; }

# Real SSH probe to confirm key was injected by cloud-init
log "Waiting for SSH key to land (cloud-init final stage)"
for i in $(seq 1 60); do
    if ssh -i "$SSH_KEY" -p "$SSH_PORT" \
           -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o BatchMode=yes -o ConnectTimeout=5 \
           "${SSH_USER}@127.0.0.1" true 2>/dev/null; then
        log "  SSH login succeeded"
        break
    fi
    sleep 5
done

# ─── Run install script ───────────────────────────────────────────────────────
log "Running install script ${INSTALL_SCRIPT}"
ssh -i "$SSH_KEY" -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@127.0.0.1" 'sudo bash -se' < "$INSTALL_SCRIPT"

# ─── Graceful shutdown ────────────────────────────────────────────────────────
log "Shutting down guest"
ssh -i "$SSH_KEY" -p "$SSH_PORT" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "${SSH_USER}@127.0.0.1" 'sudo shutdown -h now' || true

PID="$(cat "$PIDFILE")"
log "Waiting up to 2 min for qemu (pid ${PID}) to exit"
for i in $(seq 1 60); do
    kill -0 "$PID" 2>/dev/null || break
    sleep 2
done
if kill -0 "$PID" 2>/dev/null; then
    log "  qemu still alive, forcing"
    kill -9 "$PID" 2>/dev/null || true
fi

# ─── Publish ─────────────────────────────────────────────────────────────────
log "Publishing → ${IMG_DIR}/${IMAGE_BASENAME}.raw"
mv -f "$WORK_DISK" "${IMG_DIR}/${IMAGE_BASENAME}.raw"

log "Bake complete: ${IMG_DIR}/${IMAGE_BASENAME}.raw"
