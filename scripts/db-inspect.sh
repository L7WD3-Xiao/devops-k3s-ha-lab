#!/usr/bin/env bash
# db-inspect.sh -- MySQL 自动巡检脚本 (在 node-03 / Slave 执行)
#
# 覆盖 7 个维度：基本信息、空间概览、碎片率、慢查询、复制延迟、
# 连接、性能/Buffer Pool 命中率，以及近 7 天错误日志摘要。
# 输出结构化报告 → ossutil 推送 OSS，形成可对比的趋势基线。
#
# 用法:
#   /usr/local/bin/db-inspect.sh           # 全量巡检 + OSS 推送
#   /usr/local/bin/db-inspect.sh --local   # 仅生成报告，不推送 OSS
#   /usr/local/bin/db-inspect.sh --dry-run # 仅展示配置，不执行
#
# Cron: 0 2 * * 0 /usr/local/bin/db-inspect.sh >> /var/log/db-inspect.log 2>&1

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
MYSQL_USER="${MYSQL_USER:-root}"
# 密码由 /root/.my.cnf [client] 提供 (host=127.0.0.1 user=root password=XXX)
# 脚本不传 --password 以防覆盖 my.cnf 配置
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
MYSQL_PORT="${MYSQL_PORT:-3306}"

OSS_BUCKET="${OSS_BUCKET:-k3s-backup-velero}"
OSS_PREFIX="${OSS_PREFIX:-mysql-inspect}"
OSSUTIL_BIN="${OSSUTIL_BIN:-/usr/local/bin/ossutil}"
OSS_ENDPOINT="${OSS_ENDPOINT:-oss-cn-hangzhou-internal.aliyuncs.com}"
REPORT_DIR="${REPORT_DIR:-/var/log/mysql-inspect}"

# my.cnf 已配置 [client] host/port/user/password, mysql 命令会自动读取
MYSQL_CMD="mysql -h ${MYSQL_HOST} -P ${MYSQL_PORT} -u ${MYSQL_USER}"
MYSQLADMIN_CMD="mysqladmin -h ${MYSQL_HOST} -P ${MYSQL_PORT} -u ${MYSQL_USER}"

# ── Dry-run / Local-only mode ─────────────────────────────────
DRY_RUN=false
LOCAL_ONLY=false
for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=true ;;
        --local) LOCAL_ONLY=true ;;
    esac
done

DATE="$(date +%Y%m%d-%H%M%S)"
REPORT="${REPORT_DIR}/mysql-inspect-${DATE}.txt"

# ── Helper: section separator ────────────────────────────────
section() {
    local title="$1"
    {
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ${title}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    } >> "${REPORT}"
}

write_report() {
    echo -e "$*" >> "${REPORT}"
}

run_query() {
    ${MYSQL_CMD} -N -e "$1" 2>/dev/null || echo "ERROR: query failed"
}

# ── Pre-flight checks ───────────────────────────────────────
if ${DRY_RUN}; then
    echo "[DRY-RUN] db-inspect.sh"
    echo "  MYSQL_USER=${MYSQL_USER}"
    echo "  MYSQL_HOST=${MYSQL_HOST}"
    echo "  MYSQL_PORT=${MYSQL_PORT}"
    echo "  OSS_BUCKET=${OSS_BUCKET}"
    echo "  OSS_PREFIX=${OSS_PREFIX}"
    echo "  OSS_ENDPOINT=${OSS_ENDPOINT}"
    echo "  REPORT_DIR=${REPORT_DIR}"
    echo "  REPORT=${REPORT}"
    echo ""
    echo "  Would run 7 inspection sections + OSS push"
    exit 0
fi

# MySQL connectivity check
if ! ${MYSQLADMIN_CMD} ping --silent 2>/dev/null; then
    echo "FATAL: MySQL not reachable. Check /root/.my.cnf credentials."
    exit 1
fi

mkdir -p "${REPORT_DIR}"

# ── Report Header ────────────────────────────────────────────
{
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              MySQL 巡检报告                                ║"
    echo "║  时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "║  主机: $(hostname -f 2>/dev/null || hostname)"
    echo "╚══════════════════════════════════════════════════════════════╝"
} > "${REPORT}"

HOSTNAME_SHORT=$(hostname -s 2>/dev/null || echo "unknown")

# ── 1. 基础信息 ────────────────────────────────────────────
section "1. 基础信息"

VERSION=$(run_query "SELECT VERSION();")
UPTIME_SEC=$(${MYSQLADMIN_CMD} status 2>/dev/null | sed -n 's/.*Uptime: \([0-9]*\).*/\1/p')
if [ -n "${UPTIME_SEC}" ]; then
    UPTIME_DAYS=$((UPTIME_SEC / 86400))
    UPTIME_HOURS=$(( (UPTIME_SEC % 86400) / 3600 ))
    UPTIME_MIN=$(( (UPTIME_SEC % 3600) / 60 ))
    UPTIME_STR="${UPTIME_DAYS} 天 ${UPTIME_HOURS} 小时 ${UPTIME_MIN} 分钟"
else
    UPTIME_STR="(unknown)"
fi

write_report "  MySQL 版本:  ${VERSION}"
write_report "  运行时间:    ${UPTIME_STR}"

# Replica status (Slave 专属)
# 使用 ${MYSQL_CMD} -e 而非 run_query (含 -N), 因为 \G 输出需要字段名才能解析
REPLICA_INFO=$(${MYSQL_CMD} -e "SHOW REPLICA STATUS\\G" 2>/dev/null || echo "")
if [ -n "${REPLICA_INFO}" ]; then
    IO_RUNNING=$(echo "${REPLICA_INFO}" | awk -F': ' '/Replica_IO_Running:/{print $2}' | tr -d ' ')
    SQL_RUNNING=$(echo "${REPLICA_INFO}" | awk -F': ' '/Replica_SQL_Running:/{print $2}' | tr -d ' ')
    BEHIND_MASTER=$(echo "${REPLICA_INFO}" | awk -F': ' '/Seconds_Behind_Source:/{print $2}' | tr -d ' ')
    SOURCE_HOST=$(echo "${REPLICA_INFO}" | awk -F': ' '/Source_Host:/{print $2}' | tr -d ' ')

    IO_ICON="❌"
    [ "${IO_RUNNING}" = "Yes" ] && IO_ICON="✅"
    SQL_ICON="❌"
    [ "${SQL_RUNNING}" = "Yes" ] && SQL_ICON="✅"

    write_report "  复制状态:"
    write_report "    主库地址:  ${SOURCE_HOST:-N/A}"
    write_report "    IO 线程:   ${IO_ICON} ${IO_RUNNING:-No}"
    write_report "    SQL 线程:  ${SQL_ICON} ${SQL_RUNNING:-No}"
    write_report "    复制延迟:  ${BEHIND_MASTER:-N/A} 秒"
else
    write_report "  复制状态:  ⚠️  (非 Slave 节点或无复制配置)"
fi

# ── 2. 空间概览 ────────────────────────────────────────────
section "2. 空间概览"

TOTAL_SIZE=$(run_query "
  SELECT CONCAT(ROUND(SUM(data_length + index_length) / 1024 / 1024, 2), ' MB')
  FROM information_schema.tables
  WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys');" 2>/dev/null)
write_report "  总数据量 (含索引):  ${TOTAL_SIZE:-0 MB}"

# Top 10 大表
write_report ""
write_report "  TOP 10 大表:"
run_query "
  SELECT CONCAT(table_schema, '.', table_name) AS '表名',
         CONCAT(ROUND((data_length + index_length) / 1024 / 1024, 2), ' MB') AS '总大小',
         CONCAT(ROUND(data_length / 1024 / 1024, 2), ' MB') AS '数据',
         CONCAT(ROUND(index_length / 1024 / 1024, 2), ' MB') AS '索引',
         table_rows AS '行数'
  FROM information_schema.tables
  WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys')
  ORDER BY (data_length + index_length) DESC
  LIMIT 10;" | column -t -s $'\t' >> "${REPORT}" 2>/dev/null || true

# 最大表
MAX_TABLE=$(run_query "
  SELECT CONCAT(table_schema, '.', table_name)
  FROM information_schema.tables
  WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys')
  ORDER BY (data_length + index_length) DESC
  LIMIT 1;" 2>/dev/null)
write_report ""
write_report "  最大表:  ${MAX_TABLE:-N/A}"

# ── 3. 碎片率 ────────────────────────────────────────────
section "3. 碎片分析"

# 碎片率 > 30% 的表
FRAG_SQL="
  SELECT CONCAT(table_schema, '.', table_name) AS '表名',
         CONCAT(ROUND(data_length / 1024 / 1024, 2), ' MB') AS '数据大小',
         CONCAT(ROUND(data_free / 1024 / 1024, 2), ' MB') AS '碎片大小',
         CONCAT(ROUND(data_free / NULLIF(data_length, 0) * 100, 1), ' %') AS '碎片率'
  FROM information_schema.tables
  WHERE table_schema NOT IN ('mysql','performance_schema','information_schema','sys')
    AND data_length > 0
    AND data_free / data_length > 0.3
  ORDER BY data_free / data_length DESC;"

FRAG_RESULT=$(run_query "${FRAG_SQL}" 2>/dev/null)
if [ -z "${FRAG_RESULT}" ] || echo "${FRAG_RESULT}" | grep -q "ERROR"; then
    write_report "  碎片率 > 30% 的表:  无  ✅"
else
    write_report "  碎片率 > 30% 的表  (建议 OPTIMIZE TABLE):"
    echo "${FRAG_RESULT}" | column -t -s $'\t' >> "${REPORT}" 2>/dev/null || true
fi

# ── 4. 慢查询 ────────────────────────────────────────────
section "4. 慢查询分析"

SLOW_LOG_DIR="/var/lib/mysql"
# MySQL 8.0 slow query log 默认路径
SLOW_LOGS=$(find "${SLOW_LOG_DIR}" -name "*-slow.log" -o -name "slow.log" 2>/dev/null || true)

if [ -z "${SLOW_LOGS}" ]; then
    write_report "  慢查询日志:  未找到 (可能未启用 slow_query_log)"
else
    for SL in ${SLOW_LOGS}; do
        SL_NAME=$(basename "${SL}")
        SL_COUNT=$(grep -c "^# Time:" "${SL}" 2>/dev/null || echo "0")
        write_report "  ${SL_NAME}:  ${SL_COUNT} 条慢查询记录"

        # Top 10 耗时最长的慢查询 (需要 mysqldumpslow)
        if command -v mysqldumpslow &>/dev/null && [ "${SL_COUNT}" -gt 0 ]; then
            write_report ""
            write_report "  TOP 10 慢查询 (按耗时):"
            mysqldumpslow -s t -t 10 "${SL}" 2>/dev/null >> "${REPORT}" || true
        fi
    done
fi

# ── 5. 复制延迟 (详细) ──────────────────────────────────
section "5. 复制延迟"

# 复用 awk -F': ' 解析, 避免多次查询 (不用 run_query 因为 -N 会去掉字段名)
REPLICA_EXTRA=$(${MYSQL_CMD} -e "SHOW REPLICA STATUS\\G" 2>/dev/null || echo "")
REPL_LAG=$(echo "${REPLICA_EXTRA}" | awk -F': ' '/Seconds_Behind_Source:/{print $2}' | tr -d ' ')
REPL_IO_ERR=$(echo "${REPLICA_EXTRA}" | awk -F': ' '/Last_IO_Error:/{print $2}')
REPL_SQL_ERR=$(echo "${REPLICA_EXTRA}" | awk -F': ' '/Last_SQL_Error:/{print $2}')

write_report "  Seconds_Behind_Source:  ${REPL_LAG:-N/A}"
write_report ""
if [ -n "${REPL_IO_ERR}" ] && [ "${REPL_IO_ERR}" != "" ]; then
    write_report "  最近 IO 错误:  ${REPL_IO_ERR}"
fi
if [ -n "${REPL_SQL_ERR}" ] && [ "${REPL_SQL_ERR}" != "" ]; then
    write_report "  最近 SQL 错误:  ${REPL_SQL_ERR}"
fi
if [ "${REPL_LAG:-999}" = "0" ]; then
    write_report "  状态:  ✅ 无延迟"
elif [ "${REPL_LAG:-999}" != "N/A" ] && [ "${REPL_LAG:-999}" -lt 10 ]; then
    write_report "  状态:  ⚠️ 轻微延迟 (${REPL_LAG} 秒)"
elif [ "${REPL_LAG:-999}" != "N/A" ]; then
    write_report "  状态:  ❌ 严重延迟 (${REPL_LAG} 秒)"
fi

# ── 6. 连接 ────────────────────────────────────────────
section "6. 连接状态"

CONN_TOTAL=$(run_query "SELECT COUNT(*) FROM information_schema.processlist;" 2>/dev/null || echo "0")
CONN_ACTIVE=$(run_query "SELECT COUNT(*) FROM information_schema.processlist WHERE command != 'Sleep';" 2>/dev/null || echo "0")
CONN_MAX=$(run_query "SELECT VARIABLE_VALUE FROM performance_schema.global_variables WHERE variable_name='max_connections';" 2>/dev/null || echo "151")

write_report "  总连接数:    ${CONN_TOTAL}"
write_report "  活跃连接:    ${CONN_ACTIVE}"
write_report "  最大连接:    ${CONN_MAX}"

write_report ""
write_report "  来源 IP 分布:"
# 各来源 IP 的连接数
run_query "
  SELECT IF(host LIKE '%:%', 'unix-socket', SUBSTRING_INDEX(host, ':', 1)) AS source_ip,
         COUNT(*) AS connections
  FROM information_schema.processlist
  GROUP BY source_ip
  ORDER BY connections DESC;" | column -t -s $'\t' >> "${REPORT}" 2>/dev/null || true

# ── 7. 性能 (InnoDB Buffer Pool 命中率) ─────────────────
section "7. 性能指标"

# InnoDB Buffer Pool 命中率
BP_READS=$(run_query "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read_requests';" 2>/dev/null | grep -oP '\d+' || echo "0")
BP_MISS=$(run_query "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_reads';" 2>/dev/null | grep -oP '\d+' || echo "0")
BP_HIT_RATE="N/A"
if [ "${BP_READS}" -gt 0 ] 2>/dev/null; then
    BP_HIT_RATE=$(awk "BEGIN {printf \"%.2f\", (1 - ${BP_MISS} / ${BP_READS}) * 100}")
fi
write_report "  Buffer Pool 命中率:  ${BP_HIT_RATE}%"
write_report "    (read_requests=${BP_READS}, reads=${BP_MISS})"

# 查询缓存状态 (MySQL 8.0 已移除查询缓存)
QCACHE=$(run_query "SHOW GLOBAL STATUS LIKE 'Qcache_%';" 2>/dev/null || echo "")
if [ -n "${QCACHE}" ]; then
    write_report ""
    write_report "  查询缓存:"
    echo "${QCACHE}" | while IFS= read -r line; do
        write_report "    ${line}"
    done
else
    write_report "  查询缓存:  MySQL 8.0+ 已移除"
fi

# 关键 InnoDB 指标
write_report ""
write_report "  关键 InnoDB 状态变量:"
for VAR in "Innodb_rows_read" "Innodb_rows_inserted" "Innodb_rows_updated" "Innodb_rows_deleted"; do
    VAL=$(run_query "SHOW GLOBAL STATUS LIKE '${VAR}';" 2>/dev/null | grep -oP '\d+' || echo "0")
    write_report "    ${VAR}:  ${VAL}"
done

# ── 7b. 错误日志摘要 ──────────────────────────────────
section "8. 错误日志 (近 7 天)"

ERROR_LOG="/var/log/mysqld.log"
if [ -f "${ERROR_LOG}" ]; then
    ERROR_COUNT=$(grep -i "error" "${ERROR_LOG}" 2>/dev/null | grep "$(date -d '7 days ago' '+%Y-%m-%d' 2>/dev/null || echo '')" 2>/dev/null | wc -l || echo "0")
    write_report "  日志文件:  ${ERROR_LOG}"
    write_report "  近 7 天 ERROR 条数:  ${ERROR_COUNT}"

    # 输出最近 5 条错误
    RECENT_ERRORS=$(grep -i "error" "${ERROR_LOG}" 2>/dev/null | tail -5)
    if [ -n "${RECENT_ERRORS}" ]; then
        write_report ""
        write_report "  最近 5 条 ERROR:"
        echo "${RECENT_ERRORS}" | while IFS= read -r line; do
            write_report "    ${line}"
        done
    fi
else
    write_report "  日志文件  ${ERROR_LOG}  不存在"
    # 尝试查找其他可能的错误日志路径
    ALT_LOGS=$(find /var/log -name "mysql*" -o -name "mysqld*" 2>/dev/null | head -5)
    if [ -n "${ALT_LOGS}" ]; then
        write_report "  发现其他日志文件:"
        for LF in ${ALT_LOGS}; do
            write_report "    ${LF}"
        done
    fi
fi

# ── Summary ────────────────────────────────────────────
section "9. 综合摘要"

# 自动判定告警
ALERTS=""

# 1) 复制延迟 > 10s
if [ -n "${REPL_LAG:-}" ] && [ "${REPL_LAG:-0}" -gt 10 ] 2>/dev/null; then
    ALERTS="${ALERTS}  ❌ 复制延迟 ${REPL_LAG} 秒\n"
fi

# 2) Buffer Pool 命中率 < 95%
if [ "${BP_HIT_RATE}" != "N/A" ]; then
    BP_VAL=$(echo "${BP_HIT_RATE}" | awk -F'.' '{print $1}')
    if [ "${BP_VAL:-100}" -lt 95 ] 2>/dev/null; then
        ALERTS="${ALERTS}  ⚠️  Buffer Pool 命中率偏低: ${BP_HIT_RATE}% (建议 >95%)\n"
    fi
fi

# 3) 碎片率 > 30% 的表
if [ -z "${FRAG_RESULT}" ] || echo "${FRAG_RESULT}" | grep -q "ERROR\|无"; then
    : # no alert needed
else
    FRAG_COUNT=$(echo "${FRAG_RESULT}" | wc -l)
    ALERTS="${ALERTS}  ⚠️  发现 ${FRAG_COUNT} 个碎片率 >30% 的表，建议 OPTIMIZE\n"
fi

# 4) 连接数使用率 > 80%
if [ "${CONN_TOTAL:-0}" -gt 0 ] && [ "${CONN_MAX:-151}" -gt 0 ] 2>/dev/null; then
    CONN_RATIO=$(awk "BEGIN {printf \"%.0f\", ${CONN_TOTAL} / ${CONN_MAX} * 100}" 2>/dev/null)
    if [ "${CONN_RATIO:-0}" -gt 80 ] 2>/dev/null; then
        ALERTS="${ALERTS}  ⚠️  连接数使用率 ${CONN_RATIO}% (${CONN_TOTAL}/${CONN_MAX})\n"
    fi
fi

if [ -z "${ALERTS}" ]; then
    write_report "  无告警 ✅"
else
    write_report "  告警项:"
    echo -e "${ALERTS}" >> "${REPORT}" 2>/dev/null || true
fi

# ── Footer ────────────────────────────────────────────────
{
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  巡检完成                                                    ║"
    echo "║  $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "╚══════════════════════════════════════════════════════════════╝"
} >> "${REPORT}"

# ── Push to OSS ────────────────────────────────────────────
if ${LOCAL_ONLY}; then
    echo "Report generated (local-only): ${REPORT}"
    echo ""
    wc -l "${REPORT}"
    exit 0
fi

if ! command -v "${OSSUTIL_BIN}" &>/dev/null; then
    echo "WARNING: ${OSSUTIL_BIN} not found. Report saved locally: ${REPORT}"
    exit 0
fi

echo "--- Pushing report to OSS: ${OSS_BUCKET}/${OSS_PREFIX}/ ---"
"${OSSUTIL_BIN}" cp "${REPORT}" \
  "oss://${OSS_BUCKET}/${OSS_PREFIX}/$(basename "${REPORT}")" \
  -e "${OSS_ENDPOINT}"
echo "OSS push complete."

# ── Final Summary ─────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " MySQL inspection complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Host:           ${HOSTNAME_SHORT}"
echo " Report:         ${REPORT}"
echo " Report size:    $(wc -c < "${REPORT}" 2>/dev/null || echo '?') bytes"
echo " OSS location:   oss://${OSS_BUCKET}/${OSS_PREFIX}/$(basename "${REPORT}")"
echo " Contains:"
echo "   - 基本信息 & 复制状态"
echo "   - 空间概览 & TOP 10 大表"
echo "   - 碎片分析"
echo "   - 慢查询 (TOP 10)"
echo "   - 复制延迟"
echo "   - 连接状态 & 来源 IP"
echo "   - InnoDB Buffer Pool 命中率"
echo "   - 错误日志摘要 (近 7 天)"
echo "   - 综合摘要 & 告警"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
