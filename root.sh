#!/bin/bash
# 函数：检查错误并退出
check_error() {
    if [ $? -ne 0 ]; then
        echo "发生错误： $1"
        exit 1
    fi
}

# 函数：检查是否具有 root 权限
check_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "需要 root 权限来运行此脚本。请使用 sudo 或以 root 用户身份运行。"
        exit 1
    fi
}

# 函数：生成随机密码
generate_random_password() {
    random_password=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+')
    sudo passwd -u root >/dev/null 2>&1
    echo "root:$random_password" | sudo chpasswd
    check_error "生成随机密码时出错"
    echo "$random_password"
}

# 函数：修改 sshd_config 文件
modify_sshd_config() {
    sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F-%H%M%S)
    check_error "备份 sshd_config 文件时出错"

    if grep -q "^Include /etc/ssh/sshd_config.d/\*\.conf" /etc/ssh/sshd_config; then
        echo "# 由脚本添加的 root 登录配置" | sudo tee /etc/ssh/sshd_config.d/root-login.conf > /dev/null
        echo "PermitRootLogin yes" | sudo tee -a /etc/ssh/sshd_config.d/root-login.conf > /dev/null
        echo "PasswordAuthentication yes" | sudo tee -a /etc/ssh/sshd_config.d/root-login.conf > /dev/null
        echo "PubkeyAuthentication no" | sudo tee -a /etc/ssh/sshd_config.d/root-login.conf > /dev/null
        echo "ChallengeResponseAuthentication no" | sudo tee -a /etc/ssh/sshd_config.d/root-login.conf > /dev/null
        check_error "创建自定义配置文件时出错"
    else
        declare -A settings=(
            ["PermitRootLogin"]="yes"
            ["PasswordAuthentication"]="yes"
            ["PubkeyAuthentication"]="no"
            ["ChallengeResponseAuthentication"]="no"
        )
        for key in "${!settings[@]}"; do
            if grep -q "^$key" /etc/ssh/sshd_config; then
                sudo sed -i "s/^$key.*/$key ${settings[$key]}/" /etc/ssh/sshd_config
            else
                echo "$key ${settings[$key]}" | sudo tee -a /etc/ssh/sshd_config > /dev/null
            fi
            check_error "设置 $key 时出错"
        done
    fi

    if [ -d "/etc/ssh/sshd_config.d" ]; then
        for conf_file in /etc/ssh/sshd_config.d/*.conf; do
            if [ -f "$conf_file" ] && [ "$conf_file" != "/etc/ssh/sshd_config.d/root-login.conf" ]; then
                for key in PermitRootLogin PasswordAuthentication PubkeyAuthentication ChallengeResponseAuthentication AuthenticationMethods; do
                    if grep -q "^$key" "$conf_file"; then
                        sudo sed -i "s/^$key/# $key/" "$conf_file"
                        check_error "注释 $key 于 $conf_file 时出错"
                    fi
                done
            fi
        done
    fi
}

# 函数：检查 SSH 服务状态
check_ssh_service() {
    if command -v systemctl &> /dev/null; then
        if ! systemctl is-active --quiet ssh.service && ! systemctl is-active --quiet sshd.service; then
            echo "SSH 服务未运行，正在启动"
            if systemctl list-unit-files | grep -q ssh.service; then
                sudo systemctl start ssh.service
            elif systemctl list-unit-files | grep -q sshd.service; then
                sudo systemctl start sshd.service
            else
                echo "未找到 SSH 服务，尝试安装"
                sudo apt update && sudo apt install -y openssh-server
                check_error "安装 openssh-server 时出错"
            fi
        fi
    else
        if ! service ssh status &> /dev/null && ! service sshd status &> /dev/null; then
            echo "SSH 服务未运行，正在启动..."
            if service --status-all 2>&1 | grep -q " ssh"; then
                sudo service ssh start
            elif service --status-all 2>&1 | grep -q " sshd"; then
                sudo service sshd start
            else
                echo "未找到 SSH 服务，尝试安装"
                sudo apt update && sudo apt install -y openssh-server
                check_error "安装 openssh-server 时出错"
            fi
        fi
    fi
}

# 函数：重启 SSH 服务
restart_ssh_service() {
    check_ssh_service
    if command -v systemctl &> /dev/null; then
        if systemctl list-unit-files | grep -q ssh.service; then
            sudo systemctl restart ssh.service
        elif systemctl list-unit-files | grep -q sshd.service; then
            sudo systemctl restart sshd.service
        fi
    else
        if service --status-all 2>&1 | grep -q " ssh"; then
            sudo service ssh restart
        elif service --status-all 2>&1 | grep -q " sshd"; then
            sudo service sshd restart
        fi
    fi
    check_error "重启 SSH 服务时出错"

    if command -v systemctl &> /dev/null; then
        if systemctl is-active --quiet ssh.service || systemctl is-active --quiet sshd.service; then
            echo "SSH 服务已成功重启"
        else
            echo "警告: SSH 服务可能未正确启动，请手动检查"
        fi
    else
        if service ssh status &> /dev/null || service sshd status &> /dev/null; then
            echo "SSH 服务已成功重启"
        else
            echo "警告: SSH 服务可能未正确启动，请手动检查"
        fi
    fi
}

# 主函数
main() {
    check_root

    if ! command -v sshd &> /dev/null; then
        echo "未检测到 SSH 服务，尝试安装"
        apt update && apt install -y openssh-server
        check_error "安装 SSH 服务时出错"
    fi

    echo "请选择密码选项："
    echo "1. 生成密码"
    echo "2. 输入密码"
    read -p "请输入选项编号：" option

    case $option in
        1)
            password=$(generate_random_password)
            ;;
        2)
            read -s -p "请输入 root 密码：" custom_password
            echo
            read -s -p "请再次输入密码确认：" confirm_password
            echo
            if [ "$custom_password" != "$confirm_password" ]; then
                echo "两次输入的密码不匹配，退出"
                exit 1
            fi
            sudo passwd -u root >/dev/null 2>&1
            echo "root:$custom_password" | sudo chpasswd
            check_error "修改密码时出错"
            password=$custom_password
            ;;
        *)
            echo "无效选项，退出"
            exit 1
            ;;
    esac

    modify_sshd_config
    restart_ssh_service
    echo "✅ root 密码设置为：$password"
}

# 执行主函数
main
