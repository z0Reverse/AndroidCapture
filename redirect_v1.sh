#!/system/bin/sh
# Android iptables 流量透明转发脚本
# 支持输入数字UID / u0_aXX/u1_aXX用户名自动转换
# 需ROOT，TCP转发至目标IP:8080

TARGET_PORT="8080"
NAT_TABLE="nat"
OUTPUT_CHAIN="OUTPUT"
POST_CHAIN="POSTROUTING"

# 帮助文档
usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] [UID/USERNAME] [TARGET_IP]
支持两种UID输入：数字 或 u0_a23/u1_a100 格式

参数：
  -F                清空nat全部转发规则
  -A TARGET_IP      全局所有APP TCP转发到 TARGET_IP:8080
  -S                查看当前NAT转发规则
  UID/u0_aXX IP     仅转发指定应用流量

示例：
  $(basename "$0") -S
  $(basename "$0") -A 192.168.1.100
  $(basename "$0") 10023 192.168.1.100    # 纯数字UID
  $(basename "$0") u0_a23 192.168.1.100   # u0_a用户名自动转10023
  $(basename "$0") u1_a56 192.168.1.100   # 多用户工作空间
  $(basename "$0") -F
EOF
}

# 错误输出
error_exit() {
    echo "[ERROR] $1" >&2
    exit "$2"
}

# 校验ROOT
check_root() {
    [ "$(id -u)" -ne 0 ] && error_exit "必须ROOT运行" 1
}

# IPv4校验
check_ip() {
    local ip="$1"
    if ! echo "$ip" | grep -E "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$" >/dev/null; then
        error_exit "IP格式非法：$ip" 2
    fi
    for o in $(echo "$ip" | tr '.' ' '); do
        [ "$o" -gt 255 ] || [ "$o" -lt 0 ] && error_exit "IP段越界：$o" 2
    done
}

# 核心：u0_a23 / u1_a99 转数字UID
convert_uid() {
    local input="$1"
    # 纯数字直接返回
    if echo "$input" | grep -E "^[0-9]+$" >/dev/null; then
        echo "$input"
        return 0
    fi
    # 匹配 uX_aYYY 格式
    if echo "$input" | grep -E "^u[0-9]+_a[0-9]+$" >/dev/null; then
        local user_num=$(echo "$input" | cut -d'_' -f1 | sed 's/u//')
        local app_num=$(echo "$input" | cut -d'_' -f2 | sed 's/a//')
        local PER_USER_RANGE=100000
        local app_base=10000
        # 计算公式 userId*100000 + (10000 + app_num)
        local real_uid=$(( user_num * PER_USER_RANGE + app_base + app_num ))
        echo "$real_uid"
        return 0
    fi
    # 格式不匹配
    error_exit "UID格式错误：$input，仅支持数字或u0_aXX/u1_aXX" 3
}

# 检查UID规则是否存在
rule_exists_uid() {
    local uid="$1"
    local dst_ip="$2"
    iptables -t $NAT_TABLE -L $OUTPUT_CHAIN -n | grep "owner UID match $uid" | grep "$dst_ip:$TARGET_PORT" >/dev/null
    return $?
}

# 检查全局规则是否存在
rule_exists_all() {
    local dst_ip="$1"
    iptables -t $NAT_TABLE -L $OUTPUT_CHAIN -n | grep "DNAT.*$dst_ip:$TARGET_PORT" | grep -v "owner" >/dev/null
    return $?
}

# 打印规则
show_rules() {
    echo "==================== 当前NAT转发规则 ===================="
    iptables -t $NAT_TABLE -L $OUTPUT_CHAIN -n --line-numbers
    echo "========================================================"
}

# 主逻辑
main() {
    check_root
    [ $# -eq 0 ] && usage && exit 0

    # 处理选项 -F -S -A
    while getopts "FAS" opt; do
        case "$opt" in
            F)
                echo "[INFO] 清空全部nat转发规则"
                iptables -t $NAT_TABLE -F || error_exit "清空nat失败" 4
                echo "[SUCCESS] 规则已清除"
                exit 0
                ;;
            S)
                show_rules
                exit 0
                ;;
            A)
                shift
                [ $# -ne 1 ] && error_exit "-A 后需跟目标IP，例 $0 -A 192.168.1.100" 5
                local target_ip="$1"
                check_ip "$target_ip"
                if rule_exists_all "$target_ip"; then
                    echo "[WARN] 全局转发规则已存在，无需重复添加"
                    exit 0
                fi
                echo "[INFO] 全局TCP转发 -> $target_ip:$TARGET_PORT"
                iptables -t $NAT_TABLE -F
                iptables -t $NAT_TABLE -A $OUTPUT_CHAIN -p tcp -j DNAT --to-destination "${target_ip}:${TARGET_PORT}" || error_exit "添加DNAT失败" 6
                iptables -t $NAT_TABLE -A $POST_CHAIN -p tcp -j MASQUERADE || error_exit "添加MASQUERADE失败" 6
                echo "[SUCCESS] 全局转发完成"
                exit 0
                ;;
            \?)
                error_exit "无效参数：-$OPTARG" 5
                ;;
        esac
    done

    # 双参数模式：UID/u0_aXX + IP
    if [ $# -eq 2 ]; then
        local raw_uid="$1"
        local target_ip="$2"
        check_ip "$target_ip"
        local real_uid=$(convert_uid "$raw_uid")
        echo "[INFO] 输入标识 $raw_uid 转换为真实UID: $real_uid"

        if rule_exists_uid "$real_uid" "$target_ip"; then
            echo "[WARN] UID:$real_uid 转发规则已存在"
            exit 0
        fi

        echo "[INFO] 配置UID=$real_uid TCP转发 -> $target_ip:$TARGET_PORT"
        iptables -t $NAT_TABLE -A $OUTPUT_CHAIN -p tcp -m owner --uid-owner "$real_uid" \
            -j DNAT --to-destination "${target_ip}:${TARGET_PORT}" || error_exit "DNAT规则添加失败" 7
        iptables -t $NAT_TABLE -A $POST_CHAIN -p tcp -m owner --uid-owner "$real_uid" \
            -j MASQUERADE || error_exit "MASQUERADE添加失败" 7
        echo "[SUCCESS] 应用专属转发配置完成"
        exit 0
    fi

    error_exit "参数数量错误，执行 $0 查看帮助" 5
}

main "$@"