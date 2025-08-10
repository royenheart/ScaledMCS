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
curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
yum install -y wget unzip git htop vim nginx python3 python3-pip jq dnsutils nodejs pcre-devel openssl-devel gcc

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

# 3. 获取实际域名或IP地址
if [ -z "${var.domain_name}" ]; then
  ACTUAL_DOMAIN=$(curl -s ifconfig.me)
  USE_HTTPS=false
else
  ACTUAL_DOMAIN="${var.domain_name}"
  USE_HTTPS=true
fi

# 4. 安装OpenResty
cd /tmp
wget https://openresty.org/download/openresty-1.21.4.1.tar.gz
tar -xzf openresty-1.21.4.1.tar.gz
cd openresty-1.21.4.1
./configure --with-luajit --with-http_ssl_module --with-http_v2_module --with-stream --with-stream_ssl_module
make && make install
useradd -r -s /sbin/nologin openresty

# 下载MC监控系统
git clone https://github.com/royenheart/Deploy-MC.git /tmp/Deploy-MC
cp -r /tmp/Deploy-MC/openresty /opt/

# 创建必要目录
mkdir -p /mnt/mc-shared
mkdir -p /usr/local/openresty/nginx/logs
mkdir -p /var/log/openresty

# 创建配置文件，动态替换变量
sed "s/\${var.mcsmanager.web_port}/$WEB_PORT/g; s/\${var.mcsmanager.daemon_port}/$DAEMON_PORT/g" \
    /opt/openresty/conf/nginx.conf > /usr/local/openresty/nginx/conf/nginx.conf

# 设置权限
chown -R openresty:openresty /opt/openresty /mnt/mc-shared /usr/local/openresty/nginx/logs /var/log/openresty

# 创建节点信息文件（空文件，等待MC服务器写入）
echo "[]" > /mnt/mc-shared/nodes.json
chown openresty:openresty /mnt/mc-shared/nodes.json

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
User=openresty
Group=openresty

[Install]
WantedBy=multi-user.target
OPENRESTY_SERVICE_EOF

# 启用并启动OpenResty（等MCSM先启动）
systemctl enable openresty

# 创建延迟启动OpenResty的脚本
tee /usr/local/bin/start-openresty.sh > /dev/null << 'START_OPENRESTY_EOF'
#!/bin/bash
while ! curl -s http://localhost:$WEB_PORT > /dev/null; do
  sleep 5
done

echo "MCSM Web服务已启动，现在启动OpenResty..."
systemctl start openresty

if systemctl is-active --quiet openresty; then
  echo "OpenResty启动成功"
else
  echo "OpenResty启动失败，查看日志: journalctl -u openresty"
fi
START_OPENRESTY_EOF

chmod +x /usr/local/bin/start-openresty.sh

# 创建延迟启动服务
tee /etc/systemd/system/openresty-starter.service > /dev/null << 'STARTER_SERVICE_EOF'
[Unit]
Description=Start OpenResty after MCSM is ready
After=mcsm-web.service
Wants=mcsm-web.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/start-openresty.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
STARTER_SERVICE_EOF

systemctl enable --now openresty-starter.service

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
curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
yum install -y wget unzip git htop vim screen jq java-17-amazon-corretto-devel java-21-amazon-corretto-devel java-11-amazon-corretto-devel java-1.8.0-amazon-corretto-devel nodejs
useradd -m -s /bin/bash mcsmanager || true
useradd -m -s /bin/bash minecraft || true

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
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)
AVAILABILITY_ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)

# 等待MCSM daemon启动并获取daemon key
while [ ! -f /opt/mcsmanager/daemon/data/Config/global.json ]; do
  echo "等待MCSM daemon配置文件生成..."
  sleep 5
done

DAEMON_KEY=$(jq -r '.gzip.key' /opt/mcsmanager/daemon/data/Config/global.json)

# 创建节点信息并写入共享存储
mkdir -p /mnt/mc-shared
NODE_INFO=$(cat << NODE_EOF
{
  "instance_id": "$INSTANCE_ID",
  "server_name": "$SERVER_NAME", 
  "private_ip": "$PRIVATE_IP",
  "daemon_port": $DAEMON_PORT,
  "daemon_key": "$DAEMON_KEY",
  "availability_zone": "$AVAILABILITY_ZONE",
  "timestamp": $(date +%s)
}
NODE_EOF
)

# 将节点信息追加到共享存储
SHARED_NODES_FILE="/mnt/mc-shared/nodes.json"

# 创建锁文件以避免并发写入冲突
LOCK_FILE="/mnt/mc-shared/.nodes.lock"
while ! (set -C; echo $$ > "$LOCK_FILE") 2>/dev/null; do
  sleep 1
done

# 读取现有节点信息
if [ -f "$SHARED_NODES_FILE" ] && [ -s "$SHARED_NODES_FILE" ]; then
  EXISTING_NODES=$(cat "$SHARED_NODES_FILE")
else
  EXISTING_NODES="[]"
fi

# 检查是否已存在此实例的信息
UPDATED_NODES=$(echo "$EXISTING_NODES" | jq --argjson new_node "$NODE_INFO" '
  # 移除已存在的同一instance_id的节点
  map(select(.instance_id != $new_node.instance_id)) + [$new_node]
')

# 写入更新后的节点信息
echo "$UPDATED_NODES" > "$SHARED_NODES_FILE"

# 释放锁
rm -f "$LOCK_FILE"

echo "MC服务器 $SERVER_NAME 初始化完成"
echo "Daemon端口: $DAEMON_PORT"
echo "监控程序将在MCSM启动后自动启动"
EOF
    )
  }
}
