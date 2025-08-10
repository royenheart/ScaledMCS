# AWS基础变量
variable "aws_region" {
  description = "AWS区域"
  type        = string
  default     = "us-east-1"
}

variable "availability_zones" {
  description = "可用区列表"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

# 项目配置
variable "project_name" {
  description = "项目名称"
  type        = string
  default     = "mc-deploy"
}

variable "environment" {
  description = "环境名称"
  type        = string
  default     = "prod"
}

# 网络配置
variable "vpc_cidr" {
  description = "VPC CIDR块"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "公网子网CIDR列表"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "私网子网CIDR列表"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.20.0/24"]
}

# SSH密钥
variable "key_name" {
  description = "AWS EC2密钥对名称"
  type        = string
}

# 代理服务器配置
variable "proxy_server" {
  description = "代理服务器配置"
  type = object({
    instance_type  = string
    volume_size    = number
    use_elastic_ip = optional(bool, false)
  })
  default = {
    instance_type  = "t3.small"
    volume_size    = 20
    use_elastic_ip = true
  }
}

# MC服务器配置
variable "mc_servers" {
  description = "MC服务器配置列表"
  type = list(object({
    name          = string
    instance_type = string
    data_volume_size = number        # 数据卷大小（持久化）
    mc_port       = number           # MC服务器端口
    max_players   = optional(number, 20)
    memory        = optional(string, "4G")
    auto_start    = optional(bool, true)  # 是否自动启动
    idle_timeout  = optional(number, 1800) # 空闲超时（秒）
  }))
  default = [
    {
      name             = "survival-server"
      instance_type    = "t3.medium"
      data_volume_size = 50
      mc_port          = 25565
      max_players      = 20
      memory           = "4G"
      auto_start       = true
      idle_timeout     = 1800
    }
  ]
}

# MCSManager配置
variable "mcsmanager" {
  description = "MCSManager配置"
  type = object({
    web_port    = number
    daemon_port = number
  })
  default = {
    web_port    = 23333
    daemon_port = 24444
  }
}

# 域名配置
variable "domain_name" {
  description = "代理服务器域名（如果没有域名则使用IP地址）"
  type        = string
  default     = ""
}

# 网络访问配置
variable "allowed_ips" {
  description = "允许访问的IP地址段"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# 通用标签
variable "common_tags" {
  description = "通用资源标签"
  type        = map(string)
  default = {
    Project     = "MC-Deploy"
    Environment = "Production"
    ManagedBy   = "Terraform"
  }
}