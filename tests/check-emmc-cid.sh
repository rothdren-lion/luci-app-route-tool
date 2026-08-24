#!/bin/sh
# Regression test: eMMC CID parsing (PNM ascii decode + MDT date decode)
# Fixtures: 59 real chips dumped with XGecu T76 programmer (ECSD_CSD.BIN @0x200,
# stored LSB-first). Dates cross-checked against T76 log.txt where the log and
# BIN belong to the same chip.
#
# Usage: sh tests/check-emmc-cid.sh
BASE=$(cd "$(dirname "$0")/.." && pwd)
. "$BASE/files/usr/libexec/route-tool.d/storage_common.sh"

CSV="$BASE/tests/emmc_cid_fixtures.csv"
[ -f "$CSV" ] || { echo "fixtures not found: $CSV"; exit 1; }

pass=0; fail=0
while IFS=, read -r sample mid pnm_ascii pnm_hex prv mdt date check; do
    [ -n "$sample" ] || continue
    [ "$sample" = "sample" ] && continue
    got_ascii="$(rt_hex2ascii "$pnm_hex")"
    got_date="$(rt_cid_mdt "$mdt")"
    ok=1
    [ "$got_ascii" = "$pnm_ascii" ] || { echo "FAIL [$sample] PNM: want '$pnm_ascii' got '$got_ascii'"; ok=0; }
    [ "$got_date" = "$date" ]     || { echo "FAIL [$sample] DATE(mdt=$mdt): want '$date' got '$got_date'"; ok=0; }
    if [ "$ok" = 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi
done < "$CSV"

echo "emmc cid fixtures: pass=$pass fail=$fail / 59"
[ "$fail" -eq 0 ]
