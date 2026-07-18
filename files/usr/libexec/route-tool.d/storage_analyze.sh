#!/bin/sh
# ============================================================
# eMMC Complete Analysis Tool
# Reads ALL eMMC info: CID, CSD, ext_csd, partitions, fs
# Uses lsblk, blkid, sysfs, debugfs
# ============================================================

SCRIPT_DIR=${0%/*}
[ "$SCRIPT_DIR" = "$0" ] && SCRIPT_DIR="."
. "$SCRIPT_DIR/storage_common.sh"

SEP="========================================"

echo "$SEP"
echo "   💾 eMMC 完整分析报告"
echo "$SEP"
date '+📅 时间: %Y-%m-%d %H:%M:%S'
echo "🖥️  设备: $(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)"
echo "🐧 内核: $(uname -r) | 架构: $(uname -m)"
echo ""

# ── 1. Device Discovery ──────────────────────────────
echo "─── 📀 设备识别 ───"

# MMC host
MMC_HOST=""
MMC_DEV=""
for host in /sys/class/mmc_host/mmc*; do
    [ -d "$host" ] || continue
    MMC_HOST="$host"
    break
done

for dev in /sys/class/mmc_host/mmc*/mmc*:*; do
    [ -d "$dev" ] || continue
    MMC_DEV="$dev"
    break
done

if [ -n "$MMC_DEV" ]; then
    echo "  MMC 设备路径: $MMC_DEV"
fi

# Block device
BLK_DEV=""
for blk in "$MMC_DEV"/block/mmcblk* /sys/block/mmcblk*; do
    [ -r "$blk/size" ] || continue
    if [ -r "$blk/device/type" ] && [ "$(cat "$blk/device/type" 2>/dev/null)" != "MMC" ]; then
        continue
    fi
    BLK_DEV="${blk##*/}"
    SIZE_SECTORS=$(cat "$blk/size" 2>/dev/null)
    if [ -n "$SIZE_SECTORS" ]; then
        SIZE_GB=$((SIZE_SECTORS * 512 / 1024 / 1024 / 1024))
        SIZE_MB=$((SIZE_SECTORS * 512 / 1024 / 1024))
        echo "  设备: /dev/$BLK_DEV | 容量: ${SIZE_GB}GB (${SIZE_MB}MB)"
        echo "  扇区: ${SIZE_SECTORS} x 512B"
    fi
    break
done

# RPMB
if [ -n "$BLK_DEV" ] && [ -e "/dev/${BLK_DEV}rpmb" ]; then
    RPMB_SIZE=$(cat "$MMC_DEV/rpmb_size" 2>/dev/null)
    [ -n "$RPMB_SIZE" ] && echo "  RPMB: ${RPMB_SIZE}KB"
fi

echo ""

# ── 2. CID Register (Manufacturer Info) ──────────────
echo "─── 🏭 制造商信息 (CID) ───"

CID=""
for cid_path in /sys/class/mmc_host/mmc*/mmc*:*/cid /sys/kernel/debug/mmc*/mmc*:*/cid; do
    [ -f "$cid_path" ] && CID=$(cat "$cid_path" 2>/dev/null) && break
done

if [ -n "$CID" ] && [ ${#CID} -ge 16 ]; then
    MANFID=$(echo "$CID" | cut -c1-2)
    OEMID=$(echo "$CID" | cut -c3-4)
    PRDCT=$(echo "$CID" | cut -c5-16)
    SERIAL=$(echo "$CID" | cut -c15-22)
    DATE_RAW=$(echo "$CID" | cut -c23-26)

    MANF="$(rt_emmc_chip_name "$MANFID" "$PRDCT")"

    # Decode CID date through printf-based helper; old BusyBox ash may not accept hex literals in arithmetic expansion.
    DATE_MONTH="$(rt_hex2dec "$(echo "$DATE_RAW" | cut -c1-1)")"
    DATE_YEAR=$((2000 + $(rt_hex2dec "$(echo "$DATE_RAW" | cut -c2-4)")))
    [ "$DATE_MONTH" -gt 12 ] && DATE_MONTH="?"

    echo "  制造商: $MANF (ID: 0x${MANFID})"
    echo "  OEM ID: 0x${OEMID}"
    echo "  产品名: ${PRDCT}"
    echo "  序列号: 0x${SERIAL}"
    echo "  生产日期: ${DATE_MONTH}/${DATE_YEAR}"
    echo "  CID 原始值: ${CID}"
else
    echo "  ⚠️ 无法读取 CID 寄存器"
fi

echo ""

# ── 3. CSD Register ───────────────────────────────────
echo "─── 📋 CSD 寄存器 ───"
for csd_path in /sys/class/mmc_host/mmc*/mmc*:*/csd /sys/kernel/debug/mmc*/mmc*:*/csd; do
    if [ -f "$csd_path" ]; then
        CSD=$(cat "$csd_path" 2>/dev/null)
        echo "  CSD: ${CSD}"
        break
    fi
done
echo ""

# ── 4. ext_csd (Health & Life) ────────────────────────
echo "─── 🏥 健康状态 (ext_csd) ───"

EXT_CSD="$(rt_read_ext_csd 300)"
if [ -n "$EXT_CSD" ] && [ ${#EXT_CSD} -ge 1000 ]; then
    # Shared parser fixes the previous PRE_EOL offset drift between analyze/detail/health.
    rt_parse_ext_csd_life "$EXT_CSD"
    LIFE_A_DEC="$RT_LIFE_A_DEC"
    LIFE_B_DEC="$RT_LIFE_B_DEC"
    PRE_EOL_DEC="$RT_PRE_EOL_DEC"

    # Decode life values (0x01=0-10%, 0x0B=exceeded)
    decode_life() {
        case "$1" in
            0) echo "未定义" ;;
            1) echo "0%-10% 已使用 (优秀)" ;;
            2) echo "10%-20% 已使用 (良好)" ;;
            3) echo "20%-30% 已使用 (良好)" ;;
            4) echo "30%-40% 已使用 (正常)" ;;
            5) echo "40%-50% 已使用 (正常)" ;;
            6) echo "50%-60% 已使用 (注意)" ;;
            7) echo "60%-70% 已使用 (注意)" ;;
            8) echo "70%-80% 已使用 (警告)" ;;
            9) echo "80%-90% 已使用 (警告)" ;;
            10) echo "90%-100% 已使用 (严重)" ;;
            11) echo "已超出额定寿命 (危险!)" ;;
            *) echo "未知 (0x$(printf '%02x' "$1"))" ;;
        esac
    }

    echo "  ext_csd路径: ${RT_EXT_CSD_PATH:-$(cat "$RT_EXT_CSD_PATH_CACHE" 2>/dev/null)}"
    echo "  偏移: PRE_EOL byte267=${RT_PRE_EOL_HEX}, TYP_A byte268=${RT_LIFE_A_HEX}, TYP_B byte269=${RT_LIFE_B_HEX}"
    echo "  TYP_A 寿命: $(decode_life "$LIFE_A_DEC")"
    echo "  TYP_B 寿命: $(decode_life "$LIFE_B_DEC")"
    echo "  PRE_EOL: ${PRE_EOL_DEC}"

    # Health verdict
    if [ "$PRE_EOL_DEC" -gt 0 ]; then
        echo "  ⚠️  注意: PRE_EOL 非零，设备可能已接近寿命终点!"
    elif [ "$LIFE_A_DEC" -le 3 ]; then
        echo "  ✅ 总体健康: 良好 (已使用 < 30%)"
    elif [ "$LIFE_A_DEC" -le 7 ]; then
        echo "  ⚠️  总体健康: 一般 (已使用 30%-70%)"
    elif [ "$LIFE_A_DEC" -le 10 ]; then
        echo "  ❌ 总体健康: 需关注 (已使用 > 70%)"
    else
        echo "  🚨 总体健康: 危险 (已超出寿命!)"
    fi
else
    echo "  ⚠️ ext_csd 数据不完整"
fi

echo ""

# ── 5. Partition Table ────────────────────────────────
echo "─── 📊 分区信息 ───"

echo ""
echo "  [lsblk 输出]"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | while read -r line; do
    echo "    $line"
done

echo ""
echo "  [blkid - 文件系统类型]"
blkid 2>/dev/null | sort | while read -r line; do
    echo "    $line"
done

echo ""
echo "  [df -h 挂载使用]"
df -h 2>/dev/null | grep -v "^tmpfs\|^devtmpfs\|^overlay" | while read -r line; do
    echo "    $line"
done

echo ""

# ── 6. Boot Partitions ────────────────────────────────
echo "─── 🔒 启动分区 ───"
if [ -n "$BLK_DEV" ]; then
    for boot in /dev/${BLK_DEV}boot0 /dev/${BLK_DEV}boot1; do
        if [ -e "$boot" ]; then
            # Use the current loop item; boot1 must not inherit boot0's size.
            SIZE=$(cat /sys/block/${boot##*/}/size 2>/dev/null)
            if [ -n "$SIZE" ]; then
                SIZE_KB=$((SIZE * 512 / 1024))
                echo "  $boot: ${SIZE_KB}KB"
            fi
        fi
    done
fi
echo ""

# ── 7. System Memory ──────────────────────────────────
echo "─── 🧠 系统内存 ───"
TOTAL=$(grep MemTotal /proc/meminfo | awk '{printf "%.0f", $2/1024}')
FREE=$(grep MemAvailable /proc/meminfo | awk '{printf "%.0f", $2/1024}')
SWAP_TOTAL=$(grep SwapTotal /proc/meminfo | awk '{printf "%.0f", $2/1024}')
SWAP_FREE=$(grep SwapFree /proc/meminfo | awk '{printf "%.0f", $2/1024}')
echo "  总内存: ${TOTAL}MB | 可用: ${FREE}MB"
echo "  总交换: ${SWAP_TOTAL}MB | 可用: ${SWAP_FREE}MB"
echo ""

# ── 8. Other Storage ──────────────────────────────────
echo "─── 💿 其他存储 ───"
NAND_FOUND=0
if [ -f /proc/mtd ]; then
    MTD_COUNT=$(wc -l < /proc/mtd)
    if [ "$MTD_COUNT" -gt 1 ]; then
        NAND_FOUND=1
        echo "  NAND 分区: ${MTD_COUNT} 个"
    fi
fi
[ "$NAND_FOUND" -eq 0 ] && echo "  未检测到 NAND 设备"

echo ""
echo "$SEP"
echo "   ✅ 分析完成"
echo "$SEP"
