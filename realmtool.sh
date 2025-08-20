#!/bin/bash

# =========================================
# 描述: Realm 转发一键管理脚本
# =========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# root权限检查
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行此脚本！${NC}"
    exit 1
fi

# 初始化 realm 安装状态
if [ -f "/root/realm/realm" ]; then
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
    echo "0. 退出脚本"
    echo "================================================="
    echo -e "Realm 状态：${realm_status_color}${realm_status}${NC}"
    echo -n "服务状态："
    check_realm_service_status
}

configure_firewall() {
    local port=$1
    local action=$2

    if command -v ufw >/dev/null 2>&1; then
        [ "$action" = "add" ] && ufw allow $port/tcp || ufw delete allow $port/tcp
    fi
    if command -v iptables >/dev/null 2>&1; then
        [ "$action" = "add" ] && iptables -I INPUT -p tcp --dport $port -j ACCEPT || iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null
    fi
}

# ===================== 主要修复点：自动切换下载源 =====================
download_realm_binary() {
    local file_name=$1
    local url_github="https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz"
    local url_jsdelivr="https://cdn.jsdelivr.net/gh/zhboner/realm@main/realm-x86_64-unknown-linux-gnu.tar.gz"

    echo -e "${GREEN}尝试从 GitHub 下载 Realm...${NC}"
    if wget --no-check-certificate --no-proxy -O "$file_name" "$url_github"; then
        return 0
    else
        echo -e "${RED}从 GitHub 下载失败，尝试使用 jsDelivr 镜像...${NC}"
        if wget --no-check-certificate --no-proxy -O "$file_name" "$url_jsdelivr"; then
            return 0
        else
            echo -e "${RED}下载 Realm 失败，请检查网络或手动下载${NC}"
            return 1
        fi
    fi
}
# ====================================================================

deploy_realm() {
    mkdir -p /root/realm
    cd /root/realm

    echo -e "${GREEN}正在下载 Realm...${NC}"
    if ! download_realm_binary "realm.tar.gz"; then
        echo -e "${RED}Realm 下载失败，安装中止${NC}"
        return
    fi

    tar -xvf realm.tar.gz
    chmod +x realm

    if [ ! -f "/root/realm/config.toml" ]; then
        cat > /root/realm/config.toml <<EOF
[network]
no_tcp = false
use_udp = true

EOF
    else
        if ! grep -q "^\[network\]" /root/realm/config.toml; then
            echo -e "\n[network]\nno_tcp = false\nuse_udp = true" >> /root/realm/config.toml
        fi
    fi

    cat > /etc/systemd/system/realm.service <<EOF
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStart=/root/realm/realm -c /root/realm/config.toml
WorkingDirectory=/root/realm

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 /etc/systemd/system/realm.service
    systemctl daemon-reload
    systemctl enable realm.service

    ln -sf /root/realmtool.sh /usr/local/bin/rt
    chmod +x /usr/local/bin/rt

    realm_status="已安装"
    realm_status_color=$GREEN
    echo -e "${GREEN}Realm 部署完成！可直接运行 rt 打开管理菜单${NC}"
}

uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    rm -rf /root/realm
    rm -f /usr/local/bin/rt
    echo -e "${GREEN}Realm 已卸载${NC}"

    read -p "是否同时删除当前脚本本体？(y/n): " delete_self
    if [[ "$delete_self" =~ ^[Yy]$ ]]; then
        echo "删除脚本：/root/realmtool.sh"
        rm -f /root/realmtool.sh
        exit 0
    fi
}

add_forward() {
    while true; do
        read -p "请输入本地监听端口: " port
        read -p "请输入目标IP或域名: " ip
        read -p "请输入目标端口: " remote_port

        if grep -q "\[::\]:$port" /root/realm/config.toml; then
            echo -e "${RED}端口 $port 的转发规则已存在！${NC}"
            continue
        fi

        echo "[[endpoints]]
listen = \"[::]:$port\"
remote = \"$ip:$remote_port\"" >> /root/realm/config.toml

        configure_firewall $port "add"
        echo -e "${GREEN}添加成功：$port -> $ip:$remote_port${NC}"

        read -p "继续添加下一个？(y/n): " cont
        [[ "$cont" != "y" && "$cont" != "Y" ]] && break
    done

    restart_service
}

delete_forward() {
    echo "当前转发规则："
    local rules=($(grep -n '^\[\[endpoints\]\]' /root/realm/config.toml | cut -d: -f1))
    if [ ${#rules[@]} -eq 0 ]; then
        echo "未发现任何规则"
        return
    fi

    local total=${#rules[@]}
    declare -A start_lines

    for i in "${!rules[@]}"; do
        local start=${rules[$i]}
        local end=$((${rules[$i+1]:-99999} - 1))
        local listen=$(sed -n "$((start+1))p" /root/realm/config.toml | cut -d'"' -f2)
        local remote=$(sed -n "$((start+2))p" /root/realm/config.toml | cut -d'"' -f2)
        echo "$((i+1)). $listen -> $remote"
        start_lines[$((i+1))]=$start
    done

    read -p "请输入要删除的序号（回车返回）：" choice
    [ -z "$choice" ] && return
    if ! [[ $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$total" ]; then
        echo -e "${RED}无效选择${NC}"
        return
    fi

    local start=${start_lines[$choice]}
    local end=$((${rules[$choice]:-99999} - 1))

    sed -i "${start},${end}d" /root/realm/config.toml
    local port=$(echo "$listen" | grep -o '[0-9]\+')
    configure_firewall $port "remove"

    echo -e "${GREEN}已删除规则 #$choice${NC}"
    restart_service
}

restart_service() {
    systemctl daemon-reload
    systemctl restart realm
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Realm 服务已重启${NC}"
    else
        echo -e "${RED}Realm 服务重启失败，请运行：journalctl -u realm${NC}"
    fi
}

start_service() {
    systemctl daemon-reload
    systemctl enable realm
    systemctl start realm
    echo -e "${GREEN}Realm 服务已启动${NC}"
}

stop_service() {
    systemctl stop realm
    echo -e "${GREEN}Realm 服务已停止${NC}"
}

check_and_update_realm_binary() {
    echo -e "${GREEN}正在检查 Realm 最新版本...${NC}"
    cd /root/realm || mkdir -p /root/realm && cd /root/realm
    if ! download_realm_binary "realm_latest.tar.gz"; then
        echo -e "${RED}Realm 下载失败，更新中止${NC}"
        return
    fi
    tar -xvf realm_latest.tar.gz
    chmod +x realm
    echo -e "${GREEN}Realm 可执行文件已更新为最新版本！${NC}"
    restart_service
}

check_and_update_script() {
    echo -e "${GREEN}正在检查脚本更新...${NC}"
    SCRIPT_PATH="/root/realmtool.sh"
    TMP_SCRIPT="/tmp/realmtool_update.sh"
    wget --no-check-certificate --no-proxy -O $TMP_SCRIPT https://raw.githubusercontent.com/LisonChan/realm/main/realmtool.sh
    if [ $? -eq 0 ] && grep -q "Realm 转发一键管理脚本" $TMP_SCRIPT; then
        chmod +x $TMP_SCRIPT
        mv $TMP_SCRIPT $SCRIPT_PATH
        echo -e "${GREEN}脚本已更新，请重新运行 rt${NC}"
        exit 0
    else
        echo -e "${RED}更新失败，保持现有版本${NC}"
        rm -f $TMP_SCRIPT
    fi
}

# 主程序循环
while true; do
    show_menu
    read -p "请选择一个选项 [0-9]: " choice
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
        0) echo -e "${GREEN}退出脚本，再见！${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请输入 0-9${NC}" ;;
    esac
    read -p "按任意键返回菜单..." dummy
done
