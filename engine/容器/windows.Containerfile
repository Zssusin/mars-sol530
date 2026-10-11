# Windows 交叉编译环境：Ubuntu 24.04 + mingw-w64（GCC 13，posix 线程模型）+ scons。
# Godot 官方文档推荐 posix 变体（win32 线程模型缺 std::thread / std::mutex）。
# 构建： podman build -t mars-win-cross -f engine/容器/windows.Containerfile engine/容器
FROM docker.io/library/ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config python3 scons git ca-certificates \
      gcc-mingw-w64-x86-64-posix g++-mingw-w64-x86-64-posix mingw-w64-tools \
 && update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix \
 && update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix \
 && rm -rf /var/lib/apt/lists/*
