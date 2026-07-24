#!/bin/bash
#
# autossh-tunnel.sh - SSH 反向隧道持久化守护脚本
#
# 功能：监控 SSH 反向隧道，断线自动重连（autossh 等效实现）
#   - while 循环 + ssh 后台运行 + wait 监控 + 退出后自动重启
#   - 依赖 SSH config 中的 ServerAliveInterval/ServerAliveCountMax 检测断线
#   - PID 文件管理（不依赖 pgrep/pkill，兼容 Git Bash / MSYS2 环境）
#
# 用法：
#   ./autossh-tunnel.sh start       # 后台启动守护进程
#   ./autossh-tunnel.sh stop        # 停止守护进程及 SSH 子进程
#   ./autossh-tunnel.sh restart     # 重启
#   ./autossh-tunnel.sh status      # 查看状态
#   ./autossh-tunnel.sh foreground  # 前台运行（阻塞，方便调试）
#
# 配置：SSH config 中需有以下 Host（本机:7897 -> node-01:8888）
#   Host k3s-node-01-proxy
#       HostName <node-01实际公网IP>
#       User ops
#       IdentityFile ~/.ssh/id_rsa
#       RemoteForward 8888 127.0.0.1:7897
#       ServerAliveInterval 30
#       ServerAliveCountMax 3
#       ExitOnForwardFailure yes
#
# 断线恢复时间 ≈ ServerAliveInterval × ServerAliveCountMax + RETRY_INTERVAL
#             ≈ 30 × 3 + 5 = 95 秒
#

set -uo pipefail

# ==================== 解析自身绝对路径 ====================
# nohup 后台重调用时需要绝对路径，避免相对路径找不到脚本
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"

# ==================== 配置 ====================
SSH_HOST="k3s-node-01-proxy"
SSH_CLEANUP_HOST="k3s-node-01"           # 用于远端清理的 Host（不带 RemoteForward，避免端口冲突）
SSH_PORT=8888                            # 远端隧道端口
RETRY_INTERVAL=5                         # 断线后重连间隔（秒）
MAX_RETRY_INTERVAL=60                    # 连续失败时的最大退避间隔（秒）
STATE_DIR="${HOME}/.ssh"
LOG_FILE="${STATE_DIR}/tunnel.log"
DAEMON_PID_FILE="${STATE_DIR}/tunnel-daemon.pid"
SSH_PID_FILE="${STATE_DIR}/tunnel-ssh.pid"
SSH_BIN="ssh"

# ==================== 工具函数 ====================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# 读取 PID 文件并验证进程存活（0 = 不存在/已死）
read_pid() {
    local pidfile="$1"
    if [ -f "$pidfile" ]; then
        local pid
        pid=$(cat "$pidfile" 2>/dev/null || echo 0)
        if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
        fi
    fi
    echo 0
}

daemon_pid() { read_pid "$DAEMON_PID_FILE"; }
ssh_pid()     { read_pid "$SSH_PID_FILE"; }

# ==================== 本地端口检测 ====================

# 从 SSH config 解析本地隧道监听端口（RemoteForward 第三个字段的最后一个 :xxxx 部分）
# RemoteForward 8888 127.0.0.1:7897  → 7897
read_local_port() {
    local ssh_config="${HOME}/.ssh/config"
    [ ! -f "$ssh_config" ] && return 1

    awk -v host="$SSH_HOST" '
        tolower($1) == "host" && tolower($2) == tolower(host) { in_block = 1; next }
        in_block && /^[[:space:]]*$/ { in_block = 0; next }
        in_block && tolower($1) == "host" && tolower($2) != tolower(host) { in_block = 0; next }
        in_block && tolower($1) == "remoteforward" {
            split($3, a, ":")
            print a[length(a)]
            exit
        }
    ' "$ssh_config"
}

# 检查指定端口是否已被本机进程监听
is_port_listening() {
    local port="$1"
    [ -z "$port" ] && return 1

    # Git Bash / MSYS2 / Windows：netstat
    if command -v netstat &>/dev/null; then
        netstat -an 2>/dev/null | grep -qiE "LISTENING.*[:.]${port}\b" && return 0
    fi

    # Linux：ss
    if command -v ss &>/dev/null; then
        ss -tln 2>/dev/null | grep -qE ":${port}\b" && return 0
    fi

    # Windows fallback：PowerShell
    if command -v powershell.exe &>/dev/null; then
        powershell.exe -NoProfile -Command \
            "Get-NetTCPConnection -LocalPort ${port} -State Listen -ErrorAction SilentlyContinue | Out-Null; if (\$?) { exit 0 } else { exit 1 }" \
            2>/dev/null && return 0
    fi

    return 1
}

# ==================== 远端端口清理 ====================
# SSH 断开后，node-01 的 sshd 可能仍持有隧道端口，导致重连失败。
# 通过不设 RemoteForward 的专用 Host 执行远程清理。
cleanup_remote_port() {
    log "Attempting to clean up remote port ${SSH_PORT} via ${SSH_CLEANUP_HOST}..."
    local result
    result=$($SSH_BIN -o ConnectTimeout=5 -o BatchMode=yes "$SSH_CLEANUP_HOST" \
        "sudo fuser -k ${SSH_PORT}/tcp 2>/dev/null; echo 'done'" 2>/dev/null)
    if [ -n "$result" ]; then
        log "Remote port cleanup succeeded: ${result}"
    else
        log "Remote port cleanup failed or unreachable (host may be down)"
    fi
}

# ==================== 守护主循环 ====================
# autossh 核心逻辑：启动 ssh（后台）→ wait 监控 → 退出后重启
run_forever() {
    local interval=$RETRY_INTERVAL
    local fail_count=0

    log "=========================================="
    log "Tunnel daemon started (host=$SSH_HOST)"
    log "Retry interval: ${RETRY_INTERVAL}s (max ${MAX_RETRY_INTERVAL}s)"
    log "=========================================="

    while true; do
        log "Starting SSH tunnel to ${SSH_HOST}..."

        # 后台启动 ssh，记录 PID
        $SSH_BIN -N "$SSH_HOST" 2>>"$LOG_FILE" &
        local spid=$!
        echo "$spid" > "$SSH_PID_FILE"
        log "SSH child started (PID $spid)"

        # 阻塞等待 ssh 退出
        wait "$spid"
        local exit_code=$?
        rm -f "$SSH_PID_FILE"

        # 本机代理检测：代理已关闭则不再重试，避免无限循环
        local local_port
        local_port=$(read_local_port) || true
        if [ -n "$local_port" ] && ! is_port_listening "$local_port"; then
            log "Local proxy :${local_port} is gone — tunnel cannot continue, exiting"
            log "=========================================="
            exit 0
        fi

        if [ $exit_code -eq 0 ]; then
            log "SSH tunnel exited normally (code=0)"
            fail_count=0
            interval=$RETRY_INTERVAL
        else
            fail_count=$((fail_count + 1))
            log "SSH tunnel exited with error (code=$exit_code, fail #$fail_count)"

            # 检测是否为端口绑定失败（远端端口被旧进程持有）
            if tail -5 "$LOG_FILE" 2>/dev/null | grep -q "remote port forwarding failed for listen port ${SSH_PORT}"; then
                log "Detected stale remote port ${SSH_PORT} — cleaning up before retry"
                cleanup_remote_port
                # 清理后立即重试，不进退避
                interval=$RETRY_INTERVAL
                fail_count=0
            else
                # 其他错误：线性退避
                interval=$((RETRY_INTERVAL * fail_count))
                if [ $interval -gt $MAX_RETRY_INTERVAL ]; then
                    interval=$MAX_RETRY_INTERVAL
                fi
            fi
        fi

        log "Waiting ${interval}s before reconnect..."
        sleep "$interval"
    done
}

# ==================== 子命令 ====================

cmd_start() {
    local pid
    pid=$(daemon_pid)
    if [ "$pid" -gt 0 ]; then
        echo "Daemon already running (PID $pid)"
        return 1
    fi

    # 端口预检：先确保本机代理已启动，否则隧道 RemoteForward 连不上
    local local_port
    local_port=$(read_local_port) || true
    if [ -n "$local_port" ]; then
        if ! is_port_listening "$local_port"; then
            echo "ERROR: Local proxy port :${local_port} is NOT listening"
            echo "       The RemoteForward tunnel needs a local service on port ${local_port}"
            echo "       Please start the local proxy first, then retry"
            return 1
        fi
        echo "Port check: local :${local_port} is listening (proxy OK)"
    else
        echo "Port check: skipped (could not parse local port from SSH config)"
    fi

    mkdir -p "$STATE_DIR"
    # nohup 后台运行本脚本的 _daemon 分支
    nohup "$SCRIPT_PATH" _daemon >>"$LOG_FILE" 2>&1 &
    local new_pid=$!
    echo "$new_pid" > "$DAEMON_PID_FILE"
    sleep 2  # 等待 ssh 建立
    echo "Tunnel daemon started (PID $new_pid)"
    local spid
    spid=$(ssh_pid)
    if [ "$spid" -gt 0 ]; then
        echo "SSH child process: PID $spid"
        echo "Log: $LOG_FILE"
    else
        echo "WARNING: SSH child not started yet, check log: $LOG_FILE"
    fi
}

cmd_stop() {
    # 先杀 SSH 子进程
    local spid
    spid=$(ssh_pid)
    if [ "$spid" -gt 0 ]; then
        kill "$spid" 2>/dev/null && log "Killed SSH child (PID $spid)" || true
    fi
    # 再杀守护进程
    local pid
    pid=$(daemon_pid)
    if [ "$pid" -gt 0 ]; then
        kill "$pid" 2>/dev/null && log "Killed daemon (PID $pid)" || true
    else
        echo "Daemon not running"
    fi
    rm -f "$DAEMON_PID_FILE" "$SSH_PID_FILE"
    echo "Tunnel daemon stopped"
}

cmd_status() {
    local pid
    pid=$(daemon_pid)
    if [ "$pid" -gt 0 ]; then
        echo "Daemon:  RUNNING (PID $pid)"
    else
        echo "Daemon:  STOPPED"
    fi
    local spid
    spid=$(ssh_pid)
    if [ "$spid" -gt 0 ]; then
        echo "SSH:     ACTIVE (PID $spid)"
    else
        echo "SSH:     INACTIVE"
    fi

    # 本机代理端口状态（隧道的前提条件）
    local local_port
    local_port=$(read_local_port) || true
    if [ -n "$local_port" ]; then
        if is_port_listening "$local_port"; then
            echo "Proxy:   :${local_port} — LISTENING"
        else
            echo "Proxy:   :${local_port} — NOT LISTENING (tunnel cannot connect)"
        fi
    fi

    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "--- Recent log ---"
        tail -5 "$LOG_FILE" 2>/dev/null
    fi
}

cmd_restart() {
    cmd_stop
    sleep 1
    cmd_start
}

cmd_foreground() {
    mkdir -p "$STATE_DIR"
    trap 'log "Received interrupt, exiting."; rm -f "$SSH_PID_FILE"; exit 0' INT TERM
    run_forever
}

# ==================== 入口 ====================
case "${1:-}" in
    start)      cmd_start ;;
    stop)       cmd_stop ;;
    restart)    cmd_restart ;;
    status)     cmd_status ;;
    foreground) cmd_foreground ;;
    _daemon)
        # 内部调用：后台守护循环
        trap 'log "Daemon received terminate signal."; exit 0' INT TERM
        run_forever
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|foreground}"
        echo ""
        echo "  start      - Launch daemon in background"
        echo "  stop       - Stop daemon and SSH child"
        echo "  restart    - Restart daemon"
        echo "  status     - Show daemon/SSH status + recent log"
        echo "  foreground - Run in foreground (Ctrl+C to stop)"
        exit 1
        ;;
esac
