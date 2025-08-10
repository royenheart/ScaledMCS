# 输出重要信息

# 网络信息
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "公网子网ID列表"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "私网子网ID列表"
  value       = aws_subnet.private[*].id
}

# 代理服务器信息
output "proxy_server_info" {
  description = "代理服务器信息"
  value = {
    instance_id = aws_instance.proxy.id
    private_ip  = aws_instance.proxy.private_ip
    public_ip   = var.proxy_server.use_elastic_ip ? aws_eip.proxy[0].public_ip : aws_instance.proxy.public_ip
    public_dns  = aws_instance.proxy.public_dns
  }
  sensitive = false
}

# MC服务器信息
output "mc_servers_info" {
  description = "MC服务器信息列表"
  value = {
    for i, server in var.mc_servers : server.name => {
      instance_id      = aws_instance.mc_servers[i].id
      private_ip       = aws_instance.mc_servers[i].private_ip
      server_name      = server.name
      instance_type    = server.instance_type
      data_volume_size = server.data_volume_size
      data_volume_id   = aws_ebs_volume.mc_data[i].id
      mc_port          = server.mc_port
      max_players      = server.max_players
      memory           = server.memory
      auto_start       = server.auto_start
      idle_timeout     = server.idle_timeout
    }
  }
  sensitive = false
}

# MCSManager访问信息
output "mcsmanager_access" {
  description = "MCSManager访问信息"
  value = {
    web_url        = "http://${var.proxy_server.use_elastic_ip ? aws_eip.proxy[0].public_ip : aws_instance.proxy.public_ip}:${var.mcsmanager.web_port}"
    admin_username = "admin"
    web_port       = var.mcsmanager.web_port
    daemon_port    = var.mcsmanager.daemon_port
  }
  sensitive = false
}

# 管理员密码（敏感信息）
# 管理员密码现在通过Web界面初始化，不再由Terraform管理

# SSH连接信息
output "ssh_connections" {
  description = "SSH连接信息"
  value = {
    proxy_server = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${var.proxy_server.use_elastic_ip ? aws_eip.proxy[0].public_ip : aws_instance.proxy.public_ip}"
    mc_servers = {
      for i, server in var.mc_servers : server.name => 
        "ssh -i ~/.ssh/${var.key_name}.pem -o ProxyJump=ubuntu@${var.proxy_server.use_elastic_ip ? aws_eip.proxy[0].public_ip : aws_instance.proxy.public_ip} ubuntu@${aws_instance.mc_servers[i].private_ip}"
    }
  }
  sensitive = false
}

# 安全组ID
output "security_groups" {
  description = "安全组ID"
  value = {
    proxy_sg     = aws_security_group.proxy.id
    mc_server_sg = aws_security_group.mc_server.id
  }
}

# 守护进程连接信息
output "daemon_connections" {
  description = "MCSManager守护进程连接信息"
  value = {
    for i, server in var.mc_servers : server.name => {
      daemon_host = aws_instance.mc_servers[i].private_ip
      daemon_port = var.mcsmanager.daemon_port
      connection_string = "${aws_instance.mc_servers[i].private_ip}:${var.mcsmanager.daemon_port}"
    }
  }
  sensitive = false
}

# MC服务器连接信息
output "minecraft_connections" {
  description = "Minecraft服务器连接信息"
  value = {
    for i, server in var.mc_servers : server.name => {
      connect_host = var.proxy_server.use_elastic_ip ? aws_eip.proxy[0].public_ip : aws_instance.proxy.public_ip
      connect_port = server.mc_port
      connection_string = "${var.proxy_server.use_elastic_ip ? aws_eip.proxy[0].public_ip : aws_instance.proxy.public_ip}:${server.mc_port}"
      server_type = "auto-start"
      idle_timeout_minutes = server.idle_timeout / 60
    }
  }
  sensitive = false
}

# 部署摘要
output "deployment_summary" {
  description = "部署摘要信息"
  value = {
    project_name = var.project_name
    environment = var.environment
    region = var.aws_region
    proxy_server_count = 1
    mc_server_count = length(var.mc_servers)
    total_instances = 1 + length(var.mc_servers)
    vpc_cidr = var.vpc_cidr
    deployment_time = timestamp()
  }
}