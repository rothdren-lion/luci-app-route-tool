#!/bin/sh
# Storage Health Tool - eMMC Health Check
# Reads PRE_EOL/LIFE_A/LIFE_B from eMMC ext_csd register
# BusyBox compatible POSIX shell

SCRIPT_DIR=${0%/*}
[ "$SCRIPT_DIR" = "$0" ] && SCRIPT_DIR="."
. "$SCRIPT_DIR/storage_common.sh"

# Shared reader caches ext_csd and centralizes offsets so health/detail/analyze stay consistent.
EXT_CSD=$(rt_read_ext_csd 300)
MMC_CSD="$(cat "$RT_EXT_CSD_PATH_CACHE" 2>/dev/null)"
[ -n "$MMC_CSD" ] || MMC_CSD="cached_or_unknown"

if [ -z "$EXT_CSD" ]; then
    echo "eMMC_STATUS=未检测到eMMC设备"
    echo "EMMC_LIFE_TEXT=N/A"
    echo "EMMC_LIFE_LEFT_PCT=0"
    exit 1
fi

if [ ${#EXT_CSD} -lt 1000 ]; then
    echo "eMMC_STATUS=数据不完整"
    echo "EMMC_LIFE_TEXT=N/A"
    echo "EMMC_LIFE_LEFT_PCT=0"
    exit 1
fi

rt_parse_ext_csd_life "$EXT_CSD"
PRE_EOL_DEC="$RT_PRE_EOL_DEC"
SLC_DEC="$RT_LIFE_A_DEC"
MLC_DEC="$RT_LIFE_B_DEC"

MAIN_DEC="$SLC_DEC"; MAIN_TYPE="SLC/TYP_A"
if [ "$MLC_DEC" -gt "$MAIN_DEC" ]; then MAIN_DEC="$MLC_DEC"; MAIN_TYPE="MLC/TYP_B"; fi

if [ "$MAIN_DEC" -le 0 ]; then
    USED_PCT=0; LEFT_PCT=100; USED_RANGE="厂家未上报"
elif [ "$MAIN_DEC" -ge 11 ]; then
    USED_PCT=100; LEFT_PCT=0; USED_RANGE="超过100%"
else
    USED_PCT=$((MAIN_DEC * 10)); LEFT_PCT=$((100 - USED_PCT)); USED_RANGE="$(rt_life_used_text "$MAIN_DEC")"
fi

PRE_EOL_STR="$(rt_pre_eol_text "$PRE_EOL_DEC")"
STATUS="$(rt_status_by_used "$MAIN_DEC" "$PRE_EOL_DEC")"
LIFE_TEXT="约剩余${LEFT_PCT}%，按${MAIN_TYPE}较大磨损值估算；SLC:${SLC_DEC}($(rt_life_used_text "$SLC_DEC")) MLC:${MLC_DEC}($(rt_life_used_text "$MLC_DEC"))；预警:${PRE_EOL_STR}"

# Backward-compatible fields + corrected names.
echo "eMMC_STATUS=${STATUS}"
echo "eMMC_HEALTH=${LIFE_TEXT}"
echo "eMMC_EOL_PCT=${LEFT_PCT}"
echo "eMMC_EOL_DEC=${PRE_EOL_DEC}"
echo "eMMC_SLC_DEC=${SLC_DEC}"
echo "eMMC_MLC_DEC=${MLC_DEC}"
echo "eMMC_PATH=${MMC_CSD}"
echo "EMMC_PRE_EOL_DEC=${PRE_EOL_DEC}"
echo "EMMC_PRE_EOL_TEXT=${PRE_EOL_STR}"
echo "EMMC_LIFE_A_DEC=${SLC_DEC}"
echo "EMMC_LIFE_B_DEC=${MLC_DEC}"
echo "EMMC_PRE_EOL_HEX=${RT_PRE_EOL_HEX}"
echo "EMMC_LIFE_A_HEX=${RT_LIFE_A_HEX}"
echo "EMMC_LIFE_B_HEX=${RT_LIFE_B_HEX}"
echo "EMMC_EXT_CSD_OFFSETS=PRE_EOL:267,LIFE_A:268,LIFE_B:269"
echo "EMMC_LIFE_MAIN_TYPE=${MAIN_TYPE}"
echo "EMMC_LIFE_USED_BUCKET=${MAIN_DEC}"
echo "EMMC_LIFE_USED_PCT=${USED_PCT}"
echo "EMMC_LIFE_LEFT_PCT=${LEFT_PCT}"
echo "EMMC_LIFE_USED_RANGE=${USED_RANGE}"
echo "EMMC_LIFE_TEXT=${LIFE_TEXT}"

# ── eMMC 硬件诊断信息 ──
MMC_SYS=""
for d in /sys/class/mmc_host/mmc*/mmc*:*; do
    [ -d "$d" ] && { MMC_SYS="$d"; break; }
done
if [ -n "$MMC_SYS" ]; then
    CID_RAW="$(cat "$MMC_SYS/cid" 2>/dev/null | tr -d '\n ')"
    [ -n "$CID_RAW" ] && echo "EMMC_CID=$CID_RAW"
    MANFID="$(printf '%s' "$CID_RAW" | cut -c1-2)"
    echo "EMMC_MANUFACTURER=$(rt_emmc_manf_name "$MANFID")"
    if [ -n "$EXT_CSD" ]; then
        BOOT1_HEX="$(rt_ext_csd_byte_hex "$EXT_CSD" 226)"
        BOOT2_HEX="$(rt_ext_csd_byte_hex "$EXT_CSD" 227)"
        BOOT1_KB=$(( $(rt_hex2dec "$BOOT1_HEX") * 128 ))
        BOOT2_KB=$(( $(rt_hex2dec "$BOOT2_HEX") * 128 ))
        echo "EMMC_BOOT1_SIZE_KB=$BOOT1_KB"
        echo "EMMC_BOOT2_SIZE_KB=$BOOT2_KB"
        RPMB_HEX="$(rt_ext_csd_byte_hex "$EXT_CSD" 222)"
        RPMB_KB=$(( $(rt_hex2dec "$RPMB_HEX") * 128 ))
        echo "EMMC_RPMB_SIZE_KB=$RPMB_KB"
        VER_HEX="$(rt_ext_csd_byte_hex "$EXT_CSD" 192)"
        VER_DEC="$(rt_hex2dec "$VER_HEX")"
        # eMMC版本判定：byte192=EXT_CSD_REV(规范版本)
        # 但实际路由器eMMC颗粒基本都是5.1，byte308=CMDQ是5.1新增特性
        # byte192=8(5.01) + CMDQ支持 → 实际颗粒为5.1
        CMDQ_HEX="$(rt_ext_csd_byte_hex "$EXT_CSD" 308)"
        CMDQ_DEC="$(rt_hex2dec "$CMDQ_HEX")"
        DEV_TYPE_HEX="$(rt_ext_csd_byte_hex "$EXT_CSD" 196)"
        DEV_TYPE_DEC="$(rt_hex2dec "$DEV_TYPE_HEX")"
        case "$VER_DEC" in
            0) VER_TXT="4.0" ;; 1) VER_TXT="4.1" ;;
            2) VER_TXT="4.2" ;; 3) VER_TXT="4.3" ;;
            4) VER_TXT="4.4" ;; 5) VER_TXT="4.41" ;;
            6) VER_TXT="4.5" ;; 7) VER_TXT="5.0" ;;
            8) VER_TXT="5.01" ;; 9) VER_TXT="5.1" ;;
            10) VER_TXT="5.1B" ;; *) VER_TXT="未知(0x$VER_HEX)" ;;
        esac
        # CMDQ(byte308)是eMMC 5.1新增特性，有CMDQ+byte192=5.01→实际5.1
        if [ "$VER_DEC" -eq 8 ] && [ "$CMDQ_DEC" -gt 0 ]; then
            VER_TXT="5.1"
            VER_NOTE="CMDQ支持，规范5.01→颗粒5.1"
        fi
        echo "EMMC_VERSION=$VER_TXT"
        echo "EMMC_VERSION_RAW=0x$VER_HEX"
        [ -n "$VER_NOTE" ] && echo "EMMC_VERSION_NOTE=$VER_NOTE"
        echo "EMMC_DEVICE_TYPE=0x$DEV_TYPE_HEX"
        echo "EMMC_CMDQ_SUPPORT=$CMDQ_DEC"
    fi
fi
