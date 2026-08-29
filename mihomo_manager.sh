#!/bin/bash
# ==============================================================================
# Caesar 蜜汁 Mihomo 管理工具
# 统一管理安装、分流、卸载及Geo文件更新等脚本
# ==============================================================================

# --- 全局设置 ---
set -uo pipefail
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[96m'
PLAIN='\033[0m'

# --- 仓库配置 ---
GITHUB_USER="RomanovCaesar"
GITHUB_REPO="Install-Mihomo-Inbounds"
GITHUB_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

# --- 本地路径 ---
MANAGER_PATH="/usr/bin/mihomo-manager"
WORK_DIR="/root"

# --- 基础函数 ---
die() { echo -e "${RED}[ERROR] $*${PLAIN}" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO] $*${PLAIN}"; }
warn() { echo -e "${YELLOW}[WARN] $*${PLAIN}"; }

# --- 权限检测 ---
check_root() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] && die "请以 root 身份运行此脚本。"
}

# --- 依赖检测 ---
check_deps() {
    if ! command -v curl >/dev/null 2>&1; then
        info "正在安装 curl..."
        if [ -f /etc/alpine-release ]; then
            apk add --no-cache curl
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y curl
        else
            die "无法自动安装 curl，请先手动安装。"
        fi
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        info "正在安装 python3..."
        if [ -f /etc/alpine-release ]; then
            apk add --no-cache python3
        elif command -v apt-get >/dev/null 2>&1; then
            apt-get update && apt-get install -y python3
        else
            die "无法自动安装 python3，请先手动安装。"
        fi
    fi
    local required=(curl python3 bash install mktemp realpath)
    local cmd
    for cmd in "${required[@]}"; do command -v "$cmd" >/dev/null 2>&1 || die "缺少必要命令: $cmd"; done
}

download_script() {
    local download_url="$1"
    local target_file="$2"
    local tmp_file
    tmp_file="$(mktemp "${target_file}.tmp.XXXXXX")" || return 1

    if ! curl -fsSL -o "$tmp_file" "$download_url"; then
        rm -f "$tmp_file"
        return 1
    fi
    if ! bash -n "$tmp_file"; then
        warn "下载内容未通过 Bash 语法检查，拒绝覆盖 $target_file。"
        rm -f "$tmp_file"
        return 1
    fi
    if ! chmod 0755 "$tmp_file" || ! mv -f "$tmp_file" "$target_file"; then
        rm -f "$tmp_file"
        return 1
    fi
}

# --- 自我安装 ---
install_self() {
    local current_path
    current_path="$(realpath "$0")"
    
    if [[ "$current_path" != "$MANAGER_PATH" ]]; then
        info "正在安装管理脚本到 $MANAGER_PATH ..."
        cp "$current_path" "$MANAGER_PATH"
        chmod +x "$MANAGER_PATH"
        info "安装完成！以后可以直接在终端输入 ${CYAN}mihomo-manager${PLAIN} 唤醒此菜单。"
        sleep 1
        exec "$MANAGER_PATH" "$@"
    fi
}

# --- 核心：拉取并运行脚本 ---
pull_and_run() {
    local script_name="$1"
    local desc="${2:-运行脚本}"
    local target_file="${WORK_DIR}/${script_name}"
    local download_url="${BASE_URL}/${script_name}"

    info "正在拉取: $script_name ..."
    
    if download_script "$download_url" "$target_file"; then
        info "拉取成功，正在$desc..."
        echo "----------------------------------------------------------------"
        if ! (cd "$WORK_DIR" && ./"$script_name"); then
            warn "$script_name 执行失败，请查看上方错误信息。"
        fi
        
        echo "----------------------------------------------------------------"
        read -n 1 -s -r -p "子脚本执行结束，按任意键返回主菜单..." || true
    else
        echo -e "${RED}[ERROR] 无法下载脚本: $script_name${PLAIN}"
        echo -e "${RED}请检查网络连接或 Github 仓库地址是否正确。${PLAIN}"
        read -n 1 -s -r -p "按任意键返回主菜单..." || true
    fi
}

# --- 功能: 更新自身 ---
update_self() {
    info "正在检查更新..."
    local download_url="${BASE_URL}/mihomo_manager.sh"
    
    if download_script "$download_url" "$MANAGER_PATH"; then
        info "脚本更新成功！正在重新加载..."
        sleep 1
        exec "$MANAGER_PATH"
    else
        die "更新失败，请检查网络。"
    fi
}

# --- 主菜单 ---
show_menu() {
    clear
    echo -e "${CYAN}=================================================${PLAIN}"
    echo -e "${CYAN}          Caesar 蜜汁 Mihomo 管理工具             ${PLAIN}"
    echo -e "${CYAN}=================================================${PLAIN}"
    echo -e "  ${GREEN}1.${PLAIN} Geo文件更新 (立即执行，不设定时任务)"
    echo -e "  ${GREEN}2.${PLAIN} 安装/管理 Shadowsocks (2022)"
    echo -e "  ${GREEN}3.${PLAIN} 安装/管理 VLESS Reality"
    echo -e "  ${GREEN}4.${PLAIN} 安装/管理 VLESS Encryption (PQ)"
    echo -e "  ${YELLOW}5.${PLAIN} Mihomo 服务端分流配置 (Routing)"
    echo -e "  ${RED}6.${PLAIN} 卸载 Mihomo 及相关文件"
    echo -e "  ${CYAN}7.${PLAIN} 还原 Mihomo 配置 (Restore)"
    echo "-------------------------------------------------"
    echo -e "  ${CYAN}8.${PLAIN} 更新此管理脚本"
    echo -e "  ${CYAN}0.${PLAIN} 退出脚本"
    echo -e "${CYAN}=================================================${PLAIN}"
    
    read -rp " 请输入选项 [0-8]: " choice
    
    case "$choice" in
        1) pull_and_run "update_geo.sh" "更新 GeoIP/GeoSite" ;;
        2) pull_and_run "install_ss2022.sh" "执行 SS2022 安装向导" ;;
        3) pull_and_run "install_vless_reality.sh" "执行 VLESS Reality 安装向导" ;;
        4) pull_and_run "install_vless_encryption.sh" "执行 VLESS Encryption (PQ) 安装向导" ;;
        5) pull_and_run "mihomo_routing.sh" "进入分流配置工具" ;;
        6) pull_and_run "uninstall_mihomo.sh" "执行卸载程序" ;;
        7) pull_and_run "mihomo_restore.sh" "执行配置还原工具" ;;
        8) update_self ;;
        0) echo -e "${GREEN}感谢使用此脚本，再见！${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}无效输入，请重新选择。${PLAIN}"; sleep 1 ;;
    esac
}

# --- 入口逻辑 ---
main() {
    check_root
    check_deps
    install_self
    
    while true; do
        show_menu
    done
}

main "$@"
