#!/bin/sh
# Shared helpers for Route Tool storage scripts.
# Keep this POSIX sh compatible: these files run under BusyBox ash on OpenWrt.

RT_COMMON_DIR=${0%/*}
[ "$RT_COMMON_DIR" = "$0" ] && RT_COMMON_DIR="."
RT_EXT_CSD_CACHE="${RT_EXT_CSD_CACHE:-/tmp/route-tool-ext-csd.cache}"
RT_EXT_CSD_PATH_CACHE="${RT_EXT_CSD_PATH_CACHE:-/tmp/route-tool-ext-csd.path}"
RT_EXT_CSD_CACHE_AGE="${RT_EXT_CSD_CACHE_AGE:-300}"

rt_hex2dec() {
    h="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
    h="${h#0x}"
    case "$h" in
        ''|*[!0-9a-f]*) echo 0 ;;
        *) printf '%d\n' "0x$h" 2>/dev/null || echo 0 ;;
    esac
}

rt_cache_fresh() {
    file="$1"
    age="$2"
    [ -f "$file" ] || return 1
    cache_time="$(stat -c %Y "$file" 2>/dev/null || echo 0)"
    now="$(date +%s 2>/dev/null || echo 0)"
    case "$cache_time:$now:$age" in
        *[!0-9:]*|0:*) return 1 ;;
    esac
    [ $((now - cache_time)) -lt "$age" ]
}

rt_emmc_manf_name() {
    id="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
    id="${id#0x}"
    # Manufacturer mapping: JEDEC CID MID + mmc-utils lsmmc.c + 实测补充
    case "$id" in
        # 国际大厂
        01) echo "Samsung(三星)" ;;
        02) echo "SK Hynix(海力士)/Kingston(金士顿)" ;;
        03) echo "Toshiba(东芝)" ;;
        04) echo "Intel(英特尔)" ;;
        06) echo "Micron(美光)" ;;
        07) echo "Spansion/Cypress" ;;
        08) echo "Toshiba/Kioxia(东芝/铠侠)" ;;
        09) echo "STMicro(意法半导体)" ;;
        0a) echo "GigaDevice(兆易创新)" ;;
        0b) echo "Macronix(旺宏)" ;;
        0c) echo "Winbond(华邦)" ;;
        11) echo "Toshiba(东芝)" ;;
        13) echo "Micron(美光)" ;;
        15) echo "Samsung(三星)/SanDisk(闪迪)" ;;
        19) echo "Western Digital(西部数据)" ;;
        1b) echo "Transcend(创见)/Samsung(三星)" ;;
        1d) echo "Corsair(海盗船)/ADATA(威刚)" ;;
        1f) echo "Kingston(金士顿)" ;;
        20) echo "Lexar(雷克沙)" ;;
        25) echo "Kingston(金士顿)" ;;
        28) echo "Crucial(英睿达)/Lexar(雷克沙)" ;;
        29) echo "ADATA(威刚)" ;;
        2c) echo "Hikvision(海康)/HIKSEMI(海康存储)" ;;
        2d) echo "YMTC(长江存储)" ;;
        2e) echo "CXMT(长鑫存储)" ;;
        2f) echo "Konsemi(康芯威)" ;;
        30) echo "Netac(朗科)/SanDisk(闪迪)" ;;
        33) echo "STMicroelectronics(意法)" ;;
        37) echo "KingMax(胜创)" ;;
        41) echo "Kingston(金士顿)" ;;
        44) echo "ATP" ;;
        45) echo "SanDisk(闪迪)" ;;
        6f) echo "STMicroelectronics(意法)" ;;
        70) echo "Kingston(金士顿)" ;;
        74) echo "Transcend(创见)" ;;
        76) echo "Patriot( Patriot)" ;;
        82) echo "Gobe/Sony(索尼)" ;;
        90) echo "SK Hynix(海力士)" ;;
        9b) echo "YMTC(长江存储)" ;;
        d9) echo "Apacer(宇瞻)" ;;
        df) echo "SYC(时意创)" ;;
        ec) echo "ATO/JingCun(晶存)" ;;
        # 国产/代工
        88|d6) echo "Longsys(江波龙)" ;;
        f4) echo "BIWIN(佰维)" ;;
        ea) echo "SPeMMC/康盈/硅格" ;;
        f2) echo "ICMAX(宏旺)" ;;
        fe) echo "Micron(美光)" ;;
        "") echo "未知" ;;
        *) echo "未知(0x$id)" ;;
    esac
}

rt_emmc_chip_name() {
    mid="$(printf '%s' "$1" | tr 'A-F' 'a-f')"
    mid="${mid#0x}"
    pnm="$(printf '%s' "$2" | tr 'A-F' 'a-f')"
    pnm="${pnm#0x}"
    case "$mid:$pnm" in
        f4:415142313154) echo "BIWIN(佰维) AQB11T" ;;
        f4:426977696e*) echo "BIWIN(佰维) Biwin" ;;
        90:4841473265*) echo "SK Hynix(海力士) HAG2e" ;;
        90:4838473461*) echo "SK Hynix(海力士) H8G4a" ;;
        2c:4853654d4d*) echo "HIKSEMI(海康存储) HSeMM" ;;
        2f:303553303030) echo "Konsemi(康芯威) 05S000" ;;
        ea:533033313131) echo "Kowin(康盈) S03111" ;;
        ea:5350654d4d43) echo "SiliconGo(硅格)/SPeMMC" ;;
        15:41474e443352) echo "Samsung(三星) AGND3R" ;;
        15:384754463452) echo "Samsung(三星) 8GTF4R" ;;
        11:303034473630) echo "Toshiba(东芝) 004G60" ;;
        ec:415432533338) echo "ATO/JingCun(晶存) AT2S38" ;;
        df:534341303847) echo "SYC(时意创) SCA08G" ;;
        88:4e43617264) echo "Longsys(江波龙) NCard" ;;
        9b:593053323536) echo "YMTC(长江存储) Y0S256" ;;
        *) rt_emmc_manf_name "$mid" ;;
    esac
}
rt_find_ext_csd_path() {
    for host in /sys/class/mmc_host/mmc*/mmc*:*/ext_csd; do
        [ -f "$host" ] && [ -r "$host" ] && { echo "$host"; return 0; }
    done
    for host in /sys/kernel/debug/mmc*/mmc*:*/ext_csd; do
        [ -f "$host" ] && [ -r "$host" ] && { echo "$host"; return 0; }
    done
    return 1
}

rt_read_ext_csd() {
    age="${1:-$RT_EXT_CSD_CACHE_AGE}"
    if rt_cache_fresh "$RT_EXT_CSD_CACHE" "$age"; then
        RT_EXT_CSD_PATH="$(cat "$RT_EXT_CSD_PATH_CACHE" 2>/dev/null)"
        cat "$RT_EXT_CSD_CACHE"
        return 0
    fi

    RT_EXT_CSD_PATH="$(rt_find_ext_csd_path 2>/dev/null)"
    if [ -z "$RT_EXT_CSD_PATH" ]; then
        # Mount debugfs once and cache the result so health/detail/analyze do not repeat the work.
        mount -t debugfs none /sys/kernel/debug 2>/dev/null
        RT_EXT_CSD_PATH="$(rt_find_ext_csd_path 2>/dev/null)"
    fi
    [ -n "$RT_EXT_CSD_PATH" ] || return 1

    raw="$(cat "$RT_EXT_CSD_PATH" 2>/dev/null | tr -d '\n ' | tr 'A-F' 'a-f')"
    [ ${#raw} -ge 1000 ] || return 1
    printf '%s\n' "$raw" > "$RT_EXT_CSD_CACHE" 2>/dev/null || true
    printf '%s\n' "$RT_EXT_CSD_PATH" > "$RT_EXT_CSD_PATH_CACHE" 2>/dev/null || true
    printf '%s\n' "$raw"
}

rt_ext_csd_byte_hex() {
    raw="$1"
    byte="$2"
    start=$((byte * 2 + 1))
    end=$((start + 1))
    printf '%s' "$raw" | cut -c"${start}-${end}"
}

rt_parse_ext_csd_life() {
    raw="$1"
    # The Linux/mmc-utils EXT_CSD indices are PRE_EOL_INFO=267,
    # DEVICE_LIFE_TIME_EST_TYP_A=268, DEVICE_LIFE_TIME_EST_TYP_B=269.
    # cut(1) positions are 1-based over the 1024-char hex string: byte*2+1..byte*2+2.
    RT_PRE_EOL_HEX="$(rt_ext_csd_byte_hex "$raw" 267)"
    RT_LIFE_A_HEX="$(rt_ext_csd_byte_hex "$raw" 268)"
    RT_LIFE_B_HEX="$(rt_ext_csd_byte_hex "$raw" 269)"
    RT_PRE_EOL_DEC="$(rt_hex2dec "$RT_PRE_EOL_HEX")"
    RT_LIFE_A_DEC="$(rt_hex2dec "$RT_LIFE_A_HEX")"
    RT_LIFE_B_DEC="$(rt_hex2dec "$RT_LIFE_B_HEX")"
}

rt_life_used_text() {
    case "$1" in
        0) echo "厂家未上报" ;;
        1) echo "0-10%" ;;
        2) echo "10-20%" ;;
        3) echo "20-30%" ;;
        4) echo "30-40%" ;;
        5) echo "40-50%" ;;
        6) echo "50-60%" ;;
        7) echo "60-70%" ;;
        8) echo "70-80%" ;;
        9) echo "80-90%" ;;
        10) echo "90-100%" ;;
        11) echo "超过100%" ;;
        *) echo "未知" ;;
    esac
}

rt_pre_eol_text() {
    case "$1" in
        0|1) echo "正常" ;;
        2) echo "接近寿命预警" ;;
        3) echo "已到寿命预警" ;;
        *) echo "未知" ;;
    esac
}

rt_status_by_used() {
    used="$1"
    pre="$2"
    if [ "$pre" -ge 3 ]; then echo "危险"; return; fi
    if [ "$pre" -eq 2 ]; then echo "警告"; return; fi
    if [ "$used" -le 3 ]; then
        echo "良好"
    elif [ "$used" -le 6 ]; then
        echo "一般"
    elif [ "$used" -le 8 ]; then
        echo "警告"
    else
        echo "严重"
    fi
}
