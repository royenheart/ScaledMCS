# 完全避免S3的方案 - 分片式用户数据

locals {
  proxy_user_data_minimal = base64encode(<<-EOF
#!/bin/bash
exec > >(tee /var/log/user-data.log) 2>&1
WEB_PORT=${var.mcsmanager.web_port}
DAEMON_PORT=${var.mcsmanager.daemon_port}
HTTPS_WEB_PORT=443
HTTPS_DAEMON_PORT=8443
DOMAIN_NAME="${var.domain_name != "" ? var.domain_name : "$(curl -s ifconfig.me)"}"

# 1. Configure basic env
yum install -y yum-utils
yum-config-manager --add-repo https://openresty.org/package/amazon/openresty.repo
curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
yum install -y wget unzip git htop vim nginx python3 python3-pip jq dnsutils nodejs pcre-devel openssl-devel gcc openresty openresty-resty postgresql15-server postgresql15-contrib

# 2. Install MCSM
useradd -m -s /bin/bash mcsmanager || true
wget -qO- https://script.mcsmanager.com/setup.sh | bash
if [ -f /opt/mcsmanager/web/data/SystemConfig/config.json ]; then
  cp /opt/mcsmanager/web/data/SystemConfig/config.json /opt/mcsmanager/web/data/SystemConfig/config.json.bak
  
  # Use jq to change http ip
  jq ".httpPort = $WEB_PORT | .httpIp = \"0.0.0.0\"" /opt/mcsmanager/web/data/SystemConfig/config.json.bak | tee /opt/mcsmanager/web/data/SystemConfig/config.json > /dev/null
fi
systemctl restart mcsm-web.service
systemctl restart mcsm-daemon.service

# 3. 配置PostgreSQL
postgresql-setup --initdb
systemctl enable --now postgresql

# 配置PostgreSQL允许内网连接
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /var/lib/pgsql/data/postgresql.conf
echo "host    all             all             10.0.0.0/8             md5" >> /var/lib/pgsql/data/pg_hba.conf
echo "host    all             all             172.16.0.0/12          md5" >> /var/lib/pgsql/data/pg_hba.conf
echo "host    all             all             192.168.0.0/16         md5" >> /var/lib/pgsql/data/pg_hba.conf

# 创建MC监控数据库和用户
sudo -u postgres psql << 'POSTGRES_EOF'
CREATE DATABASE mc_monitor;
CREATE USER mc_user WITH PASSWORD 'mc_monitor_2024!';
GRANT ALL PRIVILEGES ON DATABASE mc_monitor TO mc_user;
\q
POSTGRES_EOF

# 创建节点信息表
sudo -u postgres psql -d mc_monitor << 'CREATE_TABLE_EOF'
CREATE TABLE IF NOT EXISTS mc_nodes (
    instance_id VARCHAR(50) PRIMARY KEY,
    server_name VARCHAR(100) NOT NULL,
    private_ip INET NOT NULL,
    daemon_port INTEGER NOT NULL,
    daemon_key VARCHAR(200) NOT NULL,
    availability_zone VARCHAR(50),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 创建更新时间触发器
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_mc_nodes_updated_at BEFORE UPDATE
    ON mc_nodes FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- 授权给mc_user
GRANT ALL PRIVILEGES ON TABLE mc_nodes TO mc_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO mc_user;
\q
CREATE_TABLE_EOF

systemctl restart postgresql

# 3. 获取实际域名或IP地址
if [ -z "${var.domain_name}" ]; then
  ACTUAL_DOMAIN=$(curl -s ifconfig.me)
  USE_HTTPS=false
else
  ACTUAL_DOMAIN="${var.domain_name}"
  USE_HTTPS=true
fi

# 下载MC监控系统
git clone https://github.com/royenheart/ScaledMCS.git /tmp/ScaledMCS
cp -r /tmp/ScaledMCS/openresty /opt/

# 创建必要目录
mkdir -p /usr/local/openresty/nginx/logs
mkdir -p /var/log/openresty

# 创建配置文件，动态替换变量
sed "s/\$${var.mcsmanager.web_port}/$WEB_PORT/g; s/\$${var.mcsmanager.daemon_port}/$DAEMON_PORT/g" \
    /opt/openresty/conf/nginx.conf > /usr/local/openresty/nginx/conf/nginx.conf

# 复制Daemon代理端口配置文件
cp /opt/openresty/conf/daemon_proxy_ports.conf /usr/local/openresty/nginx/conf/daemon_proxy_ports.conf

# 创建OpenResty服务
tee /etc/systemd/system/openresty.service > /dev/null << 'OPENRESTY_SERVICE_EOF'
[Unit]
Description=OpenResty Web Platform Based MC Monitor
After=network.target remote-fs.target nss-lookup.target mcsm-web.service
Wants=mcsm-web.service

[Service]
Type=forking
PIDFile=/usr/local/openresty/nginx/logs/nginx.pid
ExecStartPre=/usr/local/openresty/bin/openresty -t
ExecStart=/usr/local/openresty/bin/openresty
ExecReload=/bin/kill -s HUP $MAINPID
ExecStop=/bin/kill -s QUIT $MAINPID

[Install]
WantedBy=multi-user.target
OPENRESTY_SERVICE_EOF

# 启用 OpenResty
systemctl enable --now openresty

# 下载 lua-resty-http 组件
git clone https://github.com/pintsized/lua-resty-http /tmp/lua-resty-http
cp /tmp/lua-resty-http/lib/resty/http* /usr/local/openresty/lualib/resty

echo "OpenResty监控系统正在启动..."
echo "配置界面URL: http://$ACTUAL_DOMAIN:9000"
echo "MCSM Web界面: http://$ACTUAL_DOMAIN"

echo "MCSManager 代理服务器初始化完成"
echo "Web Panel HTTP 地址: http://$ACTUAL_DOMAIN"
echo "本地 Daemon HTTP 地址: http://$ACTUAL_DOMAIN:8443"
echo "各 MC 服务器 Daemon HTTP 地址："
${join("\n", [for i, server in var.mc_servers :
    "echo \"  ${server.name}: http://$ACTUAL_DOMAIN:${9000 + i}\""
])}
EOF
)
}

# MC服务器用户数据（分片方式）
locals {
  mc_server_user_data_minimal = { for server in var.mc_servers :
    server.name => base64encode(<<-EOF
#!/bin/bash
exec > >(tee /var/log/user-data.log) 2>&1
SERVER_NAME='${server.name}'
DAEMON_PORT=${var.mcsmanager.daemon_port}
MC_PORT=${server.mc_port}
MEMORY='${server.memory}'
MAX_PLAYERS=${server.max_players}
PROXY_PRIVATE_IP='${aws_instance.proxy.private_ip}'
curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
yum install -y wget unzip git htop vim screen jq java-17-amazon-corretto-devel java-21-amazon-corretto-devel java-11-amazon-corretto-devel java-1.8.0-amazon-corretto-devel nodejs postgresql15
useradd -m -s /bin/bash mcsmanager || true
# 创建minecraft用户，指定固定UID/GID为1001
groupadd -g 1394 minecraft || true
useradd -u 1394 -g 1394 -m -s /bin/bash minecraft || true

# 挂载数据卷
sleep 10
for device in /dev/xvdf /dev/nvme1n1; do
  if [ -b "$device" ]; then
    if ! blkid "$device"; then
      mkfs.ext4 "$device"
    fi
    mkdir -p /mnt/mc-data
    mount "$device" /mnt/mc-data
    UUID=$(blkid -s UUID -o value "$device")
    echo "UUID=$UUID /mnt/mc-data ext4 defaults,nofail 0 2" | tee -a /etc/fstab
    mkdir -p /mnt/mc-data/servers /mnt/mc-data/backups
    chown -R minecraft:minecraft /mnt/mc-data
    break
  fi
done

# Configure mcsm
wget -qO- https://script.mcsmanager.com/setup.sh | bash
if [ -f /opt/mcsmanager/daemon/data/Config.json ]; then
  cp /opt/mcsmanager/daemon/data/Config.json /opt/mcsmanager/daemon/data/Config.json.bak
  
  jq ".httpPort = $DAEMON_PORT | .httpIp = \"0.0.0.0\" | .defaultInstancePath = \"/mnt/mc-data/servers\"" /opt/mcsmanager/daemon/data/Config.json.bak | tee /opt/mcsmanager/daemon/data/Config.json > /dev/null
fi

systemctl enable --now mcsm-daemon.service
systemctl disable --now mcsm-web.service

# 获取当前实例的元数据
# 使用 Instance Metadata Service (IMDS)
# SEE: https://docs.aws.amazon.com/zh_cn/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html
TOKEN=`curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"` \
	&& curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/
INSTANCE_ID=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/local-ipv4)
AVAILABILITY_ZONE=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

# 等待MCSM daemon启动并获取daemon key
while [ ! -f /opt/mcsmanager/daemon/data/Config/global.json ]; do
  echo "等待MCSM daemon配置文件生成..."
  sleep 5
done

DAEMON_KEY=$(jq -r '.key' /opt/mcsmanager/daemon/data/Config/global.json)

# 使用Terraform传递的代理服务器内网IP
PROXY_IP="$PROXY_PRIVATE_IP"
echo "代理服务器内网IP: $PROXY_IP"

for i in {1..10}; do
  echo "尝试连接数据库，第 $i 次..."
  PGPASSWORD='mc_monitor_2024!' psql -h $PROXY_IP -U mc_user -d mc_monitor -c '\q' 2>/dev/null
  if [ $? -eq 0 ]; then
    echo "数据库连接成功，开始写入节点信息..."
    PGPASSWORD='mc_monitor_2024!' psql -h $PROXY_IP -U mc_user -d mc_monitor << PSQL_EOF
INSERT INTO mc_nodes (instance_id, server_name, private_ip, daemon_port, daemon_key, availability_zone)
VALUES ('$INSTANCE_ID', '$SERVER_NAME', '$PRIVATE_IP', $DAEMON_PORT, '$DAEMON_KEY', '$AVAILABILITY_ZONE')
ON CONFLICT (instance_id) DO UPDATE SET
    server_name = EXCLUDED.server_name,
    private_ip = EXCLUDED.private_ip,
    daemon_port = EXCLUDED.daemon_port,
    daemon_key = EXCLUDED.daemon_key,
    availability_zone = EXCLUDED.availability_zone,
    updated_at = CURRENT_TIMESTAMP;
PSQL_EOF
    if [ $? -eq 0 ]; then
      echo "成功将节点信息写入数据库"
      break
    else
      echo "写入数据库失败，将重试..."
    fi
  else
    echo "数据库连接失败，30秒后重试..."
    sleep 30
  fi
  if [ $i -eq 10 ]; then
    echo "警告: 无法连接到数据库，节点信息写入失败"
    echo "请手动检查代理服务器上的PostgreSQL服务状态"
  fi
done

echo "MC服务器 $SERVER_NAME 初始化完成"
echo "Daemon端口: $DAEMON_PORT"
echo "监控程序将在MCSM启动后自动启动"
EOF
    )
  }
}
