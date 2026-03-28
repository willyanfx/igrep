#!/bin/bash
# Benchmark script for comparing igrep vs ripgrep vs grep
# TODO: add hyperfine integration for statistical analysis
# FIXME: this script assumes all tools are in PATH

set -euo pipefail

CORPUS_DIR="${1:-.}"
PATTERN="${2:-TODO}"
ITERATIONS="${3:-10}"

echo "=== Search Benchmark ==="
echo "Corpus: $CORPUS_DIR"
echo "Pattern: $PATTERN"
echo "Iterations: $ITERATIONS"
echo ""

# Check which tools are available
tools=()
if command -v igrep &>/dev/null; then tools+=("igrep"); fi
if command -v rg &>/dev/null; then tools+=("rg"); fi
if command -v grep &>/dev/null; then tools+=("grep -r"); fi

if [ ${#tools[@]} -eq 0 ]; then
    echo "ERROR: No search tools found in PATH"
    exit 1
fi

for tool in "${tools[@]}"; do
    echo "--- $tool ---"
    total=0
    for i in $(seq 1 "$ITERATIONS"); do
        start=$(date +%s%N)
        $tool "$PATTERN" "$CORPUS_DIR" > /dev/null 2>&1 || true
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        total=$((total + elapsed))
    done
    avg=$((total / ITERATIONS))
    echo "Average: ${avg}ms over $ITERATIONS runs"
    echo ""
done
