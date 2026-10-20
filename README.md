# 🚀 LDNAT - 轻量级 Linux 服务器网络转发与系统状态监控套件

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Alpine | Debian | Ubuntu](https://img.shields.io/badge/Platform-Alpine%20%7C%20Linux-green.svg)](https://alpinelinux.org/)
[![Sing-box: 1.14.3](https://img.shields.io/badge/Sing--box-1.14.3-orange.svg)](https://github.com/SagerNet/sing-box)
[![Realm: High Performance](https://img.shields.io/badge/Realm-Proxy-blueviolet.svg)](https://github.com/zhboner/realm)

> **轻舟已过万重山**：面向 **Alpine Linux (BusyBox) 及主流 Linux 系统** 的轻量级网络转发、系统调优与状态监控全能套件。128MB 超低配内存稳定运行，纯 POSIX sh 打造，原生兼容 `x86_64` 与 `aarch64` 架构。

---

## ⚡ 极速一键安装

在任何 Alpine / Debian / Ubuntu VPS 上使用 root 权限执行：

```bash
wget -qO ldnat.sh https://raw.githubusercontent.com/yunyin-boy/ldnat/main/ldnat.sh && chmod +x ldnat.sh && ./ldnat.sh
```

首次运行后脚本会自动软链接至 `/usr/local/bin/ldnat`，此后直接输入 `ldnat` 即可随时唤出控制面板。

---

## 📌 核心特性

- **官方 Sing-box 1.14.3 核心与现代传输架构**：
  - 自动拉取官方 Musl 版核心，遵循现代规范（`action: "sniff"`）；
  - 支持多端口监听、多传输协议安全通道组合。
- **Realm 高性能多端口中继与流量转发**：
  - 基于 Rust 高性能低内存转发内核，支持 TCP 与 UDP 双向高并发中继；
  - 交互式增删查改端口转发规则，OpenRC/Systemd 守护无缝开机自启。
- **轻舟 (SubSkiff Daemon) 系统健康与网络指标守护进程**：
  - 原生内置轻量化 Rust 静态守护进程（`subskiff-daemon`），开箱即用；
  - 自动上报主机健康度、出口网络纯净度及网络指标；
  - 资产采用规范 `.tar.gz` 打包分发，GitHub Actions 云端透明构建。
- **系统 TCP 与 BBR 深度网络调优**：
  - 10M ~ 5000M 13 档带宽自适应匹配，精准配置系统 TCP 拥塞控制与队列；
  - 针对微型容器与小内存环境提供 OOM 防爆内存保护。
- **Cloudflare DDNS 动态域名自动化集成**：
  - 纯 Shell + 系统 Crontab 轻量实现，毫秒级更新 DNS 记录。
- **全自动更新中心 (支持 CLI 与菜单)**：
  - 支持一键全量更新（脚本 + 守护进程同时更新并原地无缝平滑重载）；
  - 支持回车拉取最新、输入版本号拉取或输入自定义直链。

---

## 🖥️ 控制台主菜单

直接在终端输入 `ldnat`：

```text
==========================================================
   🚀 LDNAT - Alpine 落地与中转全能工具箱 (v0.3.0)
==========================================================
  1. 节点多端口与全协议服务管理 (REALITY/SS/AnyTLS/Hy2/TUIC/Trojan)
  2. Realm 高性能多端口转发管理 (增/删/查/改/启停)
  3. 部署/更新 Cloudflare DDNS 动态域名
  4. 系统 TCP 与 BBR 深度网络调优 (支持 10M~5000M 自适应)
  5. 查看当前所有配置、转发规则与二维码 (支持 A+B 导出)
  6. 快速网络与服务健康诊断
  7. 轻舟云端协同与守护进程管理 (SubSkiff Daemon)
  8. 🔄 检查与更新系统组件 (支持 ldnat.sh 与轻舟守护进程同时更新)
  0. 退出运行 (支持按 q)
==========================================================
```

---

## 🔄 命令行快速更新

```bash
# 一键全量更新至最新版 (脚本 + 守护进程)
ldnat update

# 仅更新轻舟守护进程
ldnat update daemon

# 仅更新控制台脚本自身
ldnat update script

# 指定版本号全量更新
ldnat update 0.3.0
```

---

## 📄 开源许可

本项目遵循 [MIT License](LICENSE) 开源协议。
