#!/bin/bash
# MC服务器自动化部署脚本

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查必要工具
check_requirements() {
    log_info "检查必要工具..."
    
    local missing_tools=()
    
    if ! command -v terraform &> /dev/null; then
        missing_tools+=("terraform")
    fi
    
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws-cli")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "缺少必要工具: ${missing_tools[*]}"
        log_info "请安装以下工具："
        for tool in "${missing_tools[@]}"; do
            case $tool in
                "terraform")
                    echo "  - Terraform: https://www.terraform.io/downloads.html"
                    ;;
                "aws-cli")
                    echo "  - AWS CLI: https://aws.amazon.com/cli/"
                    ;;
            esac
        done
        exit 1
    fi
    
    log_success "所有必要工具已安装"
}

# 检查AWS凭证
check_aws_credentials() {
    log_info "检查AWS凭证..."
    
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS凭证未配置或无效"
        log_info "请运行: aws configure"
        exit 1
    fi
    
    local aws_identity=$(aws sts get-caller-identity --output text --query 'Account')
    log_success "AWS凭证有效，账户ID: $aws_identity"
}

# 检查配置文件
check_config() {
    log_info "检查配置文件..."
    
    if [ ! -f "terraform.tfvars" ]; then
        if [ -f "terraform.tfvars.example" ]; then
            log_warning "terraform.tfvars 不存在，使用示例文件创建"
            cp terraform.tfvars.example terraform.tfvars
            log_info "请编辑 terraform.tfvars 文件并配置您的参数"
            exit 1
        else
            log_error "配置文件不存在"
            exit 1
        fi
    fi
    
    log_success "配置文件检查完成"
}

# 初始化Terraform
terraform_init() {
    log_info "初始化Terraform..."
    
    terraform init
    
    if [ $? -eq 0 ]; then
        log_success "Terraform初始化完成"
    else
        log_error "Terraform初始化失败"
        exit 1
    fi
}

# 验证Terraform配置
terraform_validate() {
    log_info "验证Terraform配置..."
    
    terraform validate
    
    if [ $? -eq 0 ]; then
        log_success "Terraform配置验证通过"
    else
        log_error "Terraform配置验证失败"
        exit 1
    fi
}

# 显示部署计划
terraform_plan() {
    log_info "生成Terraform部署计划..."
    
    terraform plan -out=tfplan
    
    if [ $? -eq 0 ]; then
        log_success "Terraform计划生成完成"
        return 0
    else
        log_error "Terraform计划生成失败"
        exit 1
    fi
}

# 执行部署
terraform_apply() {
    log_info "开始部署基础设施..."
    
    terraform apply tfplan
    
    if [ $? -eq 0 ]; then
        log_success "基础设施部署完成"
        return 0
    else
        log_error "基础设施部署失败"
        exit 1
    fi
}

# 配置MCSM API Key
configure_mcsm_api() {
    log_info "配置MCSM API Key..."
    
    local web_access=$(terraform output -raw mcsmanager_access 2>/dev/null || echo "")
    local proxy_ip=$(terraform output -raw proxy_server_ip 2>/dev/null || echo "")
    local config_web_url="http://${proxy_ip}:9000"
    
    echo ""
    echo "==============================================="
    echo "          MCSM API 配置设置"
    echo "==============================================="
    echo ""
    echo "🚀 OpenResty高性能监控系统已启动！"
    echo ""
    echo "📋 请按照以下步骤完成配置："
    echo ""
    echo "1️⃣  打开MCSManager Web管理界面创建管理员账户："
    echo "   🔗 $web_access"
    echo ""
    echo "2️⃣  生成API Key："
    echo "   登录 → 用户中心 → API密钥 → 生成新的API密钥"
    echo ""
    echo "3️⃣  打开监控系统配置界面并输入API Key："
    echo "   🔗 $config_web_url"
    echo ""
    echo "4️⃣  系统将自动扫描并注册所有MC服务器节点"
    echo ""
    echo "💡 新架构优势："
    echo "   - 🚀 OpenResty + Lua 高性能架构"
    echo "   - 📁 共享存储自动发现节点"
    echo "   - 🔄 无需复杂的程序间通信"
    echo "   - 🎯 单一监控服务，简化运维"
    echo ""
    echo "⚠️  重要：所有MC服务器会自动将节点信息写入共享存储"
    echo ""
    
    # 等待用户确认
    echo "请完成Web界面配置后，按回车键继续..."
    read -r
    
    log_success "配置流程已完成，监控系统已准备就绪"
}

# 显示部署结果
show_results() {
    log_info "获取部署结果..."
    
    echo ""
    echo "==============================================="
    echo "           MC服务器部署完成"
    echo "==============================================="
    
    # 获取输出信息
    local web_access=$(terraform output -raw mcsmanager_access 2>/dev/null || echo "")
    local proxy_ip=$(terraform output -raw proxy_server_ip 2>/dev/null || echo "")
    
    echo "🌐 MCSManager Web管理界面:"
    echo "   访问方式: $web_access"
    echo ""
    
    echo "🖥️  服务器信息:"
    echo "   代理服务器IP: $proxy_ip"
    
    # 显示MC服务器信息
    local mc_servers=$(terraform output -json mc_servers_info 2>/dev/null || echo "[]")
    echo "   MC服务器信息：$mc_servers"
    
    echo ""
    echo "🔗 SSH连接命令:"
    echo "   代理服务器: ssh -i ~/.ssh/mc-deployment-key ubuntu@$proxy_ip"
    
    # 显示守护进程连接信息
    echo ""
    echo "🔧 智能监控功能:"
    echo "   ✅ 自动服务器启停管理"
    echo "   ✅ 玩家在线监控"
    echo "   ✅ Nginx动态代理配置"
    echo "   ✅ MCSM节点自动注册"
    
    echo ""
    echo "==============================================="
    echo "基础设施部署完成！正在配置智能监控系统..."
    echo "==============================================="
}

# 清理函数
cleanup() {
    log_info "清理临时文件..."
    rm -f tfplan
}

# 销毁基础设施
destroy_infrastructure() {
    log_warning "开始销毁基础设施..."
    
    read -p "确定要销毁所有资源吗？这将删除所有服务器和数据！(yes/no): " confirm
    
    if [ "$confirm" = "yes" ]; then
        terraform destroy -auto-approve
        
        if [ $? -eq 0 ]; then
            log_success "基础设施销毁完成"
        else
            log_error "基础设施销毁失败"
            exit 1
        fi
    else
        log_info "取消销毁操作"
    fi
}

# 显示帮助信息
show_help() {
    echo "MC服务器自动化部署工具"
    echo ""
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  deploy     部署基础设施"
    echo "  plan       显示部署计划"
    echo "  destroy    销毁基础设施"
    echo "  output     显示部署输出信息"
    echo "  validate   验证配置"
    echo "  help       显示此帮助信息"
    echo ""
    echo "示例:"
    echo "  $0 deploy      # 部署完整的MC服务器环境"
    echo "  $0 plan        # 查看将要创建的资源"
    echo "  $0 destroy     # 销毁所有资源"
}

# 主函数
main() {
    local command=${1:-deploy}
    
    case $command in
        "deploy")
            check_requirements
            check_aws_credentials
            check_config
            terraform_init
            terraform_validate
            terraform_plan
            terraform_apply
            show_results
            configure_mcsm_api
            
            echo ""
            echo "==============================================="
            echo "          🎉 部署完全完成！"
            echo "==============================================="
            echo ""
            echo "您的MC服务器智能部署系统已经启动并运行！"
            echo ""
            echo "🔥 核心功能："
            echo "   • 🚀 OpenResty高性能架构：Lua脚本直接处理"
            echo "   • 📁 共享存储发现：自动识别所有MC服务器"
            echo "   • 🔄 智能监控：实时玩家数量检测"
            echo "   • 💰 自动启停：无人时关闭节约成本"
            echo "   • 🎯 单一服务：简化运维管理"
            echo ""
            echo "🌐 重要提醒："
            echo "   请访问监控配置界面完成API Key设置："
            local proxy_ip=$(terraform output -raw proxy_server_ip 2>/dev/null || echo "")
            echo "   🔗 http://${proxy_ip}:9000"
            echo ""
            echo "📊 系统监控："
            echo "   OpenResty日志: tail -f /usr/local/openresty/nginx/logs/error.log"
            echo "   访问日志: tail -f /usr/local/openresty/nginx/logs/access.log"
            echo "   共享存储: cat /mnt/mc-shared/nodes.json"
            echo ""
            echo "Happy Gaming! 🎮"
            ;;
        "plan")
            check_requirements
            check_aws_credentials
            check_config
            terraform_init
            terraform_validate
            terraform_plan
            ;;
        "destroy")
            check_requirements
            check_aws_credentials
            destroy_infrastructure
            ;;
        "output")
            terraform output
            ;;
        "validate")
            check_requirements
            terraform_init
            terraform_validate
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            log_error "未知命令: $command"
            show_help
            exit 1
            ;;
    esac
}

# 设置错误处理
trap cleanup EXIT

# 执行主函数
main "$@"