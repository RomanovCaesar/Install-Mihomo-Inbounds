#!/bin/bash
# update_geo.sh
# 用于自动更新 Mihomo 的 Geo 文件并重启服务
# 适配 Debian/Ubuntu (systemd) 和 Alpine (OpenRC)

# --- 环境变量设置 ---
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- 配置路径 ---
GEO_DIR="/usr/local/etc/mihomo"
DOWNLOAD_URL_GEOIP="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.metadb"
DOWNLOAD_URL_GEOSITE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"

# --- 日志函数 ---
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# --- 1. 下载文件 ---
log "开始下载 Geo 文件..."
mkdir -p "$GEO_DIR"

if curl -fsSL -o "$GEO_DIR/geoip.metadb" "$DOWNLOAD_URL_GEOIP"; then
    log "geoip.metadb 下载成功"
else
    log "Error: geoip.metadb 下载失败"
    exit 1
fi

if curl -fsSL -o "$GEO_DIR/geosite.dat" "$DOWNLOAD_URL_GEOSITE"; then
    log "geosite.dat 下载成功"
else
    log "Error: geosite.dat 下载失败"
    exit 1
fi

# --- 2. 重启 Mihomo 服务 ---
log "正在重启 Mihomo 服务..."

if command -v systemctl >/dev/null 2>&1; then
    systemctl restart mihomo
    if systemctl is-active --quiet mihomo; then
        log "Mihomo (systemd) 重启成功"
    else
        log "Error: Mihomo 重启失败，请检查日志"
    fi
elif command -v rc-service >/dev/null 2>&1; then
    rc-service mihomo restart
    if rc-service mihomo status | grep -q "started"; then
        log "Mihomo (OpenRC) 重启成功"
    else
        log "Error: Mihomo 重启失败"
    fi
else
    log "Warning: 未找到 systemctl 或 rc-service，无法重启 Mihomo"
fi

log "更新流程结束"
