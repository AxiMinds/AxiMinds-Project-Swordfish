#!/usr/bin/env bash
# Dual-run FFN consumer + fixture forward + test suite (compendious local verify).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ZIG="${ZIG:-/tmp/zig-x86_64-linux-0.16.0/zig}"
export PATH="$(dirname "$ZIG"):/home/linuxbrew/.linuxbrew/bin:${PATH:-}"
LOGDIR="$ROOT/logs"
mkdir -p "$LOGDIR"
TS="$(date -Iseconds)"

echo "=== [$TS] zig build test ===" | tee "$LOGDIR/verify-rerun.log"
"$ZIG" build test --summary all 2>&1 | tee -a "$LOGDIR/verify-rerun.log"

echo "=== FFN dual-run ===" | tee -a "$LOGDIR/verify-rerun.log"
"$ZIG" build run -- ffn-consumer --cycles 128 2>&1 | tee -a "$LOGDIR/verify-rerun.log"
"$ZIG" build run -- ffn-consumer --cycles 128 2>&1 | tee -a "$LOGDIR/verify-rerun.log"

echo "=== GGUF forward fixture ===" | tee -a "$LOGDIR/verify-rerun.log"
"$ZIG" build run -- gguf-forward --path src/models/fixtures/tiny.gguf --prompt "verify" --max-tokens 4 2>&1 | tee -a "$LOGDIR/verify-rerun.log"

echo "=== live-demo ===" | tee -a "$LOGDIR/verify-rerun.log"
"$ZIG" build run -- live-demo --path src/models/fixtures/tiny.gguf --prompt "verify" --cycles 64 --max-tokens 4 2>&1 | tee -a "$LOGDIR/verify-rerun.log"

echo "OK — see $LOGDIR/verify-rerun.log and $LOGDIR/AXINC-TEST-RESULTS.md"
