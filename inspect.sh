#!/usr/bin/env bash
# Diagnostic for the local.sh arm64 harness on Apple Silicon macOS.
# Runs read-only checks: host, brew, qemu, firmware, workdir, vm state.
# Exits 0 if every check passes; non-zero if any failed.
#
# Usage:
#   ./inspect.sh           # full report
#   ./inspect.sh --quiet   # only print FAIL lines
#   ./inspect.sh --json    # machine-readable summary at end

WORKDIR="${WORKDIR:-$HOME/.local-qemu-arm64}"
SSH_PORT="${SSH_PORT:-2240}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"
BREW_QEMU_SHARE="/opt/homebrew/share/qemu"

QUIET=0
JSON=0
case "${1:-}" in
    --quiet) QUIET=1 ;;
    --json)  JSON=1 ;;
esac

PASS=0
FAIL=0
FAIL_LINES=()

ok()   { (( QUIET )) || printf '  \033[1;32m✓\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; FAIL=$((FAIL+1)); FAIL_LINES+=("$*"); }
info() { (( QUIET )) || printf '    \033[2m%s\033[0m\n' "$*"; }
hdr()  { (( QUIET )) || printf '\n\033[1;34m── %s\033[0m\n' "$*"; }

# --- 1. Host ------------------------------------------------------------------
hdr "Host"
if [[ "$(uname)" == "Darwin" ]]; then
    ok "macOS host"
    info "$(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
else
    bad "Not macOS (uname=$(uname)) — local.sh is macOS-only"
fi

ARCH="$(uname -m)"
if [[ "$ARCH" == "arm64" ]]; then
    ok "Apple Silicon (arm64)"
else
    bad "Host is $ARCH, not arm64 — arm64 emulation under TCG isn't worth running here"
fi

# Native arm64 vs Rosetta
if [[ "$(arch 2>/dev/null)" == "arm64" ]]; then
    ok "Shell is running natively as arm64 (not Rosetta)"
else
    bad "Shell appears to be running under Rosetta (arch=$(arch 2>/dev/null)) — open a native arm64 Terminal"
fi

# CPU info
if (( ! QUIET )) && [[ "$ARCH" == "arm64" ]]; then
    info "CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null) / $(sysctl -n hw.ncpu 2>/dev/null) cores"
    info "RAM: $(( $(sysctl -n hw.memsize 2>/dev/null) / 1024 / 1024 / 1024 )) GiB"
fi

# --- 2. Homebrew --------------------------------------------------------------
hdr "Homebrew"
if command -v brew >/dev/null 2>&1; then
    ok "brew found at $(command -v brew)"
    BREW_PREFIX="$(brew --prefix 2>/dev/null)"
    info "prefix: $BREW_PREFIX"
    if [[ "$BREW_PREFIX" == "/opt/homebrew" ]]; then
        ok "brew is the arm64 install (prefix /opt/homebrew)"
    else
        bad "brew prefix is $BREW_PREFIX — expected /opt/homebrew for arm64. Likely an Intel brew running under Rosetta."
    fi
    # brew itself is a shell script; check the bash interpreter is native arm64
    BASH_BIN="$(/usr/bin/env bash -c 'echo $BASH')"
    if file "$BASH_BIN" 2>/dev/null | grep -q 'arm64'; then
        ok "bash interpreter is arm64 ($BASH_BIN)"
    else
        bad "bash interpreter is not arm64 — running under Rosetta? (file: $(file "$BASH_BIN" 2>/dev/null | head -1))"
    fi
else
    bad "Homebrew not installed — see https://brew.sh"
fi

# --- 3. Required packages -----------------------------------------------------
hdr "Required packages"
for pkg in qemu cdrtools wget; do
    if brew list --formula --versions "$pkg" >/dev/null 2>&1; then
        ver="$(brew list --formula --versions "$pkg" 2>/dev/null | awk '{print $2}')"
        ok "$pkg ($ver)"
    else
        bad "$pkg not installed — brew install $pkg"
    fi
done

# qemu-system-aarch64 in PATH and its version
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    ok "qemu-system-aarch64 in PATH"
    info "$(qemu-system-aarch64 --version 2>/dev/null | head -1)"
else
    bad "qemu-system-aarch64 not in PATH"
fi

# mkisofs (from cdrtools)
if command -v mkisofs >/dev/null 2>&1; then
    ok "mkisofs in PATH"
else
    bad "mkisofs not in PATH — needed for cloud-init seed ISO"
fi

# --- 4. HVF acceleration ------------------------------------------------------
hdr "Acceleration"
if command -v qemu-system-aarch64 >/dev/null 2>&1; then
    if qemu-system-aarch64 -accel help 2>/dev/null | grep -q '^hvf$'; then
        ok "HVF acceleration available in this qemu build"
    else
        bad "qemu reports no HVF accelerator — VMs would fall back to TCG"
    fi
    # Try a 0.1-second HVF boot to confirm permission/entitlement
    if timeout 3 qemu-system-aarch64 -M virt -accel hvf -cpu host -m 256 -display none -nographic -kernel /dev/null 2>&1 | grep -qE 'hvf.*(failed|denied|error)'; then
        bad "HVF init reports failure — check macOS hypervisor entitlement"
    else
        ok "HVF initializes (no permission/entitlement error)"
    fi
fi

# --- 5. UEFI firmware ---------------------------------------------------------
hdr "AAVMF / edk2 firmware"
EDK2_CODE=""
for c in "$BREW_QEMU_SHARE/edk2-aarch64-code.fd" "$BREW_QEMU_SHARE/edk2-aarch64-secure-code.fd"; do
    if [[ -f "$c" ]]; then
        EDK2_CODE="$c"
        ok "firmware code: $c ($(stat -f%z "$c") bytes)"
        break
    fi
done
[[ -z "$EDK2_CODE" ]] && bad "No edk2-aarch64-*-code.fd under $BREW_QEMU_SHARE"

EDK2_VARS=""
for v in "$BREW_QEMU_SHARE/edk2-arm-vars.fd" "$BREW_QEMU_SHARE/edk2-aarch64-vars.fd"; do
    if [[ -f "$v" ]]; then
        EDK2_VARS="$v"
        ok "vars template: $v ($(stat -f%z "$v") bytes)"
        break
    fi
done
[[ -z "$EDK2_VARS" ]] && bad "No edk2-*-vars.fd under $BREW_QEMU_SHARE"

# --- 6. SSH key ---------------------------------------------------------------
hdr "SSH key"
if [[ -f "$SSH_KEY" ]]; then
    ok "private key: $SSH_KEY"
    if [[ -f "${SSH_KEY}.pub" ]]; then
        ok "public key: ${SSH_KEY}.pub"
        info "fingerprint: $(ssh-keygen -lf "${SSH_KEY}.pub" 2>/dev/null | awk '{print $2}')"
    else
        bad "Missing ${SSH_KEY}.pub"
    fi
else
    bad "$SSH_KEY not present — ./local.sh setup will create it"
fi

# --- 7. WORKDIR state ---------------------------------------------------------
hdr "Workdir ($WORKDIR)"
if [[ -d "$WORKDIR" ]]; then
    ok "workdir exists"
    for f in debian-12-arm64-base.qcow2 disk.raw seed.iso vars.fd; do
        if [[ -f "$WORKDIR/$f" ]]; then
            ok "$f ($(du -h "$WORKDIR/$f" | awk '{print $1}'))"
        else
            bad "$f missing — run ./local.sh setup"
        fi
    done
    if [[ -d "$WORKDIR/seed" ]]; then
        ok "seed/ directory present"
        for s in user-data meta-data; do
            if [[ -f "$WORKDIR/seed/$s" ]]; then
                ok "  seed/$s"
            else
                bad "  seed/$s missing"
            fi
        done
    else
        bad "seed/ directory missing — run ./local.sh setup"
    fi
else
    bad "Workdir $WORKDIR doesn't exist — run ./local.sh setup"
fi

# --- 8. VM runtime state ------------------------------------------------------
hdr "VM runtime state"
PIDFILE="$WORKDIR/qemu.pid"
if [[ -f "$PIDFILE" ]]; then
    PID="$(cat "$PIDFILE" 2>/dev/null)"
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        ok "qemu running (pid $PID)"
        info "elapsed: $(ps -o etime= -p "$PID" 2>/dev/null | xargs)"
        info "cmd: $(ps -o command= -p "$PID" 2>/dev/null | cut -c1-100)..."
    else
        bad "stale pidfile (pid $PID not alive)"
    fi
else
    info "No pidfile — VM is not running (this is normal pre-boot)"
    PASS=$((PASS+1))
fi

# --- 9. SSH port + banner -----------------------------------------------------
hdr "SSH port $SSH_PORT"
if nc -z 127.0.0.1 "$SSH_PORT" 2>/dev/null; then
    ok "port $SSH_PORT accepts TCP"
    # Read for up to 3 s; expect SSH-2.0 banner if guest sshd up
    BANNER="$(timeout 3 bash -c "cat </dev/tcp/127.0.0.1/$SSH_PORT" 2>/dev/null | head -c 50)"
    if [[ "$BANNER" == SSH-* ]]; then
        ok "guest sshd banner: $BANNER"
    elif [[ -z "$BANNER" ]]; then
        info "TCP open but no banner — qemu hostfwd is up, guest sshd not yet (or VM still booting)"
    else
        bad "unexpected banner: $BANNER"
    fi
else
    info "port $SSH_PORT not listening (VM not running)"
    PASS=$((PASS+1))
fi

# --- 10. Logs -----------------------------------------------------------------
hdr "Logs"
for f in serial.log stderr.log; do
    p="$WORKDIR/$f"
    if [[ -f "$p" ]]; then
        sz=$(stat -f%z "$p" 2>/dev/null)
        if [[ "$sz" -gt 0 ]]; then
            ok "$f ($sz bytes)"
            if [[ "$f" == "stderr.log" ]] && (( ! QUIET )); then
                printf '    \033[2mlast 5 lines of stderr.log:\033[0m\n'
                tail -5 "$p" | sed 's/^/      /'
            fi
        else
            info "$f exists but is empty"
        fi
    else
        info "$f absent"
    fi
done

# --- Summary ------------------------------------------------------------------
echo
if (( JSON )); then
    printf '{"pass":%d,"fail":%d,"failures":[' "$PASS" "$FAIL"
    for i in "${!FAIL_LINES[@]}"; do
        (( i > 0 )) && printf ','
        printf '"%s"' "$(printf '%s' "${FAIL_LINES[$i]}" | sed 's/"/\\"/g')"
    done
    printf ']}\n'
else
    if (( FAIL == 0 )); then
        printf '\033[1;32m✓ %d checks passed, 0 failures\033[0m\n' "$PASS"
    else
        printf '\033[1;31m✗ %d failures (%d checks passed):\033[0m\n' "$FAIL" "$PASS"
        for line in "${FAIL_LINES[@]}"; do
            printf '  - %s\n' "$line"
        done
    fi
fi

exit "$FAIL"
