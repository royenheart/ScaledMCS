# Proxy server eip
resource "aws_eip" "proxy" {
  count = var.proxy_server.use_elastic_ip ? 1 : 0

  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.project_name}-proxy-eip"
    Type = "Proxy"
  }
}

# 代理服务器实例（MCSManager Web前端）
resource "aws_instance" "proxy" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = var.proxy_server.instance_type
  key_name      = var.key_name
  subnet_id     = aws_subnet.public[0].id

  vpc_security_group_ids = [aws_security_group.proxy.id]
  iam_instance_profile   = aws_iam_instance_profile.proxy_profile.name

  user_data                   = local.proxy_user_data_minimal
  user_data_replace_on_change = true

  root_block_device {
    volume_type = "gp3"
    volume_size = var.proxy_server.volume_size
    encrypted   = true

    tags = {
      Name = "${var.project_name}-proxy-root"
    }
  }

  tags = {
    Name = "${var.project_name}-proxy"
    Type = "Proxy"
    Role = "MCSManager-Web"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 关联弹性IP到代理服务器
resource "aws_eip_association" "proxy" {
  count = var.proxy_server.use_elastic_ip ? 1 : 0

  instance_id   = aws_instance.proxy.id
  allocation_id = aws_eip.proxy[0].id
}

# MC服务器数据卷（独立持久化存储）
resource "aws_ebs_volume" "mc_data" {
  count = length(var.mc_servers)

  availability_zone = aws_subnet.private[count.index % length(aws_subnet.private)].availability_zone
  size              = var.mc_servers[count.index].data_volume_size
  type              = "gp3"
  encrypted         = true

  tags = {
    Name       = "${var.project_name}-${var.mc_servers[count.index].name}-data"
    Type       = "MCData"
    ServerName = var.mc_servers[count.index].name
    MCPort     = var.mc_servers[count.index].mc_port
  }

  lifecycle {
    prevent_destroy = true
  }
}

# MC服务器实例（MCSManager Daemon后端）
resource "aws_instance" "mc_servers" {
  count = length(var.mc_servers)

  ami           = data.aws_ami.amazon_linux.id
  instance_type = var.mc_servers[count.index].instance_type
  key_name      = var.key_name
  subnet_id     = aws_subnet.private[count.index % length(aws_subnet.private)].id

  vpc_security_group_ids = [aws_security_group.mc_server.id]
  iam_instance_profile   = aws_iam_instance_profile.mc_server_profile.name

  user_data                   = local.mc_server_user_data_minimal[var.mc_servers[count.index].name]
  user_data_replace_on_change = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 20 # 系统盘固定20GB
    encrypted   = true

    tags = {
      Name = "${var.project_name}-${var.mc_servers[count.index].name}-root"
    }
  }

  tags = {
    Name        = "${var.project_name}-${var.mc_servers[count.index].name}"
    Type        = "MCServer"
    Role        = "MCSManager-Daemon"
    ServerName  = var.mc_servers[count.index].name
    MCPort      = var.mc_servers[count.index].mc_port
    AutoStart   = var.mc_servers[count.index].auto_start
    IdleTimeout = var.mc_servers[count.index].idle_timeout
    MaxPlayers  = var.mc_servers[count.index].max_players
    Memory      = var.mc_servers[count.index].memory
  }

  lifecycle {
    ignore_changes = [
      # 忽略这些变化，避免实例重建
      ami
    ]
  }
}

# 挂载数据卷到MC服务器
resource "aws_volume_attachment" "mc_data" {
  count = length(var.mc_servers)

  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.mc_data[count.index].id
  instance_id = aws_instance.mc_servers[count.index].id

  # 强制分离，避免停止实例时出现问题
  force_detach = true
}

# 代理服务器IAM角色（需要管理EC2实例）
resource "aws_iam_role" "proxy_role" {
  name = "${var.project_name}-proxy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-proxy-role"
  }
}

# 代理服务器IAM策略（EC2管理权限）
resource "aws_iam_role_policy" "proxy_policy" {
  name = "${var.project_name}-proxy-policy"
  role = aws_iam_role.proxy_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumeStatus"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "logs:PutLogEvents",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssm:SendCommand",
          "ssm:ListCommands",
          "ssm:ListCommandInvocations",
          "ssm:DescribeInstanceInformation",
          "ssm:GetCommandInvocation"
        ]
        Resource = "*"
      }
    ]
  })
}

# 代理服务器IAM实例配置文件
resource "aws_iam_instance_profile" "proxy_profile" {
  name = "${var.project_name}-proxy-profile"
  role = aws_iam_role.proxy_role.name
}

# MC服务器IAM角色（基础权限）
resource "aws_iam_role" "mc_server_role" {
  name = "${var.project_name}-mc-server-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-mc-server-role"
  }
}

# MC服务器IAM策略（基础监控权限）
resource "aws_iam_role_policy" "mc_server_policy" {
  name = "${var.project_name}-mc-server-policy"
  role = aws_iam_role.mc_server_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "logs:PutLogEvents",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssm:SendCommand",
          "ssm:ListCommands",
          "ssm:ListCommandInvocations",
          "ssm:DescribeInstanceInformation",
          "ssm:GetCommandInvocation"
        ]
        Resource = "*"
      }
    ]
  })
}

# MC服务器IAM实例配置文件
resource "aws_iam_instance_profile" "mc_server_profile" {
  name = "${var.project_name}-mc-server-profile"
  role = aws_iam_role.mc_server_role.name
}
