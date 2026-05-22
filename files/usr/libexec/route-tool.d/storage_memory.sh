# by 数码罗记 · godsun.pro
#!/bin/sh
# Memory Pressure Test - tmpfs fill stability check
# Usage: storage_memory.sh [mode:info|quick|standard|full|stress|burnin] [size_MB] [duration_sec]
#
# Intent: this is not a reliable RAM bandwidth benchmark. It fills /tmp (tmpfs/RAM)
# with /dev/zero and checks whether the router stays alive and cleanup succeeds.
# "No space left on device" is expected for the full-fill mode and is treated as PASS.

MODE="${1:-quick}"
SIZE="${2:-0}"
DURATION="${3:-60}"
case "$SIZE" in ''|*[!0-9]*) SIZE=0 ;; esac
case "$DURATION" in ''|*[!0-9]*) DURATION=60 ;; esac

TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2}')
FREE_MEM=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
[ -n "$TOTAL_MEM" ] || TOTAL_MEM=0
[ -n "$FREE_MEM" ] || FREE_MEM=0
TOTAL_MB=$((TOTAL_MEM / 1024))
FREE_MB=$((FREE_MEM / 1024))
TMP_FREE_KB=$(df -P /tmp 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$TMP_FREE_KB" ] || TMP_FREE_KB=0
TMP_FREE_MB=$((TMP_FREE_KB / 1024))

TEST_FILE="/tmp/route-tool-memfill-$$.dat"
cleanup() {
    rm -f "$TEST_FILE" /tmp/memory_test_$$.dat /tmp/mem_burn_$$.dat /tmp/mem_stress_$$_*.dat /tmp/mem_rnd_*_$$.dat 2>/dev/null
}
trap cleanup EXIT HUP INT TERM

now_cs() {
    awk '{printf "%d", $1 * 100}' /proc/uptime 2>/dev/null
}

file_size_bytes() {
    wc -c "$1" 2>/dev/null | awk '{print $1}'
}

calc_speed() {
    bytes="$1"
    start="$2"
    end="$3"
    delta=$((end - start))
    [ "$delta" -le 0 ] && delta=1
    awk -v b="$bytes" -v d="$delta" 'BEGIN { if (d<=0) d=1; printf "%.1f", (b * 10000) / (1048576 * d) }'
}

choose_target_mb() {
    mode="$1"
    explicit="$2"
    tmp_free="$3"
    mem_avail="$4"

    if [ "$explicit" -gt 0 ]; then
        target="$explicit"
    else
        case "$mode" in
            quick)
                target=$((mem_avail / 4))
                [ "$target" -lt 64 ] && target=64
                [ "$target" -gt 256 ] && target=256
                ;;
            standard|stress|burnin)
                target=$((mem_avail * 60 / 100))
                [ "$target" -lt 128 ] && target=128
                [ "$target" -gt 1024 ] && target=1024
                ;;
            full)
                # Request more than available tmpfs so ENOSPC becomes the normal stop condition.
                target=$((tmp_free + 256))
                [ "$target" -lt 256 ] && target=256
                ;;
            *)
                target=$((mem_avail / 2))
                [ "$target" -lt 128 ] && target=128
                [ "$target" -gt 1024 ] && target=1024
                ;;
        esac
    fi

    # For non-full modes, keep a /tmp reserve to avoid breaking LuCI/SSH.
    if [ "$mode" != "full" ]; then
        reserve=64
        [ "$tmp_free" -lt 256 ] && reserve=32
        max_safe=$((tmp_free - reserve))
        [ "$max_safe" -lt 1 ] && max_safe=1
        [ "$target" -gt "$max_safe" ] && target="$max_safe"
    fi
    [ "$target" -lt 1 ] && target=1
    echo "$target"
}

echo "MEM_TOTAL_KB=${TOTAL_MEM}"
echo "MEM_TOTAL_MB=${TOTAL_MB}"
echo "MEM_FREE_KB=${FREE_MEM}"
echo "MEM_FREE_MB=${FREE_MB}"
echo "MEM_AVAILABLE_KB=${FREE_MEM}"
echo "MEM_AVAILABLE_MB=${FREE_MB}"
echo "MEM_TMP_FREE_KB=${TMP_FREE_KB}"
echo "MEM_TMP_FREE_MB=${TMP_FREE_MB}"
echo "MEM_MODE=${MODE}"
echo "MEM_TEST_KIND=tmpfs_pressure"
echo "MEM_TARGET=/tmp"
echo "MEM_NOTE=仅供参考：该测试写入/tmp(tmpfs)制造内存压力，不代表真实内存带宽；设备不重启且能清理即说明基本稳定。"

if [ "$MODE" = "info" ]; then
    echo "MEM_TEST_DONE=info"
    exit 0
fi

case "$MODE" in
    quick|standard|full|stress|burnin) ;;
    *) MODE="quick"; echo "MEM_MODE_NORMALIZED=quick" ;;
esac

TARGET_MB=$(choose_target_mb "$MODE" "$SIZE" "$TMP_FREE_MB" "$FREE_MB")
COUNT=$((TARGET_MB * 1024 / 8))
[ "$COUNT" -lt 1 ] && COUNT=1
REQUEST_MB=$((COUNT * 8 / 1024))

EXPECTED="count_done"
[ "$MODE" = "full" ] && EXPECTED="tmpfs_full"

echo "MEM_PHASE=tmpfs_pressure_write"
echo "MEM_TEST_FILE=${TEST_FILE}"
echo "MEM_BLOCK_SIZE=8K"
echo "MEM_COUNT=${COUNT}"
echo "MEM_REQUEST_MB=${REQUEST_MB}"
echo "MEM_PRESSURE_TARGET_MB=${TARGET_MB}"
echo "MEM_EXPECTED_STOP=${EXPECTED}"
echo "MEM_REFERENCE_ONLY=1"

sync
START=$(now_cs)
DD_OUT=$(dd if=/dev/zero of="$TEST_FILE" bs=8k count="$COUNT" 2>&1)
WRITE_RC=$?
END=$(now_cs)

WRITTEN_BYTES=$(file_size_bytes "$TEST_FILE")
[ -n "$WRITTEN_BYTES" ] || WRITTEN_BYTES=0
WRITTEN_MB=$(awk -v b="$WRITTEN_BYTES" 'BEGIN { printf "%.1f", b / 1048576 }')
WRITE_SPEED=$(calc_speed "$WRITTEN_BYTES" "$START" "$END")
WRITE_TIME_CS=$((END - START))
[ "$WRITE_TIME_CS" -le 0 ] && WRITE_TIME_CS=1

if echo "$DD_OUT" | grep -qi "No space\|space left\|ENOSPC"; then
    STOP_REASON="tmpfs_full"
elif [ "$WRITE_RC" -eq 0 ]; then
    STOP_REASON="count_done"
else
    STOP_REASON="dd_error"
fi

echo "MEM_WRITTEN_BYTES=${WRITTEN_BYTES}"
echo "MEM_WRITTEN_MB=${WRITTEN_MB}"
# Kept for backward compatibility with older JS/log parsers; UI marks it as reference only.
echo "MEM_WRITE_SPEED=${WRITE_SPEED}"
echo "MEM_WRITE_TIME_CS=${WRITE_TIME_CS}"
echo "MEM_WRITE_RC=${WRITE_RC}"
echo "MEM_STOP_REASON=${STOP_REASON}"
printf '%s\n' "$DD_OUT" | sed 's/^/MEM_DD_OUT=/'

echo "MEM_PHASE=cleanup"
cleanup
sync
TMP_FREE_AFTER_KB=$(df -P /tmp 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$TMP_FREE_AFTER_KB" ] || TMP_FREE_AFTER_KB=0
echo "MEM_TMP_FREE_AFTER_KB=${TMP_FREE_AFTER_KB}"
echo "MEM_TMP_FREE_AFTER_MB=$((TMP_FREE_AFTER_KB / 1024))"
echo "MEM_CLEANUP_DONE=1"

if [ "$STOP_REASON" = "tmpfs_full" ] || [ "$STOP_REASON" = "count_done" ]; then
    echo "MEM_PRESSURE_VERDICT=PASS"
    echo "MEM_VERDICT=PASS"
    echo "MEM_RESULT_TEXT=通过：设备保持在线，/tmp压力文件已清理"
else
    echo "MEM_PRESSURE_VERDICT=FAIL"
    echo "MEM_VERDICT=FAIL"
    echo "MEM_RESULT_TEXT=失败：dd写入异常，请检查内存、/tmp空间或系统日志"
fi

# Optional repeated pressure loop for longer observation; still bounded and cleans every round.
if [ "$MODE" = "stress" ] || [ "$MODE" = "burnin" ]; then
    echo "MEM_PHASE=stress_loop"
    echo "MEM_STRESS_DURATION=${DURATION}"
    SPASS=0
    SFAIL=0
    SSTART_CS=$(now_cs)
    SEND_CS=$((SSTART_CS + DURATION * 100))
    LOOP_MB="$TARGET_MB"
    [ "$LOOP_MB" -gt 128 ] && LOOP_MB=128
    LOOP_COUNT=$((LOOP_MB * 1024 / 8))
    [ "$LOOP_COUNT" -lt 1 ] && LOOP_COUNT=1
    while [ "$(now_cs)" -lt "$SEND_CS" ]; do
        rm -f "$TEST_FILE"
        dd if=/dev/zero of="$TEST_FILE" bs=8k count="$LOOP_COUNT" >/dev/null 2>&1
        RC=$?
        if [ -s "$TEST_FILE" ] && { [ "$RC" -eq 0 ] || [ "$RC" -eq 1 ]; }; then
            SPASS=$((SPASS + 1))
        else
            SFAIL=$((SFAIL + 1))
        fi
        rm -f "$TEST_FILE"
    done
    echo "MEM_STRESS_PASS=${SPASS}"
    echo "MEM_STRESS_FAIL=${SFAIL}"
    if [ "$SFAIL" -gt 0 ]; then
        echo "MEM_STRESS_VERDICT=FAIL"
    else
        echo "MEM_STRESS_VERDICT=PASS"
    fi
fi

echo "MEM_TEST_DONE=1"
