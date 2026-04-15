#!/bin/bash
# ==============================================================================
# Caesar 蜜汁 Mihomo 服务端分流脚本 v1.0
# 适配环境：Debian/Ubuntu/Alpine
# 依赖：curl, python3, openssl
# 功能：安装Geo数据、添加Outbounds(代理)、添加Routing(规则)、查询配置
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
GEO_DIR="/usr/local/etc/mihomo"

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

# --- 辅助：按任意键继续 ---
pause() {
    echo
    read -n 1 -s -r -p "按任意键回到主菜单..." || true
    echo
}

# --- 功能 1: 安装 Geo 文件与定时任务 ---
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
    
    info "设置 Crontab 定时任务 (每天凌晨 3:00 执行 /root/update_geo.sh)..."
    
    local cron_job="0 3 * * * $updater_script >> /var/log/update_geo.log 2>&1"
    
    local tmp_cron
    tmp_cron=$(mktemp)
    crontab -l 2>/dev/null > "$tmp_cron" || true
    
    sed -i '/update_geo.sh/d' "$tmp_cron"
    
    echo "$cron_job" >> "$tmp_cron"
    crontab "$tmp_cron"
    rm -f "$tmp_cron"
    
    info "Geo 文件自动更新已配置完成！"
    info "日志将保存在: /var/log/update_geo.log"
    pause
}

# --- Python 解析脚本 ---
parse_link_py() {
    python3 -c '
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
            userpass_part, hostport = body.split("@", 1)
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
                method_pass, host_port = decoded.split("@", 1)
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
' "$1"
}

# --- 功能 2: 添加 Outbound (代理节点) ---
add_outbound() {
    if [[ ! -f "$CONFIG_FILE" ]]; then die "配置文件不存在: $CONFIG_FILE"; fi

    echo "================ 添加出站代理节点 ================"
    
    local tag
    while true; do
        read -rp "请输入节点唯一名称: " tag
        [[ -z "$tag" ]] && continue
        if grep -q "name: $tag" "$CONFIG_FILE" 2>/dev/null; then
            echo -e "${RED}名称 '$tag' 已存在，请使用其他名称。${PLAIN}"
        else
            break
        fi
    done

    echo "请选择节点类型:"
    echo "  1) Shadowsocks (SS)"
    echo "  2) VLESS"
    read -rp "选择 (1-2): " type_choice

    case "$type_choice" in
        1) # SS
            echo "添加方式: 1) 粘贴链接  2) 手动输入"
            read -rp "选择 (1/2): " ss_method_choice
            if [[ "$ss_method_choice" == "1" ]]; then
                read -rp "请输入 SS 分享链接: " link
                local parsed
                parsed=$(parse_link_py "$link")
                if echo "$parsed" | grep -q '"error"'; then
                    die "解析失败: $(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("error",""))')"
                fi
                local addr method pass port
                addr=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["address"])')
                port=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["port"])')
                method=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["method"])')
                pass=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["password"])')
                info "解析成功: $method@$addr:$port"
            else
                read -rp "地址: " addr
                read -rp "端口: " port
                echo "加密 (1-6): 1)aes-128-gcm 2)aes-256-gcm 3)chacha20 4)2022-blake3-aes-128 5)2022-blake3-aes-256 6)2022-blake3-chacha20"
                read -rp "选择: " m_idx
                local methods=("aes-128-gcm" "aes-256-gcm" "chacha20-ietf-poly1305" "2022-blake3-aes-128-gcm" "2022-blake3-aes-256-gcm" "2022-blake3-chacha20-poly1305")
                local method="${methods[$((m_idx-1))]}"
                [[ -z "$method" ]] && die "无效选择"
                read -rp "密码: " pass
            fi

            # 写入 proxies 段
            python3 -c "
import sys
config_path = sys.argv[1]
name = sys.argv[2]
server = sys.argv[3]
port = sys.argv[4]
cipher = sys.argv[5]
password = sys.argv[6]

with open(config_path, 'r') as f:
    content = f.read()

proxy_block = '''
  - name: \"{name}\"
    type: ss
    server: {server}
    port: {port}
    cipher: {cipher}
    password: \"{password}\"
    udp: true'''.format(name=name, server=server, port=port, cipher=cipher, password=password)

import re
if re.search(r'^proxies:\s*\[\]\s*$', content, re.MULTILINE):
    content = re.sub(r'^proxies:\s*\[\]\s*$', 'proxies:' + proxy_block, content, flags=re.MULTILINE)
elif re.search(r'^proxies:\s*$', content, re.MULTILINE):
    content = re.sub(r'^proxies:\s*$', 'proxies:' + proxy_block, content, flags=re.MULTILINE)
elif 'proxies:' in content:
    lines = content.split('\n')
    result_lines = []
    in_proxies = False
    inserted = False
    for line in lines:
        result_lines.append(line)
        if line.startswith('proxies:'):
            in_proxies = True; continue
        if in_proxies and not inserted:
            if line and not line.startswith(' ') and not line.startswith('#') and ':' in line:
                result_lines.insert(len(result_lines) - 1, proxy_block.lstrip('\n'))
                inserted = True; in_proxies = False
    if in_proxies and not inserted:
        result_lines.append(proxy_block.lstrip('\n'))
    content = '\n'.join(result_lines)
else:
    content += '\nproxies:' + proxy_block + '\n'

with open(config_path, 'w') as f:
    f.write(content)
" "$CONFIG_FILE" "$tag" "$addr" "$port" "$method" "$pass"
            ;;

        2) # VLESS
            read -rp "请输入 VLESS 分享链接: " link
            local parsed
            parsed=$(parse_link_py "$link")
            if echo "$parsed" | grep -q '"error"'; then
                die "解析失败"
            fi
            
            local addr port uuid security sni pbk sid fp flow
            addr=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["address"])')
            port=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["port"])')
            uuid=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin)["uuid"])')
            security=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("security","none"))')
            sni=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sni",""))')
            pbk=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("pbk",""))')
            sid=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("sid",""))')
            fp=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("fp","chrome"))')
            flow=$(echo "$parsed" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("flow",""))')
            
            info "解析成功: VLESS $uuid@$addr:$port (Sec: $security)"

            python3 -c "
import sys
config_path = sys.argv[1]
name = sys.argv[2]
server = sys.argv[3]
port = sys.argv[4]
uuid = sys.argv[5]
security = sys.argv[6]
sni = sys.argv[7]
pbk = sys.argv[8]
sid = sys.argv[9]
fp = sys.argv[10]
flow = sys.argv[11]

with open(config_path, 'r') as f:
    content = f.read()

proxy_block = '''
  - name: \"{name}\"
    type: vless
    server: {server}
    port: {port}
    uuid: {uuid}
    network: tcp
    udp: true'''.format(name=name, server=server, port=port, uuid=uuid)

if flow:
    proxy_block += '\n    flow: ' + flow

if security == 'reality':
    proxy_block += '''
    tls: true
    servername: {sni}
    client-fingerprint: {fp}
    reality-opts:
      public-key: {pbk}
      short-id: {sid}'''.format(sni=sni, fp=fp, pbk=pbk, sid=sid)
elif security == 'tls':
    proxy_block += '''
    tls: true
    servername: {sni}'''.format(sni=sni)

import re
if re.search(r'^proxies:\s*\[\]\s*$', content, re.MULTILINE):
    content = re.sub(r'^proxies:\s*\[\]\s*$', 'proxies:' + proxy_block, content, flags=re.MULTILINE)
elif re.search(r'^proxies:\s*$', content, re.MULTILINE):
    content = re.sub(r'^proxies:\s*$', 'proxies:' + proxy_block, content, flags=re.MULTILINE)
elif 'proxies:' in content:
    lines = content.split('\n')
    result_lines = []
    in_proxies = False
    inserted = False
    for line in lines:
        result_lines.append(line)
        if line.startswith('proxies:'):
            in_proxies = True; continue
        if in_proxies and not inserted:
            if line and not line.startswith(' ') and not line.startswith('#') and ':' in line:
                result_lines.insert(len(result_lines) - 1, proxy_block.lstrip('\n'))
                inserted = True; in_proxies = False
    if in_proxies and not inserted:
        result_lines.append(proxy_block.lstrip('\n'))
    content = '\n'.join(result_lines)
else:
    content += '\nproxies:' + proxy_block + '\n'

with open(config_path, 'w') as f:
    f.write(content)
" "$CONFIG_FILE" "$tag" "$addr" "$port" "$uuid" "$security" "$sni" "$pbk" "$sid" "$fp" "$flow"
            ;;
        *) die "无效选择" ;;
    esac

    info "已添加出站代理: $tag"
    restart_mihomo
    pause
}

# --- 功能 3: 添加 Routing 规则 ---
add_routing() {
    if [[ ! -f "$CONFIG_FILE" ]]; then die "配置文件不存在"; fi
    
    echo "================ 添加分流规则 ================"

    echo "请选择规则类型:"
    echo "  1) DOMAIN-SUFFIX (域名后缀)"
    echo "  2) DOMAIN-KEYWORD (域名关键词)"
    echo "  3) IP-CIDR (IP 段)"
    echo "  4) GEOIP (地理 IP)"
    echo "  5) GEOSITE (地理站点)"
    read -rp "选择 (1-5): " rule_type_choice

    local rule_prefix
    case "$rule_type_choice" in
        1) rule_prefix="DOMAIN-SUFFIX" ;;
        2) rule_prefix="DOMAIN-KEYWORD" ;;
        3) rule_prefix="IP-CIDR" ;;
        4) rule_prefix="GEOIP" ;;
        5) rule_prefix="GEOSITE" ;;
        *) die "无效选择" ;;
    esac

    read -rp "请输入匹配值 (如 google.com, cn, 8.8.8.8/32): " match_value
    [[ -z "$match_value" ]] && die "值不能为空"

    echo "当前可用出站目标:"
    echo "  - DIRECT (直连)"
    echo "  - REJECT (拒绝)"
    # 列出 proxies 中的节点
    if grep -q "^proxies:" "$CONFIG_FILE"; then
        python3 -c "
with open('$CONFIG_FILE','r') as f:
    content = f.read()
in_proxies = False
for line in content.split('\n'):
    s = line.strip()
    if s.startswith('proxies:'):
        in_proxies = True; continue
    elif in_proxies:
        if s.startswith('- name:'):
            name = s.split(':', 1)[1].strip().strip('\"').strip(\"'\")
            print('  - ' + name)
        elif s and not s.startswith(' ') and not s.startswith('-') and ':' in s:
            break
" 2>/dev/null || true
    fi

    read -rp "请输入目标出站: " target

    local rule="${rule_prefix},${match_value},${target}"
    
    # 插入到 rules 段 (在 MATCH 之前)
    python3 -c "
import sys, re
config_path = sys.argv[1]
new_rule = sys.argv[2]

with open(config_path, 'r') as f:
    lines = f.readlines()

result = []
inserted = False
for line in lines:
    s = line.strip()
    if not inserted and s.startswith('- MATCH,'):
        result.append('  - ' + new_rule + '\n')
        inserted = True
    result.append(line)

if not inserted:
    # 没有 MATCH 规则，追加到 rules 段末尾
    in_rules = False
    result2 = []
    for line in lines:
        result2.append(line)
        if line.strip().startswith('rules:'):
            in_rules = True
    if in_rules:
        result2.append('  - ' + new_rule + '\n')
    result = result2

with open(config_path, 'w') as f:
    f.writelines(result)
" "$CONFIG_FILE" "$rule"

    info "分流规则添加成功: $rule"
    restart_mihomo
    pause
}

# --- 功能 4: 查询 Listeners ---
query_listeners() {
    echo "================ Listeners 列表 ================"
    python3 -c "
with open('$CONFIG_FILE','r') as f:
    content = f.read()
in_listeners = False
current = {}
for line in content.split('\n'):
    s = line.strip()
    if s.startswith('listeners:'):
        in_listeners = True; continue
    if in_listeners:
        if s.startswith('- name:'):
            if current:
                print(f\"  {current.get('name','?'):20s} {current.get('type','?'):15s} {current.get('port','?')}\")
            current = {'name': s.split(':',1)[1].strip()}
        elif s.startswith('type:'):
            current['type'] = s.split(':',1)[1].strip()
        elif s.startswith('port:'):
            current['port'] = s.split(':',1)[1].strip()
        elif s and not s.startswith(' ') and not s.startswith('-') and not s.startswith('#') and ':' in s:
            break
if current:
    print(f\"  {current.get('name','?'):20s} {current.get('type','?'):15s} {current.get('port','?')}\")
" 2>/dev/null || echo "  (无)"
    pause
}

# --- 功能 5: 查询 Proxies ---
query_proxies() {
    echo "================ Proxies (出站代理) 列表 ================"
    python3 -c "
with open('$CONFIG_FILE','r') as f:
    content = f.read()
in_proxies = False
current = {}
for line in content.split('\n'):
    s = line.strip()
    if s.startswith('proxies:'):
        in_proxies = True; continue
    if in_proxies:
        if s.startswith('- name:'):
            if current:
                print(f\"  {current.get('name','?'):20s} {current.get('type','?'):15s} {current.get('server','N/A'):25s} {current.get('port','N/A')}\")
            current = {'name': s.split(':',1)[1].strip().strip('\"')}
        elif s.startswith('type:'):
            current['type'] = s.split(':',1)[1].strip()
        elif s.startswith('server:'):
            current['server'] = s.split(':',1)[1].strip()
        elif s.startswith('port:'):
            current['port'] = s.split(':',1)[1].strip()
        elif s and not s.startswith(' ') and not s.startswith('-') and not s.startswith('#') and ':' in s:
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
    content = f.read()
in_rules = False
idx = 0
for line in content.split('\n'):
    s = line.strip()
    if s.startswith('rules:'):
        in_rules = True; continue
    if in_rules:
        if s.startswith('- '):
            idx += 1
            print(f'  {idx:3d}. {s[2:]}')
        elif s and not s.startswith(' ') and not s.startswith('#') and ':' in s:
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
    echo "       Caesar 蜜汁 Mihomo 服务端分流脚本 v1.0     "
    echo "================================================="
    echo
    echo "  1. 安装 Geo 文件 (配置每日自动更新)"
    echo "  2. 添加出站代理 (SS / VLESS)"
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
