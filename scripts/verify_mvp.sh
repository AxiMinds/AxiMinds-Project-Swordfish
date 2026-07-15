#!/bin/bash
# Atomic verify for MVP per strategy.
# rm first, >file 2>&1 + .exit, post conditions (diff first rates run1/2, test -s), pure.
# Empty build logs ok if .exit==0.
set -euo pipefail
SCRATCH=${SCRATCH:-/tmp/idare/grok-goal-1807a5ddb40b/implementer}
ZIG="/tmp/zig-x86_64-linux-0.16.0/zig"

rm -rf "$SCRATCH"/* .zig-cache zig-out l4_cache l5_shards 2>/dev/null || true
mkdir -p "$SCRATCH" l4_cache l5_shards

# builds with .exit , use --summary all for raw transcript in logs (even success)
$ZIG build --summary all > "$SCRATCH/audit-build.log" 2>&1; rc=$?; echo $rc > "$SCRATCH/audit-build.log.exit"
$ZIG build test --summary all > "$SCRATCH/audit-test.log" 2>&1; rc=$?; echo $rc > "$SCRATCH/audit-test.log.exit"
$ZIG build bench --summary all > "$SCRATCH/verif-bench.log" 2>&1; rc=$?; echo $rc > "$SCRATCH/verif-bench.log.exit"

# runs with clean , .exit ; pre-builds with summary for raw content
rm -rf l4_cache l5_shards; mkdir -p l4_cache l5_shards
$ZIG build --summary all > "$SCRATCH/audit-build-r1.log" 2>&1; echo $? > "$SCRATCH/audit-build-r1.log.exit"
./zig-out/bin/axinc > "$SCRATCH/run1.log" 2>&1; echo $? > "$SCRATCH/run1.log.exit"

rm -rf l4_cache l5_shards; mkdir -p l4_cache l5_shards
$ZIG build --summary all > "$SCRATCH/audit-build-r2.log" 2>&1; echo $? > "$SCRATCH/audit-build-r2.log.exit"
./zig-out/bin/axinc > "$SCRATCH/run2.log" 2>&1; echo $? > "$SCRATCH/run2.log.exit"

$ZIG test src/kgdb/root.zig > "$SCRATCH/kgdb-test.log" 2>&1; echo $? > "$SCRATCH/kgdb-test.log.exit"

# html / artifacts (no extra)
wc -l demo-ocean.html > "$SCRATCH/html-check.log" 2>&1 || true
grep -E 'nc-pane|nc-log|data-real-trace|canvas id="ocean"' demo-ocean.html >> "$SCRATCH/html-check.log" 2>&1 || true
ls l4_cache/ > "$SCRATCH/artifacts-l4.log" 2>&1 || true
ls l5_shards/ > "$SCRATCH/artifacts-l5.log" 2>&1 || true

# verif-final: cleaned concat of rate/trace lines only (strip banner 'AxiMinds...' and 'Demo complete' for pure)
grep -E '\[T\+|AI REAL|NC-TRACE|NC SELF-MOD|NC op:' "$SCRATCH/run1.log" > "$SCRATCH/verif-final.log" 2>/dev/null || true
grep -E '\[T\+|AI REAL|NC-TRACE|NC SELF-MOD|NC op:' "$SCRATCH/run2.log" >> "$SCRATCH/verif-final.log" 2>/dev/null || true

# post-conditions: first (l4= l5=) lines from run1 and run2 must match (uniform)
grep -o '(l4=[^)]*)' "$SCRATCH/run1.log" | head -1 > "$SCRATCH/_r1_first_rate.txt" || true
grep -o '(l4=[^)]*)' "$SCRATCH/run2.log" | head -1 > "$SCRATCH/_r2_first_rate.txt" || true
diff "$SCRATCH/_r1_first_rate.txt" "$SCRATCH/_r2_first_rate.txt" || { echo "first rates differ"; exit 1; }

test -s "$SCRATCH/run1.log"
test -s "$SCRATCH/run2.log"

echo "verify ok" > "$SCRATCH/verify-ok.txt"
echo "Atomic verify complete"