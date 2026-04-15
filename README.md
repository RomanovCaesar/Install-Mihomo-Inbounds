[中文](/README.md)

# Caesar 蜜汁 Mihomo 一键安装与管理工具箱 (Install-Mihomo-Inbounds)

这是一个功能强大、高度模块化且极具兼容性的 Mihomo 节点安装与管理脚本集合。使用 Mihomo (Meta Kernel) 替代 Xray 作为代理服务端核心，解决 Xray 存在的 TCP 连接数泄露问题。支持在一台服务器上完美共存部署多种主流协议（VLESS-Reality、Shadowsocks 2022 等），并提供便捷的配置备份、路由分流管理以及 Geo 数据更新功能。

## ✨ 核心特性

* **Mihomo 核心**：使用 Mihomo (Clash Meta) 作为代理服务端，解决 Xray 的 TCP 连接数泄露 Bug，资源占用更低，稳定性更强。
* **多协议智能共存**：采用 Python 解析 YAML 配置并智能追加 listeners，随心所欲安装多个不同协议或多端口节点，**绝对不会覆盖**原有节点配置。
* **极致的系统兼容**：不仅完美支持 Debian / Ubuntu 等基于 Systemd 的主流系统，更**深度兼容 Alpine Linux (OpenRC)**，对极其精简的轻量级系统同样友好。
* **NAT / DDNS 友好**：内置独立连接地址自定义功能，无论你是使用 NAT 动态端口机，还是通过 DDNS 域名解析，都能一键生成正确的分享链接。
* **一站式管理**：提供全局统一的管理菜单 (`mihomo-manager`)、路由分流配置工具 (`mihomo-routing`) 以及配置备份还原工具 (`mihomo-restore`)。
* **安全精准删除**：支持按端口和协议精准识别并删除特定节点配置，绝不误伤无辜配置。

---

## 🚀 快速开始（推荐）

如果你想体验最完整的管理功能，推荐直接安装**统一管理中心（Mihomo Manager）**。

执行以下命令即可下载并唤出全局管理菜单：

```bash
curl -L https://raw.githubusercontent.com/RomanovCaesar/Install-Mihomo-Inbounds/main/mihomo_manager.sh -o mihomo_manager.sh && chmod +x mihomo_manager.sh && sudo ./mihomo_manager.sh
```

**💡 贴心提示：**
统一管理工具安装完成后，会自动注册全局命令。以后你随时可以通过在终端输入以下命令来快速唤醒主菜单：
```bash
mihomo-manager
```

在 `mihomo-manager` 菜单中，你可以直接一键调用以下所有独立功能，无需再单独下载脚本。

---

## 📦 各功能模块独立安装指南

如果你只想使用本项目的某一个特定功能，也可以直接使用以下独立安装命令。

### 1. VLESS-Reality (Vision) 节点管理
支持自动生成 X25519 密钥对，默认使用 `xtls-rprx-vision` 流控，使用 Mihomo 的 listeners 接入。
```bash
curl -L https://raw.githubusercontent.com/RomanovCaesar/Install-Mihomo-Inbounds/main/install_vless_reality.sh -o install_vless_reality.sh && chmod +x install_vless_reality.sh && sudo ./install_vless_reality.sh
```

### 2. Shadowsocks 2022 & 传统 SS 节点管理
支持极速的 2022-blake3-aes 等新一代加密协议，并向下兼容传统的 aes-gcm 加密，自动生成强随机密码。
```bash
curl -L https://raw.githubusercontent.com/RomanovCaesar/Install-Mihomo-Inbounds/main/install_ss2022.sh -o install_ss2022.sh && chmod +x install_ss2022.sh && sudo ./install_ss2022.sh
```

### 3. 服务端路由分流工具 (Mihomo Routing)
强大的服务端出口分流控制面板。支持解析 SS 和 VLESS 分享链接，可视化配置分流规则。
```bash
curl -L https://raw.githubusercontent.com/RomanovCaesar/Install-Mihomo-Inbounds/main/mihomo_routing.sh -o mihomo_routing.sh && chmod +x mihomo_routing.sh && sudo ./mihomo_routing.sh
```
*安装后随时可用 `mihomo-routing` 命令唤起。*

### 4. 备份与还原工具 (Mihomo Restore)
不小心改错了配置？想要迁移配置？使用此工具可以通过直链 URL 导入配置文件，或者打开控制台手动粘贴 `config.yaml`，自带安全测试防报错功能。
```bash
curl -L https://raw.githubusercontent.com/RomanovCaesar/Install-Mihomo-Inbounds/main/mihomo_restore.sh -o mihomo_restore.sh && chmod +x mihomo_restore.sh && sudo ./mihomo_restore.sh
```
*安装后随时可用 `mihomo-restore` 命令唤起。*

### 5. 完全卸载工具
如果你遇到无法解决的严重问题，或者想要完全清理服务器，可以使用此脚本。它会极其干净地清理系统服务（Systemd/OpenRC）、二进制文件、日志以及残留配置。
```bash
curl -L https://raw.githubusercontent.com/RomanovCaesar/Install-Mihomo-Inbounds/main/uninstall_mihomo.sh -o uninstall_mihomo.sh && chmod +x uninstall_mihomo.sh && sudo ./uninstall_mihomo.sh
```

---

## 🔄 与 Xray 版本的对应关系

| Xray 脚本 | Mihomo 脚本 | 功能 |
|---|---|---|
| `install_ss2022.sh` | `install_ss2022.sh` | Shadowsocks 2022 节点管理 |
| `install_vless_reality.sh` | `install_vless_reality.sh` | VLESS-Reality 节点管理 |
| `install_vless_encryption.sh` | *(暂不支持)* | VLESS Encryption (Post-Quantum) |
| `xray_manager.sh` | `mihomo_manager.sh` | 统一管理菜单 |
| `xray_routing.sh` | `mihomo_routing.sh` | 服务端分流配置 |
| `xray_restore.sh` | `mihomo_restore.sh` | 配置备份还原 |
| `uninstall_xray.sh` | `uninstall_mihomo.sh` | 完全卸载 |
| `update_geo.sh` | `update_geo.sh` | Geo 数据更新 |

> **注意**: VLESS Encryption (Post-Quantum / ML-KEM-768) 是 Xray 独有的前沿功能，Mihomo 目前不支持此协议。如需使用该协议，请继续使用 Xray 版本。

---

## 🛠️ 常见问题 (FAQ)

**Q: 为什么要从 Xray 迁移到 Mihomo？**

**A:** Xray 代理服务端存在严重的 TCP 连接数泄露 Bug。Mihomo (Meta Kernel) 不存在此问题，且在资源占用和稳定性方面表现更优。

**Q: 我的服务器是 NAT VPS，或者入口 IP 跟出口 IP 不一样，生成的节点不通怎么办？**

**A:** 请在任意安装菜单中选择 **"设置连接地址 (NAT/DDNS)"** 选项。填入你实际用于外部连接的 IP 地址或 DDNS 域名。

**Q: 如何查看 Mihomo 的运行日志？**

**A:** 在各个安装管理脚本的菜单中，都有 **"查看日志"** 选项。选择后即可实时查看运行日志，按 `Ctrl + C` 即可停止。

**Q: 如何更新 GeoIP 和 GeoSite 路由规则文件？**

**A:** 使用 `mihomo-routing` (服务端分流工具) 里的一键自动配置定时任务功能，会每天凌晨自动更新。你也可以在主管理工具 (`mihomo-manager`) 中手动执行即时更新。

**Q: Mihomo 的配置文件在哪里？**

**A:** 配置文件位于 `/usr/local/etc/mihomo/config.yaml`。Mihomo 使用 YAML 格式而非 Xray 的 JSON 格式。
