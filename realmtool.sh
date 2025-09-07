#!/bin/bash

# =========================================
# 描述: Realm 转发一键管理脚本（优化版）
# 作者: ChatGPT
# =========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 当前脚本路径
SCRIPT_PATH=$(readlink -f "$0")

# root 权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行此脚本！${NC}"
    exit 1
fi

# Realm 安装状态
REALM_DIR="/root/realm"
REALM_BIN="$REALM_DIR/realm"
REALM_CONF="$REALM_DIR/config.toml"
REALM_SERVICE="/etc/systemd/system/realm.service"

if [ -f "$REALM_BIN" ]; then
    realm_status="已安装"
    realm_status_color=$GREEN
else
    realm_status="未安装"
    realm_status_color=$RED
fi

check_realm_service_status() {
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}启用${NC}"
    else
        echo -e "${RED}未启用${NC}"
    fi
}

# 获取 Realm 最新版本下载链接
get_latest_realm_url() {
    arch=$(uname -m)
    if [[ "$arch" == "x86_64" ]]; then
        pkg="realm-x86_64-unknown-linux-gnu.tar.gz"
    elif [[ "$arch" == "aarch64" ]]; then
        pkg="realm-aarch64-unknown-linux-gnu.tar.gz"
    else
        echo -e "${RED}暂不支持当前架构: $arch${NC}"
        exit 1
    fi

    api_url="https://api.github.com/repos/zhboner/realm/releases/latest"
    latest_url=$(curl -s "$api_url" | grep browser_download_url | grep "$pkg" | head -n1 | cut -d '"' -f4)

    if [ -z "$latest_url" ]; then
        echo "https://github.com/zhboner/realm/releases/latest/download/$pkg"
    else
        echo "$latest_url"
    fi
}

# 下载 Realm 二进制
download_realm_binary() {
    local file_name=$1
    local url=$(get_latest_realm_url)

    echo -e "${GREEN}尝试从：$url${NC}"
    if wget --no-check-certificate --no-proxy -O "$file_name" "$url"; then
        return 0
    else
        echo -e "${RED}Realm 下载失败，请检查网络${NC}"
        return 1
    fi
}

# 部署 Realm
deploy_realm() {
    mkdir -p "$REALM_DIR"
    cd "$REALM_DIR" || exit 1

    echo -e "${GREEN}正在下载 Realm...${NC}"
    if ! download_realm_binary "realm.tar.gz"; then
        echo -e "${RED}Realm 下载失败，安装中止${NC}"
        return
    fi

    rm -f "$REALM_BIN"
    tar -xvf realm.tar.gz
    chown root:root realm
    chmod +x "$REALM_BIN"

    # 如果没有配置文件则创建
    if [ ! -f "$REALM_CONF" ]; then
        cat > "$REALM_CONF" <<EOF
[network]
no_tcp = false
use_udp = true
EOF
    fi

    # 写入 systemd 服务文件
    cat > "$REALM_SERVICE" <<EOF
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
ExecStart=$REALM_BIN -c $REALM_CONF
WorkingDirectory=$REALM_DIR

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 "$REALM_SERVICE"
    systemctl daemon-reload
    systemctl enable realm.service

    ln -sf "$SCRIPT_PATH" /usr/local/bin/rt
    chmod +x /usr/local/bin/rt

    realm_status="已安装"
    realm_status_color=$GREEN
    echo -e "${GREEN}Realm 部署完成！可直接运行 rt 打开管理菜单${NC}"
}

# 卸载 Realm
uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f "$REALM_SERVICE"
    systemctl daemon-reload
    rm -rf "$REALM_DIR"
    rm -f /usr/local/bin/rt
    echo -e "${GREEN}Realm 已卸载${NC}"

    read -p "是否同时删除当前脚本本体？(y/n): " delete_self
    if [[ "$delete_self" =~ ^[Yy]$ ]]; then
        echo "删除脚本：$SCRIPT_PATH"
        rm -f "$SCRIPT_PATH"
        exit 0
    fi
}

# 添加转发规则
add_forward() {
    while true; do
        read -p "请输入本地监听端口: " port
        read -p "请输入目标IP或域名: " ip
        read -p "请输入目标端口: " remote_port

        if grep -q "\[::\]:$port" "$REALM_CONF"; then
            echo -e "${RED}端口 $port 的转发规则已存在！${NC}"
            continue
        fi

        echo "[[endpoints]]
listen = \"[::]:$port\"
remote = \"$ip:$remote_port\"" >> "$REALM_CONF"

        echo -e "${GREEN}添加成功：$port -> $ip:$remote_port${NC}"

        read -p "继续添加下一个？(y/n): " cont
        [[ "$cont" != "y" && "$cont" != "Y" ]] && break
    done

    restart_service
}

# 删除转发规则
delete_forward() {
    echo "当前转发规则："
    local rules=($(grep -n '^\[\[endpoints\]\]' "$REALM_CONF" | cut -d: -f1))
    if [ ${#rules[@]} -eq 0 ]; then
        echo "未发现任何规则"
        return
    fi

    local total=${#rules[@]}
    declare -A start_lines

    for i in "${!rules[@]}"; do
        local start=${rules[$i]}
        local listen=$(sed -n "$((start+1))p" "$REALM_CONF" | cut -d'"' -f2)
        local remote=$(sed -n "$((start+2))p" "$REALM_CONF" | cut -d'"' -f2)
        echo "$((i+1)). $listen -> $remote"
        start_lines[$((i+1))]=$start
    done

    read -p "请输入要删除的序号（回车返回）:" choice
    [ -z "$choice" ] && return
    if ! [[ $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ]; then
        echo -e "${RED}无效选择${NC}"
        return
    fi

    local start=${start_lines[$choice]}
    local end=$((${rules[$choice]:-99999} - 1))

    sed -i "${start},${end}d" "$REALM_CONF"

    echo -e "${GREEN}已删除规则 #$choice${NC}"
    restart_service
}

# 重启 Realm 服务
restart_service() {
    systemctl daemon-reload
    systemctl restart realm
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Realm 服务已重启${NC}"
    else
        echo -e "${RED}Realm 服务重启失败，日志如下：${NC}"
        systemctl status realm --no-pager | tail -n 20
    fi
}

# 启动 Realm 服务
start_service() {
    systemctl daemon-reload
    systemctl enable realm
    systemctl start realm
    echo -e "${GREEN}Realm 服务已启动${NC}"
}

# 停止 Realm 服务
stop_service() {
    systemctl stop realm
    echo -e "${GREEN}Realm 服务已停止${NC}"
}

# 检查并更新 Realm 可执行文件
check_and_update_realm_binary() {
    echo -e "${GREEN}正在检查 Realm 最新版本...${NC}"
    cd "$REALM_DIR" || mkdir -p "$REALM_DIR" && cd "$REALM_DIR"
    if ! download_realm_binary "realm_latest.tar.gz"; then
        echo -e "${RED}Realm 下载失败，更新中止${NC}"
        return
    fi
    rm -f "$REALM_BIN"
    tar -xvf realm_latest.tar.gz
    chown root:root realm
    chmod +x "$REALM_BIN"
    echo -e "${GREEN}Realm 可执行文件已更新为最新版本！${NC}"
    restart_service
}

# 查看 Realm 状态
show_realm_status() {
    echo -e "\n${YELLOW}Realm 状态:${NC}"
    echo "-----------------------------------"
    if [ ! -f "$REALM_BIN" ]; then
        echo "Realm 未安装"
        return
    fi

    echo -n "版本号: "
    "$REALM_BIN" -v 2>/dev/null || echo "未知"

    echo -n "运行状态: "
    if systemctl is-active --quiet realm; then
        echo -e "${GREEN}正在运行${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi

    echo "监听端口: "
    ss -tulnp | grep realm || echo "无监听端口"

    echo "转发规则数量: $(grep -c '^\[\[endpoints\]\]' "$REALM_CONF" 2>/dev/null || echo 0)"
    echo "日志位置: /var/log/realm.log"
    echo "-----------------------------------"
}

# 显示菜单
show_menu() {
    clear
    echo "Realm 转发管理脚本"
    echo "================================================="
    echo "1. 安装 / 部署 Realm"
    echo "2. 添加转发规则"
    echo "3. 删除转发规则"
    echo "4. 启动服务"
    echo "5. 停止服务"
    echo "6. 重启服务"
    echo "7. 一键卸载"
    echo "8. 检查并安装最新版 Realm"
    echo "9. 检查并更新管理脚本"
    echo "10. 查看 Realm 状态"
    echo "0. 退出脚本"
    echo "================================================="
    echo -e "Realm 状态：${realm_status_color}${realm_status}${NC}"
    echo -n "服务状态："
    check_realm_service_status
}

# 主程序循环
while true; do
    show_menu
    read -p "请选择一个选项 [0-10]: " choice
    case $choice in
        1) deploy_realm ;;
        2) add_forward ;;
        3) delete_forward ;;
        4) start_service ;;
        5) stop_service ;;
        6) restart_service ;;
        7) uninstall_realm ;;
        8) check_and_update_realm_binary ;;
        9) check_and_update_script ;;
        10) show_realm_status ;;
        0) echo -e "${GREEN}退出脚本，再见！${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请输入 0-10${NC}" ;;
    esac
    read -p "按任意键返回菜单..." dummy
done
