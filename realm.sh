#!/bin/bash

# =========================================
# 描述: Realm 转发一键管理脚本
# =========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 版本号
VERSION="1.2"

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
    echo "Realm 转发管理脚本 v$VERSION"
    echo "================================================="
    echo "1. 安装 / 部署 Realm"
    echo "2. 添加转发规则"
    echo "3. 删除转发规则"
    echo "4. 启动服务"
    echo "5. 停止服务"
    echo "6. 重启服务"
    echo "7. 一键卸载"
    echo "8. 更新脚本"
    echo "9. 检查并安装最新版 Realm"
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

deploy_realm() {
    mkdir -p /root/realm
    cd /root/realm

    echo -e "${GREEN}正在下载 Realm...${NC}"
    wget -O realm.tar.gz https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz
    tar -xvf realm.tar.gz
    chmod +x realm

    [ ! -f "/root/realm/config.toml" ] && touch /root/realm/config.toml

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

    realm_status="已安装"
    realm_status_color=$GREEN
    echo -e "${GREEN}Realm 部署完成！${NC}"
}

uninstall_realm() {
    systemctl stop realm
    systemctl disable realm
    rm -f /etc/systemd/system/realm.service
    systemctl daemon-reload
    rm -rf /root/realm
    echo -e "${GREEN}Realm 已卸载${NC}"

    read -p "是否同时删除当前脚本本体？(y/n): " delete_self
    if [[ "$delete_self" =~ ^[Yy]$ ]]; then
        echo "删除脚本：$0"
        rm -- "$0"
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
    local lines=($(grep -n 'listen =' /root/realm/config.toml))
    if [ ${#lines[@]} -eq 0 ]; then
        echo "未发现任何规则"
        return
    fi

    declare -A port_map
    local index=1
    for line in "${lines[@]}"; do
        local port=$(echo "$line" | grep -o '[0-9]\+')
        port_map[$index]=$port
        local lineno=$(echo "$line" | cut -d':' -f1)
        local remote=$(sed -n "$((lineno+1))p" /root/realm/config.toml | cut -d'"' -f2)
        echo "$index. 本地端口 $port -> $remote"
        ((index++))
    done

    read -p "请输入要删除的序号（回车返回）：" choice
    [ -z "$choice" ] && return
    if ! [[ $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -ge "$index" ]; then
        echo -e "${RED}无效选择${NC}"
        return
    fi

    local target_port=${port_map[$choice]}

    awk -v target="listen = \\\"[::]:$target_port\\\"" '
    BEGIN { skip=0 }
    /^\[\[endpoints\]\]/ { block=NR }
    $0 ~ target { skip=1 }
    skip && $0 ~ /^\[\[endpoints\]\]/ && NR!=block { skip=0 }
    !skip { print }
    ' /root/realm/config.toml > /root/realm/config.tmp && mv /root/realm/config.tmp /root/realm/config.toml

    configure_firewall $target_port "remove"
    echo -e "${GREEN}已删除端口 $target_port 的转发规则${NC}"

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

update_script() {
    echo -e "${GREEN}检查脚本更新中...${NC}"
    remote_version=$(curl -s https://raw.githubusercontent.com/LisonChan/realm/refs/heads/main/realm.sh | grep "^VERSION=" | cut -d'"' -f2)

    if [ "$VERSION" = "$remote_version" ]; then
        echo -e "${GREEN}当前已是最新版本 v$VERSION${NC}"
        return
    fi

    echo -e "${GREEN}发现新版本 v$remote_version，是否更新？${NC}"
    read -p "更新脚本？(y/n): " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && return

    wget -O /tmp/realm.sh https://github.com/LisonChan/realm/raw/refs/heads/main/realm.sh
    if [ -s /tmp/realm.sh ]; then
        cp "$0" "$0.backup"
        mv /tmp/realm.sh "$0"
        chmod +x "$0"
        echo -e "${GREEN}脚本已更新为 v$remote_version，原脚本已备份为 $0.backup${NC}"
        exit 0
    else
        echo -e "${RED}更新失败，远程脚本为空或无法下载${NC}"
        rm -f /tmp/realm.sh
    fi
}

check_and_update_realm_binary() {
    echo -e "${GREEN}正在检查 Realm 最新版本...${NC}"
    cd /root/realm || mkdir -p /root/realm && cd /root/realm
    wget -O realm_latest.tar.gz https://gh-proxy.com/https://github.com/zhboner/realm/releases/latest/download/realm-x86_64-unknown-linux-gnu.tar.gz
    tar -xvf realm_latest.tar.gz
    chmod +x realm
    echo -e "${GREEN}Realm 可执行文件已更新为最新版本！${NC}"
    restart_service
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
        8) update_script ;;
        9) check_and_update_realm_binary ;;
        0) echo -e "${GREEN}退出脚本，再见！${NC}"; exit 0 ;;
        *) echo -e "${RED}无效选项，请输入 0-9${NC}" ;;
    esac
    read -p "按任意键返回菜单..." dummy
done
