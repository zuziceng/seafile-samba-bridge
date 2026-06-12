#!/bin/bash
set -e

# ============================================
# 1. 从环境变量读取配置
# ============================================
SEAFILE_URL=${SEAFILE_URL:-""}
SEAFILE_USERNAME=${SEAFILE_USERNAME:-""}
SEAFILE_PASSWORD=${SEAFILE_PASSWORD:-""}
SEAFILE_TOKEN=${SEAFILE_TOKEN:-""}
SEAFILE_IS_PRO=${SEAFILE_IS_PRO:-"false"}

CACHE_SIZE_LIMIT=${CACHE_SIZE_LIMIT:-"10GB"}
CACHE_CLEAN_INTERVAL=${CACHE_CLEAN_INTERVAL:-"10"}
CACHE_DIR=${CACHE_DIR:-"/dev/shm/seadrive-cache"}

SAMBA_SHARE_NAME=${SAMBA_SHARE_NAME:-"seafile_share"}
SAMBA_USERNAME=${SAMBA_USERNAME:-"seafile_user"}
SAMBA_PASSWORD=${SAMBA_PASSWORD:-""}

CLIENT_NAME=${CLIENT_NAME:-"docker-samba-bridge"}

# ============================================
# 2. 参数校验与 Token 获取
# ============================================
if [ -z "$SEAFILE_URL" ]; then
    echo "ERROR: SEAFILE_URL is required"
    exit 1
fi

if [ -z "$SEAFILE_TOKEN" ]; then
    if [ -z "$SEAFILE_USERNAME" ] || [ -z "$SEAFILE_PASSWORD" ]; then
        echo "ERROR: Either SEAFILE_TOKEN or (SEAFILE_USERNAME + SEAFILE_PASSWORD) is required"
        exit 1
    fi
    
    echo "Fetching token from Seafile server..."
    TOKEN_RESPONSE=$(curl -s -X POST "$SEAFILE_URL/api2/auth-token/" \
        -d "username=$SEAFILE_USERNAME" \
        -d "password=$SEAFILE_PASSWORD")
    
    SEAFILE_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.token')
    
    if [ -z "$SEAFILE_TOKEN" ] || [ "$SEAFILE_TOKEN" = "null" ]; then
        echo "ERROR: Failed to get token. Check your credentials."
        echo "Response: $TOKEN_RESPONSE"
        exit 1
    fi
    echo "Token obtained successfully"
fi

if [ -z "$SAMBA_PASSWORD" ]; then
    echo "ERROR: SAMBA_PASSWORD is required"
    exit 1
fi

# ============================================
# 3. 创建内存盘缓存（tmpfs）
# ============================================
echo "Creating tmpfs for cache at $CACHE_DIR..."
mkdir -p "$CACHE_DIR"
mount -t tmpfs -o size=${CACHE_SIZE_LIMIT} tmpfs "$CACHE_DIR"

# ============================================
# 4. 生成 SeaDrive 配置文件
# ============================================
mkdir -p /etc/seadrive
cat > /etc/seadrive/seadrive.conf <<EOF
[account]
server = $SEAFILE_URL
username = $SEAFILE_USERNAME
token = $SEAFILE_TOKEN
is_pro = $SEAFILE_IS_PRO

[general]
client_name = $CLIENT_NAME

[cache]
size_limit = $CACHE_SIZE_LIMIT
cache_dir = $CACHE_DIR
clean_cache_interval = $CACHE_CLEAN_INTERVAL
EOF

# ============================================
# 5. 启动 SeaDrive
# ============================================
echo "Starting SeaDrive..."
/opt/seadrive/seadrive -c /etc/seadrive/seadrive.conf -f -d /var/lib/seadrive /mnt/seadrive &
SEADRIVE_PID=$!

# 等待 SeaDrive 就绪
sleep 10

# 检查挂载点
if [ ! -d "/mnt/seadrive" ] || [ -z "$(ls -A /mnt/seadrive 2>/dev/null)" ]; then
    echo "Warning: Seadrive mount seems empty. Waiting longer..."
    sleep 15
fi

# ============================================
# 6. 配置 Samba
# ============================================
echo "Configuring Samba..."

useradd -m -s /bin/false "$SAMBA_USERNAME" 2>/dev/null || true
echo "$SAMBA_USERNAME:$SAMBA_PASSWORD" | chpasswd
(echo "$SAMBA_PASSWORD"; echo "$SAMBA_PASSWORD") | smbpasswd -a -s "$SAMBA_USERNAME"

cat > /etc/samba/smb.conf <<EOF
[global]
   workgroup = WORKGROUP
   server string = %h server (Samba)
   security = user
   map to guest = Bad User
   log file = /var/log/samba/log.%m
   max log size = 1000
   socket options = TCP_NODELAY IPTOS_LOWDELAY

[$SAMBA_SHARE_NAME]
   path = /mnt/seadrive
   browseable = yes
   writable = yes
   read only = no
   valid users = $SAMBA_USERNAME
   create mask = 0644
   directory mask = 0755
   force user = $SAMBA_USERNAME
EOF

# ============================================
# 7. 启动 Samba
# ============================================
echo "Starting Samba..."
smbd -F --no-process-group &

# ============================================
# 8. 保持容器运行
# ============================================
echo "========================================="
echo "Seafile-Samba Bridge Started"
echo "========================================="
echo "Seafile Server: $SEAFILE_URL"
echo "Samba Share:    \\\\$(hostname -i)\\${SAMBA_SHARE_NAME}"
echo "Samba User:     $SAMBA_USERNAME"
echo "Cache Location: $CACHE_DIR (tmpfs, limit: $CACHE_SIZE_LIMIT)"
echo "========================================="

wait $SEADRIVE_PID
