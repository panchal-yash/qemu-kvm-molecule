#!/usr/bin/env bash
# Local QEMU+HVF arm64 test harness for Apple Silicon macOS.
# Builds and boots a Debian 12 arm64 cloud image with cloud-init, hostfwd SSH on 2240.
#
# Usage:
#   ./local.sh setup     # install deps, download image, prepare cloud-init seed
#   ./local.sh boot      # launch qemu (foreground, serial on this terminal)
#   ./local.sh boot-bg   # launch qemu daemonized
#   ./local.sh ssh       # ssh into the running VM
#   ./local.sh destroy   # kill VM, remove disks + seed
#   ./local.sh status    # show pid, ssh port, banner status
#
# All state lives under ${WORKDIR} (default ~/.local-qemu-arm64).

# Intentionally not using `set -e` here: brew/qemu quirks can return non-zero
# in subtle ways that we want to recover from rather than die silently.
set -u
set -o pipefail

trap 'rc=$?; printf "\033[1;31m[local.sh]\033[0m aborted at line %d (rc=%d): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR
set -E

WORKDIR="${WORKDIR:-$HOME/.local-qemu-arm64}"
IMG_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2"
IMG_BASE="$WORKDIR/debian-12-arm64-base.qcow2"
DISK="$WORKDIR/disk.raw"
SEED_DIR="$WORKDIR/seed"
SEED_ISO="$WORKDIR/seed.iso"
VARS="$WORKDIR/vars.fd"
PIDFILE="$WORKDIR/qemu.pid"
SERIAL_LOG="$WORKDIR/serial.log"
STDERR_LOG="$WORKDIR/stderr.log"
SSH_PORT="${SSH_PORT:-2240}"
MEM="${MEM:-2048}"
CPUS="${CPUS:-2}"
DISK_SIZE="${DISK_SIZE:-20G}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"

BREW_QEMU_SHARE="/opt/homebrew/share/qemu"
EDK2_CODE=""
EDK2_VARS=""

log()   { printf '\033[1;34m[local.sh]\033[0m %s\n' "$*"; }
step()  { printf '\033[1;36m[local.sh]\033[0m → %s\n' "$*"; }
warn()  { printf '\033[1;33m[local.sh]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[local.sh]\033[0m %s\n' "$*" >&2; exit 1; }

require_apple_silicon() {
    [[ "$(uname)" == "Darwin" ]] || die "macOS only — found $(uname)"
    [[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon only — found $(uname -m)"
}

detect_edk2_paths() {
    EDK2_CODE=""
    EDK2_VARS=""
    if [[ -f "$BREW_QEMU_SHARE/edk2-aarch64-code.fd" ]]; then
        EDK2_CODE="$BREW_QEMU_SHARE/edk2-aarch64-code.fd"
    elif [[ -f "$BREW_QEMU_SHARE/edk2-aarch64-secure-code.fd" ]]; then
        EDK2_CODE="$BREW_QEMU_SHARE/edk2-aarch64-secure-code.fd"
    fi

    if [[ -f "$BREW_QEMU_SHARE/edk2-arm-vars.fd" ]]; then
        EDK2_VARS="$BREW_QEMU_SHARE/edk2-arm-vars.fd"
    elif [[ -f "$BREW_QEMU_SHARE/edk2-aarch64-vars.fd" ]]; then
        EDK2_VARS="$BREW_QEMU_SHARE/edk2-aarch64-vars.fd"
    fi

    [[ -n "$EDK2_CODE" && -n "$EDK2_VARS" ]] \
        || die "edk2 firmware not found under $BREW_QEMU_SHARE — reinstall qemu (brew reinstall qemu)"
}

ensure_dep() {
    local pkg="$1"
    if brew list --formula --versions "$pkg" >/dev/null 2>&1; then
        log "  $pkg already installed"
        return 0
    fi
    step "  installing $pkg"
    brew install "$pkg" || die "brew install $pkg failed"
}

cmd_setup() {
    require_apple_silicon

    step "Checking Homebrew"
    command -v brew >/dev/null 2>&1 || die "Homebrew missing — see https://brew.sh"
    log "  brew prefix: $(brew --prefix)"

    step "Installing dependencies"
    ensure_dep qemu
    ensure_dep cdrtools
    ensure_dep wget

    step "Locating AAVMF firmware"
    detect_edk2_paths
    log "  code: $EDK2_CODE"
    log "  vars: $EDK2_VARS"

    step "Preparing workdir $WORKDIR"
    mkdir -p "$WORKDIR" "$SEED_DIR" || die "could not create $WORKDIR"
    log "  ok"

    step "SSH key"
    if [[ -f "$SSH_KEY" ]]; then
        log "  $SSH_KEY exists"
    else
        log "  generating $SSH_KEY"
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N "" -q || die "ssh-keygen failed"
    fi
    [[ -f "${SSH_KEY}.pub" ]] || die "${SSH_KEY}.pub missing after keygen"

    step "Base cloud image"
    if [[ -f "$IMG_BASE" ]]; then
        log "  $IMG_BASE exists ($(du -h "$IMG_BASE" | awk '{print $1}'))"
    else
        log "  downloading $IMG_URL"
        curl -L --fail --progress-bar "$IMG_URL" -o "$IMG_BASE" \
            || die "download failed: $IMG_URL"
    fi

    step "Converting to raw + resizing to $DISK_SIZE"
    if [[ -f "$DISK" ]]; then
        log "  $DISK exists"
    else
        qemu-img convert -f qcow2 -O raw "$IMG_BASE" "$DISK" || die "qemu-img convert failed"
        qemu-img resize -f raw "$DISK" "$DISK_SIZE" || die "qemu-img resize failed"
        log "  ok"
    fi

    step "Cloud-init seed"
    local pubkey
    pubkey="$(cat "${SSH_KEY}.pub")" || die "could not read ${SSH_KEY}.pub"
    {
        printf '#cloud-config\n'
        printf 'users:\n'
        printf '  - name: debian\n'
        printf '    sudo: ALL=(ALL) NOPASSWD:ALL\n'
        printf '    shell: /bin/bash\n'
        printf '    ssh_authorized_keys:\n'
        printf '      - %s\n' "$pubkey"
    } > "$SEED_DIR/user-data" || die "could not write user-data"

    {
        printf 'instance-id: local-debian12-arm64\n'
        printf 'local-hostname: local-debian12-arm64\n'
    } > "$SEED_DIR/meta-data" || die "could not write meta-data"

    mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock "$SEED_DIR" 2>/dev/null \
        || die "mkisofs failed"
    log "  $SEED_ISO ($(du -h "$SEED_ISO" | awk '{print $1}'))"

    step "EFI NVRAM"
    if [[ -f "$VARS" ]]; then
        log "  $VARS exists"
    else
        cp "$EDK2_VARS" "$VARS" || die "could not copy NVRAM template"
        log "  initialized from $EDK2_VARS"
    fi

    echo
    log "Setup complete. Next: ./local.sh boot-bg"
}

assert_setup_done() {
    [[ -f "$DISK"     ]] || die "Missing $DISK     — run ./local.sh setup"
    [[ -f "$SEED_ISO" ]] || die "Missing $SEED_ISO — run ./local.sh setup"
    [[ -f "$VARS"     ]] || die "Missing $VARS     — run ./local.sh setup"
}

cmd_boot() {
    require_apple_silicon
    detect_edk2_paths
    assert_setup_done

    log "Booting (foreground; exit serial with Ctrl-A x)"
    exec qemu-system-aarch64 \
        -name local-debian12-arm64 \
        -M virt -accel hvf -cpu host -m "$MEM" -smp "$CPUS" \
        -drive if=pflash,format=raw,readonly=on,file="$EDK2_CODE" \
        -drive if=pflash,format=raw,file="$VARS" \
        -drive file="$DISK",format=raw,if=none,id=disk0,cache=unsafe \
        -device virtio-blk-device,drive=disk0,bootindex=0 \
        -drive file="$SEED_ISO",format=raw,if=none,id=cdrom0,readonly=on \
        -device virtio-blk-device,drive=cdrom0,bootindex=1 \
        -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 \
        -device virtio-net-device,netdev=net0 \
        -nographic
}

cmd_boot_bg() {
    require_apple_silicon
    detect_edk2_paths
    assert_setup_done

    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        warn "VM already running (pid $(cat "$PIDFILE")). Use ./local.sh destroy first."
        return 1
    fi
    rm -f "$PIDFILE" "$SERIAL_LOG" "$STDERR_LOG"

    step "Starting daemonized qemu"
    qemu-system-aarch64 \
        -name local-debian12-arm64 \
        -M virt -accel hvf -cpu host -m "$MEM" -smp "$CPUS" \
        -drive if=pflash,format=raw,readonly=on,file="$EDK2_CODE" \
        -drive if=pflash,format=raw,file="$VARS" \
        -drive file="$DISK",format=raw,if=none,id=disk0,cache=unsafe \
        -device virtio-blk-device,drive=disk0,bootindex=0 \
        -drive file="$SEED_ISO",format=raw,if=none,id=cdrom0,readonly=on \
        -device virtio-blk-device,drive=cdrom0,bootindex=1 \
        -netdev user,id=net0,hostfwd=tcp::"$SSH_PORT"-:22 \
        -device virtio-net-device,netdev=net0 \
        -serial "file:$SERIAL_LOG" \
        -daemonize -display none \
        -pidfile "$PIDFILE" \
        2> "$STDERR_LOG"
    local rc=$?

    if (( rc != 0 )); then
        warn "qemu exited with rc=$rc. stderr:"
        [[ -s "$STDERR_LOG" ]] && cat "$STDERR_LOG" >&2 || warn "(stderr empty)"
        return $rc
    fi
    if [[ ! -f "$PIDFILE" ]]; then
        warn "qemu rc=0 but no pidfile written. stderr:"
        [[ -s "$STDERR_LOG" ]] && cat "$STDERR_LOG" >&2 || warn "(stderr empty)"
        return 1
    fi

    log "Started. pid=$(cat "$PIDFILE")  ssh port=$SSH_PORT"
    step "Waiting up to 120s for guest sshd banner"
    local deadline=$(( $(date +%s) + 120 ))
    while (( $(date +%s) < deadline )); do
        if kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
            local banner
            banner=$(timeout 2 bash -c "cat </dev/tcp/127.0.0.1/$SSH_PORT" 2>/dev/null | head -c 50)
            if [[ "$banner" == SSH-* ]]; then
                log "Guest sshd ready: $banner"
                log "Next: ./local.sh ssh"
                return 0
            fi
        else
            warn "qemu died after launch — check $SERIAL_LOG and $STDERR_LOG"
            return 1
        fi
        sleep 3
    done
    warn "Timed out waiting for sshd. Check $SERIAL_LOG"
    return 1
}

cmd_ssh() {
    if [[ ! -f "$PIDFILE" ]] || ! kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        die "VM not running. ./local.sh boot-bg first."
    fi
    exec ssh -p "$SSH_PORT" \
        -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        debian@127.0.0.1
}

cmd_destroy() {
    if [[ -f "$PIDFILE" ]]; then
        local pid
        pid="$(cat "$PIDFILE" 2>/dev/null)"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            log "Killing qemu pid $pid"
            kill "$pid" 2>/dev/null
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$PIDFILE"
    fi
    log "Removing disk, seed, NVRAM, logs"
    rm -f "$DISK" "$SEED_ISO" "$VARS" "$SERIAL_LOG" "$STDERR_LOG"
    rm -rf "$SEED_DIR"
    log "Destroyed. Base image kept at $IMG_BASE."
}

cmd_status() {
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        log "VM running (pid $(cat "$PIDFILE"))  ssh port $SSH_PORT"
    else
        log "VM not running"
    fi
    [[ -f "$SERIAL_LOG" ]] && log "Serial log: $SERIAL_LOG ($(wc -l < "$SERIAL_LOG" | xargs) lines)"
    [[ -s "$STDERR_LOG" ]] && log "stderr non-empty: $STDERR_LOG"
    if timeout 2 bash -c "cat </dev/tcp/127.0.0.1/$SSH_PORT" 2>/dev/null \
       | head -c 20 | grep -q '^SSH-'; then
        log "Guest sshd: responding"
    fi
}

case "${1:-}" in
    setup)         cmd_setup ;;
    boot)          cmd_boot ;;
    boot-bg)       cmd_boot_bg ;;
    ssh)           cmd_ssh ;;
    destroy)       cmd_destroy ;;
    status)        cmd_status ;;
    ""|-h|--help)
        sed -n '2,15p' "$0"
        ;;
    *)
        die "Unknown subcommand: $1 (try: setup, boot, boot-bg, ssh, destroy, status)"
        ;;
esac
