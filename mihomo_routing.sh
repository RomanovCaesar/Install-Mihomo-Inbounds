#!/bin/bash
# ==============================================================================
# Caesar 蜜汁 Mihomo 服务端分流脚本 v2.0
# 适配环境：Debian/Ubuntu/Alpine
# 依赖：curl, python3, openssl
# 功能：安装Geo数据、添加Outbounds(代理)、添加Routing(规则)、查询配置
# 增强：完全支持 Socks5 / SS2022 / VLESS-Reality，并支持 IN-NAME 链式路由分流
# ==============================================================================

# --- 全局设置 ---
set -euo pipefail
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[96m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/mihomo/config.yaml"
SCRIPT_PATH="/usr/bin/mihomo-routing"

# --- 基础函数 ---
die() { echo -e "${RED}[ERROR] $*${PLAIN}" >&2; exit 1; }
info() { echo -e "${GREEN}[INFO] $*${PLAIN}"; }
warn() { echo -e "${YELLOW}[WARN] $*${PLAIN}"; }

# --- 权限与依赖检测 ---
pre_check() {
    [[ ${EUID:-$(id -u)} -ne 0 ]] && die "请以 root 身份运行此脚本。"
    
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_ID="${ID,,}"
    else
        die "无法检测系统版本。"
    fi

    local deps=("curl" "python3" "openssl")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            info "正在安装依赖: $dep ..."
            if [[ "$OS_ID" == "alpine" ]]; then
                apk add --no-cache "$dep" >/dev/null 2>&1 || die "安装 $dep 失败。"
            elif [[ "$OS_ID" =~ debian|ubuntu ]]; then
                apt-get update >/dev/null 2>&1 && apt-get install -y "$dep" >/dev/null 2>&1 || die "安装 $dep 失败。"
            fi
        fi
    done
}

# --- 自我安装 ---
install_self() {
    local current_path
    current_path="$(realpath "$0")"
    if [[ "$current_path" != "$SCRIPT_PATH" ]]; then
        info "正在安装脚本到 $SCRIPT_PATH ..."
        cp "$current_path" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        info "脚本安装完成，请在命令行直接输入 mihomo-routing 使用。"
        sleep 1
        exec "$SCRIPT_PATH" "$@"
    fi
}

# --- 重启 Mihomo ---
restart_mihomo() {
    info "正在重启 Mihomo 服务..."
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart mihomo || warn "Mihomo 重启失败，请检查日志"
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service mihomo restart || warn "Mihomo 重启失败"
    else
        warn "未检测到服务管理工具，请手动重启 Mihomo。"
    fi
}

pause() {
    echo
    read -n 1 -s -r -p "按任意键回到主菜单..." || true
    echo
}

# --- 核心：配置注入器 (Python) ---
run_insert_proxy() {
    local config=$1
    local snippet=$2
    cat << 'EOF' > /tmp/insert_proxy.py
import sys, re
config_path = sys.argv[1]
yaml_snippet = sys.argv[2]

with open(config_path, 'r') as f:
    content = f.read()

if not re.search(r'^proxies:', content, re.MULTILINE):
    content += '\nproxies:\n'

lines = content.split('\n')
result = []
in_proxies = False
inserted = False

for line in lines:
    if line.startswith('proxies:'):
        in_proxies = True
        result.append(line)
        continue
    
    if in_proxies and not inserted:
        if line.strip() == '' or line.strip().startswith('#') or line.startswith(' '):
            result.append(line)
        else:
            result.append(yaml_snippet.rstrip('\n'))
            inserted = True
            in_proxies = False
            result.append(line)
    else:
        result.append(line)

if in_proxies and not inserted:
    result.append(yaml_snippet.rstrip('\n'))

with open(config_path, 'w') as f:
    f.write('\n'.join(result))
EOF
    python3 /tmp/insert_proxy.py "$config" "$snippet"
    rm -f /tmp/insert_proxy.py
}

run_insert_rule() {
    local config=$1
    local new_rule=$2
    cat << 'EOF' > /tmp/insert_rule.py
import sys
config_path = sys.argv[1]
new_rule = sys.argv[2]

with open(config_path, 'r') as f:
    lines = f.readlines()

if not any(line.startswith('rules:') for line in lines):
    lines.append('\nrules:\n')

result = []
inserted = False
in_rules = False

for line in lines:
    if line.strip().startswith('- MATCH,'):
        if not inserted:
            result.append(new_rule + '\n')
            inserted = True
        result.append(line)
        continue

    if line.startswith('rules:'):
        in_rules = True
        result.append(line)
        continue

    if in_rules and not inserted:
        if line.strip() == '' or line.strip().startswith('#') or line.startswith(' '):
            result.append(line)
        else:
            result.append(new_rule + '\n')
            inserted = True
            in_rules = False
            result.append(line)
    else:
        result.append(line)

if in_rules and not inserted:
    result.append(new_rule + '\n')

with open(config_path, 'w') as f:
    f.writelines(result)
EOF
    python3 /tmp/insert_rule.py "$config" "  - $new_rule"
    rm -f /tmp/insert_rule.py
}

parse_link_py() {
    cat << 'EOF' > /tmp/parse_link.py
import sys, urllib.parse, json, base64, re

link = sys.argv[1]
result = {}

def b64decode(s):
    s = s.strip()
    missing_padding = len(s) % 4
    if missing_padding:
        s += "=" * (4 - missing_padding)
    try:
        return base64.urlsafe_b64decode(s).decode("utf-8")
    except:
        return base64.b64decode(s).decode("utf-8")

try:
    if link.startswith("ss://"):
        result["protocol"] = "shadowsocks"
        body = link[5:]
        tag = ""
        if "#" in body:
            body, tag = body.split("#", 1)
            result["tag_comment"] = urllib.parse.unquote(tag)
        
        if "@" in body:
            userpass_part, hostport = body.rsplit("@", 1)
            method = ""
            password = ""
            decoded_success = False
            try:
                decoded_up = b64decode(userpass_part)
                if ":" in decoded_up and decoded_up.isprintable():
                    method, password = decoded_up.split(":", 1)
                    decoded_success = True
            except:
                pass
            if not decoded_success:
                if ":" in userpass_part:
                    method, password = userpass_part.split(":", 1)
                    password = urllib.parse.unquote(password)
                else:
                    raise Exception("Invalid SS format")
            host, port = hostport.split(":")
            result["address"] = host
            result["port"] = int(port)
            result["method"] = method
            result["password"] = password
        else:
            decoded = b64decode(body)
            if "@" in decoded:
                method_pass, host_port = decoded.rsplit("@", 1)
                if ":" in method_pass:
                    method, password = method_pass.split(":", 1)
                host, port = host_port.split(":")
                result["address"] = host
                result["port"] = int(port)
                result["method"] = method
                result["password"] = password

    elif link.startswith("vless://"):
        result["protocol"] = "vless"
        parsed = urllib.parse.urlparse(link)
        result["uuid"] = parsed.username
        result["address"] = parsed.hostname
        result["port"] = parsed.port
        result["tag_comment"] = urllib.parse.unquote(parsed.fragment)
        params = urllib.parse.parse_qs(parsed.query)
        result["encryption"] = params.get("encryption", ["none"])[0]
        result["security"] = params.get("security", ["none"])[0]
        result["flow"] = params.get("flow", [""])[0]
        result["sni"] = params.get("sni", [""])[0]
        result["pbk"] = params.get("pbk", [""])[0]
        result["sid"] = params.get("sid", [""])[0]
        result["fp"] = params.get("fp", [""])[0]
        result["type"] = params.get("type", ["tcp"])[0]
        result["spiderx"] = params.get("spiderx", [""])[0]
        
    else:
        result["error"] = "Unsupported scheme"

    print(json.dumps(result))

except Exception as e:
    print(json.dumps({"error": str(e)}))
EOF
    python3 /tmp/parse_link.py "$1"
    rm -f /tmp/parse_link.py
}

# --- 功能 1: 安装 Geo 文件 ---
install_geo_assets() {
    local updater_script="/root/update_geo.sh"
    local updater_url="https://raw.githubusercontent.com/RomanovCaesar/Install-Mihomo-Inbounds/main/update_geo.sh"

    info "正在拉取自动更新脚本 update_geo.sh ..."
    if curl -fsSL -o "$updater_script" "$updater_url"; then
        chmod +x "$updater_script"
        info "脚本下载成功: $updater_script"
    else
        die "无法从 Github 下载更新脚本。"
    fi

    info "正在执行第一次 Geo 文件下载与安装..."
    if "$updater_script"; then
        info "初始化下载成功！"
    else
        die "初始化下载失败。"
    fi
    
    info "设置 Crontab 定时任务 (每天凌晨 3:00 执行)..."
    local cron_job="0 3 * * * $updater_script >> /var/log/update_geo.log 2>&1"
    local tmp_cron; tmp_cron=$(mktemp)
    crontab -l 2>/dev/null > "$tmp_cron" || true
    sed -i '/update_geo.sh/d' "$tmp_cron"
    echo "$cron_job" >> "$tmp_cron"
    crontab "$tmp_cron"
    rm -f "$tmp_cron"
    
    success "Geo 文件自动更新已配置完成！日志保存在: /var/log/update_geo.log"
    pause
}

# --- 功能 2: 添加出站代理 ---
add_outbound() {
    if [[ ! -f "$CONFIG_FILE" ]]; then die "配置文件不存在: $CONFIG_FILE"; fi

    echo "================ 添加 Outbounds (出站节点) ================"
    
    local tag
    while true; do
        read -rp "请输入节点唯一名称 (Tag): " tag
        [[ -z "$tag" ]] && continue
        if grep -q "name: $tag" "$CONFIG_FILE" 2>/dev/null || grep -q "name: \"$tag\"" "$CONFIG_FILE" 2>/dev/null; then
            echo -e "${RED}名称 '$tag' 已存在，请使用其他名称。${PLAIN}"
        else
            break
        fi
    done

    echo "请选择节点类型:"
    echo "  1) Socks"
    echo "  2) Shadowsocks (SS)"
    echo "  3) VLESS"
    read -rp "选择 (1-3): " type_choice

    local yaml_snippet=""

    case "$type_choice" in
        1) # Socks
            read -rp "地址 (Address): " addr
            read -rp "端口 (Port): " port
            read -rp "用户名 (User, 可留空): " user
            read -rp "密码 (Pass, 可留空): " pass
            
yaml_snippet=$(cat <<EOF
  - name: "${tag}"
    type: socks5
    server: ${addr}
    port: ${port}
    udp: true
EOF
)
            if [[ -n "$user" ]]; then yaml_snippet+=$'\n'"    username: \"${user}\""; fi
            if [[ -n "$pass" ]]; then yaml_snippet+=$'\n'"    password: \"${pass}\""; fi
            ;;

        2) # SS
            echo "添加方式: 1) 粘贴链接  2) 手动输入"
            read -rp "选择 (1/2): " ss_method_choice
            local addr method pass port
            if [[ "$ss_method_choice" == "1" ]]; then
                read -rp "请输入 SS 分享链接: " link
                local parsed; parsed=$(parse_link_py "$link")
                if echo "$parsed" | grep -q '"error"'; then
                    die "解析失败: $(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("error",""))')"
                fi
                addr=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["address"])')
                port=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["port"])')
                method=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["method"])')
                pass=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["password"])')
                info "解析成功: $method@$addr:$port"
            else
                read -rp "地址 (Address): " addr
                read -rp "端口 (Port): " port
                echo "加密 (1-6): 1)aes-128-gcm 2)aes-256-gcm 3)chacha20-ietf 4)2022-blake3-aes-128 5)2022-blake3-aes-256 6)2022-blake3-chacha20"
                read -rp "选择: " m_idx
                local methods=("aes-128-gcm" "aes-256-gcm" "chacha20-ietf-poly1305" "2022-blake3-aes-128-gcm" "2022-blake3-aes-256-gcm" "2022-blake3-chacha20-poly1305")
                method="${methods[$((m_idx-1))]}"
                [[ -z "$method" ]] && die "无效选择"
                read -rp "密码: " pass
            fi

yaml_snippet=$(cat <<EOF
  - name: "${tag}"
    type: ss
    server: ${addr}
    port: ${port}
    cipher: ${method}
    password: "${pass}"
    udp: true
EOF
)
            ;;

        3) # VLESS
            read -rp "请输入 VLESS 分享链接: " link
            local parsed; parsed=$(parse_link_py "$link")
            if echo "$parsed" | grep -q '"error"'; then die "解析失败"; fi
            
            local addr port uuid security sni pbk sid fp flow type
            addr=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["address"])')
            port=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["port"])')
            uuid=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["uuid"])')
            security=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("security","none"))')
            encryption=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("encryption","none"))')
            sni=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sni",""))')
            pbk=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("pbk",""))')
            sid=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sid",""))')
            fp=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("fp","chrome"))')
            flow=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("flow",""))')
            type=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("type","tcp"))')
            
            info "解析成功: VLESS $uuid@$addr:$port (Sec: $security, Net: $type)"

yaml_snippet=$(cat <<EOF
  - name: "${tag}"
    type: vless
    server: ${addr}
    port: ${port}
    uuid: ${uuid}
    network: ${type}
    udp: true
EOF
)
            if [[ -n "$flow" && "$flow" != "none" ]]; then yaml_snippet+=$'\n'"    flow: ${flow}"; fi
            if [[ -n "$encryption" && "$encryption" != "none" ]]; then 
                yaml_snippet+=$'\n'"    encryption: \"${encryption}\""
            fi
            if [[ "$security" == "reality" ]]; then
                yaml_snippet+=$'\n'"    tls: true"
                yaml_snippet+=$'\n'"    servername: ${sni}"
                yaml_snippet+=$'\n'"    client-fingerprint: ${fp}"
                yaml_snippet+=$'\n'"    reality-opts:"
                yaml_snippet+=$'\n'"      public-key: ${pbk}"
                if [[ -n "$sid" ]]; then yaml_snippet+=$'\n'"      short-id: ${sid}"; fi
            elif [[ "$security" == "tls" ]]; then
                yaml_snippet+=$'\n'"    tls: true"
                yaml_snippet+=$'\n'"    servername: ${sni}"
                yaml_snippet+=$'\n'"    client-fingerprint: ${fp}"
            fi
            ;;
        *) die "无效选择" ;;
    esac

    run_insert_proxy "$CONFIG_FILE" "$yaml_snippet"
    info "已添加出站代理: $tag"
    restart_mihomo
    pause
}

# --- 功能 3: 添加 Routing 规则 ---
add_routing() {
    if [[ ! -f "$CONFIG_FILE" ]]; then die "配置文件不存在"; fi
    
    echo "================ 添加分流规则 (Routing) ================"
    echo "请选择分流规则类型:"
    echo "  1) 指定入站名称 (IN-NAME)   <-- 纯链式代理转发专属"
    echo "  2) 域名后缀 (DOMAIN-SUFFIX)"
    echo "  3) 域名关键词 (DOMAIN-KEYWORD)"
    echo "  4) IP 段 (IP-CIDR)"
    echo "  5) 地理位置 (GEOIP)"
    echo "  6) 站点集合 (GEOSITE)"
    read -rp "选择 (1-6): " rule_type_choice

    local rule_prefix
    local match_value

    case "$rule_type_choice" in
        1) 
            rule_prefix="IN-NAME"
            echo "当前可用入站 (Listeners):"
            python3 -c "
with open('$CONFIG_FILE','r') as f:
    content = f.read()
in_listeners = False
for line in content.split('\n'):
    s = line.strip()
    if s.startswith('listeners:'):
        in_listeners = True; continue
    elif in_listeners:
        if s.startswith('- name:'):
            name = s.split(':', 1)[1].strip().strip('\"').strip(\"'\")
            print('  - ' + name)
        elif s and not s.startswith(' ') and not s.startswith('-') and ':' in s:
            break
" 2>/dev/null || true
            read -rp "请输入需要被转发的入站名称: " match_value
            ;;
        2) rule_prefix="DOMAIN-SUFFIX" ; read -rp "请输入匹配值 (如 google.com): " match_value ;;
        3) rule_prefix="DOMAIN-KEYWORD" ; read -rp "请输入关键词 (如 google): " match_value ;;
        4) rule_prefix="IP-CIDR" ; read -rp "请输入 IP 段 (如 8.8.8.8/32): " match_value ;;
        5) rule_prefix="GEOIP" ; read -rp "请输入 GEOIP (如 cn): " match_value ;;
        6) rule_prefix="GEOSITE" ; read -rp "请输入 GEOSITE (如 cn): " match_value ;;
        *) die "无效选择" ;;
    esac

    [[ -z "$match_value" ]] && die "匹配值不能为空"

    echo "当前可用目标出站 (Proxies/DIRECT/REJECT):"
    echo "  - DIRECT (直连)"
    echo "  - REJECT (拒绝)"
    python3 -c "
with open('$CONFIG_FILE','r') as f:
    lines = f.readlines()
in_proxies = False
for line in lines:
    s = line.strip()
    if s.startswith('proxies:'):
        in_proxies = True; continue
    elif in_proxies:
        if s.startswith('- name:'):
            name = s.split(':', 1)[1].strip().strip('\"').strip(\"'\")
            print('  - ' + name)
        elif s and not s.startswith(' ') and not s.startswith('-') and not s.startswith('#'):
            break
" 2>/dev/null || true

    local target
    while true; do
        read -rp "请输入最终指向的目标出站名称: " target
        if [[ -n "$target" ]]; then break; fi
    done

    local rule="${rule_prefix},${match_value},${target}"
    run_insert_rule "$CONFIG_FILE" "$rule"

    info "分流规则添加成功: $rule"
    restart_mihomo
    pause
}

# --- 功能 4: 查询 Listeners ---
query_listeners() {
    echo "================ Listeners (入站) 列表 ================"
    python3 -c "
with open('$CONFIG_FILE','r') as f:
    lines = f.readlines()
in_listeners = False
current = {}
print(f\"  {'Tag/名称':25s} {'Type/类型':15s} {'Port/端口'}\")
print(\"  \" + \"-\"*50)
for line in lines:
    s = line.strip()
    if s.startswith('listeners:'):
        in_listeners = True; continue
    if in_listeners:
        if s.startswith('- name:'):
            if current:
                print(f\"  {current.get('name','?'):25s} {current.get('type','?'):15s} {current.get('port','?')}\")
            current = {'name': s.split(':',1)[1].strip().strip('\"').strip(\"'\")}
        elif s.startswith('type:'):
            current['type'] = s.split(':',1)[1].strip()
        elif s.startswith('port:'):
            current['port'] = s.split(':',1)[1].strip()
        elif s and not s.startswith(' ') and not s.startswith('-') and not s.startswith('#'):
            break
if current:
    print(f\"  {current.get('name','?'):25s} {current.get('type','?'):15s} {current.get('port','?')}\")
" 2>/dev/null || echo "  (无)"
    pause
}

# --- 功能 5: 查询 Proxies ---
query_proxies() {
    echo "================ Proxies (出站代理) 列表 ================"
    python3 -c "
with open('$CONFIG_FILE','r') as f:
    lines = f.readlines()
in_proxies = False
current = {}
print(f\"  {'Tag/名称':20s} {'Type/类型':15s} {'Address/地址':25s} {'Port/端口'}\")
print(\"  \" + \"-\"*75)
for line in lines:
    s = line.strip()
    if s.startswith('proxies:'):
        in_proxies = True; continue
    if in_proxies:
        if s.startswith('- name:'):
            if current:
                print(f\"  {current.get('name','?'):20s} {current.get('type','?'):15s} {current.get('server','N/A'):25s} {current.get('port','N/A')}\")
            current = {'name': s.split(':',1)[1].strip().strip('\"').strip(\"'\")}
        elif s.startswith('type:'):
            current['type'] = s.split(':',1)[1].strip()
        elif s.startswith('server:'):
            current['server'] = s.split(':',1)[1].strip().strip('\"').strip(\"'\")
        elif s.startswith('port:'):
            current['port'] = s.split(':',1)[1].strip()
        elif s and not s.startswith(' ') and not s.startswith('-') and not s.startswith('#'):
            break
if current:
    print(f\"  {current.get('name','?'):20s} {current.get('type','?'):15s} {current.get('server','N/A'):25s} {current.get('port','N/A')}\")
" 2>/dev/null || echo "  (无)"
    pause
}

# --- 功能 6: 查询 Rules ---
query_rules() {
    echo "================ Rules (路由规则) ================"
    python3 -c "
with open('$CONFIG_FILE','r') as f:
    lines = f.readlines()
in_rules = False
idx = 0
print(\"  ID  | 规则 (Rule)\")
print(\"  ------------------------------------------------\")
for line in lines:
    s = line.strip()
    if s.startswith('rules:'):
        in_rules = True; continue
    if in_rules:
        if s.startswith('- '):
            idx += 1
            print(f'  {idx:3d} | {s[2:]}')
        elif s and not s.startswith(' ') and not s.startswith('#'):
            break
" 2>/dev/null || echo "  (无)"
    pause
}

# --- 功能 7: 更新脚本 ---
update_script() {
    info "正在拉取最新版本脚本..."
    local update_url="https://raw.githubusercontent.com/RomanovCaesar/Install-Mihomo-Inbounds/main/mihomo_routing.sh"
    if curl -fsSL "$update_url" -o "$SCRIPT_PATH"; then
        chmod +x "$SCRIPT_PATH"
        info "脚本更新成功，即将退出，请重新运行。"
        exit 0
    else
        die "脚本更新失败。"
    fi
}

# --- 主菜单 ---
show_menu() {
    clear
    echo "================================================="
    echo "       Caesar 蜜汁 Mihomo 服务端分流脚本 v2.0     "
    echo "================================================="
    echo
    echo "  1. 安装 Geo 文件 (配置每日自动更新)"
    echo "  2. 添加出站代理 (Socks / SS / VLESS)"
    echo "  3. 添加分流规则 (Routing)"
    echo "  4. 查询已有 Listeners (入站)"
    echo "  5. 查询已有 Proxies (出站)"
    echo "  6. 查询已有 Rules (规则)"
    echo "  7. 更新脚本"
    echo "  0. 退出脚本"
    echo "================================================="
    read -rp " 请输入选项 [0-7]: " num
    
    case "$num" in
        1) install_geo_assets ;;
        2) add_outbound ;;
        3) add_routing ;;
        4) query_listeners ;;
        5) query_proxies ;;
        6) query_rules ;;
        7) update_script ;;
        0) echo -e "${GREEN}感谢使用此脚本，再见！${PLAIN}"; exit 0 ;;
        *) echo -e "${RED}无效输入。${PLAIN}"; sleep 1 ;;
    esac
}

# --- 主程序入口 ---
main() {
    pre_check
    install_self "$@"
    
    while true; do
        show_menu
    done
}

main "$@"
