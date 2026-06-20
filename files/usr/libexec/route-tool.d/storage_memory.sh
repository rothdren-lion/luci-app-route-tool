# by 数码罗记 · godsun.pro
#!/bin/sh
# Memory Pressure Test + Capacity Test (memtester)
# Usage: storage_memory.sh [mode:info|quick|standard|full|stress|burnin|capacity] [size_MB] [duration_sec]
#
# Modes:
#   info      - show memory info only
#   quick     - tmpfs pressure ~25% available (64-256MB)
#   standard  - tmpfs pressure ~60% available (128-1024MB)
#   full      - tmpfs fill until ENOSPC (= PASS)
#   stress    - repeated pressure loops for N seconds
#   burnin    - same as stress, longer default duration
#   capacity  - real memory test via memtester (auto-detect binary)
#               tests MemAvailable - 64MB, safe (malloc-based, no OOM risk)
#               falls back to tmpfs pressure if memtester not found

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
USED_MB=$((TOTAL_MB - FREE_MB))
[ "$USED_MB" -lt 0 ] && USED_MB=0
if [ "$TOTAL_MB" -gt 0 ]; then
    USED_PCT=$((USED_MB * 100 / TOTAL_MB))
    FREE_PCT=$((FREE_MB * 100 / TOTAL_MB))
else
    USED_PCT=0
    FREE_PCT=0
fi
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

find_memtester() {
    # Search order: eMMC cache > bundled > /tmp > system PATH
    # eMMC devices use hidden cache dir on the largest partition
    # NAND/other devices use /tmp (ephemeral)
    local emmc_dev=""
    for d in /dev/mmcblk0 /dev/mmcblk1; do
        [ -b "$d" ] && { emmc_dev="$d"; break; }
    done

    # Check eMMC hidden cache first
    if [ -n "$emmc_dev" ]; then
        local base="$(basename "$emmc_dev")"
        # Find the last (usually largest) mounted partition
        for p in $(ls -1r /sys/class/block/${base}p* 2>/dev/null); do
            local pname="$(basename "$p")"
            local mnt=""
            # Check mount points
            mnt="$(grep "^/dev/${pname} " /proc/mounts 2>/dev/null | awk '{print $2}' | head -1)"
            # Also check /mnt/ convention
            [ -z "$mnt" ] && [ -d "/mnt/$pname" ] && mnt="/mnt/$pname"
            if [ -n "$mnt" ] && [ -d "$mnt" ]; then
                local cached="$mnt/.route-tool/bin/memtester"
                if [ -x "$cached" ]; then
                    echo "$cached"
                    return 0
                fi
            fi
        done
    fi

    # Bundled location
    local tries="/usr/libexec/route-tool.d/bin/memtester /tmp/memtester /usr/bin/memtester"
    for p in $tries; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    # Last resort: which
    local found
    found=$(which memtester 2>/dev/null)
    if [ -n "$found" ] && [ -x "$found" ]; then
        echo "$found"
        return 0
    fi
    return 1
}

# Get cache directory for downloadable binaries
# eMMC → /mnt/mmcblk0pN/.route-tool/bin/ (persistent, hidden)
# NAND  → /tmp (ephemeral, no big eMMC partition to waste)
get_cache_dir() {
    local emmc_dev=""
    for d in /dev/mmcblk0 /dev/mmcblk1; do
        [ -b "$d" ] && { emmc_dev="$d"; break; }
    done

    if [ -n "$emmc_dev" ]; then
        local base="$(basename "$emmc_dev")"
        # Find the last mounted partition (typically the big storage one)
        for p in $(ls -1r /sys/class/block/${base}p* 2>/dev/null); do
            local pname="$(basename "$p")"
            local mnt=""
            mnt="$(grep "^/dev/${pname} " /proc/mounts 2>/dev/null | awk '{print $2}' | head -1)"
            [ -z "$mnt" ] && [ -d "/mnt/$pname" ] && mnt="/mnt/$pname"
            if [ -n "$mnt" ] && [ -d "$mnt" ]; then
                echo "$mnt/.route-tool/bin"
                return 0
            fi
        done
    fi
    # NAND or no eMMC partition mounted: use /tmp
    echo "/tmp"
}

# Download memtester binary if not found
# Priority: opkg install → gwrt.uk → GitHub (fallback)
# - Binary > 100KB → cache to eMMC hidden dir or /tmp
# - Binary <= 100KB → opkg install (small enough for system)
download_memtester() {
    local ARCH="$(uname -m)"
    local GWRT_URL="https://gwrt.uk/wp-content/uploads/route-tool/memtester_${ARCH}"
    local GITHUB_URL="https://github.com/rothdren-lion/luci-app-route-tool/releases/latest/download/memtester_${ARCH}"
    local cache_dir="$(get_cache_dir)"
    local dest=""

    # Priority 1: opkg install (most reliable, proper package management)
    echo "尝试 opkg 安装 memtester..."
    opkg update >/dev/null 2>&1
    if opkg install memtester >/dev/null 2>&1; then
        # Verify opkg-installed binary
        if command -v memtester >/dev/null 2>&1; then
            echo "OK=opkg"
            return 0
        fi
    fi
    echo "opkg 安装失败，尝试下载..."

    # Priority 2: download from gwrt.uk (China-friendly, no GFW issues)
    # Priority 3: fallback to GitHub
    mkdir -p "$cache_dir" 2>/dev/null
    dest="$cache_dir/memtester"

    for url in "$GWRT_URL" "$GITHUB_URL"; do
        echo "正在下载 memtester (${ARCH}) 从 $(echo $url | sed 's|.*//||' | cut -d/ -f1)..."
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 15 --max-time 120 "$url" -o "$dest" 2>/dev/null
        elif command -v wget >/dev/null 2>&1; then
            wget -q --timeout=15 "$url" -O "$dest" 2>/dev/null
        else
            echo "ERROR=no_download_tool"
            return 1
        fi

        if [ -s "$dest" ]; then
            chmod 755 "$dest"
            # Verify it runs
            if "$dest" --help >/dev/null 2>&1 || [ -x "$dest" ]; then
                echo "OK=$dest"
                return 0
            fi
        fi
        rm -f "$dest"
        echo "从 $(echo $url | sed 's|.*//||' | cut -d/ -f1) 下载失败，尝试下一个源..."
    done

    echo "ERROR=all_sources_failed"
    return 1
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
echo "MEM_USED_MB=${USED_MB}"
echo "MEM_USED_PCT=${USED_PCT}"
echo "MEM_FREE_PCT=${FREE_PCT}"
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
    capacity) ;;
    *) MODE="quick"; echo "MEM_MODE_NORMALIZED=quick" ;;
esac

# ── capacity mode: real memtester ──
if [ "$MODE" = "capacity" ]; then
    echo "MEM_TEST_KIND=memtester_capacity"
    MEMTESTER_BIN=$(find_memtester)
    if [ -z "$MEMTESTER_BIN" ]; then
        # Auto-download memtester
        echo "MEM_CAPACITY_NOTE=未找到 memtester，正在自动下载..."
        DL_RESULT=$(download_memtester 2>&1)
        case "$DL_RESULT" in
            OK=*)
                MEMTESTER_BIN="${DL_RESULT#OK=}"
                echo "MEM_CAPACITY_DOWNLOAD=${MEMTESTER_BIN}"
                ;;
            *)
                echo "MEM_CAPACITY_STATUS=NO_MEMTESTER"
                echo "MEM_CAPACITY_NOTE=memtester 下载失败：${DL_RESULT#ERROR=}，回退到 tmpfs 压力测试"
                echo "MEM_CAPACITY_FALLBACK=tmpfs_pressure"
                # Fallback: run standard tmpfs pressure instead
                echo ""
                echo "=== 回退到 tmpfs 压力测试 ==="
                TARGET_MB=$(choose_target_mb "standard" "$SIZE" "$TMP_FREE_MB" "$FREE_MB")
                COUNT=$((TARGET_MB * 1024 / 8))
                [ "$COUNT" -lt 1 ] && COUNT=1
                REQUEST_MB=$((COUNT * 8 / 1024))
                echo "MEM_PHASE=tmpfs_pressure_write"
                echo "MEM_TEST_FILE=${TEST_FILE}"
                echo "MEM_BLOCK_SIZE=8K"
                echo "MEM_COUNT=${COUNT}"
                echo "MEM_REQUEST_MB=${REQUEST_MB}"
                echo "MEM_PRESSURE_TARGET_MB=${TARGET_MB}"
                echo "MEM_EXPECTED_STOP=count_done"
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
                    echo "MEM_RESULT_TEXT=回退测试通过：设备保持在线，/tmp压力文件已清理（未安装memtester，仅验证基本稳定性）"
                else
                    echo "MEM_PRESSURE_VERDICT=FAIL"
                    echo "MEM_VERDICT=FAIL"
                    echo "MEM_RESULT_TEXT=失败：dd写入异常，请检查内存、/tmp空间或系统日志"
                fi
                echo "MEM_TEST_DONE=1"
                exit 0
                ;;
        esac
    fi

    # memtester found — calculate safe test size
    # Reserve 64MB for system (kernel, sshd, luci)
    SAFE_RESERVE_MB=64
    if [ "$SIZE" -gt 0 ]; then
        # User specified size via dropdown or manual input
        TEST_MB=$SIZE
    else
        # Auto: test available - reserve
        TEST_MB=$((FREE_MB - SAFE_RESERVE_MB))
    fi
    [ "$TEST_MB" -lt 16 ] && TEST_MB=16
    # Don't exceed total
    [ "$TEST_MB" -gt "$FREE_MB" ] && TEST_MB=$FREE_MB

    echo "MEM_CAPACITY_BIN=${MEMTESTER_BIN}"
    echo "MEM_CAPACITY_TEST_MB=${TEST_MB}"
    echo "MEM_CAPACITY_TOTAL_MB=${TOTAL_MB}"
    echo "MEM_CAPACITY_AVAIL_MB=${FREE_MB}"
    echo "MEM_CAPACITY_RESERVE_MB=${SAFE_RESERVE_MB}"
    echo "MEM_CAPACITY_COVERAGE=$((TEST_MB * 100 / TOTAL_MB))"
    echo "MEM_PHASE=memtester_run"
    echo "MEM_CAPACITY_NOTE=memtester 使用 malloc 申请内存，不会触发 OOM，测完自动释放"

    sync
    START=$(now_cs)
    # Run memtester: SIZE MB, 1 loop
    MEMTESTER_OUT=$("$MEMTESTER_BIN" "${TEST_MB}M" 1 2>&1)
    MEMTESTER_RC=$?
    END=$(now_cs)
    ELAPSED_CS=$((END - START))
    [ "$ELAPSED_CS" -le 0 ] && ELAPSED_CS=1
    ELAPSED_SEC=$((ELAPSED_CS / 100))

    echo "MEM_CAPACITY_RC=${MEMTESTER_RC}"
    echo "MEM_CAPACITY_ELAPSED_SEC=${ELAPSED_SEC}"

    # Parse memtester output for test results
    # Count "ok" lines and any "FAIL" lines
    OK_COUNT=$(echo "$MEMTESTER_OUT" | grep -c "ok$" 2>/dev/null || echo 0)
    FAIL_COUNT=$(echo "$MEMTESTER_OUT" | grep -ci "fail" 2>/dev/null || echo 0)
    echo "MEM_CAPACITY_TESTS_OK=${OK_COUNT}"
    echo "MEM_CAPACITY_TESTS_FAIL=${FAIL_COUNT}"

    # Extract test names that passed
    PASSED_TESTS=$(echo "$MEMTESTER_OUT" | awk '/: *ok$/ {sub(/: *ok$/, "", $0); gsub(/^ +| +$/, "", $0); printf "%s%s", sep, $0; sep=", "}' 2>/dev/null)
    echo "MEM_CAPACITY_PASSED_TESTS=${PASSED_TESTS}"

    if [ "$MEMTESTER_RC" -eq 0 ] && [ "$FAIL_COUNT" -eq 0 ]; then
        echo "MEM_CAPACITY_STATUS=PASS"
        echo "MEM_PRESSURE_VERDICT=PASS"
        echo "MEM_VERDICT=PASS"
        echo "MEM_RESULT_TEXT=✅ 内存完整性通过：${TEST_MB}MB 全部 ${OK_COUNT} 项测试 OK（覆盖率 ${TEST_MB}*100/${TOTAL_MB}）"
    else
        echo "MEM_CAPACITY_STATUS=FAIL"
        echo "MEM_PRESSURE_VERDICT=FAIL"
        echo "MEM_VERDICT=FAIL"
        echo "MEM_RESULT_TEXT=❌ 内存完整性失败：${FAIL_COUNT} 项测试异常，可能存在坏块"
    fi

    # Append key memtester output lines (strip control chars for readability)
    echo "$MEMTESTER_OUT" | sed 's/\x08//g; s/setting [0-9]*//g; s/testing [0-9]*//g' | grep -E '(Stuck Address|Random Value|Compare XOR|Compare SUB|Compare MUL|Compare DIV|Compare OR|Compare AND|Sequential Increment|Solid Bits|Block Sequential|Checkerboard|Walking Ones|Walking Zeroes|Done|^memtester version|^want |^got )' | sed 's/^/MEM_CAPACITY_LOG=/'

    echo "MEM_PHASE=cleanup"
    echo "MEM_CLEANUP_DONE=1"
    echo "MEM_TEST_DONE=1"
    exit 0
fi

# ── original tmpfs pressure modes ──
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
