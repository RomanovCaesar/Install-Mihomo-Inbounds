#!/bin/bash

# ==============================================================================
# Mihomo VLESS Encryption (Post-Quantum) 一键安装管理脚本
# 使用 Mihomo 替代 Xray 作为代理服务端
# 版本: V-PQ-Mihomo-1.0
# 功能:
# - 安装/管理 VLESS Encryption (ML-KEM-768)
# - 自动生成并替换抗量子密钥 (.native. -> .random.)
# - 智能追加 YAML 配置 (不覆盖其他 listeners)
# - 多端口/多节点管理
# - 支持自定义连接地址 (NAT/DDNS)
# - 精准删除指定 VLESS PQ 节点
# ==============================================================================

# --- Shell 严格模式 ---
set -euo pipefail

# --- 全局常量 ---
readonly SCRIPT_VERSION="V-PQ-Mihomo-1.0"
readonly mihomo_config_dir="/usr/local/etc/mihomo"
readonly mihomo_config_path="${mihomo_config_dir}/config.yaml"
readonly mihomo_binary_path="/usr/local/bin/mihomo"
readonly address_file="/root/inbound_address.txt"

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
info()  { [[ "$is_quiet" = false ]] && echo -e "\n${yellow}[!] $1${none}\n"; }
success(){ [[ "$is_quiet" = false ]] && echo -e "\n${green}[✔] $1${none}\n"; }

spinner() {
    local pid=$1; local spinstr='|/-\\'
    if [[ "$is_quiet" = true ]]; then wait "$pid"; return; fi
    while ps -p "$pid" > /dev/null 2>&1; do
        local temp=${spinstr#?}; printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}; sleep 0.1; printf "\r"
    done; printf "    \r"
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

# --- 核心安装逻辑 ---
install_mihomo_core() {
    info "开始安装 Mihomo 核心..."
    local arch machine; machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64) arch="amd64-compatible" ;; # 强制使用兼容版适配 E5 v2 等老CPU
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

    local tmpdir; tmpdir="$(mktemp -d)"
    local filename="mihomo-linux-${arch}-${tag}.gz"
    local url_tag="https://github.com/MetaCubeX/mihomo/releases/download/${tag}/${filename}"
    local url_alt="https://github.com/MetaCubeX/mihomo/releases/latest/download/mihomo-linux-${arch}.gz"

    info "正在下载 Mihomo ($filename)..."
    if [[ -n "${tag:-}" ]] && curl -fL "$url_tag" -o "$tmpdir/mihomo.gz"; then :;
    elif curl -fL "$url_alt" -o "$tmpdir/mihomo.gz"; then :;
    else rm -rf "$tmpdir"; error "下载 Mihomo 失败"; return 1; fi

    info "解压并安装到 /usr/local/bin ..."
    gzip -d "$tmpdir/mihomo.gz"
    install -m 0755 "$tmpdir/mihomo" "$mihomo_binary_path"
    mkdir -p "$mihomo_config_dir"
    rm -rf "$tmpdir"
    success "Mihomo 核心安装完成"
}

install_geodata() {
    info "正在安装/更新 GeoIP 和 GeoSite 数据文件..."
    curl -fsSL -o "${mihomo_config_dir}/geoip.metadb" https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.metadb
    curl -fsSL -o "${mihomo_config_dir}/geosite.dat" https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
    success "Geo 数据文件已更新"
}

# --- Systemd/OpenRC 服务安装 ---
install_service_systemd() {
    info "安装 Systemd 服务..."
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
    systemctl daemon-reload
    systemctl enable --now mihomo
    success "Systemd 服务已安装并启动"
}

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
    chmod +x /etc/init.d/mihomo
    rc-update add mihomo default
    rc-service mihomo restart || rc-service mihomo start
    success "OpenRC 服务已安装并启动"
}

setup_service() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then install_service_systemd
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then install_service_openrc
    else error "无法确定服务管理器，请手动配置自启动。"; fi
}

# --- 验证函数 ---
is_valid_port() { local port=$1; [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; }

is_port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then ss -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v netstat &>/dev/null; then netstat -tuln 2>/dev/null | grep -q ":$port " && return 0
    elif command -v lsof &>/dev/null; then lsof -i ":$port" &>/dev/null
    else (echo > "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1 && return 0; fi
    if [[ -f "$mihomo_config_path" ]]; then
         grep -qE "^\s+port:\s+$port\s*$" "$mihomo_config_path" 2>/dev/null && return 0
    fi
    return 1
}

is_valid_uuid() { local uuid=$1; [[ "$uuid" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

# --- 系统检测 ---
detect_system() {
    if [[ -f /etc/os-release ]]; then . /etc/os-release; OS_ID=${ID:-}; fi
    if command -v systemctl >/dev/null 2>&1; then INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then INIT_SYSTEM="openrc"
    else INIT_SYSTEM="unknown"; fi
}

service_restart() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl restart mihomo
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then rc-service mihomo restart
    else error "无法确定服务管理器，请手动重启。"; return 1; fi
}

service_is_active() {
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then systemctl is-active --quiet mihomo
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then rc-service mihomo status >/dev/null 2>&1 && rc-service mihomo status 2>/dev/null | grep -qi started
    else return 1; fi
}

check_system_compatibility() {
    if [[ "$(uname -s)" != "Linux" ]]; then error "仅支持 Linux"; return 1; fi
    detect_system
    local required_commands=("awk" "grep" "sed" "unzip")
    local missing_commands=()
    for cmd in "${required_commands[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing_commands+=("$cmd"); done
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        info "正在安装缺失依赖: ${missing_commands[*]} ..."
        if [[ "$OS_ID" == "alpine" ]]; then apk add --no-cache "${missing_commands[@]}" bash curl python3 coreutils
        elif command -v apt-get >/dev/null; then DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y curl python3 "${missing_commands[@]}"
        fi
    fi
    return 0
}

pre_check() {
    [[ $(id -u) != 0 ]] && error "必须以 root 运行" && exit 1
    check_system_compatibility
}

check_mihomo_status() {
    if [[ ! -f "$mihomo_binary_path" ]]; then mihomo_status_info="  Mihomo 状态: ${red}未安装${none}"; return; fi
    local mihomo_version=$($mihomo_binary_path -v 2>/dev/null | head -n 1 | awk '{print $3}' || echo "未知")
    local service_status
    if service_is_active; then service_status="${green}运行中${none}"; else service_status="${yellow}未运行${none}"; fi
    mihomo_status_info="  Mihomo 状态: ${green}已安装${none} | ${service_status} | 版本: ${cyan}${mihomo_version}${none}"
}

# --- 核心 VLESS Encryption 生成逻辑 ---
generate_vless_tokens() {
    info "正在生成 VLESS Encryption (ML-KEM-768) 密钥..."
    local tmpdir; tmpdir="$(mktemp -d)"
    local machine; machine="$(uname -m)"
    local arch
    case "$machine" in
        x86_64|amd64) arch="64" ;;
        aarch64|arm64) arch="arm64-v8a" ;;
        armv7|armv7l) arch="arm32-v7a" ;;
        *) error "不支持的 CPU 架构: $machine"; rm -rf "$tmpdir"; return 1 ;;
    esac

    info "自动下载临时 Xray 核心以生成最高兼容性的抗量子密钥串..."
    local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    if ! curl -fL "$url" -o "$tmpdir/xray.zip"; then
        error "下载临时核心失败。"
        rm -rf "$tmpdir"
        return 1
    fi
    unzip -qo "$tmpdir/xray.zip" -d "$tmpdir"
    chmod +x "$tmpdir/xray"

    local out dec enc
    out="$("$tmpdir/xray" vlessenc 2>&1 || true)"
    rm -rf "$tmpdir"

    dec="$(printf '%s\n' "$out" | awk '/Authentication: ML-KEM-768/ {p=1; next} p && /"decryption":/ {gsub(/^.*"decryption": *"/,""); gsub(/".*/,""); print; exit}')"
    enc="$(printf '%s\n' "$out" | awk '/Authentication: ML-KEM-768/ {p=1; next} p && /"encryption":/ {gsub(/^.*"encryption": *"/,""); gsub(/".*/,""); print; exit}')"

    if [[ -z "$dec" || -z "$enc" ]]; then
        error "密钥生成失败，无法提取特征码。"
        return 1
    fi

    # 替换 native 为 random，提高兼容性
    VLESS_DECRYPTION="${dec/.native./.random.}"
    VLESS_ENCRYPTION="${enc/.native./.random.}"
    info "密钥生成成功 (native -> random 已转换)。"
}

# --- 初始化 Mihomo 基础配置文件 ---
init_mihomo_config() {
    if [[ ! -f "$mihomo_config_path" ]]; then
        info "配置文件不存在，创建新配置..."
        mkdir -p "$mihomo_config_dir"
        cat > "$mihomo_config_path" <<'YAML'
mode: rule
log-level: warning
allow-lan: true
bind-address: "*"

listeners: []

rules:
  - MATCH,DIRECT
YAML
    fi
}

# --- 智能追加配置函数 ---
append_vless_config() {
    local port=$1 uuid=$2 decryption_key=$3
    local tag="vless-pq-in-${port}"

    init_mihomo_config
    cp "$mihomo_config_path" "${mihomo_config_path}.bak.$(date +%s)"

    python3 -c "
import sys, re

config_path = sys.argv[1]
port = int(sys.argv[2])
uuid = sys.argv[3]
dec_key = sys.argv[4]
tag = sys.argv[5]

with open(config_path, 'r') as f:
    content = f.read()

listener_block = f'''
  - name: {tag}
    type: vless
    port: {port}
    listen: 0.0.0.0
    users:
      - uuid: {uuid}
    decryption: \"{dec_key}\"'''

if re.search(r'^listeners:\s*\[\]\s*$', content, re.MULTILINE):
    content = re.sub(r'^listeners:\s*\[\]\s*$', 'listeners:' + listener_block, content, flags=re.MULTILINE)
elif re.search(r'^listeners:\s*$', content, re.MULTILINE):
    content = re.sub(r'^listeners:\s*$', 'listeners:' + listener_block, content, flags=re.MULTILINE)
elif 'listeners:' in content:
    lines = content.split('\n')
    result_lines = []
    in_listeners = False
    inserted = False
    for i, line in enumerate(lines):
        result_lines.append(line)
        if line.startswith('listeners:'):
            in_listeners = True
            continue
        if in_listeners and not inserted:
            if line and not line.startswith(' ') and not line.startswith('#') and ':' in line:
                result_lines.insert(len(result_lines) - 1, listener_block.lstrip('\n'))
                inserted = True
                in_listeners = False
    if in_listeners and not inserted:
        result_lines.append(listener_block.lstrip('\n'))
    content = '\n'.join(result_lines)
else:
    content += '\nlisteners:' + listener_block + '\n'

with open(config_path, 'w') as f:
    f.write(content)
" "$mihomo_config_path" "$port" "$uuid" "$decryption_key" "$tag"

    chmod 644 "$mihomo_config_path"
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
        rm -f "$address_file"; success "已恢复为自动获取公网 IP 模式。"
    else
        echo "$new_addr" > "$address_file"; success "连接地址已更新为: $new_addr"
    fi
}

# --- 删除 VLESS PQ 节点 ---
delete_vless_pq_node() {
    if [[ ! -f "$mihomo_config_path" ]]; then error "配置不存在"; return; fi

    echo "当前已安装的 VLESS Encryption (Post-Quantum) 节点:"
    local ports
    ports=$(python3 -c "
with open('$mihomo_config_path','r') as f:
    content = f.read()
in_pq = False
for line in content.split('\n'):
    s = line.strip()
    if s.startswith('- name: vless-pq-in-'):
        in_pq = True
    elif s.startswith('- name:') and 'vless-pq-in-' not in s:
        in_pq = False
    elif in_pq and s.startswith('port:'):
        print(s.split(':')[1].strip())
" 2>/dev/null || true)

    if [[ -z "$ports" ]]; then error "未找到任何 VLESS Encryption 节点，无需删除。"; return; fi
    for p in $ports; do echo " - 端口: $p"; done
    echo ""

    local target_p
    while true; do
        read -p "请输入要删除的端口: " target_p
        if echo "$ports" | grep -q "^$target_p$"; then break
        else error "端口无效，请重新输入。"; fi
    done

    read -p "确定要永久删除端口 $target_p 的节点吗？[y/N]: " confirm
    if [[ ! $confirm =~ ^[yY]$ ]]; then info "操作已取消。"; return; fi

    info "正在删除节点..."
    cp "$mihomo_config_path" "${mihomo_config_path}.bak.del.$(date +%s)"

    python3 -c "
import sys
config_path = sys.argv[1]
target_name = 'vless-pq-in-' + sys.argv[2]
with open(config_path, 'r') as f:
    lines = f.readlines()
result = []
skip = False
for line in lines:
    stripped = line.strip()
    if stripped == '- name: ' + target_name:
        skip = True; continue
    if skip:
        if stripped.startswith('- name:') or (stripped and not line.startswith(' ') and not line.startswith('-') and ':' in stripped and not stripped.startswith('#')):
            skip = False; result.append(line)
        else: continue
    else: result.append(line)
with open(config_path, 'w') as f:
    f.writelines(result)
" "$mihomo_config_path" "$target_p"

    local link_file="/root/mihomo_vless_encryption_link_${target_p}.txt"
    [[ -f "$link_file" ]] && rm -f "$link_file"

    service_restart
    success "VLESS Encryption 节点 (端口 $target_p) 已删除。"
}

# --- 查看订阅链接 ---
view_subscription_info() {
    if [[ ! -f "$mihomo_config_path" ]]; then error "配置不存在"; return; fi

    local ports
    ports=$(python3 -c "
with open('$mihomo_config_path','r') as f:
    content = f.read()
in_pq = False
for line in content.split('\n'):
    s = line.strip()
    if s.startswith('- name: vless-pq-in-'):
        in_pq = True
    elif s.startswith('- name:') and 'vless-pq-in-' not in s:
        in_pq = False
    elif in_pq and s.startswith('port:'):
        print(s.split(':')[1].strip())
" 2>/dev/null || true)

    if [[ -z "$ports" ]]; then error "未找到 VLESS Encryption 节点配置。"; return; fi

    local target_port="" port_count=$(echo "$ports" | wc -l)

    if [[ -n "${1:-}" ]]; then
        target_port=$1
    elif [[ "$port_count" -eq 1 ]]; then
        target_port=$(echo "$ports" | tr -d ' \n')
    else
        echo "发现多个 VLESS PQ 节点:"
        for p in $ports; do echo " - 端口: $p"; done
        echo ""
        while true; do
            read -p "请输入要查看的端口: " input_p
            if echo "$ports" | grep -q "^$input_p$"; then target_port=$input_p; break
            else error "无效端口"; fi
        done
    fi

    # 获取 UUID 和备注名
    local node_info
    node_info=$(python3 -c "
import sys
config_path = sys.argv[1]
target_port = int(sys.argv[2])
with open(config_path, 'r') as f:
    content = f.read()
in_target = False
in_target_block = False
name = uuid = ''
for line in content.split('\n'):
    s = line.strip()
    if s.startswith('- name: vless-pq-in-'):
        current_name = s.split(':', 1)[1].strip()
        in_target_block = True
        in_target = False
    elif in_target_block and not in_target and s.startswith('port:'):
        p = int(s.split(':')[1].strip())
        if p == target_port:
            in_target = True
            name = current_name
        else:
            in_target_block = False
    elif in_target:
        if s.startswith('- uuid:'):
            uuid = s.split(':', 1)[1].strip()
        elif s.startswith('- name:') and s != '- name: ' + name:
            break
if name:
    print(f'{name}|{uuid}')
" "$mihomo_config_path" "$target_port" 2>/dev/null || true)

    if [[ -z "$node_info" ]]; then error "读取配置失败"; return; fi

    local tag=$(echo "$node_info" | cut -d'|' -f1)
    local uuid=$(echo "$node_info" | cut -d'|' -f2)

    # 读取客户端 Encryption Key
    local key_file="/root/mihomo_vless_encryption_client_key_${target_port}.txt"
    local enc_key=""
    if [[ -f "$key_file" ]]; then
        enc_key=$(cat "$key_file")
    else
        error "缺失客户端 Encryption 密钥，无法生成链接。"
        return
    fi

    # 确定连接地址
    local ip
    if [[ -f "$address_file" && -s "$address_file" ]]; then
        ip=$(cat "$address_file"); [[ -z "$ip" ]] && ip=$(get_public_ip)
    else ip=$(get_public_ip); fi
    local display_ip=$ip && [[ $ip =~ ":" ]] && display_ip="[$ip]"

    # 生成链接
    local ipinfo_json country org link_name
    ipinfo_json=$(curl -sf --max-time 5 https://ipinfo.io 2>/dev/null)
    if [[ -n "$ipinfo_json" ]]; then
        country=$(echo "$ipinfo_json" | grep '"country"' | sed 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
        org=$(echo "$ipinfo_json" | grep '"org"' | sed 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi
    if [[ -n "${country:-}" && -n "${org:-}" ]]; then link_name="${country} - ${org}"
    else link_name="$tag"; fi
    local link_name_encoded=$(echo "$link_name" | sed 's/ /%20/g')

    local vless_url="vless://${uuid}@${display_ip}:${target_port}?encryption=${enc_key}&type=tcp&security=none#${link_name_encoded}"
    local save_file="/root/mihomo_vless_encryption_link_${target_port}.txt"

    if [[ "$is_quiet" = true ]]; then echo "${vless_url}"
    else
        echo "----------------------------------------------------------------"
        echo -e "${green} --- Mihomo VLESS Encryption (Post-Quantum) --- ${none}"
        echo -e "${yellow} 备注: ${cyan}$tag${none}"
        echo -e "${yellow} 地址: ${cyan}$ip${none}"
        echo -e "${yellow} 端口: ${cyan}$target_port${none}"
        echo -e "${yellow} UUID: ${cyan}$uuid${none}"
        echo -e "${yellow} 加密串: ${cyan}${enc_key:0:40}...${none}"
        echo "----------------------------------------------------------------"
        echo -e "${green} 分享链接 (已保存到 $save_file): ${none}\n"
        echo -e "${cyan}${vless_url}${none}"
        echo "----------------------------------------------------------------"
        echo "$vless_url" > "$save_file"
    fi
}

# --- 菜单操作函数 ---
install_vless_pq() {
    info "开始配置 VLESS Encryption (Post-Quantum)..."
    local port uuid

    while true; do
        read -p "$(echo -e "请输入端口 [1-65535] (默认: ${cyan}40000${none}): ")" port
        [ -z "$port" ] && port=40000
        if ! is_valid_port "$port"; then error "端口无效"; continue; fi
        if is_port_in_use "$port"; then error "端口 $port 已被占用"; continue; fi
        break
    done

    while true; do
        read -p "$(echo -e "请输入UUID (留空将默认生成随机UUID): ")" uuid
        if [[ -z "$uuid" ]]; then
            uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/')
            info "已生成随机UUID: ${cyan}${uuid}${none}"; break
        elif is_valid_uuid "$uuid"; then break
        else error "UUID格式无效"; fi
    done

    if ! install_mihomo_core; then return 1; fi
    install_geodata
    
    if ! generate_vless_tokens; then return 1; fi

    # 写入配置，服务端存 Decryption，客户端存 Encryption
    append_vless_config "$port" "$uuid" "$VLESS_DECRYPTION"
    echo "$VLESS_ENCRYPTION" > "/root/mihomo_vless_encryption_client_key_${port}.txt"

    setup_service
    if ! service_restart; then return 1; fi
    success "Mihomo VLESS PQ 安装配置成功！"
    view_subscription_info "$port"
}

update_mihomo() {
    if [[ ! -f "$mihomo_binary_path" ]]; then error "Mihomo 未安装" && return; fi
    info "正在检查最新版本..."
    if ! install_mihomo_core; then return 1; fi
    install_geodata
    service_restart
    success "Mihomo 更新成功！"
}

restart_mihomo() {
    if ! service_restart; then return 1; fi
    success "服务已重启"
}

uninstall_mihomo() {
    if [[ ! -f "$mihomo_binary_path" ]]; then error "Mihomo 未安装" && return; fi
    read -p "确定卸载 Mihomo 吗？[Y/n]: " confirm
    if [[ "$confirm" =~ ^[nN]$ ]]; then return; fi
    
    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        systemctl stop mihomo || true; systemctl disable mihomo || true
        rm -f /etc/systemd/system/mihomo.service; systemctl daemon-reload
    elif [[ "$INIT_SYSTEM" == "openrc" ]]; then
        rc-service mihomo stop || true; rc-update del mihomo default || true
        rm -f /etc/init.d/mihomo
    fi
    
    rm -f "$mihomo_binary_path"
    rm -rf "$mihomo_config_dir"
    rm -f /root/mihomo_vless_encryption_*.txt /root/inbound_address.txt
    success "Mihomo 已成功卸载。"
}

view_mihomo_log() {
    info "显示日志... 按 Ctrl+C 停止"
    trap 'echo -e "\n日志查看已停止。"' SIGINT
    if command -v journalctl >/dev/null 2>&1; then journalctl -u mihomo -f --no-pager || true
    elif [[ -d /var/log/mihomo ]]; then tail -n 200 -F /var/log/mihomo/*.log 2>/dev/null || true
    else error "无法找到日志"; fi
    trap - SIGINT; echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

modify_config() {
    if [[ ! -f "$mihomo_config_path" ]]; then error "配置不存在"; return; fi
    echo "当前 VLESS Encryption 节点:"
    local ports
    ports=$(python3 -c "
with open('$mihomo_config_path','r') as f:
    content = f.read()
in_pq = False
for line in content.split('\n'):
    s = line.strip()
    if s.startswith('- name: vless-pq-in-'):
        in_pq = True
    elif s.startswith('- name:') and 'vless-pq-in-' not in s:
        in_pq = False
    elif in_pq and s.startswith('port:'):
        print(s.split(':')[1].strip())
" 2>/dev/null || true)

    if [[ -z "$ports" ]]; then error "未找到节点"; return; fi
    for p in $ports; do echo " - 端口: $p"; done
    echo ""

    local target_p
    while true; do
        read -p "请输入要修改的端口: " target_p
        if echo "$ports" | grep -q "^$target_p$"; then break; else error "端口未找到"; fi
    done

    info "注意：修改将删除旧配置并重新生成抗量子密钥对。"
    local new_uuid
    while true; do
        read -p "$(echo -e "新 UUID (留空随机生成): ")" new_uuid
        if [[ -z "$new_uuid" ]]; then
            new_uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed 's/^\(........\)\(....\)\(....\)\(....\)\(............\)$/\1-\2-\3-\4-\5/')
            break
        elif is_valid_uuid "$new_uuid"; then break
        else error "UUID 格式无效"; fi
    done

    # 删除旧配置
    python3 -c "
import sys
config_path = sys.argv[1]
target_name = 'vless-pq-in-' + sys.argv[2]
with open(config_path, 'r') as f:
    lines = f.readlines()
result = []
skip = False
for line in lines:
    stripped = line.strip()
    if stripped == '- name: ' + target_name:
        skip = True; continue
    if skip:
        if stripped.startswith('- name:') or (stripped and not line.startswith(' ') and not line.startswith('-') and ':' in stripped and not stripped.startswith('#')):
            skip = False; result.append(line)
        else: continue
    else: result.append(line)
with open(config_path, 'w') as f:
    f.writelines(result)
" "$mihomo_config_path" "$target_p"

    # 生成新密钥
    if ! generate_vless_tokens; then return 1; fi
    echo "$VLESS_ENCRYPTION" > "/root/mihomo_vless_encryption_client_key_${target_p}.txt"

    append_vless_config "$target_p" "$new_uuid" "$VLESS_DECRYPTION"
    service_restart
    success "修改完成"
    view_subscription_info "$target_p"
}

press_any_key_to_continue() {
    echo ""; read -n 1 -s -r -p "按任意键返回主菜单..." || true
}

main_menu() {
    while true; do
        clear
        echo -e "${cyan} Mihomo VLESS Encryption (Post-Quantum) 脚本${none}"
        echo "---------------------------------------------"
        echo -e "${red} 如果您是在uzumaru购买的产品，并且该产品${none}"
        echo -e "${red} 是用IDC入口IP或者是DDNS域名连接的，请${none}"
        echo -e "${red} 先使用功能9，填入面板显示的连接IP或DDNS域名${none}"
        echo "---------------------------------------------"
        check_mihomo_status
        echo -e "${mihomo_status_info}"
        echo "---------------------------------------------"
        printf "  ${green}%-2s${none} %-35s\n" "1." "新增/安装 VLESS PQ 节点"
        printf "  ${cyan}%-2s${none} %-35s\n" "2." "更新 Mihomo 核心"
        printf "  ${yellow}%-2s${none} %-35s\n" "3." "重启 Mihomo 服务"
        printf "  ${red}%-2s${none} %-35s\n" "4." "卸载 Mihomo"
        printf "  ${magenta}%-2s${none} %-35s\n" "5." "查看日志"
        printf "  ${cyan}%-2s${none} %-35s\n" "6." "修改/重置节点配置"
        printf "  ${green}%-2s${none} %-35s\n" "7." "查看节点链接"
        printf "  ${red}%-2s${none} %-35s\n" "8." "删除 VLESS PQ 节点"
        echo "---------------------------------------------"
        printf "  ${magenta}%-2s${none} %-35s\n" "9." "设置连接地址 (NAT/DDNS)"
        printf "  ${yellow}%-2s${none} %-35s\n" "0." "退出"
        echo "---------------------------------------------"
        read -p "请输入选项 [0-9]: " choice

        local needs_pause=true
        case $choice in
            1) install_vless_pq ;;
            2) update_mihomo ;;
            3) restart_mihomo ;;
            4) uninstall_mihomo ;;
            5) view_mihomo_log; needs_pause=false ;;
            6) modify_config ;;
            7) view_subscription_info ;;
            8) delete_vless_pq_node ;;
            9) set_connection_address ;;
            0) success "再见！"; exit 0 ;;
            *) error "无效选项" ;;
        esac
        if [ "$needs_pause" = true ]; then press_any_key_to_continue; fi
    done
}

main() {
    pre_check
    if [[ $# -gt 0 && "$1" == "install" ]]; then install_vless_pq; else main_menu; fi
}

main "$@"
