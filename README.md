# 🚀 LDNAT - Alpine 落地与中转全能运维套件 (NAT VPS 专属神器)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Alpine Linux](https://img.shields.io/badge/Platform-Alpine%20%7C%20Linux-green.svg)](https://alpinelinux.org/)
[![Sing-box: 1.14.3](https://img.shields.io/badge/Sing--box-1.14.3-orange.svg)](https://github.com/SagerNet/sing-box)
[![Realm: High Performance](https://img.shields.io/badge/Realm-Proxy-blueviolet.svg)](https://github.com/zhboner/realm)

> **轻舟已过万重山**：面向 **Alpine Linux (BusyBox) 及所有 Linux** 的 NAT VPS 落地与中转全能运维脚本。在 128MB 超低配内存下稳定运行，零多余内存开销，原生兼容 `x86_64` 与 `aarch64` 架构。

---

## ⚡ 极速一键安装

在任何 Alpine / Debian / Ubuntu VPS 上使用 root 权限执行：

```bash
wget -qO ldnat.sh https://raw.githubusercontent.com/jojhaa/ldnat/main/ldnat.sh && chmod +x ldnat.sh && ./ldnat.sh
```

首次运行后脚本会自动软链接至 `/usr/local/bin/ldnat`，此后直接输入 `ldnat` 即可随时唤出控制面板。

---

## 📌 核心特性

- **官方 Sing-box 1.14.3 核心与现代规范**：
  - 自动拉取官方 Musl 版 Sing-box 1.14.3，核验 SHA-256 摘要；
  - 遵循现代 Route Action 嗅探机制（`action: "sniff"`），彻底告别旧版入站 legacy 弃用字段。
- **节点多端口与全协议服务管理 (不限端口/自由增删)**：
  - **支持 6 大主流协议自由组合**：
    1. **VLESS-REALITY** (TCP + XTLS-Vision)：直连抗封最强武器，机房智能测速并优选伪装 SNI。
    2. **Shadowsocks** (chacha20-ietf-poly1305 / 2022)：极简轻量中转落地，客户端 100% 完美兼容。
    3. **Hysteria 2** (UDP/QUIC 自适应拥塞控制)：恶劣弱网、跨大洋长链路与高丢包率救星。
    4. **TUIC v5** (UDP/QUIC + 原生 BBR)：极速低延迟、连接并发多路复用。
    5. **Trojan** (TLS 原生加密流)：成熟稳健。
    6. **AnyTLS** (Sing-box 原生 AnyTLS 协议)：提供标准链接与 Sing-box 专用 Outbound。
  - **A+B 节点链接与二维码全能展示**：
    - `[A]` 模式：一键批量输出所有已配置节点的客户端导入链接及终端二维码；
    - `[B]` 模式：单独查看指定序号节点的配置与二维码。
  - **ECC 自签名证书免维护**：自动使用 OpenSSL 生成 10 年长效 P-256 ECC 证书，供 Hy2/TUIC/Trojan/AnyTLS 共享。
- **安全审计与防滥用立体护盾 (默认内置 / 随时可控)**：
  - **BT / PT 深度封锁**：入站嗅探（`protocol: bittorrent`）特征秒杀 + 典型端口（`6881-6889`, `6969`, `51413`）+ Tracker 域名拦截，杜绝机房 DMCA 侵权警告与删号。
  - **邮件 SPAM 阻断**：严密封锁出站 `25` 端口，防止被黑客当肉鸡发垃圾邮件导致 IP 被全球拉黑。
  - **恶意挖矿拦截**：拦截门罗币等主流 Stratum 矿池域名特征与端口。
  - **内网 SSRF 与云元数据防护**：基于纯 CIDR 封锁 `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`。
  - **外发扫描阻断**：阻断对外扫描 `22` (SSH), `23` (Telnet), `445` (SMB), `3389` (RDP)，防止机房误杀。
- **Realm 高性能多端口转发模块 (中转机专用)**：
  - 基于 Rust 极轻量转发内核，内存占用几乎为零，支持 TCP + UDP 双协议极速转发。
  - 支持增删查改多条端口转发规则（规则持久化于 `/etc/realm/rules.conf`，OpenRC/Systemd 常驻守护）。
- **系统 TCP 与 BBR 深度网络调优模块 (10M~5000M 智能防爆)**：
  - 13 档带宽自适应匹配（10M ~ 5000M），精准配置最优 TCP 窗口与 FQ 队列；
  - 针对小于 256MB 的超低配小鸡自动开启防 OOM 内存保护上限。
- **Cloudflare DDNS 动态域名集成**：纯 Shell + 系统 Crontab 实现，不占用额外常驻内存。
- **轻舟 (SubSkiff) 云端协同与探针管理**：
  - 原生集成轻舟 Rust 静态探针（仅 1.8MB），同目录配置；
  - 节点变动前台 0 延迟自动同步，带 5 秒超时防卡死容错；
  - 一键开启/关闭 Crontab 周期心跳与状态上报。

---

## 🖥️ 控制台主菜单

直接在终端运行 `ldnat`：

```text
==========================================================
      🚀 LDNAT - Alpine 落地与中转全能工具箱               
==========================================================
  1. 节点多端口与全协议服务管理 (REALITY/SS/AnyTLS/Hy2/TUIC/Trojan)
  2. Realm 高性能多端口转发管理 (增/删/查/改/启停)
  3. 部署/更新 Cloudflare DDNS 动态域名
  4. 系统 TCP 与 BBR 深度网络调优 (支持 10M~5000M 自适应)
  5. 查看当前所有配置、转发规则与二维码 (支持 A+B 导出)
  6. 快速网络与服务健康诊断
  7. 轻舟云端协同与探针管理 (SubSkiff Agent)
  0. 退出
==========================================================
```

---

## ⌨️ 常用命令行快捷速查

除了交互菜单，LDNAT 支持全套非交互式命令行快捷操作：

```bash
# 节点管理
ldnat node                          # 唤出节点多端口管理子菜单
ldnat node list                     # 快速列出当前所有节点服务与运行状态
ldnat node add                      # 交互式添加新协议与端口
ldnat node del <端口/序号>          # 删除指定节点
ldnat node links                    # 导出节点链接与二维码 (支持 A+B 模式)

# 轻舟云端协同
ldnat agent                         # 唤出轻舟端侧探针管理菜单
ldnat sync                          # 立即同步本地最新节点链接至轻舟服务端

# 端口转发 (Realm)
ldnat realm                         # 唤出 Realm 多端口管理面板
ldnat realm list                    # 快速列出当前所有端口转发规则
ldnat realm add 10086 1.2.3.4:20086 # 命令行直接添加一条转发
ldnat realm del <本地端口/序号>     # 命令行删除指定转发规则

# 网络与安全
ldnat bbr                           # 交互式调优 TCP 栈
ldnat bbr 100                       # 命令行一秒匹配 100Mbps 档位调优
ldnat shield on/off                 # 开启/关闭安全审计防滥用护盾
ldnat diag                          # 一键自检服务、端口、出口 IP 与伪装握手延迟
ldnat info                          # 查看所有节点信息、转发规则与分享二维码
```

---

## ⛵ 生态协同：轻舟 (SubSkiff) 服务端

本脚本支持完全独立运行。如果您拥有多台 VPS，需要**集中聚合节点、在线全协议订阅转换、IP 出口纯净度画像与集群探针大屏监控**，强烈推荐搭配使用我们的自研服务端平台：

👉 **[轻舟 (SubSkiff) - 高性能分布式节点订阅与探针监控平台](https://github.com/jojhaa/SubSkiff)**

- 在 `ldnat` 菜单中选择 `7. 轻舟云端协同`，一键绑定轻舟 Token；
- 本地每次增删节点，秒级自动同步至轻舟后台，告别手动复制导入。

---

## 📄 开源许可证

本项目基于 **[MIT 许可证](LICENSE)** 开源，欢迎自由分发、修改与使用，请保留原版权与许可声明。
