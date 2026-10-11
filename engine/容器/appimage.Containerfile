# 打 AppImage 用：Ubuntu 24.04 + squashfs-tools（fedora 主机没有 mksquashfs，也不能 sudo 装）。
# 构建： podman build -t mars-appimage -f engine/容器/appimage.Containerfile engine/容器
FROM docker.io/library/ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends squashfs-tools file desktop-file-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/*
