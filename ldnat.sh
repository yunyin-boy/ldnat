#!/bin/sh
# Alpine 默认使用 BusyBox ash，保持 sh 兼容，无需额外安装 Bash。
set -eu
umask 077

LDNAT_VERSION="v0.3.0"

CONFIG_FILE="/etc/sing-box/config.json"
NODES_CONF="/etc/sing-box/nodes.conf"
ADDR_CONF="/etc/sing-box/server_addr"
ABUSE_CONF="/etc/sing-box/abuse_block.conf"
CERT_DIR="/etc/sing-box/certs"
CERT_PEM="/etc/sing-box/certs/cert.pem"
KEY_PEM="/etc/sing-box/certs/key.pem"
INFO_FILE="/root/node_info.txt"
DDNS_SCRIPT="/root/ddns/cf-ddns.sh"
DDNS_LOG="/root/ddns/ddns.log"
DDNS_CONFIG="/root/ddns/config.json"
REALM_CONFIG="/etc/realm/config.toml"
REALM_RULES="/etc/realm/rules.conf"
REALM_BIN="/usr/local/bin/realm"
SNI=""
SNI_SPECIFIED=false
PORT_REALITY=""
PORT_SS=""
NODE_DOMAIN=""
CF_ZONE_ID=""
CF_TOKEN=""
INSTALL_MODE=""
STAGE="参数检查"
WORK_DIR=""
ATOMIC_TEMP=""
NODE_BACKUP=""
DDNS_BACKUP=""
NODE_PENDING=false
DDNS_PENDING=false
NODE_WAS_RUNNING=false
NODE_WAS_ENABLED=false
CRON_WAS_ENABLED=false
TOKEN_ECHO_DISABLED=false

die() { printf '❌ %s\n' "$*" >&2; exit 1; }
warn() { printf '⚠️ %s\n' "$*" >&2; }
read_input() { IFS= read -r "$1" || die '输入已结束，操作取消。'; }

atomic_install() {
    ATOMIC_TEMP=$(mktemp "$2.ldnat.XXXXXX") || return 1
    if ! cp "$1" "$ATOMIC_TEMP" || ! chmod "$3" "$ATOMIC_TEMP" || ! mv -f "$ATOMIC_TEMP" "$2"; then
        rm -f "$ATOMIC_TEMP"
        ATOMIC_TEMP=""
        return 1
    fi
    ATOMIC_TEMP=""
}

make_backup() {
    [ ! -L /root/ldnat-backups ] || die '/root/ldnat-backups 不能是符号链接。'
    mkdir -p /root/ldnat-backups
    chmod 700 /root/ldnat-backups
    mktemp -d "/root/ldnat-backups/$(date '+%Y%m%d-%H%M%S').XXXXXX"
}

backup_file() {
    if [ -L "$1" ]; then
        rm -f "$1"
        return 0
    fi
    if [ -e "$1" ]; then
        [ -f "$1" ] || die "目标不是普通文件：$1"
        cp -p "$1" "$2"
    fi
}

restore_file() {
    if [ -f "$1" ]; then atomic_install "$1" "$2" "$3"; else rm -f "$2"; fi
}

rollback_node() {
    warn "节点安装未完成，正在恢复备份：$NODE_BACKUP"
    rc-service sing-box stop >/dev/null 2>&1 || true
    restore_file "$NODE_BACKUP/sing-box" /usr/local/bin/sing-box 755 || warn '核心恢复失败，请使用备份手动恢复。'
    restore_file "$NODE_BACKUP/config.json" "$CONFIG_FILE" 600 || warn '配置恢复失败，请使用备份手动恢复。'
    restore_file "$NODE_BACKUP/sing-box.init" /etc/init.d/sing-box 755 || warn '服务文件恢复失败。'
    restore_file "$NODE_BACKUP/node_info.txt" "$INFO_FILE" 600 || warn '节点信息恢复失败。'
    if [ "$NODE_WAS_ENABLED" = false ]; then rc-update del sing-box default >/dev/null 2>&1 || true; fi
    if [ "$NODE_WAS_RUNNING" = true ]; then
        rc-service sing-box start || warn '原服务未恢复运行，请检查上方错误及备份。'
    fi
}

rollback_ddns() {
    warn "DDNS 配置未完成，正在恢复备份：$DDNS_BACKUP"
    restore_file "$DDNS_BACKUP/cf-ddns.sh" "$DDNS_SCRIPT" 700 || warn 'DDNS 脚本恢复失败。'
    restore_file "$DDNS_BACKUP/config.json" "$DDNS_CONFIG" 600 || warn 'DDNS 配置恢复失败。'
    restore_file "$DDNS_BACKUP/last_ip.txt" /root/ddns/last_ip.txt 600 || warn 'DDNS 缓存恢复失败。'
    crontab "$DDNS_BACKUP/crontab" || warn '原定时任务恢复失败。'
    if [ "$CRON_WAS_ENABLED" = false ]; then rc-update del crond default >/dev/null 2>&1 || true; fi
}

cleanup() {
    EXIT_STATUS=$?
    trap - 0 HUP INT TERM
    if [ "$TOKEN_ECHO_DISABLED" = true ]; then stty echo 2>/dev/null || true; fi
    if [ "$NODE_PENDING" = true ]; then rollback_node; fi
    if [ "$DDNS_PENDING" = true ]; then rollback_ddns; fi
    if [ -n "$ATOMIC_TEMP" ]; then rm -f "$ATOMIC_TEMP"; fi
    case "$WORK_DIR" in /tmp/ldnat.*) rm -rf "$WORK_DIR" ;; esac
    if [ "$EXIT_STATUS" -ne 0 ]; then
        printf '❌ 操作失败（阶段：%s，退出码：%s），请检查上方错误。\n' "$STAGE" "$EXIT_STATUS" >&2
    fi
    exit "$EXIT_STATUS"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

require_environment() {
    [ "$(id -u)" -eq 0 ] || die '安装需要 root 权限。'
    [ -f /etc/alpine-release ] && command -v apk >/dev/null 2>&1 || die '此脚本仅支持 Alpine Linux（apk）。'
    command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 || die '未找到 OpenRC，请先确认 VPS 的初始化系统。'
    if [ -z "$WORK_DIR" ]; then WORK_DIR=$(mktemp -d /tmp/ldnat.XXXXXX); fi
}

register_command() {
    SELF_PATH=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    [ -f "$SELF_PATH" ] || return 0
    mkdir -p /usr/local/bin
    if [ -e /usr/local/bin/ldnat ] || [ -L /usr/local/bin/ldnat ]; then
        rm -f /usr/local/bin/ldnat
    fi
    chmod +x "$SELF_PATH"
    ln -s "$SELF_PATH" /usr/local/bin/ldnat
}

valid_port() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 5 ] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_domain() {
    case "$1" in ''|*[!A-Za-z0-9.-]*) return 1 ;; esac
    [ "${#1}" -le 253 ] && printf '%s\n' "$1" | LC_ALL=C grep -Eq '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
}

valid_ipv4() {
    case "$1" in ''|*[!0-9.]*) return 1 ;; esac
    [ "${#1}" -le 15 ] || return 1
    printf '%s\n' "$1" | awk -F. 'NF != 4 { exit 1 } { for (i=1; i<=4; i++) if ($i !~ /^[0-9]+$/ || length($i)>3 || $i+0>255) exit 1 }'
}

get_public_ipv4() {
    for IP_ENDPOINT in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        if IP_RESULT=$(curl -fsS4 --connect-timeout 3 --max-time 8 "$IP_ENDPOINT"); then
            IP_RESULT=$(printf '%s' "$IP_RESULT" | tr -d '\r\n')
            if valid_ipv4 "$IP_RESULT"; then
                case "$IP_RESULT" in 0.*|127.*) continue ;; esac
                printf '%s' "$IP_RESULT"
                return 0
            fi
        fi
    done
    return 1
}

install_dependencies() {
    STAGE="安装依赖"
    apk update || die '更新 APK 索引失败，请检查网络、DNS 和 /etc/apk/repositories。'
    if [ "$1" = node ]; then
        apk add --no-cache curl tar openssl jq ca-certificates || die '核心依赖安装失败。'
        if ! command -v qrencode >/dev/null 2>&1; then
            if ! apk add --no-cache libqrencode-tools; then
                warn '二维码组件安装失败；继续安装并输出节点链接。'
            fi
        fi
    elif [ "$1" = realm ]; then
        apk add --no-cache curl tar ca-certificates || die '转发依赖安装失败。'
    else
        apk add --no-cache curl jq ca-certificates || die 'DDNS 依赖安装失败。'
    fi
}

show_qr() {
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t UTF8 "$1" || warn '二维码输出失败，请复制节点链接。'
    fi
}

require_option_value() {
    [ "$#" -ge 2 ] || die "选项 $1 缺少参数。"
    case "$2" in ''|-*) die "选项 $1 缺少有效参数。" ;; esac
}

# ==================== 帮助说明 ====================
show_help() {
    echo "=================================================================="
    echo "LDNAT - Alpine 落地与中转全能工具箱 (Sing-box + Realm + DDNS)"
    echo "------------------------------------------------------------------"
    echo "【落地节点与全协议服务 (REALITY/SS/AnyTLS/Hy2/TUIC/Trojan)】:"
    echo "  ldnat node                          # 交互式管理面板 (增删查改多协议/多端口)"
    echo "  ldnat node list                     # 列出当前所有节点服务与运行状态"
    echo "  ldnat node add                      # 交互式添加新节点协议与端口"
    echo "  ldnat node del <端口/序号>          # 删除指定节点服务"
    echo "  ldnat node links                    # 导出节点链接与二维码 (支持 A+B 模式)"
    echo "  ldnat -r <端口> -s <端口>           # 快速配置 REALITY + SS 双节点 (兼容旧命令)"
    echo ""
    echo "【Realm 高性能多端口转发 (中转机专用)】:"
    echo "  ldnat realm                         # 交互式管理面板 (添加/删除/查看多端口)"
    echo "  ldnat realm list                    # 列出当前所有端口转发规则"
    echo "  ldnat realm add <本地端口> <目标:端口># 添加一条新的端口转发"
    echo "  ldnat realm del <本地端口/序号>     # 删除指定转发规则"
    echo "  ldnat realm <本地端口> <目标:端口>   # 快速添加端口转发"
    echo "  示例: ldnat realm add 10086 1.2.3.4:20086"
    echo ""
    echo "【单独部署/更新 DDNS】:"
    echo "  ldnat ddns                          # 交互式配置 DDNS"
    echo "  ldnat ddns <域名> <ZoneID> <Token>  # 传参快速配置 DDNS"
    echo ""
    echo "【系统 TCP 与 BBR 深度网络调优】:"
    echo "  ldnat bbr                           # 交互式选择带宽规格调优"
    echo "  ldnat bbr <带宽Mbps>                # 极速命令行调优 (如 ldnat bbr 100 或 ldnat bbr 2000)"
    echo "  支持规格: 10M, 20M, 30M, 50M, 100M, 200M, 300M, 400M, 500M, 1000M, 2000M, 2500M, 5000M"
    echo ""
    echo "【安全审计与防滥用护盾 (防BT/PT/邮件SPAM/矿池/内网渗透)】:"
    echo "  ldnat shield                        # 交互式切换安全护盾 (当前开启/关闭)"
    echo "  ldnat shield on                     # 命令行强制开启安全审计护盾"
    echo "  ldnat shield off                    # 命令行临时关闭安全审计护盾"
    echo ""
    echo "【诊断与查看】:"
    echo "  ldnat diag                          # 一键自检服务、端口与伪装目标"
    echo "  ldnat info                          # 查看已安装节点、转发规则与二维码"
    echo ""
    echo "【轻舟端侧协同与探针 (SubSkiff Agent)】:"
    echo "  ldnat subskiff <URL> <Token>        # 一键静默绑定轻舟服务端、部署探针并开启上报"
    echo "  ldnat agent                         # 轻舟探针综合管理菜单 (绑定/部署/Crontab/日志)"
    echo "  ldnat sync                          # 立即同步本地最新节点链接至轻舟服务端"
    echo ""
    echo "【控制台交互菜单】:"
    echo "  直接输入 ldnat"
    echo "=================================================================="
}

# ==================== 模块 1: 部署 512MB Swap ====================
setup_swap() {
    STAGE="检查 Swap"
    SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
    if [ -z "$SWAP_TOTAL" ] || [ "$SWAP_TOTAL" -eq 0 ]; then
        if [ -e /swapfile ] || [ -L /swapfile ]; then
            warn '/swapfile 已存在但未启用，为保护原文件跳过创建。'
            return 0
        fi
        echo ">>> [1/4] 未检测到 Swap，正在为小鸡创建 512MB Swap..."
        if ! (set -C; dd if=/dev/zero bs=1M count=512 > /swapfile); then
            warn 'Swap 文件创建失败，继续安装；请检查磁盘空间。'
            return 0
        fi
        chmod 600 /swapfile
        if ! mkswap /swapfile || ! swapon /swapfile; then
            warn 'Swap 未能启用（容器可能没有此权限），继续安装。'
            return 0
        fi
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        rc-update add swap boot || warn 'Swap 未加入开机启动，请检查 OpenRC。'
        echo ">>> Swap 创建成功！"
    else
        echo ">>> [1/4] Swap 已存在 (${SWAP_TOTAL}MB)，跳过。"
    fi
}

# ==================== 智能测试并选择伪装域名 ====================
probe_sni() {
    curl -s -o /dev/null -w "%{http_code}" -m 2 "https://$1" 2>/dev/null || echo "000"
}

select_sni_target() {
    if [ "$SNI_SPECIFIED" = "true" ] && [ -n "$SNI" ]; then
        return 0
    fi
    echo ""
    echo "----------------------------------------------------------"
    echo "🔎 正在自测本 VPS 出口对常见伪装域名的握手连通性..."
    
    STAT_GOOGLE=$(probe_sni "dl.google.com")
    STAT_MS=$(probe_sni "www.microsoft.com")
    STAT_APPLE=$(probe_sni "gateway.icloud.com")

    TAG_GOOGLE="[不可用/超时]"
    TAG_MS="[不可用/超时]"
    TAG_APPLE="[不可用/超时]"

    DEFAULT_OPT="1"
    if [ "$STAT_GOOGLE" != "000" ]; then TAG_GOOGLE="[秒连推荐/TLS 1.3]"; fi
    if [ "$STAT_MS" != "000" ]; then TAG_MS="[可用/TLS 1.3]"; fi
    if [ "$STAT_APPLE" != "000" ]; then TAG_APPLE="[可用/苹果生态]"; fi

    if [ "$STAT_GOOGLE" != "000" ]; then
        DEFAULT_OPT="1"
    elif [ "$STAT_MS" != "000" ]; then
        DEFAULT_OPT="2"
    elif [ "$STAT_APPLE" != "000" ]; then
        DEFAULT_OPT="3"
    fi

    echo "👉 请选择 VLESS-REALITY 伪装目标证书 (SNI):"
    echo "  1. 谷歌全球分发 (dl.google.com)   $TAG_GOOGLE"
    echo "  2. 微软官方     (www.microsoft.com) $TAG_MS"
    echo "  3. 苹果网关     (gateway.icloud.com)$TAG_APPLE"
    echo "  4. 自定义输入其他域名"
    echo "----------------------------------------------------------"
    printf "请输入选项 [1-4，直接回车默认 %s]: " "$DEFAULT_OPT"
    read_input SNI_CHOICE
    if [ -z "$SNI_CHOICE" ]; then SNI_CHOICE="$DEFAULT_OPT"; fi

    case "$SNI_CHOICE" in
        1) SNI="dl.google.com" ;;
        2) SNI="www.microsoft.com" ;;
        3) SNI="gateway.icloud.com" ;;
        4)
            CUSTOM_SNI=""
            while [ -z "$CUSTOM_SNI" ]; do
                printf "   请输入自定义伪装域名 (确保支持TLS 1.3且当前VPS可连): "
                read_input CUSTOM_SNI
            done
            SNI="$CUSTOM_SNI"
            ;;
        *) SNI="dl.google.com" ;;
    esac
    valid_domain "$SNI" || die 'SNI 必须是合法域名，不能包含协议、端口或路径。'
    echo ">>> 已选用伪装目标: ${SNI}"
}

# ==================== 模块 2: 独立部署 Cloudflare DDNS ====================
install_ddns_module() {
    DOMAIN="$1"
    ZONE_ID="$2"
    TOKEN="$3"

    echo ""
    echo "=========================================================="
    echo "        🌐 LDNAT - 部署 Cloudflare DDNS 动态域名服务      "
    echo "=========================================================="
    echo "⚠️ 警示：若你的小鸡属于跨境穿透 NAT（如新加坡入、泰国出），"
    echo "   出口 IP 与入站连接 IP 不一致，请勿开启此服务，否则会导致"
    echo "   域名被解析到无端口映射的出口 IP 上导致断连！"
    echo "----------------------------------------------------------"

    if [ -z "$DOMAIN" ]; then
        while [ -z "$DOMAIN" ]; do
            printf "👉 请输入要同步更新的完整域名 (例如 node1.yourdomain.com): "
            read_input DOMAIN
        done
    fi

    if [ -z "$ZONE_ID" ]; then
        while [ -z "$ZONE_ID" ]; do
            printf "👉 请输入 Cloudflare 【Zone ID (区域ID)】: "
            read_input ZONE_ID
        done
    fi

    if [ -z "$TOKEN" ]; then
        while [ -z "$TOKEN" ]; do
            printf "👉 请输入 Cloudflare 【API Token (API令牌)】: "
            if [ -t 0 ] && stty -echo 2>/dev/null; then TOKEN_ECHO_DISABLED=true; fi
            read_input TOKEN
            if [ "$TOKEN_ECHO_DISABLED" = true ]; then stty echo; TOKEN_ECHO_DISABLED=false; printf '\n'; fi
        done
    fi

    valid_domain "$DOMAIN" || die 'DDNS 域名不合法，不能包含协议、端口或路径。'
    case "$ZONE_ID" in *[!A-Fa-f0-9]*) die 'Zone ID 必须是 32 位十六进制字符串。' ;; esac
    [ "${#ZONE_ID}" -eq 32 ] || die 'Zone ID 必须是 32 位十六进制字符串。'
    case "$TOKEN" in ''|*[!A-Za-z0-9_-]*) die 'API Token 格式不合法。' ;; esac
    [ "${#TOKEN}" -le 512 ] || die 'API Token 长度不合法。'
    require_environment
    command -v crontab >/dev/null 2>&1 || die '未找到 crontab，无法设置 DDNS 定时任务。'
    install_dependencies ddns
    register_command
    STAGE="配置 DDNS"
    [ ! -L /root/ddns ] || die '/root/ddns 不能是符号链接。'
    mkdir -p /root/ddns
    chmod 700 /root/ddns
    DDNS_BACKUP=$(make_backup)
    backup_file "$DDNS_SCRIPT" "$DDNS_BACKUP/cf-ddns.sh"
    backup_file "$DDNS_CONFIG" "$DDNS_BACKUP/config.json"
    backup_file /root/ddns/last_ip.txt "$DDNS_BACKUP/last_ip.txt"
    if ! crontab -l > "$DDNS_BACKUP/crontab" 2>/dev/null; then : > "$DDNS_BACKUP/crontab"; fi
    if [ -e /etc/runlevels/default/crond ]; then CRON_WAS_ENABLED=true; fi

    cat > "$WORK_DIR/ddns-config.json" << DDNS_CONFIG_EOF
{"zone_id":"${ZONE_ID}","domain":"${DOMAIN}","api_token":"${TOKEN}"}
DDNS_CONFIG_EOF
    cat << 'DDNS_EOF' > "$WORK_DIR/cf-ddns.sh"
#!/bin/sh
set -eu
umask 077

LDNAT_VERSION="v0.3.0"
CONFIG_FILE="/root/ddns/config.json"
LOG_FILE="/root/ddns/ddns.log"
CACHE_FILE="/root/ddns/last_ip.txt"
WORK_DIR=""
if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 262144 ]; then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
fi
log() { printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
fail() { log "$*"; printf '❌ DDNS：%s\n' "$*" >&2; exit 1; }
cleanup() {
    RESULT=$?
    trap - 0 HUP INT TERM
    case "$WORK_DIR" in /tmp/ldnat-ddns.*) rm -rf "$WORK_DIR" ;; esac
    if [ "$RESULT" -ne 0 ]; then log "本次同步失败（退出码 $RESULT），请检查网络、API 权限及配置。"; fi
    exit "$RESULT"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
WORK_DIR=$(mktemp -d /tmp/ldnat-ddns.XXXXXX)
ZONE_ID=$(jq -er '.zone_id | strings | select(length > 0)' "$CONFIG_FILE")
DOMAIN=$(jq -er '.domain | strings | select(length > 0)' "$CONFIG_FILE")
API_TOKEN=$(jq -er '.api_token | strings | select(length > 0)' "$CONFIG_FILE")
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$API_TOKEN" > "$WORK_DIR/curl.conf"

CURRENT_IP=""
for ENDPOINT in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    if IP=$(curl -fsS4 --connect-timeout 3 --max-time 8 "$ENDPOINT"); then
        IP=$(printf '%s' "$IP" | tr -d '\r\n')
        if printf '%s\n' "$IP" | awk -F. 'NF != 4 { exit 1 } { for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || length($i)>3 || $i+0>255) exit 1 }'; then
            case "$IP" in 0.*|127.*) continue ;; esac
            CURRENT_IP="$IP"
            break
        fi
    fi
done
[ -n "$CURRENT_IP" ] || fail '无法获取合法公网 IPv4，未更新 DNS。'
CACHE_KEY="$ZONE_ID $DOMAIN $CURRENT_IP"
if [ "${1:-}" != --force ] && [ -f "$CACHE_FILE" ] && [ "$CACHE_KEY" = "$(cat "$CACHE_FILE")" ]; then exit 0; fi

cf_request() {
    REQUEST_METHOD="$1"
    REQUEST_URL="$2"
    shift 2
    if ! HTTP_STATUS=$(curl -sS --connect-timeout 5 --max-time 30 --config "$WORK_DIR/curl.conf" \
        --request "$REQUEST_METHOD" --output "$WORK_DIR/response.json" --write-out '%{http_code}' "$REQUEST_URL" "$@"); then
        fail 'Cloudflare 网络请求失败。'
    fi
    case "$HTTP_STATUS" in 2??) ;; *) fail "Cloudflare 请求失败（HTTP $HTTP_STATUS），请检查 Token、Zone ID 和 DNS 编辑权限。" ;; esac
    jq -e '.success == true' "$WORK_DIR/response.json" >/dev/null || fail 'Cloudflare 返回失败或非预期 JSON，未更新缓存。'
}

API_URL="https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records"
cf_request GET "$API_URL?name=$DOMAIN&type=A"
jq -e '.result | type == "array"' "$WORK_DIR/response.json" >/dev/null || fail 'DNS 记录列表格式不正确。'
RECORD_COUNT=$(jq '.result | length' "$WORK_DIR/response.json")
[ "$RECORD_COUNT" -le 1 ] || fail '同名 A 记录不止一条，为避免误改已停止同步。'
jq -n --arg domain "$DOMAIN" --arg ip "$CURRENT_IP" \
    '{type:"A",name:$domain,content:$ip,ttl:120,proxied:false}' > "$WORK_DIR/payload.json"
if [ "$RECORD_COUNT" -eq 0 ]; then
    cf_request POST "$API_URL" --data-binary "@$WORK_DIR/payload.json"
else
    RECORD_ID=$(jq -er '.result[0].id | strings | select(length > 0)' "$WORK_DIR/response.json")
    printf '%s\n' "$RECORD_ID" | grep -Eq '^[A-Fa-f0-9]{32}$' || fail 'DNS 记录 ID 格式不正确。'
    cf_request PATCH "$API_URL/$RECORD_ID" --data-binary "@$WORK_DIR/payload.json"
fi
printf '%s\n' "$CACHE_KEY" > "$WORK_DIR/last_ip.txt"
mv -f "$WORK_DIR/last_ip.txt" "$CACHE_FILE"
log "同步成功: $DOMAIN -> $CURRENT_IP"
DDNS_EOF
    sh -n "$WORK_DIR/cf-ddns.sh"
    DDNS_PENDING=true
    atomic_install "$WORK_DIR/ddns-config.json" "$DDNS_CONFIG" 600
    atomic_install "$WORK_DIR/cf-ddns.sh" "$DDNS_SCRIPT" 700
    echo ">>> 正在执行初次测试更新..."
    sh "$DDNS_SCRIPT" --force || die "DDNS 初次同步失败，请查看 $DDNS_LOG。"
    awk 'index($0, "/root/ddns/cf-ddns.sh") == 0 || $0 ~ /^[[:space:]]*#/' "$DDNS_BACKUP/crontab" > "$WORK_DIR/crontab"
    printf '*/5 * * * * /root/ddns/cf-ddns.sh > /dev/null 2>&1\n' >> "$WORK_DIR/crontab"
    crontab "$WORK_DIR/crontab"
    rc-update add crond default
    if ! rc-service crond status >/dev/null 2>&1; then rc-service crond start; fi
    rc-service crond status
    DDNS_PENDING=false
    echo ""
    echo "=========================================================="
    echo "🎉 Cloudflare DDNS 部署成功！"
    echo "   - 目标域名 : ${DOMAIN}"
    echo "   - 执行频率 : 每 5 分钟自动检测同步"
    echo "   - 日志文件 : cat ${DDNS_LOG}"
    echo "   - 原配置备份 : ${DDNS_BACKUP}"
    if [ -f "$DDNS_LOG" ]; then
        echo "   - 最新执行状态:"
        tail -n 2 "$DDNS_LOG"
    fi
    echo "=========================================================="
}

# ==================== 模块 3: Realm 高性能多端口转发管理 ====================

init_realm_rules() {
    mkdir -p /etc/realm
    if [ ! -f "$REALM_RULES" ] && [ -f "$REALM_CONFIG" ]; then
        touch "$REALM_RULES"
        LPORT=""
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                *listen*=*\"*:*\"*)
                    LPORT=$(printf '%s\n' "$line" | sed 's/.*:[[:space:]]*//; s/[^0-9]//g')
                    ;;
                *remote*=*\"*\"*)
                    RADDR=$(printf '%s\n' "$line" | sed 's/.*remote[[:space:]]*=[[:space:]]*"//; s/".*//')
                    if [ -n "$LPORT" ] && [ -n "$RADDR" ]; then
                        printf '%s %s\n' "$LPORT" "$RADDR" >> "$REALM_RULES"
                        LPORT=""
                        RADDR=""
                    fi
                    ;;
            esac
        done < "$REALM_CONFIG"
    fi
    [ -f "$REALM_RULES" ] || touch "$REALM_RULES"
}

ensure_realm_installed() {
    require_environment
    install_dependencies realm
    register_command

    if [ ! -f "$REALM_BIN" ]; then
        STAGE="下载官方 Realm 核心"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  REALM_ARCH="x86_64-unknown-linux-musl" ;;
            aarch64) REALM_ARCH="aarch64-unknown-linux-musl" ;;
            *) die "❌ 不支持的架构: $ARCH" ;;
        esac

        echo ">>> 正在下载官方 Realm 核心 ($REALM_ARCH)..."
        curl -fSsL --connect-timeout 10 --max-time 60 --retry 2 \
            "https://github.com/zhboner/realm/releases/latest/download/realm-${REALM_ARCH}.tar.gz" -o "$WORK_DIR/realm.tar.gz" || die '下载 Realm 失败，请检查网络。'
        tar -xzf "$WORK_DIR/realm.tar.gz" -C "$WORK_DIR"
        chmod 755 "$WORK_DIR/realm"
        cp -f "$WORK_DIR/realm" "$REALM_BIN"
    fi

    if [ ! -f /etc/init.d/realm ]; then
        cat << 'SVC' > /etc/init.d/realm
#!/sbin/openrc-run
name="realm"
description="Realm Port Forward Service"
command="/usr/local/bin/realm"
command_args="-c /etc/realm/config.toml"
command_background=true
pidfile="/run/realm.pid"
depend() {
    need net
    after firewall
}
SVC
        chmod 755 /etc/init.d/realm
        rc-update add realm default >/dev/null 2>&1 || true
    fi
}

sync_realm_config() {
    init_realm_rules
    mkdir -p /etc/realm
    TMP_CONF=$(mktemp /etc/realm/config.tmp.XXXXXX)
    cat << 'EOF' > "$TMP_CONF"
[network]
no_tcp = false
use_udp = true
EOF

    RULE_COUNT=0
    while IFS=' ' read -r L_P R_A || [ -n "$L_P" ]; do
        [ -n "$L_P" ] && [ -n "$R_A" ] || continue
        case "$L_P" in '#'*|'') continue ;; esac
        RULE_COUNT=$((RULE_COUNT + 1))
        cat << EOF >> "$TMP_CONF"

[[endpoints]]
listen = "0.0.0.0:${L_P}"
remote = "${R_A}"
EOF
    done < "$REALM_RULES"

    mv -f "$TMP_CONF" "$REALM_CONFIG"

    if [ "$RULE_COUNT" -gt 0 ]; then
        rc-service realm restart >/dev/null 2>&1 || rc-service realm start >/dev/null 2>&1 || true
    else
        rc-service realm stop >/dev/null 2>&1 || true
    fi
}

list_realm_rules() {
    init_realm_rules
    echo "=========================================================="
    echo "            ⚡ Realm 当前转发规则列表                     "
    echo "=========================================================="
    if [ ! -s "$REALM_RULES" ]; then
        echo "   (当前暂无任何转发规则，可输入 1 添加新规则)"
        echo "=========================================================="
        return 0
    fi

    printf " %-5s  %-12s  %-28s  %s\n" "序号" "本地监听端口" "转发目标地址" "运行状态"
    echo " ---------------------------------------------------------"
    INDEX=0
    while IFS=' ' read -r L_P R_A || [ -n "$L_P" ]; do
        [ -n "$L_P" ] && [ -n "$R_A" ] || continue
        case "$L_P" in '#'*|'') continue ;; esac
        INDEX=$((INDEX + 1))
        STATUS="⚪ 未监听"
        if netstat -tlpn 2>/dev/null | grep -Eq ":${L_P}[[:space:]]+"; then
            STATUS="🟢 监听中"
        fi
        printf " [%2d]   %-12s  --> %-24s %s\n" "$INDEX" "$L_P" "$R_A" "$STATUS"
    done < "$REALM_RULES"
    echo "=========================================================="
}

add_realm_rule() {
    LOCAL_PORT="${1:-}"
    REMOTE_ADDR="${2:-}"

    if [ -z "$LOCAL_PORT" ]; then
        while true; do
            printf "👉 请输入中转机【本地监听端口】(例如 10086): "
            read_input LOCAL_PORT
            if valid_port "$LOCAL_PORT"; then break; fi
            echo "❌ 端口不合法，请输入 1-65535 之间的纯数字！"
        done
    fi
    valid_port "$LOCAL_PORT" || die '本地监听端口必须是 1-65535 的数字！'

    if [ -z "$REMOTE_ADDR" ]; then
        while true; do
            printf "👉 请输入目标落地地址与端口 (例如 1.2.3.4:20086 或 hk.example.com:20086): "
            read_input REMOTE_ADDR
            case "$REMOTE_ADDR" in
                *:*) break ;;
                *) echo "❌ 格式不正确！必须包含 IP/域名和端口，例如 1.2.3.4:20086" ;;
            esac
        done
    fi
    case "$REMOTE_ADDR" in
        *:*) ;;
        *) die '目标地址格式不正确，必须为 <IP或域名:端口>！' ;;
    esac

    ensure_realm_installed
    init_realm_rules

    # 检查是否已存在同本地端口的规则
    EXISTING_REMOTE=$(awk -v p="$LOCAL_PORT" '$1 == p { print $2 }' "$REALM_RULES" 2>/dev/null || true)
    if [ -n "$EXISTING_REMOTE" ]; then
        echo "⚠️ 本地端口 ${LOCAL_PORT} 已存在转发规则 (当前指向: ${EXISTING_REMOTE})！"
        printf "是否覆盖并更新为 ${REMOTE_ADDR}？[y/N]: "
        read_input OVERWRITE_ANS
        case "$OVERWRITE_ANS" in
            y*|Y*)
                TMP_RULES=$(mktemp /etc/realm/rules.tmp.XXXXXX)
                awk -v p="$LOCAL_PORT" -v r="$REMOTE_ADDR" '{ if ($1 == p) print p, r; else print $0 }' "$REALM_RULES" > "$TMP_RULES"
                mv -f "$TMP_RULES" "$REALM_RULES"
                ;;
            *)
                echo "操作已取消。"
                return 0
                ;;
        esac
    else
        printf '%s %s\n' "$LOCAL_PORT" "$REMOTE_ADDR" >> "$REALM_RULES"
    fi

    sync_realm_config

    echo ""
    echo "=========================================================="
    echo "🎉 规则添加/更新成功！"
    echo "   - 本地监听端口 : ${LOCAL_PORT} (TCP + UDP)"
    echo "   - 目标落地地址 : ${REMOTE_ADDR}"
    echo "   - 服务运行状态 : $(rc-service realm status 2>/dev/null || echo 'running')"
    echo "=========================================================="
}

delete_realm_rule() {
    init_realm_rules
    if [ ! -s "$REALM_RULES" ]; then
        echo "ℹ️ 当前暂无可删除的转发规则。"
        return 0
    fi

    TARGET="${1:-}"
    if [ -z "$TARGET" ]; then
        list_realm_rules
        printf "👉 请输入要删除的规则【序号】或【本地端口】(输入 0 取消): "
        read_input TARGET
    fi
    [ "$TARGET" != "0" ] && [ -n "$TARGET" ] || { echo "已取消。"; return 0; }

    DEL_PORT=""
    TOTAL_RULES=$(grep -c -v '^[[:space:]]*$' "$REALM_RULES" || echo 0)
    if [ "$TARGET" -ge 1 ] 2>/dev/null && [ "$TARGET" -le "$TOTAL_RULES" ] 2>/dev/null; then
        DEL_PORT=$(sed -n "${TARGET}p" "$REALM_RULES" | awk '{print $1}')
    elif valid_port "$TARGET"; then
        DEL_PORT="$TARGET"
    fi

    if [ -z "$DEL_PORT" ]; then
        echo "❌ 未找到对应规则！"
        return 1
    fi

    TMP_RULES=$(mktemp /etc/realm/rules.tmp.XXXXXX)
    awk -v p="$DEL_PORT" '$1 != p' "$REALM_RULES" > "$TMP_RULES"
    mv -f "$TMP_RULES" "$REALM_RULES"

    sync_realm_config
    echo "🗑️ 本地端口 ${DEL_PORT} 的转发规则已成功删除并重载生效！"
}

manage_realm_menu() {
    ensure_realm_installed
    while true; do
        clear 2>/dev/null || true
        echo "=========================================================="
        echo "     ⚡ LDNAT - Realm 高性能多端口转发管理面板            "
        echo "=========================================================="
        list_realm_rules
        echo ""
        echo "  1. 添加新的转发规则 (支持多个端口)"
        echo "  2. 删除已有转发规则"
        echo "  3. 重启 Realm 转发服务"
        echo "  4. 停止 Realm 转发服务"
        echo "  0. 返回上级主菜单 (支持按 q)"
        echo "=========================================================="
        printf "请输入选项 [0-4 或 q]: "
        read_input R_CHOICE
        case "$R_CHOICE" in
            1)
                add_realm_rule "" ""
                printf "\n按回车键继续..."
                read_input DUMMY
                ;;
            2)
                delete_realm_rule ""
                printf "\n按回车键继续..."
                read_input DUMMY
                ;;
            3)
                rc-service realm restart && echo "✅ 服务已重启。"
                printf "\n按回车键继续..."
                read_input DUMMY
                ;;
            4)
                rc-service realm stop && echo "⏹️ 服务已停止。"
                printf "\n按回车键继续..."
                read_input DUMMY
                ;;
            0|q|Q)
                break
                ;;
            *)
                echo "⚠️ 输入无效，请重新选择。"
                sleep 1
                ;;
        esac
    done
}

install_realm_module() {
    if [ -z "${1:-}" ] && [ -z "${2:-}" ]; then
        manage_realm_menu
    else
        add_realm_rule "${1:-}" "${2:-}"
    fi
}

# ==================== 模块 4: 节点多端口与全协议管理系统 ====================
# 支持 6 大协议: VLESS-REALITY, Shadowsocks, Hysteria 2, TUIC v5, Trojan, AnyTLS
# 具备端口不限增删查改、凭据持久化、自动生成 ECC 自签证书、A+B 链接与二维码展示

ensure_singbox_binary() {
    TARGET_SING_VER="1.14.3"
    if [ -x /usr/local/bin/sing-box ]; then
        CUR_VER=$(/usr/local/bin/sing-box version 2>/dev/null | head -n1 | awk '{print $3}')
        if [ "$CUR_VER" = "$TARGET_SING_VER" ]; then
            return 0
        fi
        echo ">>> 检测到已安装 Sing-box 版本为 [${CUR_VER:-未知}]，正在升级至官方 ${TARGET_SING_VER}..."
    fi
    echo ">>> [1/2] 安装核心系统依赖..."
    install_dependencies node
    register_command

    echo ">>> [2/2] 拉取并校验官方 Musl 版 Sing-box (${TARGET_SING_VER})..."
    STAGE="下载和校验 Sing-box"
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  SING_ARCH="amd64" ;;
        aarch64) SING_ARCH="arm64" ;;
        *) die "不支持的架构: $ARCH" ;;
    esac

    WORK_BIN_DIR=$(mktemp -d /tmp/ldnat.bin.XXXXXX)
    curl -fSsL --proto '=https' --connect-timeout 10 --max-time 45 --retry 2 \
        "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${TARGET_SING_VER}" -o "$WORK_BIN_DIR/release.json" || die "获取官方版本 v${TARGET_SING_VER} 失败。"
    SING_VER="$TARGET_SING_VER"
    ASSET_BASE="sing-box-${SING_VER}-linux-${SING_ARCH}-musl"
    ASSET_NAME="${ASSET_BASE}.tar.gz"
    ASSET_DIGEST=$(jq -er --arg name "$ASSET_NAME" '.assets[] | select(.name == $name) | .digest | strings' "$WORK_BIN_DIR/release.json")
    printf '%s\n' "$ASSET_DIGEST" | grep -Eq '^sha256:[a-fA-F0-9]{64}$' || die '官方发布未提供有效 SHA-256 摘要，停止安装。'
    curl -fSsL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 180 --retry 2 \
        "https://github.com/SagerNet/sing-box/releases/download/v${SING_VER}/${ASSET_NAME}" -o "$WORK_BIN_DIR/sing-box.tar.gz"
    printf '%s  %s\n' "${ASSET_DIGEST#sha256:}" "$WORK_BIN_DIR/sing-box.tar.gz" | sha256sum -c - || die '核心文件 SHA-256 校验失败。'
    tar --no-same-owner -xzf "$WORK_BIN_DIR/sing-box.tar.gz" -C "$WORK_BIN_DIR" "${ASSET_BASE}/sing-box"
    NEW_BIN="$WORK_BIN_DIR/${ASSET_BASE}/sing-box"
    [ -f "$NEW_BIN" ] && [ ! -L "$NEW_BIN" ] || die '压缩包内没有有效核心文件。'
    chmod 755 "$NEW_BIN"
    mkdir -p /usr/local/bin
    mv -f "$NEW_BIN" /usr/local/bin/sing-box
    rm -rf "$WORK_BIN_DIR"
    echo ">>> Sing-box 官方核心安装/升级成功: $(/usr/local/bin/sing-box version | head -n1)"
}

ensure_singbox_service() {
    if [ ! -f /etc/init.d/sing-box ]; then
        cat << 'SVC' > /etc/init.d/sing-box
#!/sbin/openrc-run
name="sing-box"
description="Sing-box Proxy Service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/run/sing-box.pid"
depend() {
    need net
    after firewall
}
SVC
        chmod 755 /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1 || true
    fi
}

ensure_self_signed_cert() {
    mkdir -p "$CERT_DIR"
    chmod 700 "$CERT_DIR"
    if [ -f "$CERT_PEM" ] && [ -f "$KEY_PEM" ]; then
        return 0
    fi
    echo ">>> 正在为 TLS 协议 (Hy2/TUIC/Trojan/AnyTLS) 生成自签名证书 (P-256 ECC, 10年有效)..."
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -nodes -keyout "$KEY_PEM" -out "$CERT_PEM" -days 3650 \
        -subj "/CN=www.bing.com" >/dev/null 2>&1 || die '生成自签名证书失败，请检查 openssl。'
    chmod 600 "$KEY_PEM"
    chmod 644 "$CERT_PEM"
}

is_abuse_block_enabled() {
    if [ ! -f "$ABUSE_CONF" ]; then
        return 0 # 默认开启
    fi
    S_VAL=$(cat "$ABUSE_CONF" 2>/dev/null | tr -d '\r\n[:space:]')
    case "$S_VAL" in
        0|false|off|disabled) return 1 ;;
        *) return 0 ;;
    esac
}

toggle_abuse_block() {
    mkdir -p /etc/sing-box
    if is_abuse_block_enabled; then
        printf 'off\n' > "$ABUSE_CONF"
        echo "🛡️ 安全审计与防滥用护盾已【关闭】。"
    else
        printf 'on\n' > "$ABUSE_CONF"
        echo "🛡️ 安全审计与防滥用护盾已【开启】(已全面阻断 BT/PT、邮件SPAM、矿池及恶意扫描)。"
    fi
    sync_singbox_config
}

get_or_detect_server_addr() {
    if [ -n "${NODE_DOMAIN:-}" ]; then
        printf '%s' "$NODE_DOMAIN"
        return 0
    fi
    if [ -f "$ADDR_CONF" ]; then
        SAVED_ADDR=$(cat "$ADDR_CONF" 2>/dev/null | tr -d '\r\n[:space:]')
        if [ -n "$SAVED_ADDR" ]; then
            printf '%s' "$SAVED_ADDR"
            return 0
        fi
    fi
    PUB_IP=$(get_public_ipv4 2>/dev/null || echo "")
    if [ -n "$PUB_IP" ]; then
        printf '%s' "$PUB_IP"
        return 0
    fi
    printf '%s' "1.2.3.4"
}

set_server_addr() {
    CURR=$(get_or_detect_server_addr)
    echo "当前节点连接地址: $CURR"
    printf "👉 请输入新的节点域名或公网IP (回车保持不变): "
    read_input NEW_ADDR
    if [ -n "$NEW_ADDR" ]; then
        valid_domain "$NEW_ADDR" || valid_ipv4 "$NEW_ADDR" || die '输入格式不正确，必须为合法域名或IPv4！'
        mkdir -p /etc/sing-box
        printf '%s\n' "$NEW_ADDR" > "$ADDR_CONF"
        echo "✅ 节点连接地址已更新为: $NEW_ADDR"
        update_node_info_summary
    fi
}

build_node_url() {
    B_PORT="${1:-}"
    B_TYPE="${2:-}"
    B_NAME="${3:-}"
    B_P1="${4:-}"
    B_P2="${5:-}"
    B_P3="${6:-}"
    B_P4="${7:-}"
    B_P5="${8:-}"
    B_ADDR="${9:-}"

    TAG="${B_NAME:-${B_ADDR}_${B_TYPE}_${B_PORT}}"

    case "$B_TYPE" in
        reality)
            # B_P1: UUID, B_P2: PRIV, B_P3: PUB, B_P4: SID, B_P5: SNI
            printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
                "$B_P1" "$B_ADDR" "$B_PORT" "$B_P5" "$B_P3" "$B_P4" "$TAG"
            ;;
        ss)
            # B_P1: METHOD, B_P2: PASS
            B_SS_B64=$(printf '%s' "${B_P1}:${B_P2}" | base64 | tr -d '\r\n')
            printf 'ss://%s@%s:%s#%s' "$B_SS_B64" "$B_ADDR" "$B_PORT" "$TAG"
            ;;
        hy2)
            # B_P1: PASS
            printf 'hysteria2://%s@%s:%s/?insecure=1&sni=www.bing.com#%s' "$B_P1" "$B_ADDR" "$B_PORT" "$TAG"
            ;;
        tuic)
            # B_P1: UUID, B_P2: PASS
            printf 'tuic://%s:%s@%s:%s/?congestion_control=bbr&alpn=h3&allow_insecure=1#%s' "$B_P1" "$B_P2" "$B_ADDR" "$B_PORT" "$TAG"
            ;;
        trojan)
            # B_P1: PASS
            printf 'trojan://%s@%s:%s?security=tls&allowInsecure=1&sni=www.bing.com#%s' "$B_P1" "$B_ADDR" "$B_PORT" "$TAG"
            ;;
        anytls)
            # B_P1: PASS
            printf 'anytls://%s@%s:%s/?allow_insecure=1#%s' "$B_P1" "$B_ADDR" "$B_PORT" "$TAG"
            ;;
    esac
}

render_single_node_detail() {
    R_INDEX="${1:-}"
    R_PORT="${2:-}"
    R_TYPE="${3:-}"
    R_NAME="${4:-}"
    R_P1="${5:-}"
    R_P2="${6:-}"
    R_P3="${7:-}"
    R_P4="${8:-}"
    R_P5="${9:-}"
    R_ADDR="${10:-}"
    R_SHOW_QR="${11:-true}"

    echo "------------------------------------------------------------------"
    case "$R_TYPE" in
        reality)
            echo "【序号 $R_INDEX】VLESS-REALITY (TCP+Vision 强抗封/直连)"
            echo "  节点名称: $R_NAME"
            echo "  监听端口: $R_PORT"
            echo "  连接地址: $R_ADDR"
            echo "  伪装域名: $R_P5 (SNI)"
            echo "  UUID:     $R_P1"
            echo "  公钥:     $R_P3"
            echo "  ShortID:  $R_P4"
            ;;
        ss)
            echo "【序号 $R_INDEX】Shadowsocks (极简中转落地)"
            echo "  节点名称: $R_NAME"
            echo "  监听端口: $R_PORT"
            echo "  连接地址: $R_ADDR"
            echo "  加密算法: $R_P1"
            echo "  节点密码: $R_P2"
            ;;
        hy2)
            echo "【序号 $R_INDEX】Hysteria 2 (UDP/QUIC 弱网救星)"
            echo "  节点名称: $R_NAME"
            echo "  监听端口: $R_PORT (UDP)"
            echo "  连接地址: $R_ADDR"
            echo "  节点密码: $R_P1"
            echo "  证书模式: 自签 ECC P-256 (客户端请开启跳过证书校验/insecure=1)"
            ;;
        tuic)
            echo "【序号 $R_INDEX】TUIC v5 (UDP/QUIC 低延迟/BBR)"
            echo "  节点名称: $R_NAME"
            echo "  监听端口: $R_PORT (UDP)"
            echo "  连接地址: $R_ADDR"
            echo "  UUID:     $R_P1"
            echo "  节点密码: $R_P2"
            echo "  证书模式: 自签 ECC P-256 (客户端请开启跳过证书校验/allow_insecure=1)"
            ;;
        trojan)
            echo "【序号 $R_INDEX】Trojan (TLS 原生流)"
            echo "  节点名称: $R_NAME"
            echo "  监听端口: $R_PORT"
            echo "  连接地址: $R_ADDR"
            echo "  节点密码: $R_P1"
            echo "  证书模式: 自签 ECC P-256 (客户端请开启跳过证书校验/allowInsecure=1)"
            ;;
        anytls)
            echo "【序号 $R_INDEX】AnyTLS (Sing-box 原生 AnyTLS)"
            echo "  节点名称: $R_NAME"
            echo "  监听端口: $R_PORT"
            echo "  连接地址: $R_ADDR"
            echo "  节点密码: $R_P1"
            echo "  证书模式: 自签 ECC P-256 (客户端请开启跳过证书校验/allow_insecure=1)"
            ;;
    esac

    N_URL=$(build_node_url "$R_PORT" "$R_TYPE" "$R_NAME" "$R_P1" "$R_P2" "$R_P3" "$R_P4" "$R_P5" "$R_ADDR")
    echo ""
    echo "👉 客户端导入链接:"
    echo "$N_URL"

    if [ "$R_TYPE" = "anytls" ]; then
        echo ""
        echo "💡 Sing-box 客户端 Outbound 配置片段:"
        cat << JSON_SNIP
    {
      "type": "anytls",
      "tag": "${R_NAME}",
      "server": "${R_ADDR}",
      "server_port": ${R_PORT},
      "password": "${R_P1}",
      "tls": {
        "enabled": true,
        "insecure": true
      }
    }
JSON_SNIP
    fi

    if [ "$R_SHOW_QR" = "true" ]; then
        echo ""
        echo "📱 二维码预览:"
        show_qr "$N_URL"
    fi
}

list_node_rules() {
    echo "=========================================================="
    echo "          🌐 LDNAT 当前节点与全协议服务列表               "
    echo "=========================================================="
    if [ ! -f "$NODES_CONF" ] || [ ! -s "$NODES_CONF" ]; then
        echo "  暂未添加任何节点服务。"
        echo "=========================================================="
        return 0
    fi

    printf " %-5s  %-8s  %-12s %-22s %s\n" "序号" "端口" "协议类型" "节点备注名称" "状态"
    echo " ---------------------------------------------------------"
    INDEX=0
    while IFS='|' read -r N_PORT N_TYPE N_NAME N_P1 N_P2 N_P3 N_P4 N_P5 || [ -n "$N_PORT" ]; do
        [ -n "$N_PORT" ] || continue
        case "$N_PORT" in '#'*|'') continue ;; esac
        INDEX=$((INDEX + 1))
        STATUS="⚪ 未监听"
        case "$N_TYPE" in
            hy2|tuic)
                if netstat -ulpn 2>/dev/null | grep -Eq ":${N_PORT}[[:space:]]+"; then
                    STATUS="🟢 UDP运行中"
                fi
                ;;
            *)
                if netstat -tlpn 2>/dev/null | grep -Eq ":${N_PORT}[[:space:]]+"; then
                    STATUS="🟢 TCP运行中"
                fi
                ;;
        esac

        printf " [%2d]   %-8s  %-12s %-22s %s\n" "$INDEX" "$N_PORT" "$N_TYPE" "$N_NAME" "$STATUS"
    done < "$NODES_CONF"
    echo " ---------------------------------------------------------"
    if is_abuse_block_enabled; then
        echo " 🛡️ 安全审计护盾: 🟢 已开启 (防BT/PT、防邮件SPAM、防矿池、防内网渗透)"
    else
        echo " 🛡️ 安全审计护盾: ⚪ 已关闭 (注意：未阻断BT/PT及敏感端口)"
    fi
    echo "=========================================================="
}

show_node_links() {
    if [ ! -f "$NODES_CONF" ] || [ ! -s "$NODES_CONF" ]; then
        echo "ℹ️ 当前未配置任何节点！请先添加节点。"
        return 0
    fi
    S_ADDR=$(get_or_detect_server_addr)
    echo "=========================================================="
    echo "                 🔗 节点链接与二维码导出                  "
    echo "=========================================================="
    echo "当前连接地址: ${S_ADDR}"
    echo "  [A] 批量展示所有节点完整配置与二维码 (全部输出)"
    echo "  [B] 输入节点序号单独查看指定节点配置与二维码"
    echo "  [0] 返回上级菜单"
    echo "=========================================================="
    printf "👉 请输入选择 [A/B/0]: "
    read_input VIEW_MODE
    case "$VIEW_MODE" in
        a*|A*)
            echo ""
            echo "========== 批量导出全部节点链接与二维码 =========="
            INDEX=0
            while IFS='|' read -r N_PORT N_TYPE N_NAME N_P1 N_P2 N_P3 N_P4 N_P5 || [ -n "$N_PORT" ]; do
                [ -n "$N_PORT" ] || continue
                case "$N_PORT" in '#'*|'') continue ;; esac
                INDEX=$((INDEX + 1))
                render_single_node_detail "$INDEX" "$N_PORT" "$N_TYPE" "$N_NAME" "$N_P1" "$N_P2" "$N_P3" "$N_P4" "$N_P5" "$S_ADDR" true
            done < "$NODES_CONF"
            echo "=================================================="
            ;;
        b*|B*)
            list_node_rules
            TOTAL_NODES=$(grep -c -v '^[[:space:]]*#' "$NODES_CONF" 2>/dev/null || true)
            printf "👉 请输入要查看的节点序号 (1-%d): " "$TOTAL_NODES"
            read_input TARGET_INDEX
            case "$TARGET_INDEX" in ''|*[!0-9]*) echo "❌ 输入无效！"; return 0 ;; esac
            CURR=0
            FOUND=false
            while IFS='|' read -r N_PORT N_TYPE N_NAME N_P1 N_P2 N_P3 N_P4 N_P5 || [ -n "$N_PORT" ]; do
                [ -n "$N_PORT" ] || continue
                case "$N_PORT" in '#'*|'') continue ;; esac
                CURR=$((CURR + 1))
                if [ "$CURR" -eq "$TARGET_INDEX" ]; then
                    render_single_node_detail "$CURR" "$N_PORT" "$N_TYPE" "$N_NAME" "$N_P1" "$N_P2" "$N_P3" "$N_P4" "$N_P5" "$S_ADDR" true
                    FOUND=true
                    break
                fi
            done < "$NODES_CONF"
            if [ "$FOUND" = "false" ]; then
                echo "❌ 未找到对应序号的节点。"
            fi
            ;;
        *)
            return 0
            ;;
    esac
}

update_node_info_summary() {
    S_ADDR=$(get_or_detect_server_addr)
    mkdir -p /etc/sing-box
    INFO_TMP=$(mktemp /tmp/ldnat.info.XXXXXX)
    cat << INFO_HEAD > "$INFO_TMP"
==========================================================
              LDNAT - 节点配置与导入链接汇总
==========================================================
更新时间: $(date '+%Y-%m-%d %H:%M:%S')
连接地址: ${S_ADDR}
==========================================================
INFO_HEAD

    if [ -f "$NODES_CONF" ]; then
        N_IDX=0
        while IFS='|' read -r N_PORT N_TYPE N_NAME N_P1 N_P2 N_P3 N_P4 N_P5 || [ -n "$N_PORT" ]; do
            [ -n "$N_PORT" ] || continue
            case "$N_PORT" in '#'*|'') continue ;; esac
            N_IDX=$((N_IDX + 1))
            N_URL=$(build_node_url "$N_PORT" "$N_TYPE" "$N_NAME" "$N_P1" "$N_P2" "$N_P3" "$N_P4" "$N_P5" "$S_ADDR")
            cat << INFO_ITEM >> "$INFO_TMP"
【序号 $N_IDX】[$N_TYPE] $N_NAME (端口: $N_PORT)
客户端链接:
$N_URL
----------------------------------------------------------
INFO_ITEM
        done < "$NODES_CONF"
    fi
    atomic_install "$INFO_TMP" "$INFO_FILE" 600
    rm -f "$INFO_TMP"
    hook_subskiff_sync
}

sync_singbox_config() {
    STAGE="生成和同步节点配置"
    mkdir -p /etc/sing-box
    chmod 700 /etc/sing-box
    [ -f "$NODES_CONF" ] || touch "$NODES_CONF"

    # 若包含 hy2/tuic/trojan/anytls 则确保证书存在
    if grep -Eq '\|(hy2|tuic|trojan|anytls)\|' "$NODES_CONF" 2>/dev/null; then
        ensure_self_signed_cert
    fi

    ensure_singbox_binary
    ensure_singbox_service

    TMP_SYNC_DIR=$(mktemp -d /tmp/ldnat.sync.XXXXXX)
    TMP_INBOUNDS="$TMP_SYNC_DIR/inbounds.json"
    TMP_CONFIG="$TMP_SYNC_DIR/config.json"
    rm -f "$TMP_INBOUNDS"

    HAS_NODES=false
    while IFS='|' read -r PORT TYPE NAME P1 P2 P3 P4 P5 || [ -n "$PORT" ]; do
        [ -n "$PORT" ] || continue
        case "$PORT" in '#'*|'') continue ;; esac
        HAS_NODES=true

        # 兼容旧格式 (若无 NAME 列，自动以 TYPE-PORT 兜底)
        case "$TYPE" in
            reality)
                if [ -z "$P5" ] && [ -n "$P4" ]; then
                    P5="$P4"; P4="$P3"; P3="$P2"; P2="$P1"; P1="$NAME"
                    NAME="REALITY-${PORT}"
                fi
                ;;
            ss)
                case "$NAME" in
                    chacha*|aes*|2022*)
                        P2="$P1"; P1="$NAME"
                        NAME="SS-${PORT}"
                        ;;
                esac
                ;;
        esac

        case "$TYPE" in
            reality)
                # P1: UUID, P2: PRIV, P3: PUB, P4: SID, P5: SNI
                jq -n --arg port "$PORT" --arg uuid "$P1" --arg priv "$P2" --arg sid "$P4" --arg sni "$P5" '{
                    type: "vless",
                    tag: ("reality-" + $port),
                    listen: "0.0.0.0",
                    listen_port: ($port | tonumber),
                    users: [{uuid: $uuid, flow: "xtls-rprx-vision"}],
                    tls: {
                        enabled: true,
                        server_name: $sni,
                        reality: {
                            enabled: true,
                            handshake: {server: $sni, server_port: 443},
                            private_key: $priv,
                            short_id: [$sid]
                        }
                    }
                }' >> "$TMP_INBOUNDS"
                ;;
            ss)
                # P1: METHOD, P2: PASSWORD
                jq -n --arg port "$PORT" --arg method "$P1" --arg pass "$P2" '{
                    type: "shadowsocks",
                    tag: ("ss-" + $port),
                    listen: "0.0.0.0",
                    listen_port: ($port | tonumber),
                    method: $method,
                    password: $pass
                }' >> "$TMP_INBOUNDS"
                ;;
            hy2)
                # P1: PASSWORD
                jq -n --arg port "$PORT" --arg pass "$P1" --arg cert "$CERT_PEM" --arg key "$KEY_PEM" '{
                    type: "hysteria2",
                    tag: ("hy2-" + $port),
                    listen: "0.0.0.0",
                    listen_port: ($port | tonumber),
                    users: [{password: $pass}],
                    ignore_client_bandwidth: false,
                    tls: {
                        enabled: true,
                        certificate_path: $cert,
                        key_path: $key
                    }
                }' >> "$TMP_INBOUNDS"
                ;;
            tuic)
                # P1: UUID, P2: PASSWORD
                jq -n --arg port "$PORT" --arg uuid "$P1" --arg pass "$P2" --arg cert "$CERT_PEM" --arg key "$KEY_PEM" '{
                    type: "tuic",
                    tag: ("tuic-" + $port),
                    listen: "0.0.0.0",
                    listen_port: ($port | tonumber),
                    users: [{uuid: $uuid, password: $pass}],
                    congestion_control: "bbr",
                    tls: {
                        enabled: true,
                        certificate_path: $cert,
                        key_path: $key
                    }
                }' >> "$TMP_INBOUNDS"
                ;;
            trojan)
                # P1: PASSWORD
                jq -n --arg port "$PORT" --arg pass "$P1" --arg cert "$CERT_PEM" --arg key "$KEY_PEM" '{
                    type: "trojan",
                    tag: ("trojan-" + $port),
                    listen: "0.0.0.0",
                    listen_port: ($port | tonumber),
                    users: [{password: $pass}],
                    tls: {
                        enabled: true,
                        certificate_path: $cert,
                        key_path: $key
                    }
                }' >> "$TMP_INBOUNDS"
                ;;
            anytls)
                # P1: PASSWORD
                jq -n --arg port "$PORT" --arg pass "$P1" --arg cert "$CERT_PEM" --arg key "$KEY_PEM" '{
                    type: "anytls",
                    tag: ("anytls-" + $port),
                    listen: "0.0.0.0",
                    listen_port: ($port | tonumber),
                    users: [{password: $pass}],
                    tls: {
                        enabled: true,
                        certificate_path: $cert,
                        key_path: $key
                    }
                }' >> "$TMP_INBOUNDS"
                ;;
        esac
    done < "$NODES_CONF"

    if [ "$HAS_NODES" = true ] && [ -f "$TMP_INBOUNDS" ]; then
        if is_abuse_block_enabled; then
            jq -s '{
                log: {
                    level: "warn",
                    output: "/var/log/sing-box.log",
                    timestamp: true
                },
                inbounds: .,
                outbounds: [
                    {type: "direct", tag: "direct"},
                    {type: "block", tag: "block"}
                ],
                route: {
                    rules: [
                        {
                            action: "sniff"
                        },
                        {
                            protocol: "bittorrent",
                            outbound: "block"
                        },
                        {
                            port: [22, 23, 25, 135, 137, 138, 139, 445, 1900, 3389, 51413, 6881, 6882, 6883, 6884, 6885, 6886, 6887, 6888, 6889, 6969],
                            outbound: "block"
                        },
                        {
                            domain_keyword: ["torrent", "tracker", "announce", "peer", "minexmr", "nicehash", "stratum"],
                            outbound: "block"
                        },
                        {
                            ip_cidr: ["127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "::1/128", "fc00::/7", "fe80::/10"],
                            outbound: "block"
                        }
                    ]
                }
            }' "$TMP_INBOUNDS" > "$TMP_CONFIG"
        else
            jq -s '{
                log: {
                    level: "warn",
                    output: "/var/log/sing-box.log",
                    timestamp: true
                },
                inbounds: .,
                outbounds: [
                    {type: "direct", tag: "direct"}
                ]
            }' "$TMP_INBOUNDS" > "$TMP_CONFIG"
        fi
    else
        cat << 'EOF_EMPTY' > "$TMP_CONFIG"
{
  "log": {
    "level": "warn",
    "output": "/var/log/sing-box.log",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"}
  ]
}
EOF_EMPTY
    fi

    /usr/local/bin/sing-box check -c "$TMP_CONFIG" || {
        rm -rf "$TMP_SYNC_DIR"
        die 'Sing-box 配置检查未通过，请检查节点参数。'
    }

    atomic_install "$TMP_CONFIG" "$CONFIG_FILE" 600
    rm -rf "$TMP_SYNC_DIR"

    if [ "$HAS_NODES" = true ]; then
        rc-service sing-box restart || die 'Sing-box 服务重启失败。'
        sleep 1
        rc-service sing-box status || die 'Sing-box 未能持续运行。'
    else
        rc-service sing-box stop >/dev/null 2>&1 || true
        echo "ℹ️ 当前未配置任何节点，Sing-box 服务已暂停。"
    fi

    update_node_info_summary
}

add_node_rule() {
    require_environment
    setup_swap
    ensure_singbox_binary

    echo "=========================================================="
    echo "          ➕ LDNAT - 添加新节点服务 (支持6大协议)          "
    echo "=========================================================="
    echo "请选择协议类型:"
    echo "  1. VLESS-REALITY (TCP + XTLS-Vision，直连最强伪装抗封) [推荐]"
    echo "  2. Shadowsocks   (chacha20-ietf-poly1305，极简中转与链式落地)"
    echo "  3. Hysteria 2    (UDP/QUIC，恶劣网络与高丢包率救星)"
    echo "  4. TUIC v5       (UDP/QUIC，极速低延迟与BBR拥塞控制)"
    echo "  5. Trojan        (TLS 原生流，成熟稳定)"
    echo "  6. AnyTLS        (Sing-box 原生 AnyTLS 协议)"
    echo "  0. 取消返回"
    echo "=========================================================="
    printf "👉 请输入选项 [1-6, 0]: "
    read_input PROTO_CHOICE

    TARGET_TYPE=""
    case "$PROTO_CHOICE" in
        1) TARGET_TYPE="reality" ;;
        2) TARGET_TYPE="ss" ;;
        3) TARGET_TYPE="hy2" ;;
        4) TARGET_TYPE="tuic" ;;
        5) TARGET_TYPE="trojan" ;;
        6) TARGET_TYPE="anytls" ;;
        *) echo "操作已取消。"; return 0 ;;
    esac

    # 询问端口
    NEW_PORT=""
    while true; do
        printf "👉 请输入该节点的【监听端口】(1-65535): "
        read_input NEW_PORT
        if valid_port "$NEW_PORT"; then
            NEW_PORT=$(printf '%s' "$NEW_PORT" | sed 's/^0*//')
            # 检查 nodes.conf 是否冲突
            if grep -Eq "^${NEW_PORT}\|" "$NODES_CONF" 2>/dev/null; then
                echo "❌ 端口 ${NEW_PORT} 已被其他节点占用，请更换端口！"
                continue
            fi
            # 检查 realm rules.conf 是否冲突
            if grep -Eq "^${NEW_PORT}[[:space:]]+" "$REALM_RULES" 2>/dev/null; then
                echo "❌ 端口 ${NEW_PORT} 已被 Realm 转发占用，请更换端口！"
                continue
            fi
            break
        else
            echo "❌ 端口格式不正确，请输入 1-65535 之间的纯数字！"
        fi
    done

    # 自动访问 IPPure 接口获取第一手画像并生成模板 4 标准名称
    echo "[*] 正在请求 my.ippure.com 获取本地网络画像与风控分..."
    _IP_JSON=$(curl -sL --connect-timeout 4 -m 6 "https://my.ippure.com/v1/info" 2>/dev/null || true)

    _CC=$(printf '%s' "$_IP_JSON" | grep -oE '"countryCode"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | cut -d'"' -f4 | tr 'a-z' 'A-Z' || true)
    _COUNTRY=$(printf '%s' "$_IP_JSON" | grep -oE '"country"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | cut -d'"' -f4 || true)
    _CITY=$(printf '%s' "$_IP_JSON" | grep -oE '"city"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | cut -d'"' -f4 || true)
    _IS_RES=$(printf '%s' "$_IP_JSON" | grep -oE '"isResidential"[[:space:]]*:[[:space:]]*(true|false)' | head -n1 | cut -d':' -f2 | tr -d ' ' || true)
    _IS_BC=$(printf '%s' "$_IP_JSON" | grep -oE '"isBroadcast"[[:space:]]*:[[:space:]]*(true|false)' | head -n1 | cut -d':' -f2 | tr -d ' ' || true)
    _SCORE=$(printf '%s' "$_IP_JSON" | grep -oE '"fraudScore"[[:space:]]*:[[:space:]]*[0-9]+' | head -n1 | cut -d':' -f2 | tr -d ' ' || echo "0")

    _FLAG="🌐"
    case "$_CC" in
        TH) _FLAG="🇹🇭"; [ -z "$_COUNTRY" ] || [ "$_COUNTRY" = "Thailand" ] && _COUNTRY="泰国" ;;
        VN) _FLAG="🇻🇳"; [ -z "$_COUNTRY" ] || [ "$_COUNTRY" = "Vietnam" ] && _COUNTRY="越南" ;;
        HK) _FLAG="🇭🇰"; [ -z "$_COUNTRY" ] || [ "$_COUNTRY" = "Hong Kong" ] && _COUNTRY="香港" ;;
        US) _FLAG="🇺🇸"; [ -z "$_COUNTRY" ] || [ "$_COUNTRY" = "United States" ] && _COUNTRY="美国" ;;
        JP) _FLAG="🇯🇵"; [ -z "$_COUNTRY" ] || [ "$_COUNTRY" = "Japan" ] && _COUNTRY="日本" ;;
        SG) _FLAG="🇸🇬"; [ -z "$_COUNTRY" ] || [ "$_COUNTRY" = "Singapore" ] && _COUNTRY="新加坡" ;;
        KR) _FLAG="🇰🇷"; [ -z "$_COUNTRY" ] || [ "$_COUNTRY" = "Korea" ] && _COUNTRY="韩国" ;;
        TW) _FLAG="🇹🇼"; [ -z "$_COUNTRY" ] || [ "$_COUNTRY" = "Taiwan" ] && _COUNTRY="台湾" ;;
        GB) _FLAG="🇬🇧"; [ -z "$_COUNTRY" ] || [ "$_COUNTRY" = "United Kingdom" ] && _COUNTRY="英国" ;;
        DE) _FLAG="🇩🇪"; [ -z "$_COUNTRY" ] || [ "$_COUNTRY" = "Germany" ] && _COUNTRY="德国" ;;
        FR) _FLAG="🇫🇷"; [ -z "$_COUNTRY" ] || [ "$_COUNTRY" = "France" ] && _COUNTRY="法国" ;;
    esac

    case "$_CITY" in
        Bangkok) _CITY="曼谷" ;;
        Hanoi) _CITY="河内" ;;
        "Ho Chi Minh City") _CITY="胡志明" ;;
        "Tung Chung") _CITY="东涌" ;;
        Kowloon) _CITY="九龙" ;;
        Central) _CITY="中环" ;;
        Tokyo) _CITY="东京" ;;
        Osaka) _CITY="大阪" ;;
        "Los Angeles") _CITY="洛杉矶" ;;
        "San Jose") _CITY="圣何塞" ;;
        "New York") _CITY="纽约" ;;
        London) _CITY="伦敦" ;;
        Frankfurt) _CITY="法兰克福" ;;
        Singapore) _CITY="新加坡" ;;
    esac

    _RES_TEXT="机房"
    [ "$_IS_RES" = "true" ] && _RES_TEXT="家宽"
    _BC_TEXT="原生"
    [ "$_IS_BC" = "true" ] && _BC_TEXT="广播"
    _LOC_TEXT="$_COUNTRY"
    [ -n "$_CITY" ] && _LOC_TEXT="${_COUNTRY}·${_CITY}"

    # 模板 4 默认名称：{国旗} {国家·城市} ｜ {原生/广播} ｜ {家宽/机房} ｜ {分数}分
    if [ -n "$_COUNTRY" ]; then
        DEFAULT_NAME="${_FLAG} ${_LOC_TEXT} ｜ ${_BC_TEXT} ｜ ${_RES_TEXT} ｜ ${_SCORE}分"
    else
        DEFAULT_NAME="${TARGET_TYPE}-${NEW_PORT}"
    fi

    # 询问节点备注名称
    printf "👉 请输入【节点备注名称】\n   [直接回车默认: %s]: " "$DEFAULT_NAME"
    read_input USER_NAME
    NODE_NAME="${USER_NAME:-$DEFAULT_NAME}"
    NODE_NAME=$(printf '%s' "$NODE_NAME" | sed 's/|/｜/g')

    # 询问或确认服务器连接地址
    S_ADDR=$(get_or_detect_server_addr)
    echo "当前默认连接地址为: $S_ADDR"
    printf "👉 是否使用此地址？直接回车使用，或输入新的域名/公网IP: "
    read_input USER_ADDR
    if [ -n "$USER_ADDR" ]; then
        valid_domain "$USER_ADDR" || valid_ipv4 "$USER_ADDR" || die '输入格式不正确，必须为合法域名或IPv4！'
        mkdir -p /etc/sing-box
        printf '%s\n' "$USER_ADDR" > "$ADDR_CONF"
        S_ADDR="$USER_ADDR"
    fi

    # 自动生成凭据
    echo ">>> 正在生成安全随机凭据与配置..."
    RECORD=""
    case "$TARGET_TYPE" in
        reality)
            select_sni_target
            valid_domain "$SNI" || die 'SNI 必须是合法域名。'
            N_UUID=$(/usr/local/bin/sing-box generate uuid)
            N_SID=$(/usr/local/bin/sing-box generate rand --hex 8)
            KEYPAIR=$(/usr/local/bin/sing-box generate reality-keypair)
            N_PRIV=$(printf '%s\n' "$KEYPAIR" | awk '/PrivateKey/ {print $2}')
            printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040' > "$WORK_DIR/private.der"
            printf '%s=' "$N_PRIV" | tr '_-' '/+' | base64 -d >> "$WORK_DIR/private.der"
            openssl pkey -inform DER -in "$WORK_DIR/private.der" -pubout -outform DER -out "$WORK_DIR/public.der"
            N_PUB=$(tail -c 32 "$WORK_DIR/public.der" | base64 | tr '/+' '_-' | tr -d '=\n')
            RECORD="${NEW_PORT}|reality|${NODE_NAME}|${N_UUID}|${N_PRIV}|${N_PUB}|${N_SID}|${SNI}"
            ;;
        ss)
            N_PASS=$(/usr/local/bin/sing-box generate rand --base64 16)
            RECORD="${NEW_PORT}|ss|${NODE_NAME}|chacha20-ietf-poly1305|${N_PASS}"
            ;;
        hy2)
            N_PASS=$(/usr/local/bin/sing-box generate rand --base64 16)
            RECORD="${NEW_PORT}|hy2|${NODE_NAME}|${N_PASS}"
            ;;
        tuic)
            N_UUID=$(/usr/local/bin/sing-box generate uuid)
            N_PASS=$(/usr/local/bin/sing-box generate rand --base64 16)
            RECORD="${NEW_PORT}|tuic|${NODE_NAME}|${N_UUID}|${N_PASS}"
            ;;
        trojan)
            N_PASS=$(/usr/local/bin/sing-box generate rand --base64 16)
            RECORD="${NEW_PORT}|trojan|${NODE_NAME}|${N_PASS}"
            ;;
        anytls)
            N_PASS=$(/usr/local/bin/sing-box generate rand --base64 16)
            RECORD="${NEW_PORT}|anytls|${NODE_NAME}|${N_PASS}"
            ;;
    esac

    mkdir -p /etc/sing-box
    printf '%s\n' "$RECORD" >> "$NODES_CONF"
    sync_singbox_config

    clear 2>/dev/null || true
    echo "================================================================"
    echo "          🎉 节点添加成功！服务检查已通过并已启动                "
    echo "================================================================"
    TOTAL_NODES=$(grep -c -v '^[[:space:]]*#' "$NODES_CONF" 2>/dev/null || true)
    _D_P1=$(printf '%s' "$RECORD" | cut -d'|' -f4)
    _D_P2=$(printf '%s' "$RECORD" | cut -d'|' -f5)
    _D_P3=$(printf '%s' "$RECORD" | cut -d'|' -f6)
    _D_P4=$(printf '%s' "$RECORD" | cut -d'|' -f7)
    _D_P5=$(printf '%s' "$RECORD" | cut -d'|' -f8)
    render_single_node_detail "$TOTAL_NODES" "$NEW_PORT" "$TARGET_TYPE" "$NODE_NAME" \
        "$_D_P1" "$_D_P2" "$_D_P3" "$_D_P4" "$_D_P5" "$S_ADDR" true
    echo "================================================================"
    if is_abuse_block_enabled; then
        echo "🛡️ 安全审计护盾已生效 (已自动阻断 BT/PT、邮件SPAM、矿池及恶意扫描)"
        echo "================================================================"
    fi
}

delete_node_rule() {
    TARGET="$1"
    if [ ! -f "$NODES_CONF" ] || [ ! -s "$NODES_CONF" ]; then
        echo "ℹ️ 当前未配置任何节点规则。"
        return 0
    fi

    if [ -z "$TARGET" ]; then
        list_node_rules
        TOTAL_NODES=$(grep -c -v '^[[:space:]]*#' "$NODES_CONF" 2>/dev/null || true)
        printf "👉 请输入要删除的节点【序号】或【端口号】: "
        read_input TARGET
    fi
    [ -n "$TARGET" ] || { echo "操作已取消。"; return 0; }

    MATCH_PORT=""
    if valid_port "$TARGET" && grep -Eq "^${TARGET}\|" "$NODES_CONF"; then
        MATCH_PORT="$TARGET"
    else
        case "$TARGET" in
            ''|*[!0-9]*) echo "❌ 输入无效！"; return 0 ;;
            *)
                CURR=0
                while IFS='|' read -r P_NUM REST || [ -n "$P_NUM" ]; do
                    [ -n "$P_NUM" ] || continue
                    case "$P_NUM" in '#'*|'') continue ;; esac
                    CURR=$((CURR + 1))
                    if [ "$CURR" -eq "$TARGET" ]; then
                        MATCH_PORT="$P_NUM"
                        break
                    fi
                done < "$NODES_CONF"
                ;;
        esac
    fi

    if [ -z "$MATCH_PORT" ]; then
        echo "❌ 未找到对应规则（序号/端口：$TARGET）！"
        return 0
    fi

    printf "⚠️ 确定要删除端口为 %s 的节点规则吗？[y/N]: " "$MATCH_PORT"
    read_input CONFIRM
    case "$CONFIRM" in
        y*|Y*)
            TMP_N=$(mktemp /etc/sing-box/nodes.tmp.XXXXXX)
            awk -F'|' -v p="$MATCH_PORT" '$1 != p { print $0 }' "$NODES_CONF" > "$TMP_N"
            mv -f "$TMP_N" "$NODES_CONF"
            echo "🗑️ 已移除端口 $MATCH_PORT 节点规则，正在同步服务配置..."
            sync_singbox_config
            echo "✅ 节点服务配置已同步！"
            ;;
        *)
            echo "操作已取消。"
            ;;
    esac
}

manage_nodes_menu() {
    require_environment
    setup_swap
    ensure_singbox_binary
    while true; do
        clear 2>/dev/null || true
        list_node_rules
        SHIELD_OPT="开启"
        if is_abuse_block_enabled; then
            SHIELD_OPT="关闭"
        fi
        echo "  1. 添加新节点 (选协议 + 端口 + 节点备注名称 + 自动凭据)"
        echo "  2. 删除已有节点"
        echo "  3. 查看节点链接与二维码 (A 全部批量 / B 单个查看)"
        echo "  4. 修改节点连接地址 (当前域名/IP)"
        echo "  5. 切换安全审计与防滥用护盾 (当前将切换为: ${SHIELD_OPT})"
        echo "  6. 重启/重载 Sing-box 服务"
        echo "  7. 停止 Sing-box 服务"
        echo "  0. 返回上级主菜单 (支持按 q)"
        echo "=========================================================="
        printf "👉 请选择操作 [0-7 或 q]: "
        read_input SUB_CHOICE
        case "$SUB_CHOICE" in
            1)
                add_node_rule
                printf "\n按回车键继续..."
                read_input _DUMMY
                ;;
            2)
                delete_node_rule ""
                printf "\n按回车键继续..."
                read_input _DUMMY
                ;;
            3)
                show_node_links
                printf "\n按回车键继续..."
                read_input _DUMMY
                ;;
            4)
                set_server_addr
                printf "\n按回车键继续..."
                read_input _DUMMY
                ;;
            5)
                toggle_abuse_block
                printf "\n按回车键继续..."
                read_input _DUMMY
                ;;
            6)
                sync_singbox_config
                printf "\n按回车键继续..."
                read_input _DUMMY
                ;;
            7)
                rc-service sing-box stop
                echo "🛑 Sing-box 服务已停止。"
                printf "\n按回车键继续..."
                read_input _DUMMY
                ;;
            0|q|Q)
                break
                ;;
            *)
                echo "⚠️ 输入无效，请重新选择。"
                sleep 1
                ;;
        esac
    done
}

# 兼容旧函数调用：install_singbox_module
install_singbox_module() {
    REQ_MODE="${1:-}"
    PORT_REALITY="${2:-}"
    PORT_SS="${3:-}"
    NODE_DOMAIN="${4:-}"

    if [ -n "$NODE_DOMAIN" ]; then
        mkdir -p /etc/sing-box
        printf '%s\n' "$NODE_DOMAIN" > "$ADDR_CONF"
    fi

    if [ -n "$PORT_REALITY" ] || [ -n "$PORT_SS" ]; then
        require_environment
        setup_swap
        ensure_singbox_binary
        if [ -n "$PORT_REALITY" ]; then
            select_sni_target
            N_UUID=$(/usr/local/bin/sing-box generate uuid)
            N_SID=$(/usr/local/bin/sing-box generate rand --hex 8)
            KEYPAIR=$(/usr/local/bin/sing-box generate reality-keypair)
            N_PRIV=$(printf '%s\n' "$KEYPAIR" | awk '/PrivateKey/ {print $2}')
            printf '\060\056\002\001\000\060\005\006\003\053\145\156\004\042\004\040' > "$WORK_DIR/private.der"
            printf '%s=' "$N_PRIV" | tr '_-' '/+' | base64 -d >> "$WORK_DIR/private.der"
            openssl pkey -inform DER -in "$WORK_DIR/private.der" -pubout -outform DER -out "$WORK_DIR/public.der"
            N_PUB=$(tail -c 32 "$WORK_DIR/public.der" | base64 | tr '/+' '_-' | tr -d '=\n')
            printf '%s\n' "${PORT_REALITY}|reality|REALITY-${PORT_REALITY}|${N_UUID}|${N_PRIV}|${N_PUB}|${N_SID}|${SNI}" >> "$NODES_CONF"
        fi
        if [ -n "$PORT_SS" ]; then
            N_PASS=$(/usr/local/bin/sing-box generate rand --base64 16)
            printf '%s\n' "${PORT_SS}|ss|SS-${PORT_SS}|chacha20-ietf-poly1305|${N_PASS}" >> "$NODES_CONF"
        fi
        sync_singbox_config
        show_node_links
    else
        manage_nodes_menu
    fi
}

# ==================== 模块 5: 查看已有配置 ====================
view_node_info() {
    clear 2>/dev/null || true
    echo "=========================================================="
    echo "              📋 LDNAT 当前配置与规则详情                  "
    echo "=========================================================="
    if [ -f "$NODES_CONF" ] && [ -s "$NODES_CONF" ]; then
        list_node_rules
        echo ""
        printf "👉 是否导出节点链接与二维码？[y/N]: "
        read_input EXPORT_ANS
        case "$EXPORT_ANS" in
            y*|Y*)
                show_node_links
                ;;
        esac
    elif [ -f "$INFO_FILE" ]; then
        cat "$INFO_FILE"
        FIRST_URL=$(grep -m1 -E '^(vless|ss|hysteria2|tuic|trojan|anytls)://' "$INFO_FILE" || true)
        if [ -n "$FIRST_URL" ] && command -v qrencode >/dev/null 2>&1; then
            echo ""
            echo "【节点二维码预览】"
            show_qr "$FIRST_URL"
        fi
    else
        echo "ℹ️ 暂未检测到 Sing-box 节点配置信息。"
    fi

    if [ -f "$REALM_RULES" ] || [ -f "$REALM_CONFIG" ]; then
        echo ""
        list_realm_rules
    fi
    echo "=========================================================="
}

# ==================== 模块 6: 诊断与网络检测 ====================
diagnose_network() {
    echo "=========================================================="
    echo "            🩺 LDNAT 网络与服务快速诊断                   "
    echo "=========================================================="
    echo "1. 检查 Sing-box 服务状态:"
    rc-service sing-box status 2>/dev/null || echo "未安装或未运行。"
    echo ""
    echo "2. 检查 Realm 转发服务状态:"
    rc-service realm status 2>/dev/null || echo "未安装或未运行。"
    echo ""
    echo "3. 检查当前监听端口:"
    netstat -tlpn | grep -E "sing-box|realm" || echo "未检测到代理/转发监听端口！"
    echo ""
    echo "4. 检查公网出口 IP:"
    OUT_IP=$(get_public_ipv4 2>/dev/null || echo "无法获取")
    echo "   当前出口 IP: $OUT_IP"
    echo ""
    echo "5. 检查节点伪装目标握手状态:"
    if [ -f "$CONFIG_FILE" ]; then
        CURR_SNI=$(jq -r '.inbounds[]? | select(.tag == "reality-in") | .tls.server_name' "$CONFIG_FILE" 2>/dev/null || echo "")
        if [ -n "$CURR_SNI" ] && [ "$CURR_SNI" != "null" ]; then
            echo "   当前配置 SNI: $CURR_SNI"
            CODE=$(curl -s -o /dev/null -w "%{http_code}" -m 3 "https://$CURR_SNI" 2>/dev/null || echo "超时")
            echo "   伪装握手探测: $CODE (若为 000 或 超时 则说明此 SNI 被阻断)"
        else
            echo "   当前未启用 REALITY 协议。"
        fi
    fi
    echo ""
    echo "6. 检查当前 TCP 拥塞控制算法:"
    CURR_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    echo "   当前内核算法: $CURR_CC"
    echo "=========================================================="
}

# ==================== 模块 7: 系统 TCP 与 BBR 深度网络调优 ====================
optimize_tcp_bbr() {
    BW_INPUT="${1:-}"

    if [ -z "$BW_INPUT" ]; then
        clear 2>/dev/null || true
        echo "=========================================================="
        echo "     ⚡ LDNAT - Linux 系统 TCP 与 BBR 深度网络调优        "
        echo "=========================================================="
        echo "💡 根据机器真实带宽匹配最优 TCP 发送/接收缓冲区与拥塞算法："
        echo ""
        echo "  [轻量/普通带宽 (防爆内存安全防护)]"
        echo "   1. 10 Mbps   (低配小鸡/严格限速，最小内存开销防 OOM)"
        echo "   2. 20 Mbps   (轻量共享带宽)"
        echo "   3. 30 Mbps   (典型 30M 共享 NAT)"
        echo "   4. 50 Mbps   (普通 50M VPS)"
        echo ""
        echo "  [主流高速带宽 (主流 VPS / 专线中转)]"
        echo "   5. 100 Mbps  (百兆常见规格 / 动态家宽)"
        echo "   6. 200 Mbps  (200M 优化线路)"
        echo "   7. 300 Mbps  (300M 常见机房端口)"
        echo "   8. 400 Mbps  (400M 专线/商宽)"
        echo "   9. 500 Mbps  (500M 高速端口)"
        echo ""
        echo "  [千兆及超千兆狂暴大水管 (亚太大口/原生落地)]"
        echo "  10. 1000 Mbps (1G 口千兆大水管)"
        echo "  11. 2000 Mbps (2G 口原生落地大带宽)"
        echo "  12. 2500 Mbps (2.5G 专用高速口)"
        echo "  13. 5000 Mbps (5G 巨型骨干网络)"
        echo "----------------------------------------------------------"
        echo "  0. 自定义输入纯带宽数字 (例如直接输入 100 或 2000)"
        echo "=========================================================="
        printf "请输入档位编号 [1-13] 或直接输入 0 自定义: "
        read_input B_CHOICE
        case "$B_CHOICE" in
            1) BW_INPUT=10 ;;
            2) BW_INPUT=20 ;;
            3) BW_INPUT=30 ;;
            4) BW_INPUT=50 ;;
            5) BW_INPUT=100 ;;
            6) BW_INPUT=200 ;;
            7) BW_INPUT=300 ;;
            8) BW_INPUT=400 ;;
            9) BW_INPUT=500 ;;
            10) BW_INPUT=1000 ;;
            11) BW_INPUT=2000 ;;
            12) BW_INPUT=2500 ;;
            13) BW_INPUT=5000 ;;
            0)
                printf "👉 请输入带宽数值 (单位 Mbps，纯数字，如 100 或 2000): "
                read_input BW_INPUT
                ;;
            *)
                BW_INPUT="$B_CHOICE"
                ;;
        esac
    fi

    # 过滤非数字
    BW_VAL=$(printf '%s' "$BW_INPUT" | sed 's/[^0-9]//g')
    [ -n "$BW_VAL" ] && [ "$BW_VAL" -gt 0 ] || die '带宽数值必须是大于 0 的纯数字！'

    echo ""
    echo ">>> 正在针对 ${BW_VAL} Mbps 带宽计算最优 TCP 栈参数..."

    if [ "$BW_VAL" -le 15 ]; then
        RMEM_DEF=131072; WMEM_DEF=131072; RMEM_MAX=2097152; WMEM_MAX=2097152; TIER_NAME="10 Mbps (超轻量安全档)"
    elif [ "$BW_VAL" -le 25 ]; then
        RMEM_DEF=262144; WMEM_DEF=262144; RMEM_MAX=4194304; WMEM_MAX=4194304; TIER_NAME="20 Mbps"
    elif [ "$BW_VAL" -le 35 ]; then
        RMEM_DEF=262144; WMEM_DEF=262144; RMEM_MAX=4194304; WMEM_MAX=4194304; TIER_NAME="30 Mbps"
    elif [ "$BW_VAL" -le 75 ]; then
        RMEM_DEF=524288; WMEM_DEF=524288; RMEM_MAX=8388608; WMEM_MAX=8388608; TIER_NAME="50 Mbps"
    elif [ "$BW_VAL" -le 150 ]; then
        RMEM_DEF=524288; WMEM_DEF=524288; RMEM_MAX=16777216; WMEM_MAX=16777216; TIER_NAME="100 Mbps"
    elif [ "$BW_VAL" -le 250 ]; then
        RMEM_DEF=1048576; WMEM_DEF=1048576; RMEM_MAX=16777216; WMEM_MAX=16777216; TIER_NAME="200 Mbps"
    elif [ "$BW_VAL" -le 350 ]; then
        RMEM_DEF=1048576; WMEM_DEF=1048576; RMEM_MAX=25165824; WMEM_MAX=25165824; TIER_NAME="300 Mbps"
    elif [ "$BW_VAL" -le 450 ]; then
        RMEM_DEF=1048576; WMEM_DEF=1048576; RMEM_MAX=33554432; WMEM_MAX=33554432; TIER_NAME="400 Mbps"
    elif [ "$BW_VAL" -le 750 ]; then
        RMEM_DEF=1048576; WMEM_DEF=1048576; RMEM_MAX=33554432; WMEM_MAX=33554432; TIER_NAME="500 Mbps"
    elif [ "$BW_VAL" -le 1500 ]; then
        RMEM_DEF=1048576; WMEM_DEF=1048576; RMEM_MAX=67108864; WMEM_MAX=67108864; TIER_NAME="1000 Mbps (千兆狂暴档)"
    elif [ "$BW_VAL" -le 2250 ]; then
        RMEM_DEF=2097152; WMEM_DEF=2097152; RMEM_MAX=67108864; WMEM_MAX=67108864; TIER_NAME="2000 Mbps (2G 极速档)"
    elif [ "$BW_VAL" -le 3500 ]; then
        RMEM_DEF=2097152; WMEM_DEF=2097152; RMEM_MAX=100663296; WMEM_MAX=100663296; TIER_NAME="2500 Mbps (2.5G 专用档)"
    else
        RMEM_DEF=4194304; WMEM_DEF=4194304; RMEM_MAX=134217728; WMEM_MAX=134217728; TIER_NAME="5000 Mbps (5G 巨型大水管)"
    fi

    # 内存安全防护盾 (Safety Guard)
    SYS_MEM=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}' || echo 512)
    case "$SYS_MEM" in ''|*[!0-9]*) SYS_MEM=512 ;; esac
    if [ "$SYS_MEM" -lt 200 ] && [ "$RMEM_MAX" -gt 16777216 ]; then
        echo "💡 检测到小鸡物理内存较小 (${SYS_MEM}MB)，已自动启用防 OOM 内存保护 (缓冲区上限定为 16MB)！"
        RMEM_MAX=16777216
        WMEM_MAX=16777216
        RMEM_DEF=524288
        WMEM_DEF=524288
    fi

    echo ">>> [1/3] 尝试加载 BBR 内核模块..."
    modprobe tcp_bbr 2>/dev/null || true

    echo ">>> [2/3] 写入 /etc/sysctl.d/99-ldnat-bbr.conf 配置 (${TIER_NAME})..."
    mkdir -p /etc/sysctl.d
    cat << EOF > /etc/sysctl.d/99-ldnat-bbr.conf
# LDNAT 自动优化参数 (${TIER_NAME})
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.core.rmem_max = ${RMEM_MAX}
net.core.wmem_max = ${WMEM_MAX}
net.core.rmem_default = ${RMEM_DEF}
net.core.wmem_default = ${WMEM_DEF}
net.ipv4.tcp_rmem = 4096 ${RMEM_DEF} ${RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${WMEM_DEF} ${WMEM_MAX}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 300
net.ipv4.ip_local_port_range = 1024 65535
EOF

    echo ">>> [3/3] 激活并应用系统 TCP 栈参数..."
    sysctl -p /etc/sysctl.d/99-ldnat-bbr.conf 2>/dev/null || sysctl -p 2>/dev/null || true

    ACTIVE_CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
    echo ""
    echo "=========================================================="
    echo "🎉 BBR 与 TCP 网络调优完成！"
    echo "   - 匹配带宽档位 : ${TIER_NAME}"
    echo "   - 拥塞控制算法 : ${ACTIVE_CC}"
    echo "   - 单流读写上限 : $((RMEM_MAX / 1024 / 1024)) MB (自适应 BDP)"
    echo "   - 配置文件路径 : /etc/sysctl.d/99-ldnat-bbr.conf"
    echo "=========================================================="
}

# ==================== 模块 7: 轻舟端侧协同与探针管理 (SubSkiff) ====================

get_local_machine_id() {
    if [ -s /etc/machine-id ]; then
        head -n1 /etc/machine-id | tr -d ' \n\r'
    elif [ -s /var/lib/dbus/machine-id ]; then
        head -n1 /var/lib/dbus/machine-id | tr -d ' \n\r'
    elif [ -s /sys/class/dmi/id/product_uuid ]; then
        head -n1 /sys/class/dmi/id/product_uuid | tr -d ' \n\r'
    elif [ -s "$(get_subskiff_dir)/.subskiff_mid" ]; then
        head -n1 "$(get_subskiff_dir)/.subskiff_mid" | tr -d ' \n\r'
    else
        _RAND_ID="mid_$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N | cut -b1-16)"
        echo "$_RAND_ID" > "$(get_subskiff_dir)/.subskiff_mid" 2>/dev/null || true
        echo "$_RAND_ID"
    fi
}

get_local_hostname() {
    hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "vps_host"
}

get_subskiff_dir() {
    dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")"
}

get_subskiff_bin() {
    echo "$(get_subskiff_dir)/subskiff-agent"
}

get_subskiff_cfg() {
    _BASE="$(get_subskiff_dir)"
    if [ -f "$_BASE/config.json" ]; then
        echo "$_BASE/config.json"
    elif [ -f "$_BASE/agent.json" ]; then
        echo "$_BASE/agent.json"
    else
        echo "$_BASE/config.json"
    fi
}

hook_subskiff_sync() {
    _AGENT_BIN=$(get_subskiff_bin)
    _AGENT_CFG=$(get_subskiff_cfg)

    # 若未部署探针或未配置，静默跳过
    [ -f "$_AGENT_CFG" ] || return 0
    [ -x "$_AGENT_BIN" ] || return 0

    # 检查是否关闭了自动同步
    if command -v jq >/dev/null 2>&1; then
        _AUTO_SYNC=$(jq -r '.auto_sync_on_change // .auto_sync // true' "$_AGENT_CFG" 2>/dev/null || echo "true")
        [ "$_AUTO_SYNC" = "false" ] && return 0
    elif grep -qE '"auto_sync_on_change"[[:space:]]*:[[:space:]]*false' "$_AGENT_CFG" 2>/dev/null; then
        return 0
    fi

    echo ""
    echo "=========================================================="
    echo "  📡 正在同步节点配置至轻舟服务端 (SubSkiff)..."
    echo "=========================================================="

    _SYNC_OUT=$("$_AGENT_BIN" --once 2>&1) && _SYNC_CODE=0 || _SYNC_CODE=$?

    if [ "$_SYNC_CODE" -eq 0 ]; then
        echo "$_SYNC_OUT"
    else
        echo "⚠️ 轻舟同步未完成: $_SYNC_OUT"
        echo "ℹ️ 本地节点服务已成功生效，不受影响。"
    fi
    echo "=========================================================="
}

configure_subskiff() {
    _AGENT_CFG=$(get_subskiff_cfg)
    echo "=========================================================="
    echo "      📡 绑定/修改 轻舟服务端连接配置                      "
    echo "=========================================================="
    _CUR_URL=""
    _CUR_TOKEN=""
    _CUR_INTERVAL="300"
    _CUR_AUTO="true"
    if [ -f "$_AGENT_CFG" ]; then
        if command -v jq >/dev/null 2>&1; then
            _CUR_URL=$(jq -r '.server_url // empty' "$_AGENT_CFG" 2>/dev/null || true)
            _CUR_TOKEN=$(jq -r '.node_token // .token // empty' "$_AGENT_CFG" 2>/dev/null || true)
            _CUR_INTERVAL=$(jq -r '.report_interval_sec // .interval_min // 300' "$_AGENT_CFG" 2>/dev/null || echo "300")
            _CUR_AUTO=$(jq -r '.auto_sync_on_change // .auto_sync // true' "$_AGENT_CFG" 2>/dev/null || echo "true")
        else
            _CUR_URL=$(grep -oE '"server_url"[[:space:]]*:[[:space:]]*"[^"]+"' "$_AGENT_CFG" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
            _CUR_TOKEN=$(grep -oE '"(node_token|token)"[[:space:]]*:[[:space:]]*"[^"]+"' "$_AGENT_CFG" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
        fi
    fi

    printf "请输入轻舟服务端 API 地址 [%s]: " "${_CUR_URL:-https://api.yourdomain.com}"
    read_input _INPUT_URL
    [ -n "$_INPUT_URL" ] || _INPUT_URL="$_CUR_URL"
    [ -n "$_INPUT_URL" ] || die "服务端地址不能为空。"

    if [ -n "$_CUR_TOKEN" ]; then
        printf "请输入端侧通信 Token [留空保持现有: %s****]: " "${_CUR_TOKEN:0:4}"
    else
        echo "💡 提示: 通信 Token 需与 SubSkiff 后台【📡 探针集群】中的 Agent 上报密钥一致 (可直接从后台一键复制)"
        printf "请输入端侧通信 Token: "
    fi
    read_input _INPUT_TOKEN
    [ -n "$_INPUT_TOKEN" ] || _INPUT_TOKEN="$_CUR_TOKEN"
    [ -n "$_INPUT_TOKEN" ] || die "Token 不能为空，请从 SubSkiff 网页后台【📡 探针集群】复制密钥。"

    printf "请输入定时心跳上报间隔(秒) [%s]: " "$_CUR_INTERVAL"
    read_input _INPUT_INTERVAL
    [ -n "$_INPUT_INTERVAL" ] || _INPUT_INTERVAL="$_CUR_INTERVAL"

    printf "是否在节点变更时自动同步到轻舟? (y/n) [%s]: " "$([ "$_CUR_AUTO" = "true" ] && echo "y" || echo "n")"
    read_input _INPUT_AUTO
    case "$_INPUT_AUTO" in
        n|N|no|No|false) _SET_AUTO="false" ;;
        *) _SET_AUTO="true" ;;
    esac

    _MY_MID=$(get_local_machine_id)
    _MY_HOST=$(get_local_hostname)

    cat << EOF_JSON > "$_AGENT_CFG"
{
  "server_url": "${_INPUT_URL%/}",
  "node_token": "$_INPUT_TOKEN",
  "machine_id": "$_MY_MID",
  "hostname": "$_MY_HOST",
  "node_source": "$INFO_FILE",
  "report_interval_sec": $_INPUT_INTERVAL,
  "auto_sync_on_change": $_SET_AUTO,
  "request_timeout_sec": 5
}
EOF_JSON
    chmod 600 "$_AGENT_CFG"
    echo "✅ 轻舟连接配置已保存至: $_AGENT_CFG"
}

quick_bind_subskiff() {
    _INPUT_URL="$1"
    _INPUT_TOKEN="$2"
    _INPUT_INTERVAL="${3:-300}"
    _AGENT_CFG=$(get_subskiff_cfg)
    _BASE_DIR=$(get_subskiff_dir)

    [ -n "$_INPUT_URL" ] || die "服务端地址不能为空。"
    [ -n "$_INPUT_TOKEN" ] || die "Token 不能为空。"

    _MY_MID=$(get_local_machine_id)
    _MY_HOST=$(get_local_hostname)

    cat << EOF_JSON > "$_AGENT_CFG"
{
  "server_url": "${_INPUT_URL%/}",
  "node_token": "$_INPUT_TOKEN",
  "machine_id": "$_MY_MID",
  "hostname": "$_MY_HOST",
  "node_source": "$INFO_FILE",
  "report_interval_sec": $_INPUT_INTERVAL,
  "auto_sync_on_change": true,
  "request_timeout_sec": 5
}
EOF_JSON
    chmod 600 "$_AGENT_CFG"
    echo "✅ 轻舟连接配置已成功保存！"
    echo "  服务端地址: ${_INPUT_URL%/}"
    echo "  通信 Token: ${_INPUT_TOKEN:0:4}****"
    echo "  机器标识码: $_MY_MID"
    echo "  系统主机名: $_MY_HOST"
    echo "  配置文件: $_AGENT_CFG"

    # 若未安装探针，尝试自动拉取安装
    _AGENT_BIN=$(get_subskiff_bin)
    if [ ! -x "$_AGENT_BIN" ]; then
        echo "[*] 检测到本地尚未安装 subskiff-agent 探针，正在自动拉取部署..."
        install_subskiff_agent_bin || true
    fi

    # 自动配置 Crontab 周期上报
    _INTERVAL_MIN=$((_INPUT_INTERVAL / 60))
    [ "$_INTERVAL_MIN" -lt 1 ] && _INTERVAL_MIN=1
    _CRON_LINE="*/$_INTERVAL_MIN * * * * cd \"$_BASE_DIR\" && ./subskiff-agent >> ./subskiff-agent.log 2>&1"
    crontab -l 2>/dev/null | grep -v 'subskiff-agent' > /tmp/crontab.subskiff.$$ 2>/dev/null || true
    echo "$_CRON_LINE" >> /tmp/crontab.subskiff.$$
    crontab /tmp/crontab.subskiff.$$
    rm -f /tmp/crontab.subskiff.$$
    echo "✅ 已自动启用定时心跳上报 (每 ${_INTERVAL_MIN} 分钟)"

    # 立即执行一次同步测试
    echo "[*] 正在执行首次联通测试并同步节点..."
    run_subskiff_once
}

install_subskiff_agent_bin() {
    _FORCE_UPDATE="${1:-false}"
    _SPEC_VER="${2:-}"
    _AGENT_BIN=$(get_subskiff_bin)
    _BASE_DIR=$(get_subskiff_dir)
    echo "=========================================================="
    echo "      📥 部署/更新 轻舟探针 (Rust 静态 musl 版)           "
    echo "=========================================================="
    _ARCH=$(uname -m)
    case "$_ARCH" in
        x86_64|amd64) _TARGET_ARCH="amd64" ;;
        aarch64|arm64) _TARGET_ARCH="arm64" ;;
        *) die "暂不支持的 CPU 架构: $_ARCH" ;;
    esac

    echo "[*] 检测到系统架构: $_ARCH ($_TARGET_ARCH)"

    # 非强制更新模式下，若本地已存在可执行文件则跳过
    if [ "$_FORCE_UPDATE" != "force" ] && [ -f "$_BASE_DIR/subskiff-agent" ] && [ -s "$_BASE_DIR/subskiff-agent" ]; then
        chmod +x "$_AGENT_BIN"
        _CUR_V=$("$_AGENT_BIN" --version 2>/dev/null || echo "已就绪")
        echo "✅ 本地已存在 subskiff-agent 探针: $_CUR_V"
        return 0
    fi

    _U1=""
    _U2=""
    _U3=""
    _U4=""

    # 智能解析拉取模式 (自适应: 自定义直链 / 动态最新 latest / 指定版本号如 0.3.0 或 v0.3.0)
    case "$_SPEC_VER" in
        http://*|https://*)
            echo "[*] 检测到自定义直链 URL: $_SPEC_VER"
            _U1="$_SPEC_VER"
            ;;
        ""|latest|main|master)
            echo "[*] 采用默认策略: 动态拉取 GitHub Releases 最新版 (latest)"
            _U1="https://github.com/jojhaa/ldnat/releases/latest/download/subskiff-agent-linux-${_TARGET_ARCH}"
            _U2="https://github.com/jojhaa/ldnat/releases/latest/download/subskiff-agent"
            _U3="https://fastly.jsdelivr.net/gh/jojhaa/ldnat@main/subskiff-agent"
            ;;
        *)
            _CLEAN_V=$(printf '%s' "$_SPEC_VER" | sed 's/^[vV]//')
            echo "[*] 锁定拉取指定版本: v${_CLEAN_V}"
            _U1="https://github.com/jojhaa/ldnat/releases/download/v${_CLEAN_V}/subskiff-agent-linux-${_TARGET_ARCH}"
            _U2="https://github.com/jojhaa/ldnat/releases/download/${_CLEAN_V}/subskiff-agent-linux-${_TARGET_ARCH}"
            _U3="https://github.com/jojhaa/ldnat/releases/download/v${_CLEAN_V}/subskiff-agent"
            _U4="https://github.com/jojhaa/ldnat/releases/download/${_CLEAN_V}/subskiff-agent"
            ;;
    esac

    _SUCCESS=false
    echo "[*] 正在从云端下载探针内核..."
    for _U in "$_U1" "$_U2" "$_U3" "$_U4"; do
        [ -z "$_U" ] && continue
        echo "  尝试拉取: $_U"
        if curl -fksSL --connect-timeout 8 --max-time 60 --retry 1 -o "$_AGENT_BIN.tmp" "$_U"; then
            if [ -s "$_AGENT_BIN.tmp" ] && [ $(wc -c < "$_AGENT_BIN.tmp") -ge 500000 ]; then
                _SUCCESS=true
                break
            fi
        fi
        rm -f "$_AGENT_BIN.tmp"
    done

    if [ "$_SUCCESS" = true ]; then
        mv -f "$_AGENT_BIN.tmp" "$_AGENT_BIN"
        chmod +x "$_AGENT_BIN"
        _NEW_V=$("$_AGENT_BIN" --version 2>/dev/null || echo "已就绪")
        echo "✅ subskiff-agent 探针二进制已成功就绪并赋权！($_NEW_V)"
        return 0
    else
        rm -f "$_AGENT_BIN.tmp"
        warn "❌ 探针内核下载校验失败，已保留原文件，请检查版本号、直链或网络连通性。"
        return 1
    fi
}

toggle_subskiff_cron() {
    _BASE_DIR=$(get_subskiff_dir)
    _AGENT_BIN=$(get_subskiff_bin)
    _AGENT_CFG=$(get_subskiff_cfg)

    [ -x "$_AGENT_BIN" ] || { warn "subskiff-agent 未安装，请先执行安装选项。"; return 1; }
    [ -f "$_AGENT_CFG" ] || { warn "尚未配置轻舟连接信息，请先执行绑定配置。"; return 1; }

    _INTERVAL_MIN=5
    if command -v jq >/dev/null 2>&1; then
        _SEC=$(jq -r '.report_interval_sec // 300' "$_AGENT_CFG" 2>/dev/null || echo "300")
        _INTERVAL_MIN=$((_SEC / 60))
        [ "$_INTERVAL_MIN" -lt 1 ] && _INTERVAL_MIN=1
    fi

    _CRON_LINE="*/$_INTERVAL_MIN * * * * cd \"$_BASE_DIR\" && ./subskiff-agent >> ./subskiff-agent.log 2>&1"

    _HAS_CRON=false
    if crontab -l 2>/dev/null | grep -q 'subskiff-agent'; then
        _HAS_CRON=true
    fi

    echo "=========================================================="
    echo "      ⏰ 轻舟探针定时上报任务管理                         "
    echo "=========================================================="
    if [ "$_HAS_CRON" = true ]; then
        echo "当前状态: [已开启]"
        crontab -l 2>/dev/null | grep 'subskiff-agent' || true
        printf "是否关闭定时上报任务? (y/n) [n]: "
        read_input _RM_CRON
        case "$_RM_CRON" in
            y|Y|yes|Yes)
                crontab -l 2>/dev/null | grep -v 'subskiff-agent' | crontab -
                echo "✅ 定时任务已移除。"
                ;;
            *)
                echo "保持原样。"
                ;;
        esac
    else
        echo "当前状态: [未开启]"
        printf "是否开启定时上报任务(每 %s 分钟执行一次)? (y/n) [y]: " "$_INTERVAL_MIN"
        read_input _ADD_CRON
        case "$_ADD_CRON" in
            n|N|no|No)
                echo "操作已取消。"
                ;;
            *)
                ( crontab -l 2>/dev/null | grep -v 'subskiff-agent' ; echo "$_CRON_LINE" ) | crontab -
                echo "✅ 定时任务已成功添加至 Crontab: $_CRON_LINE"
                ;;
        esac
    fi
}

run_subskiff_once() {
    _AGENT_BIN=$(get_subskiff_bin)
    _AGENT_CFG=$(get_subskiff_cfg)
    [ -x "$_AGENT_BIN" ] || { warn "subskiff-agent 未安装，请先执行安装选项。"; return 1; }
    [ -f "$_AGENT_CFG" ] || { warn "尚未配置轻舟连接信息，请先执行绑定配置。"; return 1; }

    echo "=========================================================="
    echo "      🚀 正在执行轻舟前台立即同步                         "
    echo "=========================================================="
    "$_AGENT_BIN" --once
    echo "=========================================================="
}

view_subskiff_status() {
    _BASE_DIR=$(get_subskiff_dir)
    _AGENT_BIN=$(get_subskiff_bin)
    _AGENT_CFG=$(get_subskiff_cfg)
    _LOG_FILE="$_BASE_DIR/subskiff-agent.log"

    clear 2>/dev/null || true
    echo "=========================================================="
    echo "      📊 轻舟端侧探针运行状态                             "
    echo "=========================================================="
    echo "所在目录: $_BASE_DIR"
    if [ -x "$_AGENT_BIN" ]; then
        _VER=$("$_AGENT_BIN" --version 2>/dev/null || echo "已就绪")
        echo "二进制程序: [已安装] ($_VER)"
    else
        echo "二进制程序: [未安装]"
    fi

    if [ -f "$_AGENT_CFG" ]; then
        if command -v jq >/dev/null 2>&1; then
            _U=$(jq -r '.server_url // empty' "$_AGENT_CFG")
            _T=$(jq -r '.node_token // .token // empty' "$_AGENT_CFG")
            _A=$(jq -r '.auto_sync_on_change // true' "$_AGENT_CFG")
            echo "服务端地址: $_U"
            echo "节点 Token: ${_T:0:6}******"
            echo "变更自动同步: $_A"
        else
            _U=$(grep -oE '"server_url"[[:space:]]*:[[:space:]]*"[^"]+"' "$_AGENT_CFG" 2>/dev/null | head -n1 | cut -d'"' -f4 || true)
            echo "配置文件: [已就绪] ($_AGENT_CFG)"
            [ -n "$_U" ] && echo "服务端地址: $_U"
        fi
    else
        echo "配置文件: [未配置]"
    fi

    if crontab -l 2>/dev/null | grep -q 'subskiff-agent'; then
        echo "定时任务: [已启动]"
        crontab -l 2>/dev/null | grep 'subskiff-agent'
    else
        echo "定时任务: [未启动]"
    fi

    echo "----------------------------------------------------------"
    echo "最近上报日志 (末尾 15 行):"
    if [ -f "$_LOG_FILE" ]; then
        tail -n 15 "$_LOG_FILE"
    else
        echo "(暂无日志)"
    fi
    echo "=========================================================="
}

manage_subskiff_menu() {
    while true; do
        clear 2>/dev/null || true
        _AGENT_BIN=$(get_subskiff_bin)
        _AGENT_VER="未安装"
        if [ -x "$_AGENT_BIN" ]; then
            _AGENT_VER=$("$_AGENT_BIN" --version 2>/dev/null || echo "已就绪")
        fi
        echo "=========================================================="
        echo "   📡 LDNAT - 轻舟云端协同与探针管理 [内核: ${_AGENT_VER}]"
        echo "=========================================================="
        echo "  1. 绑定/修改 轻舟服务端连接 (URL 与 Node Token)"
        echo "  2. 部署/更新 轻舟探针 (Rust 静态 musl 二进制)"
        echo "  3. 开启/停用 周期心跳与状态上报 (Crontab)"
        echo "  4. 立即同步一次节点到轻舟 (前台回显)"
        echo "  5. 查看当前探针运行状态与日志"
        echo "  0. 返回上级主菜单 (支持按 q)"
        echo "=========================================================="
        printf "请输入对应数字 [0-5 或 q]: "
        read_input _S_CHOICE

        case "$_S_CHOICE" in
            1)
                configure_subskiff
                printf "\n按回车键继续..."
                read_input _
                ;;
            2)
                echo ""
                printf "👉 请输入版本号 (如 0.3.0 或 v0.3.0)、直链 URL\n   [直接回车默认拉取最新 Release]: "
                read_input _P_VER
                install_subskiff_agent_bin force "$_P_VER"
                printf "\n按回车键继续..."
                read_input _
                ;;
            3)
                toggle_subskiff_cron
                printf "\n按回车键继续..."
                read_input _
                ;;
            4)
                run_subskiff_once
                printf "\n按回车键继续..."
                read_input _
                ;;
            5)
                view_subskiff_status
                printf "\n按回车键继续..."
                read_input _
                ;;
            0|q|Q)
                break
                ;;
            *)
                echo "⚠️ 输入无效，请重新选择。"
                sleep 1
                ;;
        esac
    done
}

# ==================== 模块 8: LDNAT 工具箱与探针更新中心 ====================

update_ldnat_script() {
    _SPEC_VER="${1:-}"
    _REAL_PATH=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    if [ ! -f "$_REAL_PATH" ]; then
        _REAL_PATH="/usr/local/bin/ldnat"
    fi

    echo "=========================================================="
    echo "      🔄 更新 ldnat.sh 脚本自身                           "
    echo "=========================================================="
    echo "  当前脚本版本: $LDNAT_VERSION"
    echo "  本地目标路径: $_REAL_PATH"

    _U1=""
    _U2=""
    _U3=""
    _U4=""

    case "$_SPEC_VER" in
        http://*|https://*)
            echo "[*] 检测到自定义脚本直链 URL: $_SPEC_VER"
            _U1="$_SPEC_VER"
            ;;
        ""|latest|main|master)
            echo "[*] 采用默认策略: 动态拉取 GitHub main/latest 最新脚本"
            _U1="https://raw.githubusercontent.com/jojhaa/ldnat/main/ldnat.sh"
            _U2="https://github.com/jojhaa/ldnat/releases/latest/download/ldnat.sh"
            _U3="https://fastly.jsdelivr.net/gh/jojhaa/ldnat@main/ldnat.sh"
            ;;
        *)
            _CLEAN_V=$(printf '%s' "$_SPEC_VER" | sed 's/^[vV]//')
            echo "[*] 锁定拉取指定版本: v${_CLEAN_V}"
            _U1="https://github.com/jojhaa/ldnat/releases/download/v${_CLEAN_V}/ldnat.sh"
            _U2="https://raw.githubusercontent.com/jojhaa/ldnat/v${_CLEAN_V}/ldnat.sh"
            _U3="https://fastly.jsdelivr.net/gh/jojhaa/ldnat@v${_CLEAN_V}/ldnat.sh"
            _U4="https://raw.githubusercontent.com/jojhaa/ldnat/${_CLEAN_V}/ldnat.sh"
            ;;
    esac

    _TMP_FILE="/tmp/ldnat_new.$$.sh"
    rm -f "$_TMP_FILE"
    _SUCCESS=false

    echo "[*] 正在从云端拉取脚本代码..."
    for _U in "$_U1" "$_U2" "$_U3" "$_U4"; do
        [ -z "$_U" ] && continue
        echo "  尝试拉取: $_U"
        if curl -fksSL --connect-timeout 8 --max-time 60 --retry 1 -o "$_TMP_FILE" "$_U"; then
            if [ -s "$_TMP_FILE" ] && [ $(wc -c < "$_TMP_FILE") -ge 20000 ] && grep -q 'register_command' "$_TMP_FILE"; then
                if sh -n "$_TMP_FILE" 2>/dev/null; then
                    _SUCCESS=true
                    break
                fi
            fi
        fi
        rm -f "$_TMP_FILE"
    done

    if [ "$_SUCCESS" = true ]; then
        cp -f "$_REAL_PATH" "${_REAL_PATH}.bak" 2>/dev/null || true
        mv -f "$_TMP_FILE" "$_REAL_PATH"
        chmod +x "$_REAL_PATH"
        mkdir -p /usr/local/bin
        if [ "$_REAL_PATH" != "/usr/local/bin/ldnat" ]; then
            ln -sf "$_REAL_PATH" /usr/local/bin/ldnat
        fi
        _NEW_VER=$(grep -m1 '^LDNAT_VERSION=' "$_REAL_PATH" 2>/dev/null | cut -d'"' -f2 || echo "最新版")
        echo "=========================================================="
        echo "🎉 ldnat.sh 脚本已成功更新至: $_NEW_VER"
        echo "=========================================================="
        return 0
    else
        rm -f "$_TMP_FILE"
        warn "❌ 脚本拉取校验失败，已保留原本地文件，请检查版本号、直链或网络连通性。"
        return 1
    fi
}

update_all_components() {
    _SPEC_VER="${1:-}"
    echo "=========================================================="
    echo "      🚀 执行一键全量更新 (探针内核 + ldnat.sh 脚本)       "
    echo "=========================================================="
    
    echo "[1/2] 正在更新 subskiff-agent 轻舟探针..."
    install_subskiff_agent_bin force "$_SPEC_VER" || true
    echo ""

    echo "[2/2] 正在更新 ldnat.sh 脚本自身..."
    if update_ldnat_script "$_SPEC_VER"; then
        _REAL_PATH=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
        [ -f "$_REAL_PATH" ] || _REAL_PATH="/usr/local/bin/ldnat"
        echo "[*] 正在平滑无缝重载工具箱..."
        sleep 1
        exec "$_REAL_PATH"
    fi
}

manage_update_menu() {
    while true; do
        clear 2>/dev/null || true
        _REAL_PATH=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
        _AGENT_BIN=$(get_subskiff_bin)
        _AGENT_VER="未安装"
        if [ -x "$_AGENT_BIN" ]; then
            _AGENT_VER=$("$_AGENT_BIN" --version 2>/dev/null || echo "已就绪")
        fi
        echo "=========================================================="
        echo "      🔄 LDNAT 工具箱与探针组件更新中心                   "
        echo "=========================================================="
        echo "  当前脚本版本: ${LDNAT_VERSION} (${_REAL_PATH})"
        echo "  当前探针内核: ${_AGENT_VER} (${_AGENT_BIN})"
        echo ""
        echo "  1. 🚀 一键全量更新 (同时更新 ldnat.sh 脚本 + 轻舟探针内核) [默认推荐]"
        echo "  2. 仅更新 ldnat.sh 脚本自身"
        echo "  3. 仅更新 subskiff-agent 轻舟探针内核"
        echo "  0. 返回上级主菜单 (支持按 q)"
        echo "=========================================================="
        printf "请输入选项 [0-3 或 q, 回车默认 1]: "
        read_input _U_CHOICE
        [ -z "$_U_CHOICE" ] && _U_CHOICE="1"

        case "$_U_CHOICE" in
            0|q|Q)
                break
                ;;
            1)
                echo ""
                printf "👉 请输入目标版本号 (如 0.3.0 或 v0.3.0) 或直链 URL\n   [直接回车默认拉取最新 latest/main]: "
                read_input _USER_VER
                update_all_components "$_USER_VER"
                ;;
            2)
                echo ""
                printf "👉 请输入目标版本号 (如 0.3.0 或 v0.3.0) 或直链 URL\n   [直接回车默认拉取最新 main/latest]: "
                read_input _USER_VER
                if update_ldnat_script "$_USER_VER"; then
                    _REAL_PATH=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
                    [ -f "$_REAL_PATH" ] || _REAL_PATH="/usr/local/bin/ldnat"
                    echo "[*] 正在平滑无缝重载工具箱..."
                    sleep 1
                    exec "$_REAL_PATH"
                fi
                printf "\n按回车键继续..."
                read_input _
                ;;
            3)
                echo ""
                printf "👉 请输入目标版本号 (如 0.3.0 或 v0.3.0) 或直链 URL\n   [直接回车默认拉取最新 Release]: "
                read_input _USER_VER
                install_subskiff_agent_bin force "$_USER_VER"
                printf "\n按回车键继续..."
                read_input _
                ;;
            *)
                echo "⚠️ 输入无效，请重新选择。"
                sleep 1
                ;;
        esac
    done
}


# ==================== 命令行路由分支 ====================

# 0. 版本查询分支 (-v / --version / version)
if [ "${1:-}" = "-v" ] || [ "${1:-}" = "--version" ] || [ "${1:-}" = "version" ]; then
    echo "=========================================================="
    echo "  🚀 LDNAT 工具箱版本: $LDNAT_VERSION"
    _AGENT_BIN=$(get_subskiff_bin 2>/dev/null || echo "/usr/local/subskiff/subskiff-agent")
    if [ -x "$_AGENT_BIN" ]; then
        _AGENT_VER=$("$_AGENT_BIN" --version 2>/dev/null || echo "未知版本")
        echo "  📡 轻舟端侧探针版本: $_AGENT_VER"
    else
        echo "  📡 轻舟端侧探针版本: [未安装]"
    fi
    echo "=========================================================="
    exit 0
fi

# 1. 节点多端口与全协议管理分支
if [ "${1:-}" = "node" ] || [ "${1:-}" = "nodes" ]; then
    shift
    SUBCMD="${1:-}"
    case "$SUBCMD" in
        list|ls)
            list_node_rules
            exit 0
            ;;
        add)
            shift
            add_node_rule "$@"
            exit 0
            ;;
        del|rm|delete)
            delete_node_rule "${2:-}"
            exit 0
            ;;
        links|link|qr|export)
            show_node_links
            exit 0
            ;;
        restart)
            rc-service sing-box restart
            exit 0
            ;;
        shield)
            shift
            case "${1:-}" in
                on|enable)
                    mkdir -p /etc/sing-box
                    printf 'on\n' > "$ABUSE_CONF"
                    echo "🛡️ 安全审计护盾已【开启】。"
                    sync_singbox_config
                    exit 0
                    ;;
                off|disable)
                    mkdir -p /etc/sing-box
                    printf 'off\n' > "$ABUSE_CONF"
                    echo "🛡️ 安全审计护盾已【关闭】。"
                    sync_singbox_config
                    exit 0
                    ;;
                *)
                    toggle_abuse_block
                    exit 0
                    ;;
            esac
            ;;
        "")
            manage_nodes_menu
            exit 0
            ;;
        *)
            die "未知节点子命令: $SUBCMD (可用: list, add, del, links, shield, restart, stop)"
            ;;
    esac
fi

# 2. 安全审计与防滥用护盾分支
if [ "${1:-}" = "shield" ]; then
    shift
    case "${1:-}" in
        on|enable)
            mkdir -p /etc/sing-box
            printf 'on\n' > "$ABUSE_CONF"
            echo "🛡️ 安全审计护盾已【开启】。"
            sync_singbox_config
            exit 0
            ;;
        off|disable)
            mkdir -p /etc/sing-box
            printf 'off\n' > "$ABUSE_CONF"
            echo "🛡️ 安全审计护盾已【关闭】。"
            sync_singbox_config
            exit 0
            ;;
        *)
            toggle_abuse_block
            exit 0
            ;;
    esac
fi

# 2. 单独部署 DDNS 分支
if [ "${1:-}" = "ddns" ]; then
    shift
    [ "$#" -le 3 ] || die 'ddns 最多接受域名、Zone ID、API Token 三个参数。'
    install_ddns_module "${1:-}" "${2:-}" "${3:-}"
    exit 0
fi

# 3. Realm 多端口转发分支
if [ "${1:-}" = "realm" ]; then
    shift
    SUBCMD="${1:-}"
    case "$SUBCMD" in
        add)
            shift
            add_realm_rule "${1:-}" "${2:-}"
            exit 0
            ;;
        del|rm)
            shift
            delete_realm_rule "${1:-}"
            exit 0
            ;;
        list|ls)
            list_realm_rules
            exit 0
            ;;
        restart)
            rc-service realm restart
            exit 0
            ;;
        stop)
            rc-service realm stop
            exit 0
            ;;
        "")
            manage_realm_menu
            exit 0
            ;;
        *)
            # 兼容旧语法: ldnat realm <本地端口> <目标:端口>
            add_realm_rule "$SUBCMD" "${2:-}"
            exit 0
            ;;
    esac
fi

# 4. BBR 调优分支
if [ "${1:-}" = "bbr" ] || [ "${1:-}" = "tcp" ]; then
    shift
    optimize_tcp_bbr "${1:-}"
    exit 0
fi

# 5. 诊断命令分支
if [ "${1:-}" = "status" ] || [ "${1:-}" = "check" ] || [ "${1:-}" = "diag" ]; then
    diagnose_network
    exit 0
fi

# 6. 查看信息分支
if [ "${1:-}" = "info" ] || [ "${1:-}" = "view" ]; then
    view_node_info
    exit 0
fi

# 7. 轻舟端侧协同分支 (SubSkiff)
if [ "${1:-}" = "agent" ] || [ "${1:-}" = "subskiff" ]; then
    shift
    _SUBCMD="${1:-}"
    case "$_SUBCMD" in
        sync|push|once)
            run_subskiff_once
            exit 0
            ;;
        update|upgrade)
            install_subskiff_agent_bin force
            exit 0
            ;;
        config|bind)
            shift
            if [ "$#" -ge 2 ]; then
                quick_bind_subskiff "$1" "$2" "${3:-300}"
            else
                configure_subskiff
            fi
            exit 0
            ;;
        cron|status)
            view_subskiff_status
            exit 0
            ;;
        "")
            manage_subskiff_menu
            exit 0
            ;;
        *)
            if [ -n "$_SUBCMD" ] && [ -n "${2:-}" ]; then
                # 支持一键静默: ldnat subskiff <URL> <TOKEN> [INTERVAL]
                quick_bind_subskiff "$_SUBCMD" "$2" "${3:-300}"
                exit 0
            else
                manage_subskiff_menu
                exit 0
            fi
            ;;
    esac
fi

if [ "${1:-}" = "sync" ]; then
    run_subskiff_once
    exit 0
fi

# 7.5. 全能更新中心分支 (update/upgrade)
if [ "${1:-}" = "update" ] || [ "${1:-}" = "upgrade" ]; then
    shift
    _TARGET_SUB="${1:-}"
    case "$_TARGET_SUB" in
        script)
            shift
            update_ldnat_script "${1:-}"
            exit 0
            ;;
        agent|subskiff)
            shift
            install_subskiff_agent_bin force "${1:-}"
            exit 0
            ;;
        *)
            # 支持 ldnat update [version] 全量更新
            update_all_components "$_TARGET_SUB"
            exit 0
            ;;
    esac
fi

# 8. 传参模式 (Flag 传参 - 兼容旧版参数)
IS_FLAG=false
DDNS_ONLY=false
while [ $# -gt 0 ]; do
    case "$1" in
        -r|--reality) require_option_value "$@"; PORT_REALITY="$2"; IS_FLAG=true; shift 2 ;;
        -s|--ss)      require_option_value "$@"; PORT_SS="$2"; IS_FLAG=true; shift 2 ;;
        -d|--domain)  require_option_value "$@"; NODE_DOMAIN="$2"; IS_FLAG=true; shift 2 ;;
        -z|--zone)    require_option_value "$@"; CF_ZONE_ID="$2"; IS_FLAG=true; shift 2 ;;
        -t|--token)   require_option_value "$@"; CF_TOKEN="$2"; IS_FLAG=true; shift 2 ;;
        --sni)        require_option_value "$@"; SNI="$2"; SNI_SPECIFIED=true; IS_FLAG=true; shift 2 ;;
        --ddns-only)  DDNS_ONLY=true; IS_FLAG=true; shift ;;
        -h|--help)    show_help; exit 0 ;;
        *) die '未知参数，请使用 --help 查看用法。' ;;
    esac
done

if [ "$DDNS_ONLY" = true ]; then
    [ -z "$PORT_REALITY$PORT_SS" ] || die '--ddns-only 不能与节点端口参数同时使用。'
    install_ddns_module "$NODE_DOMAIN" "$CF_ZONE_ID" "$CF_TOKEN"
    exit 0
fi

if [ "$IS_FLAG" = "true" ]; then
    CLI_MODE=""
    if [ -n "$PORT_REALITY" ] && [ -n "$PORT_SS" ]; then
        CLI_MODE="all"
    elif [ -n "$PORT_REALITY" ]; then
        CLI_MODE="reality"
    elif [ -n "$PORT_SS" ]; then
        CLI_MODE="ss"
    else
        die '请至少指定一个端口参数 (-r 或 -s)。'
    fi

    if [ -n "$CF_ZONE_ID$CF_TOKEN" ]; then
        [ -n "$CF_ZONE_ID" ] && [ -n "$CF_TOKEN" ] || die 'Zone ID 与 API Token 必须一起提供。'
    fi

    install_singbox_module "$CLI_MODE" "$PORT_REALITY" "$PORT_SS" "$NODE_DOMAIN"
    if [ -n "$CF_ZONE_ID" ] && [ -n "$CF_TOKEN" ]; then
        install_ddns_module "$NODE_DOMAIN" "$CF_ZONE_ID" "$CF_TOKEN"
    fi
    exit 0
fi

# 9. 纯交互主菜单 (直接敲 ldnat，常驻循环避免子菜单返回闪退)
while true; do
    clear 2>/dev/null || true
    echo "=========================================================="
    echo "   🚀 LDNAT - Alpine 落地与中转全能工具箱 (${LDNAT_VERSION})"
    echo "=========================================================="
    echo "  1. 节点多端口与全协议服务管理 (REALITY/SS/AnyTLS/Hy2/TUIC/Trojan)"
    echo "  2. Realm 高性能多端口转发管理 (增/删/查/改/启停)"
    echo "  3. 部署/更新 Cloudflare DDNS 动态域名"
    echo "  4. 系统 TCP 与 BBR 深度网络调优 (支持 10M~5000M 自适应)"
    echo "  5. 查看当前所有配置、转发规则与二维码 (支持 A+B 导出)"
    echo "  6. 快速网络与服务健康诊断"
    echo "  7. 轻舟云端协同与探针管理 (SubSkiff Agent)"
    echo "  8. 🔄 检查与更新系统组件 (支持 ldnat.sh 与轻舟探针同时更新)"
    echo "  0. 退出运行 (支持按 q)"
    echo "=========================================================="
    printf "请输入对应数字 [0-8 或 q]: "
    read_input CHOICE

    case "$CHOICE" in
        1)
            manage_nodes_menu
            ;;
        2)
            manage_realm_menu
            ;;
        3)
            install_ddns_module "" "" ""
            ;;
        4)
            optimize_tcp_bbr ""
            ;;
        5)
            view_node_info
            ;;
        6)
            diagnose_network
            ;;
        7)
            manage_subskiff_menu
            ;;
        8)
            manage_update_menu
            ;;
        0|q|Q|exit)
            echo "感谢使用 LDNAT 工具箱，已退出运行。"
            exit 0
            ;;
        *)
            echo "⚠️ 输入无效，请重新输入 [0-8 或 q]..."
            sleep 1
            ;;
    esac
done
