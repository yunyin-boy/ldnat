#!/bin/sh
# ==============================================================================
# ⛵ 轻舟 · SubSkiff 分布式节点探针与状态上报客户端 (Shell 极轻版)
# 专为 Alpine Linux (Busybox ash) 及所有标准 Linux 设计，零重型依赖
# ==============================================================================
set -eu

# 1. 严格基于脚本自身物理位置锚定配置文件相对路径 (规避 Crontab 工作目录陷阱)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/config.json" ]; then
    CONFIG_FILE="$SCRIPT_DIR/config.json"
elif [ -f "$SCRIPT_DIR/agent.json" ]; then
    CONFIG_FILE="$SCRIPT_DIR/agent.json"
else
    CONFIG_FILE="$SCRIPT_DIR/config.json"
fi

die() { printf '❌ %s\n' "$*" >&2; exit 1; }
info() { printf 'ℹ️  %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }

# 计算随机休眠秒数 (POSIX 兼容，适配 BusyBox)
calc_random_sleep() {
    MIN="$1"
    MAX="$2"
    if [ "$MIN" -ge "$MAX" ]; then
        echo "$MIN"
    else
        awk -v min="$MIN" -v max="$MAX" 'BEGIN{srand(); print int(min + rand() * (max - min + 1))}'
    fi
}

# 简易 JSON 字段提取函数 (优先使用 jq，若无则优雅降级为 awk)
json_extract() {
    KEY="$1"
    FILE="$2"
    DEFAULT="${3:-}"
    if [ ! -f "$FILE" ]; then
        echo "$DEFAULT"
        return
    fi
    if command -v jq >/dev/null 2>&1; then
        VAL=$(jq -r ".$KEY // empty" "$FILE" 2>/dev/null || true)
        if [ -n "$VAL" ] && [ "$VAL" != "null" ]; then
            echo "$VAL"
            return
        fi
    else
        # POSIX awk 提取基础键值 (支持字符串与数字)
        VAL=$(awk -F'"' -v k="$KEY" '$2 == k {
            for (i=3; i<=NF; i++) {
                if ($i ~ /:[[:space:]]*/) {
                    sub(/^:[[:space:]]*/, "", $i);
                    sub(/^[[:space:]]*"/, "", $(i+1));
                    sub(/".*$/, "", $(i+1));
                    if ($(i+1) != "") { print $(i+1); exit; }
                    # 数字或布尔类型
                    gsub(/[^0-9a-zA-Z_-]/, "", $i);
                    if ($i != "") { print $i; exit; }
                }
            }
        }' "$FILE" 2>/dev/null || true)
        if [ -n "$VAL" ]; then
            echo "$VAL"
            return
        fi
    fi
    echo "$DEFAULT"
}

# 2. 交互式或参数式向导生成 agent.json
init_config() {
    info "正在初始化 SubSkiff 探针配置文件: $CONFIG_FILE"

    S_URL="${1:-}"
    S_TOKEN="${2:-}"
    S_MID="${3:-}"
    S_MODE="${4:-cron}"
    S_MIN="${5:-1800}"
    S_MAX="${6:-3600}"

    if [ -z "$S_URL" ] && [ -t 0 ]; then
        printf "👉 请输入 SubSkiff 服务端地址 (例如 https://sub.yourdomain.com): "
        IFS= read -r S_URL || true
    fi
    [ -n "$S_URL" ] || die "服务端地址不能为空！"
    # 去除末尾斜杠
    S_URL=$(printf '%s' "$S_URL" | sed 's:/*$::')

    if [ -z "$S_TOKEN" ] && [ -t 0 ]; then
        printf "👉 请输入 Agent 上报凭证 Token: "
        IFS= read -r S_TOKEN || true
    fi
    [ -n "$S_TOKEN" ] || die "上报 Token 不能为空！"

    if [ -z "$S_MID" ] && [ -t 0 ]; then
        DEF_MID=$(hostname 2>/dev/null || echo "vps_node")
        printf "👉 请输入当前机器的标识名称 [默认: %s]: " "$DEF_MID"
        IFS= read -r S_MID || true
        [ -n "$S_MID" ] || S_MID="$DEF_MID"
    elif [ -z "$S_MID" ]; then
        S_MID=$(hostname 2>/dev/null || echo "vps_node")
    fi

    cat <<EOF > "$CONFIG_FILE"
{
  "server_url": "$S_URL",
  "token": "$S_TOKEN",
  "machine_id": "$S_MID",
  "hostname": "$S_MID",
  "mode": "$S_MODE",
  "interval_min": $S_MIN,
  "interval_max": $S_MAX,
  "node_info_path": "/root/node_info.txt",
  "enable_ippure": true,
  "enable_cf_trace": true,
  "enable_watchdog": true
}
EOF
    chmod 600 "$CONFIG_FILE"
    info "✅ 配置文件已成功生成于: $CONFIG_FILE"
}

# 3. 核心探测与单次上报流程
do_report() {
    [ -f "$CONFIG_FILE" ] || die "配置文件不存在: $CONFIG_FILE (请先运行 --init 初始化)"

    SERVER_URL=$(json_extract "server_url" "$CONFIG_FILE" "")
    TOKEN=$(json_extract "node_token" "$CONFIG_FILE" "$(json_extract "token" "$CONFIG_FILE" "")")
    MACHINE_ID=$(json_extract "machine_id" "$CONFIG_FILE" "$(hostname 2>/dev/null || echo 'vps')")
    HOSTNAME=$(json_extract "hostname" "$CONFIG_FILE" "$MACHINE_ID")
    MODE=$(json_extract "mode" "$CONFIG_FILE" "cron")
    INTERVAL_MIN=$(json_extract "report_interval_sec" "$CONFIG_FILE" "$(json_extract "interval_min" "$CONFIG_FILE" 300)")
    INTERVAL_MAX=$(json_extract "interval_max" "$CONFIG_FILE" "$INTERVAL_MIN")
    NODE_PATH=$(json_extract "node_source" "$CONFIG_FILE" "$(json_extract "node_info_path" "$CONFIG_FILE" "/root/node_info.txt")")
    ENABLE_IPPURE=$(json_extract "enable_ippure" "$CONFIG_FILE" "true")
    ENABLE_CF=$(json_extract "enable_cf_trace" "$CONFIG_FILE" "true")
    ENABLE_WATCHDOG=$(json_extract "enable_watchdog" "$CONFIG_FILE" "true")

    [ -n "$SERVER_URL" ] || die "配置文件中 server_url 为空"
    [ -n "$TOKEN" ] || die "配置文件中 token 为空"

    # 3.1 巡检 Sing-box 看门狗
    SVC_STATUS="running"
    if [ "$ENABLE_WATCHDOG" = "true" ]; then
        if ! pidof sing-box >/dev/null 2>&1; then
            if command -v rc-service >/dev/null 2>&1; then
                warn "检测到 sing-box 进程丢失，正在触发看门狗拉起..."
                rc-service sing-box restart >/dev/null 2>&1 || true
                SVC_STATUS="restarted_by_watchdog"
            fi
        fi
    fi

    # 3.2 提取本地节点链接 (自 ldnat.sh 生成的文件)
    NODES_JSON="[]"
    if [ -f "$NODE_PATH" ] && [ -s "$NODE_PATH" ]; then
        RAW_URLS=$(grep -E '^(vless|ss|hysteria2|tuic|trojan|anytls)://' "$NODE_PATH" 2>/dev/null || true)
        if [ -n "$RAW_URLS" ]; then
            # 格式化为 JSON 字符串数组
            NODES_JSON=$(echo "$RAW_URLS" | awk 'BEGIN{printf "["} NR>1{printf ","} {gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); printf "\"%s\"", $0} END{printf "]"}')
        fi
    fi

    # 3.3 采集 CPU & 内存负载
    CPU_USAGE="0.0"
    CPU_CORES=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)
    if [ -f /proc/loadavg ]; then
        # 以 1 分钟平均负载折算单核利用率近似值
        ONE_MIN_LOAD=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "0")
        CPU_USAGE=$(awk -v l="$ONE_MIN_LOAD" -v c="$CPU_CORES" 'BEGIN{u=(l/c)*100; if(u>100) u=100; printf "%.1f", u}')
    fi

    MEM_TOTAL="0"
    MEM_AVAIL="0"
    MEM_USED="0"
    if [ -f /proc/meminfo ]; then
        MEM_TOTAL=$(awk '/MemTotal:/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo 0)
        MEM_AVAIL=$(awk '/MemAvailable:/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo 0)
        MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
    fi

    # 3.4 出口画像探测 (Cloudflare Trace + IPPure)
    EGRESS_IP="null"
    COUNTRY_CODE="null"
    COLO="null"

    if [ "$ENABLE_CF" = "true" ]; then
        CF_TRACE=$(curl -fsSL -m 3 https://1.1.1.1/cdn-cgi/trace 2>/dev/null || true)
        if [ -n "$CF_TRACE" ]; then
            C_IP=$(echo "$CF_TRACE" | awk -F'=' '$1=="ip"{print $2}')
            C_LOC=$(echo "$CF_TRACE" | awk -F'=' '$1=="loc"{print $2}')
            C_COLO=$(echo "$CF_TRACE" | awk -F'=' '$1=="colo"{print $2}')
            [ -z "$C_IP" ] || EGRESS_IP="\"$C_IP\""
            [ -z "$C_LOC" ] || COUNTRY_CODE="\"$C_LOC\""
            [ -z "$C_COLO" ] || COLO="\"$C_COLO\""
        fi
    fi

    AS_ORG="null"
    FRAUD_SCORE="null"
    IS_RESIDENTIAL="null"

    if [ "$ENABLE_IPPure" = "true" ] || [ "$ENABLE_IPPURE" = "true" ]; then
        IPPURE_DATA=$(curl -fsSL -m 4 https://my.ippure.com/v1/info 2>/dev/null || true)
        if [ -n "$IPPURE_DATA" ]; then
            if command -v jq >/dev/null 2>&1; then
                P_IP=$(echo "$IPPURE_DATA" | jq -r '.ip // empty' 2>/dev/null || true)
                P_CC=$(echo "$IPPURE_DATA" | jq -r '.countryCode // empty' 2>/dev/null || true)
                P_ORG=$(echo "$IPPURE_DATA" | jq -r '.asOrganization // empty' 2>/dev/null || true)
                P_SCORE=$(echo "$IPPURE_DATA" | jq -r '.fraudScore // empty' 2>/dev/null || true)
                P_RES=$(echo "$IPPURE_DATA" | jq -r '.isResidential // empty' 2>/dev/null || true)

                [ -z "$P_IP" ] || EGRESS_IP="\"$P_IP\""
                [ -z "$P_CC" ] || COUNTRY_CODE="\"$P_CC\""
                [ -z "$P_ORG" ] || AS_ORG="\"$P_ORG\""
                [ -z "$P_SCORE" ] || FRAUD_SCORE="$P_SCORE"
                [ -z "$P_RES" ] || IS_RESIDENTIAL="$P_RES"
            fi
        fi
    fi

    EXPECTED_INTERVAL=$(calc_random_sleep "$INTERVAL_MIN" "$INTERVAL_MAX")

    # 3.5 构造上报 JSON 负载
    PAYLOAD=$(cat <<EOF
{
  "machine_id": "$MACHINE_ID",
  "hostname": "$HOSTNAME",
  "token": "$TOKEN",
  "mode": "$MODE",
  "expected_interval_sec": $EXPECTED_INTERVAL,
  "cpu": {
    "usage_percent": $CPU_USAGE,
    "cores": $CPU_CORES
  },
  "memory": {
    "total_bytes": $MEM_TOTAL,
    "used_bytes": $MEM_USED,
    "available_bytes": $MEM_AVAIL
  },
  "ip_intel": {
    "ip": $EGRESS_IP,
    "country_code": $COUNTRY_CODE,
    "as_org": $AS_ORG,
    "fraud_score": $FRAUD_SCORE,
    "is_residential": $IS_RESIDENTIAL,
    "colo": $COLO
  },
  "nodes": $NODES_JSON,
  "service_status": "$SVC_STATUS"
}
EOF
)

    # 3.6 发起 HTTP POST 请求
    REPORT_URL="${SERVER_URL}/api/agent/report"
    RESP=$(curl -fsSL -X POST "$REPORT_URL" \
        -H "Content-Type: application/json" \
        -H "X-Agent-Token: $TOKEN" \
        -d "$PAYLOAD" 2>&1 || true)

    if echo "$RESP" | grep -q '"success":true'; then
        info "✅ 上报成功！[节点匹配完成，下次建议休眠: ${EXPECTED_INTERVAL}秒]"
    else
        warn "❌ 上报遇到异常，服务端返回: $RESP"
    fi
}

# ==============================================================================
# 入口命令分发
# ==============================================================================
ACTION="${1:-run}"

case "$ACTION" in
    --init|-i|init)
        shift || true
        init_config "${@}"
        do_report
        ;;
    --once|-1|once)
        do_report
        ;;
    run|daemon)
        # 如果尚未配置，则先引导初始化
        if [ ! -f "$CONFIG_FILE" ]; then
            init_config
        fi
        RUN_MODE=$(json_extract "mode" "$CONFIG_FILE" "cron")
        if [ "$RUN_MODE" = "cron" ]; then
            do_report
            exit 0
        fi
        info ">>> 启动 SubSkiff Agent 常驻守护模式 (按 Ctrl+C 退出)..."
        while true; do
            do_report
            I_MIN=$(json_extract "interval_min" "$CONFIG_FILE" 1800)
            I_MAX=$(json_extract "interval_max" "$CONFIG_FILE" 3600)
            SLEEP_SEC=$(calc_random_sleep "$I_MIN" "$I_MAX")
            info "💤 休眠 ${SLEEP_SEC} 秒后进行下一次状态巡检..."
            sleep "$SLEEP_SEC"
        done
        ;;
    *)
        echo "使用方式: $0 [--init | --once | run]"
        echo "  --init  : 初始化生成同级相对目录下的 agent.json"
        echo "  --once  : 仅执行一次上报并立即退出 (适配 Crontab 定时任务，0内存占用)"
        echo "  run     : 后台常驻守护模式，依据 agent.json 随机休眠循环"
        exit 1
        ;;
esac
