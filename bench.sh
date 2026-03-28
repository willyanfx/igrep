#!/usr/bin/env bash
set -euo pipefail

IGREP="./zig-out/bin/igrep"
CORPUS="bench_corpus"
RUNS=5
WARMUP=2

bench() {
    local label="$1"; shift
    local cmd=("$@")
    local times=()
    for ((i=0; i<WARMUP; i++)); do "${cmd[@]}" > /dev/null 2>&1 || true; done
    for ((i=0; i<RUNS; i++)); do
        local s e; s=$(date +%s%N)
        "${cmd[@]}" > /dev/null 2>&1 || true
        e=$(date +%s%N); times+=("$(( (e - s) / 1000000 ))")
    done
    local min=999999 max=0 sum=0
    for t in "${times[@]}"; do sum=$((sum+t)); ((t<min))&&min=$t; ((t>max))&&max=$t; done
    printf "  %-22s  %4d ms  (min=%d, max=%d)\n" "$label" "$((sum/RUNS))" "$min" "$max"
}

echo "Building trigram index..."
$IGREP --index-build "$CORPUS" 2>&1 | grep "igrep:"

FILES=$(find "$CORPUS" -type f | wc -l)
SIZE=$(du -sh "$CORPUS" | cut -f1)
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  igrep benchmark — $FILES files, $SIZE — $RUNS runs, $WARMUP warmup"
echo "═══════════════════════════════════════════════════════════════"

for pattern in "function" "import" "TypeError" "NONEXISTENT_XYZ"; do
    count=$($IGREP "$pattern" "$CORPUS" 2>&1 | grep -vc "^igrep:" || echo 0)
    echo ""
    echo "── literal: '$pattern'  ($count matches) ──"
    bench "igrep"          $IGREP "$pattern" "$CORPUS"
    bench "igrep --index"  $IGREP --index "$pattern" "$CORPUS"
    bench "rg"             rg "$pattern" "$CORPUS"
    bench "grep -rn"       grep -rn "$pattern" "$CORPUS"
done

echo ""
echo "── fixed-string: 'function' ──"
bench "igrep -F"         $IGREP -F "function" "$CORPUS"
bench "rg -F"            rg -F "function" "$CORPUS"
bench "grep -rFn"        grep -rFn "function" "$CORPUS"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Done."
echo "═══════════════════════════════════════════════════════════════"
