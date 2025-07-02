#!/bin/bash
# 函数：检查错误并退出
# 参数 $1: 错误消息
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
    # 使用更强的随机密码生成方式，确保至少包含一个特殊字符
    random_password=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+' | head -c 16)
    # 如果密码为空或太短，重新生成
    while [ ${#random_password} -lt 12 ]; do
        random_password=$(openssl rand -base64 20 | tr -dc 'a-zA-Z0-9!@#$%^&*()_+' | head -c 16)
    done
    
    # 确保 root 用户已启用
    passwd -u root >/dev/null 2>&1
    echo "root:$random_password" | chpasswd
    check_error "生成随机密码时出错"
    echo "$random_password" # 输出密码
}

# 函数：修改 sshd_config 文件（禁用密钥认证，仅允许密码认证）
modify_sshd_config() {
    local config_file="/etc/ssh/sshd_config"
    local custom_config="/etc/ssh/sshd_config.d/password-only.conf"
    
    # 备份原始配置文件
    cp "$config_file" "${config_file}.bak.$(date +%F-%H%M%S)"
    check_error "备份 sshd_config 文件时出错"
    
    # 处理 Ubuntu 24.04 的 Include 配置
    if grep -q "^Include /etc/ssh/sshd_config.d/\*\.conf" "$config_file"; then
        # 创建我们自己的配置文件，优先级更高
        echo "# 由脚本添加的仅密码登录配置" > "$custom_config"
        echo "# 启用 root 登录" >> "$custom_config"
        echo "PermitRootLogin yes" >> "$custom_config"
        echo "" >> "$custom_config"
        echo "# 启用密码认证" >> "$custom_config"
        echo "PasswordAuthentication yes" >> "$custom_config"
        echo "" >> "$custom_config"
        echo "# 禁用公钥认证" >> "$custom_config"
        echo "PubkeyAuthentication no" >> "$custom_config"
        echo "" >> "$custom_config"
        echo "# 禁用其他认证方式" >> "$custom_config"
        echo "ChallengeResponseAuthentication no" >> "$custom_config"
        echo "KerberosAuthentication no" >> "$custom_config"
        echo "GSSAPIAuthentication no" >> "$custom_config"
        echo "" >> "$custom_config"
        echo "# 安全设置" >> "$custom_config"
        echo "PermitEmptyPasswords no" >> "$custom_config"
        echo "MaxAuthTries 3" >> "$custom_config"
        
        check_error "创建自定义配置文件时出错"
        
        # 设置正确的权限
        chmod 644 "$custom_config"
        check_error "设置配置文件权限时出错"
        
    else
        # 如果没有 Include 指令，则直接修改主配置文件
        modify_main_config "$config_file"
    fi
    
    # 处理其他可能覆盖设置的配置文件
    if [ -d "/etc/ssh/sshd_config.d" ]; then
        for conf_file in /etc/ssh/sshd_config.d/*.conf; do
            if [ -f "$conf_file" ] && [ "$conf_file" != "$custom_config" ]; then
                # 注释掉其他文件中可能冲突的配置
                sed -i 's/^PermitRootLogin/# &/' "$conf_file" 2>/dev/null
                sed -i 's/^PasswordAuthentication/# &/' "$conf_file" 2>/dev/null
                sed -i 's/^PubkeyAuthentication/# &/' "$conf_file" 2>/dev/null
                sed -i 's/^ChallengeResponseAuthentication/# &/' "$conf_file" 2>/dev/null
            fi
        done
    fi
}

# 函数：修改主配置文件
modify_main_config() {
    local config_file="$1"
    
    # 定义需要修改的配置项
    declare -A config_settings=(
        ["PermitRootLogin"]="yes"
        ["PasswordAuthentication"]="yes"
        ["PubkeyAuthentication"]="no"
        ["ChallengeResponseAuthentication"]="no"
        ["KerberosAuthentication"]="no"
        ["GSSAPIAuthentication"]="no"
        ["PermitEmptyPasswords"]="no"
        ["MaxAuthTries"]="3"
    )
    
    # 遍历配置项进行修改
    for setting in "${!config_settings[@]}"; do
        local value="${config_settings[$setting]}"
        
        if grep -q "^${setting}" "$config_file"; then
            # 如果配置项存在，则修改
            sed -i "s/^${setting}.*/${setting} ${value}/" "$config_file"
        elif grep -q "^#${setting}" "$config_file"; then
            # 如果配置项被注释，则取消注释并修改
            sed -i "s/^#${setting}.*/${setting} ${value}/" "$config_file"
        else
            # 如果配置项不存在，则添加
            echo "${setting} ${value}" >> "$config_file"
        fi
        check_error "修改 ${setting} 时出错"
    done
}

# 函数：验证 SSH 配置
validate_ssh_config() {
    echo "正在验证 SSH 配置..."
    sshd -t
    if [ $? -eq 0 ]; then
        echo "SSH 配置验证通过"
    else
        echo "SSH 配置验证失败，请检查配置文件"
        exit 1
    fi
}

# 函数：检查并安装 SSH 服务
install_ssh_if_needed() {
    if ! command -v sshd &> /dev/null; then
        echo "检测到 SSH 服务器未安装，正在安装..."
        apt update
        check_error "更新软件包列表时出错"
        apt install -y openssh-server
        check_error "安装 SSH 服务器时出错"
        echo "SSH 服务器安装完成"
    fi
}

# 函数：启动并启用 SSH 服务
start_and_enable_ssh() {
    if command -v systemctl &> /dev/null; then
        # 确定正确的服务名称
        local service_name=""
        if systemctl list-unit-files | grep -q "^ssh.service"; then
            service_name="ssh.service"
        elif systemctl list-unit-files | grep -q "^sshd.service"; then
            service_name="sshd.service"
        else
            echo "未找到 SSH 服务"
            exit 1
        fi
        
        # 启动服务
        systemctl start "$service_name"
        check_error "启动 SSH 服务时出错"
        
        # 启用开机自启
        systemctl enable "$service_name"
        check_error "启用 SSH 服务开机自启时出错"
        
        # 验证服务状态
        if systemctl is-active --quiet "$service_name"; then
            echo "SSH 服务已成功启动并设置为开机自启"
            systemctl status "$service_name" --no-pager -l
        else
            echo "警告: SSH 服务可能未正确启动"
            exit 1
        fi
    else
        # 使用传统的 service 命令
        service ssh start || service sshd start
        check_error "启动 SSH 服务时出错"
        echo "SSH 服务已启动"
    fi
}

# 函数：重启 SSH 服务
restart_ssh_service() {
    echo "正在重启 SSH 服务..."
    
    if command -v systemctl &> /dev/null; then
        if systemctl list-unit-files | grep -q "^ssh.service"; then
            systemctl restart ssh.service
        elif systemctl list-unit-files | grep -q "^sshd.service"; then
            systemctl restart sshd.service
        fi
    else
        service ssh restart || service sshd restart
    fi
    check_error "重启 SSH 服务时出错"
    
    echo "SSH 服务重启完成"
}

# 函数：显示当前网络信息
show_network_info() {
    echo ""
    echo "========== 网络连接信息 =========="
    echo "当前服务器 IP 地址："
    
    # 获取主要网络接口的 IP
    if command -v ip &> /dev/null; then
        ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || echo "无法获取外网 IP"
        echo ""
        echo "所有网络接口："
        ip addr show | grep -E '^[0-9]+:|inet ' | grep -v '127.0.0.1' | grep -v '::1'
    else
        ifconfig 2>/dev/null | grep -E 'inet |inet6 ' | grep -v '127.0.0.1' | grep -v '::1' || echo "无法获取网络信息"
    fi
    
    echo ""
    echo "SSH 端口信息："
    if command -v ss &> /dev/null; then
        ss -tlnp | grep :22 || echo "SSH 服务可能未正确启动"
    else
        netstat -tlnp 2>/dev/null | grep :22 || echo "SSH 服务可能未正确启动"
    fi
    echo "=================================="
}

# 函数：显示安全提醒
show_security_warning() {
    echo ""
    echo "⚠️  ============ 安全提醒 ============ ⚠️"
    echo "1. 此脚本已禁用 SSH 密钥认证，仅允许密码认证"
    echo "2. 已启用 root 用户 SSH 登录"
    echo "3. 请确保使用强密码，并定期更换"
    echo "4. 建议配置防火墙限制 SSH 访问来源"
    echo "5. 建议修改默认 SSH 端口 (22) 以提高安全性"
    echo "6. 请妥善保管 root 密码，避免泄露"
    echo "======================================="
}

# 主函数
main() {
    echo "========== SSH 仅密码登录配置脚本 =========="
    
    # 检查是否为 root 权限
    check_root
    
    # 安装 SSH 服务（如果需要）
    install_ssh_if_needed
    
    # 提示用户选择密码选项
    echo ""
    echo "请选择密码选项："
    echo "1. 自动生成强密码"
    echo "2. 手动输入密码"
    read -p "请输入选项编号 (1 或 2)：" option
    
    case $option in
        1)
            echo "正在生成随机强密码..."
            password=$(generate_random_password)
            echo "随机密码生成完成"
            ;;
        2)
            while true; do
                read -s -p "请输入 root 密码（至少8位）：" custom_password
                echo
                
                # 检查密码长度
                if [ ${#custom_password} -lt 8 ]; then
                    echo "密码长度至少需要8位，请重新输入"
                    continue
                fi
                
                read -s -p "请再次输入密码确认：" confirm_password
                echo
                
                if [ "$custom_password" != "$confirm_password" ]; then
                    echo "两次输入的密码不匹配，请重新输入"
                    continue
                fi
                
                # 确保 root 用户已启用
                passwd -u root >/dev/null 2>&1
                echo "root:$custom_password" | chpasswd
                check_error "修改密码时出错"
                password=$custom_password
                echo "密码设置完成"
                break
            done
            ;;
        *)
            echo "无效选项，退出"
            exit 1
            ;;
    esac
    
    echo ""
    echo "正在配置 SSH 仅密码登录..."
    
    # 修改 SSH 配置（禁用密钥认证）
    modify_sshd_config
    
    # 验证配置
    validate_ssh_config
    
    # 重启 SSH 服务
    restart_ssh_service
    
    # 启动并启用服务
    start_and_enable_ssh
    
    echo ""
    echo "✅ SSH 配置完成！"
    echo ""
    echo "Root 密码: $password"
    
    # 显示网络信息
    show_network_info
    
    # 显示安全提醒
    show_security_warning
    
    echo ""
    echo "现在可以使用以下命令测试 SSH 连接："
    echo "ssh root@<服务器IP地址>"
    echo ""
    echo "配置完成！"
}

# 执行主函数
main "$@"
