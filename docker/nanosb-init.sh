#!/bin/sh
# nanosb-init.sh — PID 1 init script for nanosandbox VMs
#
# Starts sshd for direct access, then execs agent-gateway.
#
# Networking is NOT configured here — it is handled by the VM runtime:
#   - Linux/macOS: libkrun VMM configures gvproxy virtio-net
#   - Windows HCS: init.krun configures vsock_proxy + iptables REDIRECT
#
# NOTE: Do NOT use "set -e" here. This is an init script (PID 1) —
# if it exits for ANY reason, the VM shuts down. Every command must
# be individually guarded with "|| true" or explicit error handling.

# ---------------------------------------------------------------
# 0. Deduplicate: libkrun's init.c spawns this script twice
#    (once directly, once via a forked /init.krun copy). Use an
#    atomic mkdir lock to ensure only the first instance proceeds.
# ---------------------------------------------------------------
if ! mkdir /tmp/.nanosb-init-lock 2>/dev/null; then
    # Another instance already holds the lock — sleep forever.
    # Do NOT exit: PID 1 (/init.krun) may depend on its direct
    # child staying alive; exiting would shut down the VM.
    while true; do sleep 3600; done
fi

echo "nanosb-init: starting (v17)"

# ---------------------------------------------------------------
# 0b. Outbound proxy routing (Windows HCS)
# ---------------------------------------------------------------
# When vsock_proxy is running (started by init.krun before switch_root),
# all outbound TCP must be routed through it via NAT REDIRECT to port 1080.
#
# The WSL kernel has nftables built-in (=y) but iptables as modules (=m).
# Since we boot with nomodule, only raw nft commands work reliably.
# Fall back to iptables-nft / iptables for non-WSL kernels.
if pidof vsock_proxy >/dev/null 2>&1; then
    REDIRECT_OK=false

    # Try nft (direct nftables API — no kernel modules needed).
    # WSL kernel: NFT_NAT=y (dnat built-in), NFT_REDIR=m (redirect needs module).
    # Use dnat instead of redirect since we boot with nomodule.
    if command -v nft >/dev/null 2>&1 || [ -x /usr/sbin/nft ]; then
        NFT=$(command -v nft 2>/dev/null || echo /usr/sbin/nft)
        if $NFT add table ip nanosb 2>/dev/null \
           && $NFT add chain ip nanosb output '{ type nat hook output priority -100 ; policy accept ; }' 2>/dev/null \
           && $NFT -f - 2>/dev/null <<'NFTRULE'
add rule ip nanosb output ip daddr != 127.0.0.0/8 ip protocol tcp dnat to 127.0.0.1:1080
NFTRULE
        then
            REDIRECT_OK=true
            echo "nanosb-init: nft DNAT to vsock_proxy 127.0.0.1:1080"
        else
            echo "nanosb-init: nft dnat failed, trying iptables fallback"
        fi
    fi

    # Fallback: iptables-nft or iptables (for kernels with iptables modules loaded)
    if [ "$REDIRECT_OK" = "false" ]; then
        for ipt in iptables-nft /usr/sbin/iptables-nft iptables /usr/sbin/iptables; do
            if command -v "$ipt" >/dev/null 2>&1; then
                IPT_ERR=$($ipt -t nat -A OUTPUT -p tcp ! -d 127.0.0.0/8 -j REDIRECT --to-port 1080 2>&1)
                if [ $? -eq 0 ]; then
                    REDIRECT_OK=true
                    echo "nanosb-init: iptables REDIRECT to vsock_proxy :1080 (via $ipt)"
                else
                    echo "nanosb-init: $ipt failed: $IPT_ERR"
                fi
                break
            fi
        done
    fi

    if [ "$REDIRECT_OK" = "false" ]; then
        echo "nanosb-init: WARNING: could not set NAT REDIRECT, outbound TCP will not work"
    fi
fi

# ---------------------------------------------------------------
# 0c. Detect 9P rootfs mode (Windows HCS)
# ---------------------------------------------------------------
# When the rootfs is a Plan9 share from a Windows host, NTFS doesn't
# track Unix permissions. All files appear as 0777 through 9P.
# sshd requires strict permissions on host keys and authorized_keys.
# We detect this via a kernel cmdline flag set by the Windows runtime.
NANOSB_9P_MODE=false
if grep -q 'nanosb.9p_rootfs=1' /proc/cmdline 2>/dev/null; then
    NANOSB_9P_MODE=true
    echo "nanosb-init: 9P rootfs mode detected (Windows HCS)"
fi

# Helper: parse a key=value parameter from /proc/cmdline
get_cmdline_param() {
    local key="$1"
    cat /proc/cmdline 2>/dev/null | tr ' ' '\n' | grep "^${key}=" | cut -d= -f2-
}

# ---------------------------------------------------------------
# 1. Mount virtiofs shared directories
# ---------------------------------------------------------------
# The host writes /etc/nanosb-mounts with lines: "<tag> <mountpoint>"
# Each line corresponds to a virtiofs device registered via krun_add_virtiofs.
if [ -f /etc/nanosb-mounts ]; then
    while read -r tag mountpoint; do
        [ -z "$tag" ] && continue
        mkdir -p "$mountpoint" 2>/dev/null || true
        # Use agent-gateway --mount for direct syscall.Mount() — util-linux's
        # mount binary refuses even for root in libkrun micro-VMs.
        if /usr/local/bin/agent-gateway --mount "$tag" "$mountpoint" virtiofs 2>&1; then
            echo "nanosb-init: mounted $tag -> $mountpoint"
        else
            echo "nanosb-init: mount $tag -> $mountpoint FAILED"
        fi
    done < /etc/nanosb-mounts
    echo "nanosb-init: virtiofs mounts done"
fi

# ---------------------------------------------------------------
# 1b. Link agent state dirs into /workspace/.nanosb-state/
# ---------------------------------------------------------------
# Agent session state (conversation history, config) is stored inside
# the workspace clone at .nanosb-state/ so it persists across VM
# restarts via VirtioFS. Symlink each agent's home state dir there.
if [ -d /workspace ]; then
    STATE_DIR="/workspace/.nanosb-state"
    mkdir -p "$STATE_DIR" 2>/dev/null || true

    # Claude Code: ~/.claude/ (conversations, project memory, settings)
    # Codex:       ~/.codex/  (sessions, config.toml, AGENTS.md)
    # Cursor:      ~/.cursor/ (mcp.json, chat state)
    for dir in .claude .codex .cursor; do
        mkdir -p "$STATE_DIR/$dir" 2>/dev/null || true
        if [ -e "/home/developer/$dir" ] && [ ! -L "/home/developer/$dir" ]; then
            rm -rf "/home/developer/$dir" 2>/dev/null || true
        fi
        ln -sfn "$STATE_DIR/$dir" "/home/developer/$dir" 2>/dev/null || true
    done

    # Goose: ~/.config/goose/ (sessions, config.yaml)
    mkdir -p "$STATE_DIR/.config/goose" 2>/dev/null || true
    mkdir -p /home/developer/.config 2>/dev/null || true
    if [ -e /home/developer/.config/goose ] && [ ! -L /home/developer/.config/goose ]; then
        rm -rf /home/developer/.config/goose 2>/dev/null || true
    fi
    ln -sfn "$STATE_DIR/.config/goose" /home/developer/.config/goose 2>/dev/null || true

    chown -R developer:developer "$STATE_DIR" 2>/dev/null || true
    echo "nanosb-init: agent state symlinks created (workspace-backed)"
fi

# ---------------------------------------------------------------
# 2. Start sshd (background) — enables SSH health check + access
# ---------------------------------------------------------------
if [ -x /usr/sbin/sshd ]; then

    if [ "$NANOSB_9P_MODE" = "true" ]; then
        # --- 9P mode (Windows HCS) ---
        # NTFS doesn't track Unix permissions. All files via 9P appear as
        # 0777/root:root. sshd requires host keys be 0600 and authorized_keys
        # be 0600 with proper ownership. Use tmpfs overlays to get real perms.

        # tmpfs over /etc/ssh — gives us writable dir with proper permissions
        mkdir -p /etc/ssh 2>/dev/null || true
        mount -t tmpfs tmpfs /etc/ssh 2>/dev/null || true

        # Write sshd_config with StrictModes disabled (belt + suspenders)
        cat > /etc/ssh/sshd_config <<'SSHD_CONF'
Port 22
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication no
StrictModes no
Subsystem sftp /usr/lib/openssh/sftp-server
SSHD_CONF

        # Generate host keys on tmpfs (proper 0600 permissions)
        ssh-keygen -A 2>/dev/null || true

        # tmpfs over /root/.ssh — writable with proper permissions
        mkdir -p /root/.ssh 2>/dev/null || true
        mount -t tmpfs tmpfs /root/.ssh 2>/dev/null || true

        # Inject SSH public key from kernel cmdline (set by Windows runtime)
        NANOSB_SSH_KEY=$(get_cmdline_param nanosb.ssh_key)
        if [ -n "$NANOSB_SSH_KEY" ]; then
            # Key was passed with commas replacing spaces (cmdline limitation)
            SSH_KEY=$(echo "$NANOSB_SSH_KEY" | tr ',' ' ')
            echo "$SSH_KEY" > /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
            echo "nanosb-init: SSH key injected from kernel cmdline"
        fi

        mkdir -p /run/sshd 2>/dev/null || true
        echo "nanosb-init: 9P SSH setup complete (tmpfs overlays)"
    else
        # --- Normal mode (virtiofs / macOS / Linux) ---
        # Generate host keys if missing (first boot)
        ssh-keygen -A 2>/dev/null || true

        # Fix ownership: virtiofs passes through host UIDs, so rootfs files
        # and directories appear owned by the macOS user (e.g. UID 501)
        # instead of root. sshd StrictModes requires /run/sshd, /root,
        # /root/.ssh, and authorized_keys to all be owned by root (UID 0).
        mkdir -p /run/sshd 2>/dev/null || true
        chown 0:0 /run /run/sshd 2>/dev/null || true
        chmod 0755 /run/sshd 2>/dev/null || true
        chown 0:0 /root 2>/dev/null || true
        chown -R 0:0 /root/.ssh 2>/dev/null || true
    fi

    # Copy SSH authorized_keys from root to developer user so that
    # the TUI can connect as 'developer' (non-root) for agent CLIs.
    # Agents like Claude Code refuse --dangerously-skip-permissions as root.
    if [ -f /root/.ssh/authorized_keys ]; then
        mkdir -p /home/developer/.ssh 2>/dev/null || true
        # In 9P mode, /home/developer/.ssh is on NTFS (0777). Use tmpfs overlay
        # so sshd sees proper ownership and permissions.
        if [ "$NANOSB_9P_MODE" = "true" ]; then
            mount -t tmpfs tmpfs /home/developer/.ssh 2>/dev/null || true
        fi
        cp /root/.ssh/authorized_keys /home/developer/.ssh/authorized_keys 2>/dev/null || true
        chown -R developer:developer /home/developer/.ssh 2>/dev/null || true
        chmod 700 /home/developer/.ssh 2>/dev/null || true
        chmod 600 /home/developer/.ssh/authorized_keys 2>/dev/null || true
    fi

    # Unlock the developer account for SSH pubkey auth.
    # Debian images create users with '!' in /etc/shadow (locked), and
    # OpenSSH rejects pubkey auth for locked accounts even with StrictModes off.
    # Change '!' to '*' (disabled password, but not locked).
    usermod -p '*' developer 2>/dev/null || true

    # Fix ownership of developer's entire home directory.
    # virtiofs passes through host UIDs (e.g. macOS UID 501), so all files
    # from the rootfs appear with wrong ownership inside the VM.
    chown -R developer:developer /home/developer 2>/dev/null || true

    # Ensure /workspace is writable by the developer user
    chown -R developer:developer /workspace 2>/dev/null || true

    /usr/sbin/sshd 2>/dev/null || echo "nanosb-init: warning: sshd failed to start"
    echo "nanosb-init: sshd started"
fi

# ---------------------------------------------------------------
# 3. Start agent-gateway (foreground) — handles agent API + MCP
# ---------------------------------------------------------------
if [ -x /usr/local/bin/agent-gateway ]; then
    echo "nanosb-init: starting agent-gateway"
    exec /usr/local/bin/agent-gateway --skip-network-init
else
    echo "nanosb-init: agent-gateway not found, entering hold mode"
    # Keep the VM alive so SSH access still works for debugging.
    while true; do sleep 3600; done
fi
