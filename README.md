# luci-app-route-tool

OpenWrt LuCI 插件：路由器存储健康诊断 + 分区管理 + 网口检测 + 内存压力测试

![v0.3.8 界面展示](screenshots/v038-showcase.jpg)

## 功能

- **SoC 信息**：CPU 型号、核心数、温度、CoreMark
- **网口检测**：物理网口状态/速率、WiFi 频段/信道
- **eMMC 健康检测**：寿命预估、PRE_EOL、制造商识别（38家）
- **eMMC 读写速度**：实际读写测速 + 颗粒/BOOT/RPMB/CID/版本诊断
- **eMMC 分区管理**：GPT/cdt/art/appsbl/bl2/fip/factory 备份与写入
- **内存压力检测**：轻量/标准/写满三档，验证内存可靠性
- **NAND 检测**：MTD 分区、坏块、ECC 状态
- **开机日志分析**：异常/警告/提示三级分类
- **固件更新**：sysupgrade 在线刷机

## 一键安装

```bash
curl -L -o /tmp/route-tool.ipk https://godsun.pro/upload/luci-app-route-tool_0.3.10_all.ipk && opkg install --force-reinstall /tmp/route-tool.ipk && rm -f /tmp/route-tool.ipk
```

或从 [GitHub Releases](https://github.com/rothdren-lion/luci-app-route-tool/releases) 下载 IPK 手动安装：

```bash
opkg install luci-app-route-tool_0.3.10_all.ipk
```

## 使用

安装后在 LuCI 后台进入 **系统 → Route Tool** 即可使用。

### 内存压力检测说明

- **轻量**：约 25% 可用内存，保留 /tmp 余量
- **标准**：约 60% 可用内存
- **写满**：填满 /tmp 直到 ENOSPC（"No space left" = PASS）

⚠ 内存压力检测结果仅供参考，不代表真实内存带宽。

### eMMC 制造商识别

内置 38 家 eMMC 制造商 ID 映射（mmc-utils 官方仅 13 家），部分由 T76 编程器拆机确认：

| MID | 品牌 | 来源 |
|-----|------|------|
| 0xd6/0x88 | Longsys(江波龙) | T76 编程器确认 |
| 0xf4 | BIWIN(佰维) | T76 编程器确认 |
| 0xea | SPeMMC/深圳 SPeMMC | 实测 |
| 0x0a | GigaDevice(兆易创新) | 文档 |
| 0x01 | Samsung(三星) | mmc-utils |
| ... | 共 38 家 | |

### 分区操作危险提示

写入分区操作很危险，请确定知道自己在玩什么！对应位置写错文件必砖！

## 支持设备

- 高通 IPQ6018/IPQ807x 系列（eMMC + GPT 分区）
- 联发科 MT7981/MT7986 系列（eMMC 或 NAND）
- 联发科 MT7621 系列（NAND/NOR）
- 其他 OpenWrt 设备（部分功能可用）

## 版本历史

### v0.3.10
- 🎨 容量卡：无 NAND 时隐藏 NAND 总量行
- 🏷️ 制造商映射：0xea=SPeMMC/深圳 SPeMMC

### v0.3.9
- 🧩 MTK eMMC 分区补全：bl2/fip/u-boot-env 纳入可操作分区
- 🏷️ eMMC 制造商库扩充至 38 家（含 BIWIN 佰维 0xf4）
- 🚀 测速同时显示诊断信息：颗粒品牌、BOOT1/BOOT2、RPMB、eMMC 版本、CID

### v0.3.8
- 🧠 内存测速 → 内存压力检测：轻量/标准/写满三档
- 🛡️ 卸载不炸 LuCI：新增 prerm/postrm 脚本
- 📦 安装→卸载→重装循环验证通过

### v0.3.7
- 代码质量修复：统一 ext_csd 偏移量、修复 PRE_EOL bug
- 统一制造商 ID 映射

### v0.3.6
- 初始公开版本

## 技术栈

- 后端：POSIX sh 脚本（BusyBox 兼容）
- 前端：LuCI + 原生 JS
- 架构：`all`（纯脚本，无编译依赖）

## License

MIT
