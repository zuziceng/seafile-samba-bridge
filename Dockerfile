FROM debian:13

# 安装依赖（libfuse2t64 用于 AppImage FUSE2 兼容）
RUN sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g' \
    /etc/apt/sources.list 2>/dev/null; \
    sed -i 's|deb.debian.org|mirrors.ustc.edu.cn|g' \
    /etc/apt/sources.list.d/*.sources 2>/dev/null; \
    apt-get update && apt-get install -y \
    wget \
    samba \
    fuse \
    libfuse2t64 \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

# 下载 SeaDrive CLI（Drive Client，非同步客户端）
# 如需更新版本，修改 SEADRIVE_VERSION 即可
ARG SEADRIVE_VERSION=3.0.23
RUN wget -O /opt/seadrive \
    "https://sos-ch-dk-2.exo.io/seafile-downloads/SeaDrive-cli-x86_64-${SEADRIVE_VERSION}.AppImage" \
    && chmod +x /opt/seadrive

# 创建目录
RUN mkdir -p /mnt/seadrive /var/log/samba /etc/samba /var/lib/seadrive

# 复制启动脚本
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 暴露 Samba 端口
EXPOSE 445

ENTRYPOINT ["/entrypoint.sh"]
