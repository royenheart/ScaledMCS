# Proxy Server / MCSManager Web security group
resource "aws_security_group" "proxy" {
  name_prefix = "${var.project_name}-proxy-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for proxy server"

  # SSH访问
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ips
    description = "SSH access"
  }

  # MCSManager Web
  ingress {
    from_port   = var.mcsmanager.web_port
    to_port     = var.mcsmanager.web_port
    protocol    = "tcp"
    cidr_blocks = var.allowed_ips
    description = "MCSManager Web interface"
  }

  # MC服务器端口（代理）- 支持配置的所有端口
  dynamic "ingress" {
    for_each = var.mc_servers
    content {
      from_port   = ingress.value.mc_port
      to_port     = ingress.value.mc_port
      protocol    = "tcp"
      cidr_blocks = var.allowed_ips
      description = "Minecraft ${ingress.value.name} server port"
    }
  }

  # HTTP/HTTPS（可选，用于更新和下载）
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
  }

  # MCSManager本地Daemon端口（调试用）
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Local daemon HTTP"
  }

  # MCSManager 本地 Daemon SSL 端口
  ingress {
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Local daemon HTTPS"
  }

  # MCSManager Daemon HTTP 端口（代理 MC 服务器）
  dynamic "ingress" {
    for_each = { for i, server in var.mc_servers : i => server }
    content {
      from_port   = 8000 + ingress.key
      to_port     = 8000 + ingress.key
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "HTTP proxy for ${ingress.value.name} daemon"
    }
  }

  # MCSManager Daemon HTTPS 端口（代理MC服务器）
  dynamic "ingress" {
    for_each = { for i, server in var.mc_servers : i => server }
    content {
      from_port   = 9000 + ingress.key
      to_port     = 9000 + ingress.key
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "HTTPS proxy for ${ingress.value.name} daemon"
    }
  }

  # 出站规则：允许所有
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = {
    Name = "${var.project_name}-proxy-sg"
    Type = "Proxy"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# MC服务器安全组（MCSManager Daemon后端）
resource "aws_security_group" "mc_server" {
  name_prefix = "${var.project_name}-mc-server-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for MC servers (MCSManager Daemon)"

  # SSH访问（仅来自代理服务器）
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.proxy.id]
    description     = "SSH from proxy server"
  }

  # MCSManager Daemon端口（仅来自代理服务器）
  ingress {
    from_port       = var.mcsmanager.daemon_port
    to_port         = var.mcsmanager.daemon_port
    protocol        = "tcp"
    security_groups = [aws_security_group.proxy.id]
    description     = "MCSManager Daemon from proxy"
  }

  # MC服务器端口（仅来自代理服务器）- 支持配置的所有端口
  dynamic "ingress" {
    for_each = var.mc_servers
    content {
      from_port       = ingress.value.mc_port
      to_port         = ingress.value.mc_port
      protocol        = "tcp"
      security_groups = [aws_security_group.proxy.id]
      description     = "Minecraft ${ingress.value.name} server port from proxy"
    }
  }

  # 内网通信（MC服务器之间）
  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    self        = true
    description = "Internal communication between MC servers"
  }

  # UDP端口（MC服务器可能需要）- 支持配置的所有端口
  dynamic "ingress" {
    for_each = var.mc_servers
    content {
      from_port       = ingress.value.mc_port
      to_port         = ingress.value.mc_port
      protocol        = "udp"
      security_groups = [aws_security_group.proxy.id]
      description     = "Minecraft ${ingress.value.name} UDP port from proxy"
    }
  }

  # 出站规则：允许所有
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "All outbound traffic"
  }

  tags = {
    Name = "${var.project_name}-mc-server-sg"
    Type = "MCServer"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# VPC Endpoint安全组（可选，用于私网访问AWS服务）
resource "aws_security_group" "vpc_endpoint" {
  name_prefix = "${var.project_name}-vpc-endpoint-"
  vpc_id      = aws_vpc.main.id
  description = "Security group for VPC endpoints"

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
    description = "HTTPS from VPC"
  }

  tags = {
    Name = "${var.project_name}-vpc-endpoint-sg"
  }

  lifecycle {
    create_before_destroy = true
  }
}
