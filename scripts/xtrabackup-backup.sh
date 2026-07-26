#!/usr/bin/env bash
# xtrabackup-backup.sh -- MySQL 全量备份 via Percona XtraBackup, 推送 OSS
#
# 在 node-03 (MySQL Slave) 运行, 避免 Master 负载。
# 流式压缩备份, 上传 OSS, 清理旧本地副本。
#
# 用法:
#   /usr/local/bin/xtrabackup-backup.sh           # 全量备份 + 上传
#   /usr/local/bin/xtrabackup-backup.sh --dry-run # 仅展示
#
# Cron: 0 2 * * * /usr/local/bin/xtrabackup-backup.sh >> /var/log/xtrabackup-backup.log 2>&1

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-CHANGE_ME}"
BACKUP_DIR="${BACKUP_DIR:-/data/backups/mysql}"
OSS_BUCKET="${OSS_BUCKET:-k3s-backup-velero}"
OSS_PREFIX="${OSS_PREFIX:-mysql-backups}"
OSSUTIL_BIN="${OSSUTIL_BIN:-/usr/local/bin/ossutil}"
OSS_ENDPOINT="${OSS_ENDPOINT:-oss-cn-hangzhou-internal.aliyuncs.com}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
DATE="$(date +%Y%m%d-%H%M%S)"
BACKUP_NAME="mysql-full-${DATE}"
BACKUP_FILE="${BACKUP_DIR}/${BACKUP_NAME}.xbstream.gz"

# ── Dry-run ────────────────────────────────────────────────────
if [ "${1:-}" = "--dry-run" ]; then
    echo "[DRY-RUN] xtrabackup-backup.sh"
    echo "  MYSQL_USER=${MYSQL_USER}"
    echo "  BACKUP_DIR=${BACKUP_DIR}"
    echo "  OSS_BUCKET=${OSS_BUCKET}"
    echo "  OSS_PREFIX=${OSS_PREFIX}"
    echo "  OSS_ENDPOINT=${OSS_ENDPOINT}"
    echo "  RETENTION_DAYS=${RETENTION_DAYS}"
    echo "  BACKUP_FILE=${BACKUP_FILE}"
    echo ""
    echo "  Would run: xtrabackup --backup --stream=xbstream ... | gzip > ${BACKUP_FILE}"
    echo "  Would push: ossutil cp ${BACKUP_FILE} oss://${OSS_BUCKET}/${OSS_PREFIX}/"
    echo "  Would clean: find ${BACKUP_DIR} -name 'mysql-full-*.xbstream.gz' -mtime +${RETENTION_DAYS} -delete"
    exit 0
fi

# ── Pre-flight checks ────────────────────────────────────────
if ! command -v xtrabackup &>/dev/null; then
    echo "FATAL: xtrabackup not found. Install percona-xtrabackup-80 first."
    exit 1
fi

if ! command -v "${OSSUTIL_BIN}" &>/dev/null; then
    echo "FATAL: ossutil not found at ${OSSUTIL_BIN}. Install ossutil first."
    exit 1
fi

if ! mysqladmin ping -u"${MYSQL_USER}" -p"${MYSQL_PASSWORD}" --silent 2>/dev/null; then
    echo "WARNING: MySQL not reachable with current credentials. Check MYSQL_USER/MYSQL_PASSWORD."
    exit 1
fi

mkdir -p "${BACKUP_DIR}"

# Check available disk space (warn if < 5G)
AVAIL_KB=$(df "${BACKUP_DIR}" | tail -1 | awk '{print $4}')
if [ "${AVAIL_KB}" -lt 5242880 ]; then
    echo "WARNING: Low disk space in ${BACKUP_DIR}: $((AVAIL_KB / 1024))M available"
fi

# ── Backup ─────────────────────────────────────────────────────
# 流式备份直接写入压缩文件 (无中间暂存)
# --slave-info: 记录 relay log 位置 (replica 备份)
# --no-lock: Slave 只读 (super_read_only=ON), 安全无需锁
# --safe-slave-backup: 暂停 SQL 线程确保 binlog 位置与备份一致
# 密码通过 /root/.my.cnf [client] user=root password=XXX 提供

echo "--- Starting xtrabackup: ${BACKUP_NAME} ---"
xtrabackup --backup \
  --stream=xbstream \
  --user="${MYSQL_USER}" \
  --password="${MYSQL_PASSWORD}" \
  --slave-info \
  --no-lock \
  --safe-slave-backup \
  | gzip > "${BACKUP_FILE}"

# ── Verify backup ─────────────────────────────────────────────
BACKUP_SIZE=$(stat -c%s "${BACKUP_FILE}" 2>/dev/null || stat -f%z "${BACKUP_FILE}" 2>/dev/null || echo "0")
if [ "${BACKUP_SIZE}" -eq 0 ]; then
    echo "FATAL: Backup file is empty: ${BACKUP_FILE}"
    rm -f "${BACKUP_FILE}"
    exit 1
fi
echo "Backup file size: $(du -h "${BACKUP_FILE}" | cut -f1)"

# ── Push to OSS ───────────────────────────────────────────────
echo "--- Uploading to OSS: ${OSS_BUCKET}/${OSS_PREFIX}/ ---"
"${OSSUTIL_BIN}" cp "${BACKUP_FILE}" \
  "oss://${OSS_BUCKET}/${OSS_PREFIX}/$(basename "${BACKUP_FILE}")" \
  -e "${OSS_ENDPOINT}"

# ── Cleanup old local backups ─────────────────────────────────
# 保留本地最近 2 份 (快速恢复), OSS Lifecycle Rule 处理远端 7 天清理
echo "--- Cleaning up local backups older than ${RETENTION_DAYS} days ---"
find "${BACKUP_DIR}" -name "mysql-full-*.xbstream.gz" -mtime +${RETENTION_DAYS} -delete

# ── Summary ───────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " MySQL backup complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Backup name:    ${BACKUP_NAME}"
echo " Local file:     ${BACKUP_FILE}"
echo " Local size:     $(du -h "${BACKUP_FILE}" | cut -f1)"
echo " OSS location:   oss://${OSS_BUCKET}/${OSS_PREFIX}/$(basename "${BACKUP_FILE}")"
echo " Retention:      ${RETENTION_DAYS} days (OSS lifecycle rule)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
