#!/bin/bash

# ==============================================================================
# Mihomo Shadowsocks 2022 一键安装管理脚本
# 架构重构版：使用 Mihomo 替代 Xray 作为代理服务端
# 版本: V-SS-Mihomo-1.0
# 功能:
# - 安装/管理 Shadowsocks (Legacy & 2022)
# - 智能追加配置 (不覆盖其他 listeners)
# - 多端口/多节点管理
# - 自动配置 Systemd/OpenRC (Root 用户)
# - 支持自定义连接地址 (用于 NAT/DDNS 场景)
# - 精准删除指定 SS 节点
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="V-SS-Mihomo-1.0"
readonly mihomo_config_dir="/usr/local/etc/mihomo"
readonly mihomo_config_path="${mihomo_config_dir}/config.yaml"
readonly mihomo_binary_path="/usr/local/bin/mihomo"
readonly address_file="/root/inbound_address.txt" # 自定义地址保存路径

# --- 颜色定义 ---
readonly red='\e[91m' green='\e[92m' yellow='\e[93m'
readonly magenta='\e[95m' cyan='\e[96m' none='\e[0m'

# --- 全局变量 ---
mihomo_status_info=""
is_quiet=false
OS_ID=""
INIT_SYSTEM=""

# --- 辅助函数 ---
error() { echo -e "\n${red}[✖] $1${none}\n" >&2; }
info()  { if [[ "$is_quiet" = false ]]; then echo -e "\n${yellow}[!] $1${none}\n"; fi; return 0; }
success(){ if [[ "$is_quiet" = false ]]; then echo -e "\n${green}[✔] $1${none}\n"; fi; return 0; }

spinner() {
    local pid=$1; local spinstr='|/-\\'
    if [[ "$is_quiet" = true ]]; then
        wait "$pid"
        return
    fi
    while ps -p "$pid" > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep 0.1
        printf "\r"
    done
    printf "    \r"
}

get_public_ip() {
    local ip
    for cmd in "curl -4s --max-time 5" "wget -4qO- --timeout=5"; do
        for url in "https://api.ipify.org" "https://ip.sb" "https://checkip.amazonaws.com"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    for cmd in "curl -6s --max-time 5" "wget -6qO- --timeout=5"; do
        for url in "https://api64.ipify.org" "https://ip.sb"; do
            ip=$($cmd "$url" 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
        done
    done
    error "无法获取公网 IP 地址。" && return 1
}

normalize_connection_address() {
    python3 - "$1" <<'PY'
import ipaddress, re, sys
value = sys.argv[1].strip()
if value.startswith('[') and value.endswith(']'):
    value = value[1:-1]
try:
    print(ipaddress.ip_address(value).compressed)
except ValueError:
    if len(value) > 253 or not re.fullmatch(r'(?=.{1,253}\.?$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', value):
        raise SystemExit(1)
    print(value.rstrip('.'))
PY
}

format_uri_host() {
    if [[ "$1" == *:* ]]; then printf '[%s]' "$1"; else printf '%s' "$1"; fi
}

url_encode() {
    python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# --- 核心安装逻辑 ---
install_mihomo_core() {
    info "开始安装 Mihomo 核心..."
    
    local arch machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) arch="amd64-compatible" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7|armv7l) arch="armv7" ;;
        *) error "不支持的 CPU 架构: $machine"; return 1 ;;
    esac
    [[ "$arch" == "armv7" ]] && echo -e "\n${yellow}[!] 警告: ARMv7 支持目前处于 Alpha 阶段，二进制来自预发布版本，可能存在不稳定情况，请谨慎使用。${none}\n"

    local api="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    info "获取 Mihomo 最新版本信息..."
    local tag
    tag="$(curl -fsSL "$api" | grep -oE '"tag_name":\s*"[^"]+"' | head -n1 | cut -d'"' -f4)" || true
    
    local version_str="${tag:-latest}"
    info "目标版本: $version_str"

    local tmpdir; tmpdir="$(mktemp -d)" || return 1
    local filename="mihomo-linux-${arch}-${tag}.gz"
    local url_tag="https://github.com/MetaCubeX/mihomo/releases/download/${tag}/${filename}"
    local url_alt="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${arch}.gz"

    info "正在下载 Mihomo ($filename)..."
    if [[ -n "${tag:-}" ]] && curl -fL "$url_tag" -o "$tmpdir/mihomo.gz"; then :;
    elif curl -fL "$url_alt" -o "$tmpdir/mihomo.gz"; then :;
    else 
        rm -rf "$tmpdir"
        error "下载 Mihomo 失败"
        return 1
    fi

    info "解压并安装到 /usr/local/bin ..."
    if ! gzip -d "$tmpdir/mihomo.gz" || ! chmod +x "$tmpdir/mihomo" || ! "$tmpdir/mihomo" -v >/dev/null 2>&1; then
        rm -rf "$tmpdir"
        error "下载的 Mihomo 核心无法执行，已取消安装。"
        return 1
    fi
    install -m 0755 "$tmpdir/mihomo" "$mihomo_binary_path" || { rm -rf "$tmpdir"; return 1; }
    
    mkdir -p "$mihomo_config_dir" || return 1
    
    rm -rf "$tmpdir"
    success "Mihomo 核心安装完成"
}

install_geodata() {
    info "正在安装/更新 GeoIP 和 GeoSite 数据文件..."
    mkdir -p "$mihomo_config_dir" || return 1
    local tmpdir
    tmpdir="$(mktemp -d "${mihomo_config_dir}/.geo-install.XXXXXX")" || return 1
    if ! curl -fsSL -o "$tmpdir/geoip.metadb" https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.metadb \
        || ! curl -fsSL -o "$tmpdir/geosite.dat" https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat \
        || [[ ! -s "$tmpdir/geoip.metadb" || ! -s "$tmpdir/geosite.dat" ]]; then
        rm -rf "$tmpdir"
        error "Geo 数据文件下载失败，原文件未被覆盖。"
        return 1
    fi
    chmod 0644 "$tmpdir/geoip.metadb" "$tmpdir/geosite.dat"
    if ! mv -f "$tmpdir/geoip.metadb" "${mihomo_config_dir}/geoip.metadb" \
        || ! mv -f "$tmpdir/geosite.dat" "${mihomo_config_dir}/geosite.dat"; then
        rm -rf "$tmpdir"; error "Geo 数据文件安装失败。"; return 1
    fi
    rm -rf "$tmpdir"
    success "Geo 数据文件已更新"
}

# --- Systemd 服务安装 (User=root) ---
install_service_systemd() {
    info "安装 Systemd 服务 (User=root)..."
    cat >/etc/systemd/system/mihomo.service <<'EOF'
[Unit]
Description=Mihomo Service
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
Group=root
ExecStart=/usr/local/bin/mihomo -d /usr/local/etc/mihomo
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=false
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    [[ -s /etc/systemd/system/mihomo.service ]] || return 1
    systemctl daemon-reload || return 1
    systemctl enable --now mihomo || return 1
    success "Systemd 服务已安装并启动"
}

# --- OpenRC 服务安装 ---
install_service_openrc() {
    info "安装 OpenRC 服务..."
    install -d -m 0755 /var/log/mihomo || true

    cat >/etc/init.d/mihomo <<'EOF'
#!/sbin/openrc-run
name="mihomo"
description="Mihomo Service"
command="/usr/local/bin/mihomo"
command_args="-d /usr/local/etc/mihomo"
command_background=true
pidfile="/run/mihomo.pid"
start_stop_daemon_args="--make-pidfile --background"

depend() {
  need net
  use dns
}
EOF
    [[ -s /etc/init.d/mihomo ]] || return 1
    chmod +x /etc/init.d/mihomo || return 1
    rc-update add mihomo default || return 1
    rc-service mihomo restart || rc-service mihomo start || return 1
    success "OpenRC 服务已安装并启动"
}

setup_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        install_service_systemd
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        install_service_openrc
    else
        error "无法确定服务管理器，请手动配置自启动。"
        return 1
    fi
}

service_restart() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl restart mihomo || return 1
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service mihomo restart || return 1
    else
        error "无法确定服务管理器，请手动重启 Mihomo。"
        return 1
    fi
    sleep 1
    service_is_active
}

service_is_active() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl is-active --quiet mihomo
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service mihomo status 2>/dev/null | grep -qi started
    else
        return 1
    fi
}

validate_mihomo_config() {
    if [[ -x "$mihomo_binary_path" ]]; then
        "$mihomo_binary_path" -t -d "$mihomo_config_dir"
    else
        return 0
    fi
}

# --- 验证函数 ---
is_valid_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

is_listener_port_in_config() {
    local port=$1
    [[ -f "$mihomo_config_path" ]] || return 1

    # 只检查 listeners 顶级配置段。proxies 中的 port 是远端目标端口，
    # 不会在本机监听，因此不能据此判定本地端口冲突。
    awk -v target="$port" '
        BEGIN { in_listeners = 0; found = 0 }
        /^[^[:space:]#][^:]*:/ {
            key = $0
            sub(/:.*/, "", key)
            in_listeners = (key == "listeners")
            next
        }
        in_listeners && /^[[:space:]]+port:[[:space:]]*/ {
            value = $0
            sub(/^[[:space:]]+port:[[:space:]]*/, "", value)
            sub(/[[:space:]]*#.*/, "", value)
            gsub(/[[:space:]\"]/, "", value)
            quote = sprintf("%c", 39)
            gsub(quote, "", value)
            if (value == target) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$mihomo_config_path" 2>/dev/null
}

managed_listener_ports() {
    local prefix=$1
    [[ -f "$mihomo_config_path" ]] || return 1
    python3 - "$mihomo_config_path" "$prefix" <<'PY'
import json, re, sys
path, prefix = sys.argv[1:]
in_listeners = False
current_name = None

def scalar(value):
    value = value.strip()
    try:
        return str(json.loads(value))
    except Exception:
        return value.strip("\"'")

with open(path, encoding='utf-8') as f:
    for raw in f:
        if re.match(r'^[^\s#][^:]*:', raw):
            in_listeners = raw.split(':', 1)[0].strip() == 'listeners'
            current_name = None
            continue
        if not in_listeners:
            continue
        stripped = raw.strip()
        if stripped.startswith('- name:'):
            current_name = scalar(stripped.split(':', 1)[1])
        elif current_name and current_name.startswith(prefix) and stripped.startswith('port:'):
            value = scalar(stripped.split(':', 1)[1])
            if value.isdigit() and current_name == prefix + value:
                print(value)
PY
}

backup_config() {
    local suffix="${1:-bak}"
    local backup
    backup=$(mktemp "${mihomo_config_path}.${suffix}.$(date +%Y%m%d%H%M%S).XXXXXX") || return 1
    cp "$mihomo_config_path" "$backup" || { rm -f "$backup"; return 1; }
    chmod 600 "$backup"
    printf '%s\n' "$backup"
}

+backup_config_archive() {
    [[ -d "$mihomo_config_dir" ]] || return 0
    local archive
    archive=$(mktemp "/root/mihomo-config-backup-$(date +%Y%m%d%H%M%S).XXXXXX.tar.gz") || return 1
    if ! tar -czf "$archive" -C "$(dirname "$mihomo_config_dir")" "$(basename "$mihomo_config_dir")"; then
        rm -f "$archive"
        return 1
    fi
    chmod 600 "$archive" || return 1
    printf '%s\n' "$archive"
}

remove_managed_listener() {
    local prefix=$1 port=$2
    python3 - "$mihomo_config_path" "$prefix" "$port" <<'PY'
import json, os, re, stat, sys, tempfile
path, prefix, port = sys.argv[1:]
target_name = prefix + port
in_listeners = False
skip = False
skip_indent = -1
removed = False
result = []

def scalar(value):
    value = value.strip()
    try:
        return str(json.loads(value))
    except Exception:
        return value.strip("\"'")

with open(path, encoding='utf-8') as f:
    lines = f.readlines()

for raw in lines:
    if re.match(r'^[^\s#][^:]*:', raw):
        skip = False
        in_listeners = raw.split(':', 1)[0].strip() == 'listeners'
        result.append(raw)
        continue

    stripped = raw.strip()
    indent = len(raw) - len(raw.lstrip())
    if in_listeners and stripped.startswith('- name:'):
        if skip and indent <= skip_indent:
            skip = False
        name = scalar(stripped.split(':', 1)[1])
        if not skip and name == target_name:
            skip = True
            skip_indent = indent
            removed = True
            continue

    if skip:
        continue
    result.append(raw)

if not removed:
    raise SystemExit(2)

directory = os.path.dirname(path) or '.'
fd, tmp = tempfile.mkstemp(prefix='.config.', dir=directory, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.writelines(result)
    os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY
}

is_port_in_use() {
    local port=$1
    # 检查系统监听
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v netstat &>/dev/null; then
        netstat -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v lsof &>/dev/null; then
        lsof -i ":$port" &>/dev/null && return 0
    else
        (echo > "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1 && return 0
    fi
    
    # 检查 Mihomo 入站监听配置，防止服务未运行时漏掉内部冲突。
    is_listener_port_in_config "$port" && return 0
    return 1
}

# --- 系统检测 ---
detect_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID=${ID:-}
    fi
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="unknown"
    fi
}

check_system_compatibility() {
    if [[ "$(uname -s)" != "Linux" ]]; then error "仅支持 Linux"; return 1; fi
    detect_system
    
    local required_commands=("awk" "grep" "sed" "curl" "openssl" "python3" "gzip" "base64" "install" "mktemp" "tar")
    local missing_commands=()
    for cmd in "${required_commands[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd")
    done
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        info "正在安装缺失依赖: ${missing_commands[*]} ..."
        if [[ "$OS_ID" == "alpine" ]]; then
            apk add --no-cache bash curl python3 openssl iproute2 coreutils gzip
        elif command -v apt-get >/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash curl python3 openssl iproute2 coreutils gzip
        else
            error "当前系统不支持自动安装依赖: ${missing_commands[*]}"
            return 1
        fi
    fi
    for cmd in "${required_commands[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || { error "缺少必要命令: $cmd"; return 1; }
    done
    return 0
}

pre_check() {
    [[ $(id -u) != 0 ]] && error "必须以 root 运行" && exit 1
    check_system_compatibility || exit 1
}

check_mihomo_status() {
    if [[ ! -f "$mihomo_binary_path" ]]; then mihomo_status_info="  Mihomo 状态: ${red}未安装${none}"; return; fi
    local mihomo_version=$($mihomo_binary_path -v 2>/dev/null | head -n 1 | awk '{print $3}' || echo "未知")
    local service_status="${yellow}未运行/无法检测${none}"
    service_is_active && service_status="${green}运行中${none}"
    mihomo_status_info="  Mihomo 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${mihomo_version}${none}"
}

# --- 核心 SS 配置逻辑 ---
select_method_and_password() {
    echo ""
    echo "请选择 Shadowsocks 加密协议:"
    echo -e "  ${green}1.${none} 2022-blake3-aes-128-gcm   (推荐, 16字节密钥)"
    echo -e "  ${green}2.${none} 2022-blake3-aes-256-gcm   (推荐, 32字节密钥)"
    echo -e "  ${green}3.${none} 2022-blake3-chacha20-poly1305 (推荐, 32字节密钥)"
    echo -e "  ${yellow}4.${none} aes-128-gcm   (传统, 16字节密钥)"
    echo -e "  ${yellow}5.${none} aes-256-gcm   (传统, 32字节密钥)"
    echo -e "  ${yellow}6.${none} chacha20-ietf-poly1305 (传统, 32字节密钥)"
    
    read -p "请输入选项 [1-6] (默认 2): " method_choice
    [ -z "$method_choice" ] && method_choice=2

    local key_len=32
    case $method_choice in
        1) SS_METHOD="2022-blake3-aes-128-gcm"; key_len=16 ;;
        2) SS_METHOD="2022-blake3-aes-256-gcm"; key_len=32 ;;
        3) SS_METHOD="2022-blake3-chacha20-poly1305"; key_len=32 ;;
        4) SS_METHOD="aes-128-gcm"; key_len=16 ;;
        5) SS_METHOD="aes-256-gcm"; key_len=32 ;;
        6) SS_METHOD="chacha20-ietf-poly1305"; key_len=32 ;;
        *) error "无效选择，默认使用 2022-blake3-aes-256-gcm"; SS_METHOD="2022-blake3-aes-256-gcm"; key_len=32 ;;
    esac

    echo ""
    echo -ne "请输入密码 (留空生成随机 ${key_len} 字节密码): "
    read user_pass
    
    if [[ -z "$user_pass" ]]; then
        SS_PASSWORD=$(openssl rand -base64 $key_len | tr -d '\n')
        info "已自动生成密码: ${cyan}${SS_PASSWORD}${none}"
    else
        SS_PASSWORD="$user_pass"
    fi
}

# --- 初始化 Mihomo 基础配置文件 ---
init_mihomo_config() {
    if [[ ! -f "$mihomo_config_path" ]]; then
        info "配置文件不存在，创建新配置..."
        mkdir -p "$mihomo_config_dir" || return 1
        cat > "$mihomo_config_path" <<'YAML'
# Mihomo 代理服务端配置
mode: rule
log-level: warning
allow-lan: true
bind-address: "*"

listeners: []

rules:
  - MATCH,DIRECT
YAML
        chmod 600 "$mihomo_config_path"
    fi
}

# --- 智能追加配置函数 (不覆盖) ---
append_ss_config() {
    local port=$1 method=$2 password=$3
    local tag="ss-in-${port}"
    
    # 1. 初始化配置文件
    init_mihomo_config

    # 2. 备份
    local config_backup
    config_backup=$(backup_config "bak") || return 1

    # 3. 构建 listener YAML 块并追加
    # 使用 Python 来安全操作 YAML（避免纯 sed 的危险）
    if ! python3 -c "
import json, os, re, stat, sys, tempfile

config_path = sys.argv[1]
port = int(sys.argv[2])
method = sys.argv[3]
password = sys.argv[4]
tag = sys.argv[5]

# 读取现有配置
with open(config_path, 'r') as f:
    content = f.read()

# JSON 字符串也是合法的 YAML 标量，可避免密码中的引号、# 等字符破坏配置。
quote = lambda value: json.dumps(value, ensure_ascii=False)
listener_block = f'''
  - name: {quote(tag)}
    type: shadowsocks
    port: {port}
    listen: 0.0.0.0
    cipher: {quote(method)}
    password: {quote(password)}
    udp: true'''

# 检查 listeners 是否存在且为空列表
# 如果有 'listeners: []'，替换为带内容的版本
if re.search(r'^listeners:\s*\[\]\s*(?:#.*)?$', content, re.MULTILINE):
    content = re.sub(r'^listeners:\s*\[\]\s*(?:#.*)?$', 'listeners:' + listener_block, content, count=1, flags=re.MULTILINE)
elif re.search(r'^listeners:\s*(?:#.*)?$', content, re.MULTILINE):
    # listeners: 后面没有内容
    content = re.sub(r'^listeners:\s*(?:#.*)?$', 'listeners:' + listener_block, content, count=1, flags=re.MULTILINE)
elif re.search(r'^listeners:', content, re.MULTILINE):
    # listeners 已有内容，追加到末尾
    # 找到 listeners: 部分，在其最后一个 listener 条目后追加
    lines = content.split('\n')
    result_lines = []
    in_listeners = False
    inserted = False
    for i, line in enumerate(lines):
        result_lines.append(line)
        if re.match(r'^listeners:', line):
            in_listeners = True
            continue
        if in_listeners and not inserted:
            # 检查是否到了 listeners 块的末尾 (下一个顶级key)
            if line and not line.startswith(' ') and not line.startswith('#') and ':' in line:
                # 我们已经到了下一个顶级块，在此之前插入
                result_lines.insert(len(result_lines) - 1, listener_block.lstrip('\n'))
                inserted = True
                in_listeners = False
    if in_listeners and not inserted:
        # listeners 是最后一个块
        result_lines.append(listener_block.lstrip('\n'))
    content = '\n'.join(result_lines)
else:
    # 没有 listeners 段，添加它
    content += '\nlisteners:' + listener_block + '\n'

directory = os.path.dirname(config_path) or '.'
fd, tmp = tempfile.mkstemp(prefix='.config.', dir=directory, text=True)
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(content)
    os.chmod(tmp, stat.S_IMODE(os.stat(config_path).st_mode))
    os.replace(tmp, config_path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
" "$mihomo_config_path" "$port" "$method" "$password" "$tag"; then
        cp "$config_backup" "$mihomo_config_path"
        error "写入配置失败，已恢复原配置。"
        return 1
    fi
    
    chmod 600 "$mihomo_config_path"
    if ! validate_mihomo_config; then
        cp "$config_backup" "$mihomo_config_path"
        error "新配置未通过 Mihomo 检查，已恢复原配置。"
        return 1
    fi
    success "配置已安全追加到: $mihomo_config_path"
}

# --- 自定义连接地址管理 ---
set_connection_address() {
    echo ""
    echo "================================================="
    echo "         自定义连接地址 (NAT/DDNS 模式)"
    echo "================================================="
    echo "说明: 如果您使用的是 NAT VPS 或拥有动态 IP 的机器，"
    echo "请在此输入外部可访问的 IP 地址或 DDNS 域名。"
    echo "例如uzumaru的产品，若出口 IP 地址与网页面板上的不同，"
    echo "或是动态地址产品网页面板上显示的是 DDNS 域名，"
    echo "请在此输入网页面板上显示的外部连接地址，"
    echo "脚本生成分享链接时将优先使用此地址。"
    echo "-------------------------------------------------"
    
    if [[ -f "$address_file" ]]; then
        local current_addr=$(cat "$address_file")
        echo -e "当前已设置: ${cyan}${current_addr}${none}"
    else
        echo -e "当前状态: ${yellow}自动获取公网 IP${none}"
    fi
    echo ""
    read -p "请输入新的连接地址 (留空并回车则恢复自动获取): " new_addr
    
    if [[ -z "$new_addr" ]]; then
        rm -f "$address_file"
        success "已恢复为自动获取公网 IP 模式。"
    else
        local normalized_addr
        if ! normalized_addr=$(normalize_connection_address "$new_addr"); then
            error "连接地址无效，请输入纯 IP 地址或域名（不要包含协议和端口）。"
            return 1
        fi
        printf '%s\n' "$normalized_addr" > "$address_file"
        chmod 600 "$address_file"
        success "连接地址已更新为: $normalized_addr"
    fi
}

# --- 删除 SS 节点 ---
delete_ss_node() {
    if [[ ! -f "$mihomo_config_path" ]]; then error "配置不存在"; return; fi

    # 1. 扫描所有 SS 端口
    echo "当前已安装的 Shadowsocks 节点:"
    local ports
    ports=$(managed_listener_ports "ss-in-" || true)

    if [[ -z "$ports" ]]; then
        error "未找到任何 Shadowsocks 节点，无需删除。"
        return
    fi

    for p in $ports; do echo " - 端口: $p"; done
    echo ""

    local target_p
    while true; do
        read -p "请输入要删除的端口 (输入上述端口之一): " target_p
        if echo "$ports" | grep -q "^$target_p$"; then
            break
        else
            error "端口无效或该端口不是 Shadowsocks 节点，请重新输入。"
        fi
    done

    read -p "确定要永久删除端口 $target_p 的 Shadowsocks 节点吗？[y/N]: " confirm
    if [[ ! $confirm =~ ^[yY]$ ]]; then
        info "操作已取消。"
        return
    fi

    info "正在删除节点..."

    # 备份
    local delete_backup
    delete_backup=$(backup_config "bak.del") || { error "备份配置失败"; return 1; }

    remove_managed_listener "ss-in-" "$target_p" || { error "删除节点配置失败，已保留备份。"; return 1; }

    # 删除本地连接文件
    local link_file="/root/mihomo_ss_link_${target_p}.txt"
    if [[ -f "$link_file" ]]; then
        rm -f "$link_file"
        info "已删除本地连接文件: $link_file"
    fi

    # 重启服务
    if ! validate_mihomo_config || ! service_restart; then
        cp "$delete_backup" "$mihomo_config_path"
        service_restart >/dev/null 2>&1 || true
        error "删除后配置未能正常加载，已恢复原配置。"
        return 1
    fi
    success "Shadowsocks 节点 (端口 $target_p) 已删除。"
}

# --- 菜单操作函数 ---
install_ss() {
    info "开始配置 Shadowsocks..."
    
    local port
    while true; do
        read -p "$(echo -e "请输入端口 [1-65535] (默认: ${cyan}2022${none}): ")" port
        [ -z "$port" ] && port=2022
        if ! is_valid_port "$port"; then error "端口无效"; continue; fi
        if is_port_in_use "$port"; then error "端口 $port 已被占用"; continue; fi
        break
    done

    select_method_and_password

    # 安装核心 & GeoData
    if ! install_mihomo_core; then return 1; fi
    install_geodata || return 1
    
    # 写入配置
    append_ss_config "$port" "$SS_METHOD" "$SS_PASSWORD" || return 1
    
    # 设置并重启服务
    setup_service || return 1
    service_restart || return 1
    
    success "安装配置完成！"
    view_subscription_info "$port"
}

view_subscription_info() {
    # 自动查找 SS 节点
    if [[ ! -f "$mihomo_config_path" ]]; then error "配置不存在"; return; fi
    
    # 1. 扫描所有 SS 节点端口
    local ports
    ports=$(managed_listener_ports "ss-in-" || true)
    
    if [[ -z "$ports" ]]; then error "未找到 Shadowsocks 节点配置。"; return; fi

    local target_port=""
    local port_count=$(echo "$ports" | wc -l)

    # 2. 智能选择逻辑
    if [[ -n "${1:-}" ]]; then
        target_port=$1
    elif [[ "$port_count" -eq 1 ]]; then
        target_port=$(echo "$ports" | tr -d ' \n')
    else
        echo "发现多个 Shadowsocks 节点:"
        for p in $ports; do echo " - 端口: $p"; done
        echo ""
        
        while true; do
            read -p "请输入要查看的端口: " input_p
            if echo "$ports" | grep -q "^$input_p$"; then
                target_port=$input_p
                break
            else
                error "无效端口，请从列表中选择。"
            fi
        done
    fi

    # 3. 读取详细信息 (使用 Python 解析 YAML)
    local node_info
    node_info=$(python3 -c "
import json, re, sys
config_path = sys.argv[1]
target_port = int(sys.argv[2])

with open(config_path, 'r') as f:
    content = f.read()

in_target = False
name = method = password = ''
port = 0

def scalar(value):
    value = value.strip()
    try:
        return str(json.loads(value))
    except Exception:
        return value.strip('\"').strip(\"'\")

in_listeners = False
current_name = ''
for line in content.split('\n'):
    s = line.strip()
    if re.match(r'^[^\s#][^:]*:', line):
        in_listeners = line.split(':', 1)[0].strip() == 'listeners'
        in_target = False
        current_name = ''
        continue
    if not in_listeners:
        continue
    if s.startswith('- name:'):
        current_name = scalar(s.split(':', 1)[1])
        in_target = False
    elif current_name.startswith('ss-in-') and not in_target and s.startswith('port:'):
        p = int(s.split(':')[1].strip())
        if p == target_port:
            in_target = True
            name = current_name
            port = p
    elif in_target:
        if s.startswith('cipher:'):
            method = scalar(s.split(':', 1)[1])
        elif s.startswith('password:'):
            password = scalar(s.split(':', 1)[1])
        elif s.startswith('- name:'):
            break

if name:
    print(json.dumps({'name': name, 'port': port, 'method': method, 'password': password}, ensure_ascii=False))
" "$mihomo_config_path" "$target_port" 2>/dev/null || true)

    if [[ -z "$node_info" ]]; then error "读取配置失败"; return; fi

    local tag method password
    tag=$(printf '%s' "$node_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
    method=$(printf '%s' "$node_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["method"])')
    password=$(printf '%s' "$node_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"])')
    
    # 4. 确定连接地址 (NAT/DDNS 支持)
    local ip
    if [[ -f "$address_file" && -s "$address_file" ]]; then
        ip=$(cat "$address_file")
        if [[ -z "$ip" ]]; then ip=$(get_public_ip); fi
    else
        ip=$(get_public_ip)
    fi
    
    # 5. 生成链接 (SIP002)
    local user_info="${method}:${password}"
    local user_info_b64
    user_info_b64=$(python3 -c 'import base64,sys; print(base64.urlsafe_b64encode(sys.argv[1].encode()).decode().rstrip("="))' "$user_info")

    local ipinfo_json country org link_name
    ipinfo_json=$(curl -sf --max-time 5 https://ipinfo.io 2>/dev/null)
    if [[ -n "$ipinfo_json" ]]; then
        country=$(echo "$ipinfo_json" | grep '"country"' | sed 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        org=$(echo "$ipinfo_json" | grep '"org"' | sed 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi
    if [[ -n "${country:-}" && -n "${org:-}" ]]; then
        link_name="${country} - ${org}"
    else
        link_name="$tag"
    fi
    local link_name_encoded display_ip
    link_name_encoded=$(url_encode "$link_name")
    display_ip=$(format_uri_host "$ip")
    local link="ss://${user_info_b64}@${display_ip}:${target_port}#${link_name_encoded}"

    # 6. 独立文件保存
    local save_file="/root/mihomo_ss_link_${target_port}.txt"

    if [[ "$is_quiet" = true ]]; then
        echo "$link"
    else
        echo "----------------------------------------------------------------"
        echo -e "${green} --- Shadowsocks 配置信息 (Mihomo) --- ${none}"
        echo -e "${yellow} 协议: ${cyan}${method}${none}"
        echo -e "${yellow} 地址: ${cyan}${ip}${none}"
        echo -e "${yellow} 端口: ${cyan}${target_port}${none}"
        echo -e "${yellow} 密码: ${cyan}${password}${none}"
        echo -e "${yellow} 别名: ${cyan}${tag}${none}"
        echo "----------------------------------------------------------------"
        echo -e "${green} 分享链接 (已保存到 $save_file):${none}\n"
        echo -e "${cyan}${link}${none}"
        echo "----------------------------------------------------------------"
        echo "$link" > "$save_file"
        chmod 600 "$save_file"
    fi
}

update_mihomo() {
    info "检查更新..."
    install_mihomo_core || return 1
    install_geodata || return 1
    service_restart || return 1
    success "Mihomo 已更新"
}

restart_mihomo() {
    info "正在重启 Mihomo..."
    service_restart || return 1
    success "服务已重启"
}

uninstall_mihomo() {
    read -p "确定卸载 Mihomo 吗？(删除程序文件，保留配置文件可选) [y/N]: " confirm
    if [[ ! $confirm =~ ^[yY]$ ]]; then return; fi

    local del_conf config_archive=""
    read -p "是否删除配置文件和日志？删除前会自动备份。[y/N]: " del_conf
    if [[ $del_conf =~ ^[yY]$ ]]; then
        if ! config_archive=$(backup_config_archive); then
            error "配置备份失败，已取消卸载，未删除任何文件。"
            return 1
        fi
    fi
    
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop mihomo || true
        systemctl disable mihomo || true
        rm -f /etc/systemd/system/mihomo.service
        systemctl daemon-reload || true
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service mihomo stop || true
        rc-update del mihomo default || true
        rm -f /etc/init.d/mihomo
    else
        error "无法确定服务管理器，已取消卸载。"
        return 1
    fi
    
    rm -f "$mihomo_binary_path"
    if [[ $del_conf =~ ^[yY]$ ]]; then
        rm -rf "$mihomo_config_dir" /var/log/mihomo
        rm -f /root/inbound_address.txt # 同时清理地址配置文件
        success "Mihomo 及配置已完全卸载；配置备份: $config_archive"
    else
        success "Mihomo 程序已卸载，配置保留"
    fi
}

view_mihomo_log() {
    info "显示日志... 按 Ctrl+C 停止查看"
    trap 'echo -e "\n日志查看已停止。"' SIGINT
    
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u mihomo -f --no-pager || true
    elif [[ -d /var/log/mihomo ]]; then
        (tail -n 200 -F /var/log/mihomo/*.log 2>/dev/null || tail -n 200 -F /var/log/*.log | grep -i mihomo) || true
    else
        error "无法找到日志"
    fi
    
    trap - SIGINT
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

modify_config() {
    if [[ ! -f "$mihomo_config_path" ]]; then error "配置不存在"; return; fi
    
    # 1. 扫描所有 SS 端口
    echo "当前 Shadowsocks 节点:"
    local ports
    ports=$(managed_listener_ports "ss-in-" || true)
    
    if [[ -z "$ports" ]]; then error "未找到 SS 节点"; return; fi
    
    for p in $ports; do echo " - 端口: $p"; done
    echo ""
    
    local target_p
    while true; do
        read -p "请输入要修改的端口: " target_p
        if echo "$ports" | grep -q "^$target_p$"; then break; else error "端口未找到"; fi
    done
    
    info "注意：修改将删除旧端口配置并重新添加。"
    info "请重新配置参数:"
    
    select_method_and_password
    
    # 先备份原始配置，再删除旧入站；避免 append 阶段的备份已经丢失旧节点。
    local modify_backup
    modify_backup=$(backup_config "bak.modify") || { error "备份配置失败"; return 1; }
    remove_managed_listener "ss-in-" "$target_p" || { error "删除旧节点失败"; return 1; }
    
    # 追加新配置
    if ! append_ss_config "$target_p" "$SS_METHOD" "$SS_PASSWORD" || ! service_restart; then
        cp "$modify_backup" "$mihomo_config_path"
        service_restart >/dev/null 2>&1 || true
        error "修改失败，已恢复原配置。"
        return 1
    fi
    success "修改完成"
    view_subscription_info "$target_p"
}

press_any_key_to_continue() {
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

main_menu() {
    while true; do
        clear
        echo -e "${cyan} Mihomo Shadowsocks 2022 管理脚本${none}"
        echo "---------------------------------------------"
        echo -e "${red} 如果您是在uzumaru购买的产品，并且该产品${none}"
        echo -e "${red} 是用IDC入口IP或者是DDNS域名连接的，请${none}"
        echo -e "${red} 先使用功能9，填入uzumaru网站面板上显示的连接IP或DDNS域名${none}"
        echo -e "${red} 避免创建节点后因使用的连接地址错误而不通。${none}"
        echo "---------------------------------------------"
        check_mihomo_status
        echo -e "${mihomo_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "新增/安装 Shadowsocks 节点"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Mihomo 核心"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 Mihomo 服务"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 Mihomo"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "修改/重置 SS 节点配置"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看节点链接"
        printf "  ${red}%-2s${none} %-35s\n" "8." "删除 Shadowsocks 节点"
        echo "---------------------------------------------"
        printf "  ${magenta}%-2s${none} %-35s\n" "9." "设置连接地址 (NAT/DDNS)"
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-9]: " choice

        local needs_pause=true
        case $choice in
            1) install_ss ;;
            2) update_mihomo ;;
            3) restart_mihomo ;;
            4) uninstall_mihomo ;;
            5) view_mihomo_log; needs_pause=false ;;
            6) modify_config ;;
            7) view_subscription_info "" ;;
            8) delete_ss_node ;;
            9) set_connection_address ;;
            0) success "再见！"; exit 0 ;;
            *) error "无效选项" ;;
        esac

        if [ "$needs_pause" = true ]; then
            press_any_key_to_continue
        fi
    done
}

main() {
    pre_check
    if [[ $# -gt 0 && "$1" == "install" ]]; then
        install_ss
    else
        main_menu
    fi
}

main "$@"
