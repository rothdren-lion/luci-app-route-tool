# route-tool

OpenWrt LuCI 路由分区工具：在同一个页面备份/写入关键分区。

![Route Tool LuCI 界面](screenshots/route-tool-dashboard.png)

- 高通 eMMC：GPT 分区表、cdt、art、appsbl、factory、mibib（部分机型没有）
- MTK：BL2、fip、factory；如果是 eMMC 机型也显示 GPT 分区表
- 其他非 eMMC 设备：不显示 GPT，只按实际 MTD 分区显示
- 备份按钮直接下载：`分区名.bin`
- 写入自动区分：eMMC 块设备用 `dd`，NAND 用 `flash_erase + nandwrite`，NOR/MTD 优先用 `mtd write`
- UI：系统 / Route Tool
- footer：by 数码罗记 · godsun.pro

## 安装

从 GitHub Releases 下载最新 IPK：

```sh
wget -O /tmp/luci-app-route-tool.ipk https://github.com/rothdren-lion/luci-app-route-tool/releases/latest/download/luci-app-route-tool_all.ipk
opkg install /tmp/luci-app-route-tool.ipk
```

### opkg 报错 Malformed package file？

部分第三方固件（QWRT 等）的 BusyBox 精简了 `ar` applet，导致旧版 opkg 无法解析 ar 格式的 ipk。如果 `opkg install` 报 `Malformed package file`，用手动安装：

```sh
cd /tmp
wget -O luci-app-route-tool.ipk https://github.com/rothdren-lion/luci-app-route-tool/releases/latest/download/luci-app-route-tool_all.ipk
# 解包 ipk（ar 归档 = debian-binary + control.tar.gz + data.tar.gz）
tar -xzf luci-app-route-tool.ipk 2>/dev/null || ar x luci-app-route-tool.ipk
# 安装文件到系统
tar -xzf data.tar.gz -C /
# 注册到 opkg（让 opkg info 能看到，方便后续卸载/升级）
mkdir -p /usr/lib/opkg/info
tar -xzf control.tar.gz -C /usr/lib/opkg/info/
# 清理
rm -f debian-binary control.tar.gz data.tar.gz luci-app-route-tool.ipk
# 刷新 LuCI 缓存
rm -rf /tmp/luci-*
/etc/init.d/uhttpd restart
```

> **说明**：ipk 本身是标准 ar 归档格式，格式没有问题。问题出在固件端 BusyBox 缺少 `ar` 解包能力。OpenWrt 官方固件不受影响。

安装后页面标题版本号旁会每天自动检查一次 GitHub Releases；发现新版本时显示 `可更新` 小标识，点击即可在线 OTA 更新插件。

也可以从源码安装：

```sh
sh install.sh
```

## 可选依赖

- GPT 备份/恢复需要 `sgdisk`：`opkg install gdisk`
- NAND 写入需要 `flash_erase` / `nandwrite`，通常来自 `mtd-utils`

## 后端命令

```sh
/usr/libexec/route-tool list
/usr/libexec/route-tool backup appsbl > /tmp/appsbl.bin
/usr/libexec/route-tool write appsbl /tmp/uboot.bin YES
```
