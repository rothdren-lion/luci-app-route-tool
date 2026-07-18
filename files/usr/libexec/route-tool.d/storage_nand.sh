#!/bin/sh
# NAND Flash Detection & Health Check
# Supports MTD, UBI, raw NAND

MTD_FOUND=0

if [ -f /proc/mtd ]; then
    # Count only real mtdN rows; /proc/mtd usually has a header even when no NAND/MTD exists.
    MTD_COUNT=$(grep -c '^mtd[0-9]' /proc/mtd 2>/dev/null)
    if [ "$MTD_COUNT" -gt 0 ]; then
        MTD_FOUND=1
        echo "NAND_MTD_FOUND=1"
        echo "NAND_MTD_COUNT=${MTD_COUNT}"

        PART_NUM=0
        while read -r line; do
            # Direct echo output avoids fragile printf %b buffering and skips /proc/mtd header rows.
            case "$line" in mtd*) ;;
                *) continue ;;
            esac
            DEV=$(echo "$line" | cut -d: -f1)
            NAME=$(echo "$line" | cut -d'"' -f2)
            SIZE_HEX=$(echo "$line" | awk '{print $2}')
            # Safe hex conversion
            SIZE_DEC=$(printf "%d" "0x${SIZE_HEX}" 2>/dev/null || echo 0)
            SIZE_KB=$((SIZE_DEC / 1024))
            SIZE_MB=$((SIZE_KB / 1024))
            echo "NAND_P_${PART_NUM}=${DEV}:${NAME}:${SIZE_MB}MB"
            PART_NUM=$((PART_NUM + 1))
        done < /proc/mtd
        echo "NAND_PART_TOTAL=${PART_NUM}"
    fi
fi

# Sysfs MTD details
PART_NUM=0
HAS_ECC_ERR=0
HAS_CORRECTED=0
for mtd in /sys/class/mtd/mtd*; do
    [ -d "$mtd" ] || continue
    base="${mtd##*/}"
    case "$base" in
        mtd[0-9]*) ;;
        *) continue ;;
    esac
    case "${base#mtd}" in
        ''|*[!0-9]*) continue ;;
    esac

    if [ -d "$mtd" ]; then
        DEV_NAME=$(cat "$mtd/name" 2>/dev/null || echo "?")
        DEV_SIZE=$(cat "$mtd/size" 2>/dev/null || echo "0")
        WRITE_SZ=$(cat "$mtd/writesize" 2>/dev/null || echo "?")
        BAD_BLKS=$(cat "$mtd/bad_blocks" 2>/dev/null || echo "?")
        ECC_F=$(cat "$mtd/ecc_failures" 2>/dev/null || echo "?")
        CORR=$(cat "$mtd/corrected_bits" 2>/dev/null || echo "?")

        SIZE_MB=$((DEV_SIZE / 1024 / 1024))
        echo "NAND_${PART_NUM}=${DEV_NAME}:${SIZE_MB}MB:${BAD_BLKS}bad:ECC${ECC_F}"

        if [ "$ECC_F" != "?" ] && [ "$ECC_F" != "0" ]; then
            HAS_ECC_ERR=1
            echo "NAND_${PART_NUM}_ECC=FAIL(${ECC_F})"
        fi
        if [ "$CORR" != "?" ] && [ "$CORR" != "0" ]; then
            HAS_CORRECTED=1
            echo "NAND_${PART_NUM}_CORRECTED=${CORR}"
        fi
        PART_NUM=$((PART_NUM + 1))
    fi
done
echo "NAND_DETAIL_COUNT=${PART_NUM}"

# UBI check
if command -v ubinfo >/dev/null 2>&1; then
    UBI_COUNT=0
    for ubi in /sys/class/ubi/ubi*; do
        [ -d "$ubi" ] && UBI_COUNT=$((UBI_COUNT + 1))
    done
    if [ "$UBI_COUNT" -gt 0 ]; then
        echo "NAND_UBI_DEVICES=${UBI_COUNT}"
        VOL_INFO=$(ubinfo -a 2>/dev/null | grep "Volume ID" | wc -l)
        echo "NAND_UBI_VOLUMES=${VOL_INFO}"
    fi
fi

# Health verdict
if [ "$HAS_ECC_ERR" -eq 1 ]; then
    echo "NAND_HEALTH=WARN - ECC错误"
elif [ "$HAS_CORRECTED" -eq 1 ]; then
    echo "NAND_HEALTH=WARN - 有已纠正错误"
elif [ "$MTD_FOUND" -eq 1 ]; then
    echo "NAND_HEALTH=OK"
else
    echo "NAND_HEALTH=N/A"
fi

echo "NAND_DONE=1"
