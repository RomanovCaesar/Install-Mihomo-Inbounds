#!/usr/bin/env bash
# uninstall_mihomo.sh
# 更稳健的 Mihomo 卸载脚本：systemd/OpenRC 全面清理
set -uo pipefail  # 去掉 -e，避免提前退出

PURGE=false
ASSUME_YES=false
CONFIG_REMOVED=false
CONFIG_BACKUP=""

die()  { echo -e "\e[31m[ERROR]\e[0m $*" >&2; exit 1; }
info() { echo -e "\e[32m[INFO]\e[0m $*"; }
warn() { echo -e "\e[33m[WARN]\e[0m $*"; }

for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=true ;;
    --yes|-y) ASSUME_YES=true ;;
    *) die "未知参数: $arg（支持 --yes 和 --purge）" ;;
  esac
done

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "请以 root 身份运行（使用 sudo）"
  fi
}

confirm_uninstall() {
  $ASSUME_YES && return 0
  if [[ ! -t 0 ]]; then
    die "非交互环境必须显式传入 --yes 才会执行卸载。"
  fi
  local answer
  read -r -p "确定卸载 Mihomo 并删除其程序与配置吗？[y/N]: " answer
  [[ "$answer" =~ ^[yY]$ ]] || { info "已取消卸载。"; exit 0; }
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID,,}"
  else
    OS_ID="unknown"
  fi
  case "$OS_ID" in
    debian|ubuntu) OS_FAMILY="debian" ;;
    alpine)        OS_FAMILY="alpine" ;;
    *)             OS_FAMILY="other" ;;
  esac
  info "系统：${PRETTY_NAME:-$OS_ID}"
}

has_systemd() { command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

collect_mihomo_units() {
  if ! has_systemd; then
    return 0
  fi

  # 1) unit-files
  systemctl list-unit-files --type=service --no-pager --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E '.*mihomo.*\.service$' || true

  # 2) list-units
  systemctl list-units --type=service --all --no-pager --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -E '.*mihomo.*\.service$' || true

  # 3) 兜底
  for f in /etc/systemd/system/*mihomo*.service /lib/systemd/system/*mihomo*.service /usr/lib/systemd/system/*mihomo*.service; do
    [[ -f "$f" ]] && basename "$f"
  done
}

stop_disable_systemd_units() {
  has_systemd || { warn "未检测到已注册的 Mihomo 服务（systemd）。"; return 0; }

  mapfile -t units < <(collect_mihomo_units | awk 'NF && !seen[$0]++')
  if ((${#units[@]}==0)); then
    warn "未检测到已注册的 Mihomo 服务（systemd）。"
    return 0
  fi

  info "检测到以下 systemd 单元将被停止并禁用："
  for u in "${units[@]}"; do echo "  - $u"; done

  for u in "${units[@]}"; do
    systemctl stop "$u" --no-block 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
    systemctl reset-failed "$u" 2>/dev/null || true
  done

  for wants in /etc/systemd/system/*/*mihomo*.service; do
    [[ -L "$wants" || -f "$wants" ]] && { info "移除残留链接/文件：$wants"; rm -f "$wants" || true; }
  done
}

remove_systemd_files() {
  has_systemd || return 0
  local removed=false
  for f in /etc/systemd/system/*mihomo*.service /lib/systemd/system/*mihomo*.service /usr/lib/systemd/system/*mihomo*.service; do
    if [[ -f "$f" ]]; then
      info "删除 systemd 单元文件：$f"
      rm -f "$f" || true
      removed=true
    fi
  done
  $removed && systemctl daemon-reload || true
}

stop_disable_openrc() {
  if command -v rc-update >/dev/null 2>&1 && [[ -f /etc/init.d/mihomo ]]; then
    info "检测到 OpenRC 服务，停止并移出开机自启 ..."
    rc-service mihomo stop || true
    rc-update del mihomo default || true
  else
    warn "未检测到已注册的 Mihomo 服务（OpenRC）。"
  fi
}

remove_openrc_files() {
  [[ -f /etc/init.d/mihomo ]] && { info "删除 OpenRC 脚本 /etc/init.d/mihomo"; rm -f /etc/init.d/mihomo || true; }
  [[ -f /run/mihomo.pid ]] && rm -f /run/mihomo.pid || true
}

backup_and_remove_config() {
  local cfg_dir="/usr/local/etc/mihomo"
  if [[ -d "$cfg_dir" ]]; then
    local ts backup
    ts="$(date +%Y%m%d-%H%M%S)"
    backup="/root/mihomo-config-backup-${ts}-$$.tar.gz"
    info "备份配置目录到 $backup"
    if ! tar -czf "$backup" -C "$(dirname "$cfg_dir")" "$(basename "$cfg_dir")"; then
      warn "配置备份失败，出于安全考虑不会删除 $cfg_dir"
      rm -f "$backup" 2>/dev/null || true
      return 1
    fi
    chmod 600 "$backup" || { warn "无法收紧备份文件权限，配置目录不会删除。"; return 1; }
    info "删除配置目录 $cfg_dir"
    if ! rm -rf "$cfg_dir"; then
      warn "配置目录删除失败：$cfg_dir"
      return 1
    fi
    CONFIG_REMOVED=true
    CONFIG_BACKUP="$backup"
    echo -e "\e[34m[NOTE]\e[0m 备份已保存：$backup"
  else
    warn "未找到配置目录：$cfg_dir"
  fi
}

remove_binary_and_misc() {
  local bin="/usr/local/bin/mihomo"
  [[ -f "$bin" ]] && { info "删除二进制文件 $bin"; rm -f "$bin" || true; } || warn "未找到二进制文件：$bin"

  for d in /usr/local/share/mihomo /usr/share/mihomo /var/lib/mihomo; do
    [[ -d "$d" ]] && { info "删除数据目录 $d"; rm -rf "$d" || true; }
  done

  for f in /var/log/mihomo.log /var/log/mihomo/mihomo.log; do
    [[ -f "$f" ]] && { info "删除日志文件 $f"; rm -f "$f" || true; }
  done
  [[ -d /var/log/mihomo ]] && { info "删除日志目录 /var/log/mihomo"; rm -rf /var/log/mihomo || true; }

  # 清理脚本生成的各种链接文件
  rm -f /root/mihomo_ss_link_*.txt 2>/dev/null || true
  rm -f /root/mihomo_vless_reality_link_*.txt 2>/dev/null || true
  rm -f /root/mihomo_vless_encryption_link_*.txt 2>/dev/null || true
  rm -f /root/mihomo_reality_pubkey_*.txt 2>/dev/null || true
  rm -f /root/inbound_address.txt 2>/dev/null || true
}

remove_user_group_if_purge() {
  $PURGE || { info "保留用户/组 mihomo（未使用 --purge）。"; return; }

  info "执行 --purge：尝试删除 mihomo 用户与组 ..."
  pkill -u mihomo 2>/dev/null || true

  if command -v deluser >/dev/null 2>&1; then
    deluser mihomo 2>/dev/null || true
  elif command -v userdel >/dev/null 2>&1; then
    userdel mihomo 2>/dev/null || true
  fi

  if command -v delgroup >/dev/null 2>&1; then
    delgroup mihomo 2>/dev/null || true
  elif command -v groupdel >/dev/null 2>&1; then
    groupdel mihomo 2>/dev/null || true
  fi
}

summary() {
  echo
  echo "====== 卸载完成 ======"
  echo "已停止并移除 systemd/OpenRC 服务，并删除 Mihomo 二进制。"
  if $CONFIG_REMOVED; then
    echo "配置已删除，备份保存在：$CONFIG_BACKUP"
  elif [[ -d /usr/local/etc/mihomo ]]; then
    echo "配置仍保留在 /usr/local/etc/mihomo（备份或删除未成功）。"
  else
    echo "未发现 Mihomo 配置目录。"
  fi
  if $PURGE; then
    echo "已尝试删除 mihomo 用户与组。"
  else
    echo "保留了 mihomo 用户与组（如需同时删除，请加 --purge 重新执行）。"
  fi
  echo
  if has_systemd; then
    echo "检查残留："
    echo "  systemctl list-units --type=service --all | grep -i mihomo || true"
    echo "  systemctl list-unit-files | grep -i mihomo || true"
  fi
}

main() {
  require_root
  confirm_uninstall
  detect_os

  stop_disable_systemd_units
  remove_systemd_files
  stop_disable_openrc
  remove_openrc_files
  backup_and_remove_config || true
  remove_binary_and_misc
  remove_user_group_if_purge
  has_systemd && systemctl daemon-reload || true

  summary
}

main "$@"
