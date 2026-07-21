#!/bin/bash
#
# check-tunnel.sh - SSH 反向隧道健康检查脚本
#
# 三级健康检查：
#   1. 本地守护进程 + SSH 子进程存活（通过 PID 文件）
#   2. node-01 远端端口 8888 在监听
#   3. 代理连通性（经 8888 访问 Docker Hub registry）+ 本机代理 7897
#
# 用法：
#   ./check-tunnel.sh           # 全量检查（含远端 curl）
#   ./check-tunnel.sh --local   # 仅本地检查（不连远端，速度快）
#
# 退出码：0 = 健康，1 = 异常
#

set -uo pipefail

SSH_HOST="k3s-node-01-proxy"
SSH_CHECK_HOST="k3s-node-01"   # 远端检查用普通 Host（不带 RemoteForward，避免端口冲突）
SSH_BIN="ssh"
STATE_DIR="${HOME}/.ssh"
DAEMON_PID_FILE="${STATE_DIR}/tunnel-daemon.pid"
SSH_PID_FILE="${STATE_DIR}/tunnel-ssh.pid"
DAEMON_SCRIPT="${BASH_SOURCE[0]%/*}/autossh-tunnel.sh"
EXIT_CODE=0
LOCAL_ONLY=false

if [ "${1:-}" = "--local" ]; then
    LOCAL_ONLY=true
fi

# 检查 PID 存活
check_pid() {
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
    return 1
}

echo "============================================"
echo " SSH Tunnel Health Check"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"

# ==================== 检查 1：守护进程 ====================
echo -n "[1/4] Daemon process:    "
DPID=$(check_pid "$DAEMON_PID_FILE" || true)
if [ "$DPID" -gt 0 ]; then
    echo "OK (PID $DPID)"
else
    echo "FAIL (daemon not running)"
    EXIT_CODE=1
fi

# ==================== 检查 2：SSH 子进程 ====================
echo -n "[2/4] SSH tunnel process: "
SPID=$(check_pid "$SSH_PID_FILE" || true)
if [ "$SPID" -gt 0 ]; then
    echo "OK (PID $SPID)"
else
    echo "FAIL (SSH child not running)"
    EXIT_CODE=1
fi

# ==================== 检查 3：本机代理端口 7897 ====================
echo -n "[3/4] Local proxy (7897): "
# netstat 在 Windows/Git Bash 可用，代理可能绑定 0.0.0.0 或 127.0.0.1
if netstat -an 2>/dev/null | grep -q ":7897.*LISTEN"; then
    echo "OK (listening)"
else
    echo "FAIL (local 7897 not listening - is your proxy/airport running?)"
    EXIT_CODE=1
fi

# ==================== 检查 4：远端端口 + 代理连通性 ====================
if [ "$LOCAL_ONLY" = false ]; then
    echo ""
    echo "--- Remote checks (via ${SSH_CHECK_HOST}) ---"

    # 检查 4a：node-01 端口 8888
    echo -n "[4a] Remote port 8888:    "
    PORT_RESULT=$($SSH_BIN -o ConnectTimeout=5 -o BatchMode=yes "$SSH_CHECK_HOST" \
        "ss -tlnp 2>/dev/null | grep ':8888'" 2>/dev/null || echo "")
    if [ -n "$PORT_RESULT" ]; then
        echo "OK (listening)"
    else
        echo "FAIL (8888 not listening on remote)"
        EXIT_CODE=1
    fi

    # 检查 4b：代理连通性（经 8888 访问 Docker Hub）
    echo -n "[4b] Proxy -> Docker Hub: "
    HTTP_CODE=$($SSH_BIN -o ConnectTimeout=5 -o BatchMode=yes "$SSH_CHECK_HOST" \
        "curl -x http://127.0.0.1:8888 -s -o /dev/null -w '%{http_code}' --connect-timeout 8 https://registry-1.docker.io/v2/" 2>/dev/null || echo "000")
    case "$HTTP_CODE" in
        401|200|301|302)
            echo "OK (HTTP $HTTP_CODE - reachable)"
            ;;
        000)
            echo "FAIL (connection failed/timeout)"
            EXIT_CODE=1
            ;;
        *)
            echo "WARN (HTTP $HTTP_CODE - unexpected but reachable)"
            ;;
    esac
fi

# ==================== 汇总 ====================
echo ""
echo "============================================"
if [ $EXIT_CODE -eq 0 ]; then
    echo " RESULT: HEALTHY"
else
    echo " RESULT: UNHEALTHY"
    echo ""
    echo " Fix: bash ${DAEMON_SCRIPT} restart"
fi
echo "============================================"

exit $EXIT_CODE
