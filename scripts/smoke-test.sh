#!/usr/bin/env bash
# deromine bash smoke tests — non-interactive verification of the bash path.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

PASS=0
FAIL=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== deromine bash smoke tests ==="
echo ""

# 1. Prerequisites
echo "1. Prerequisites:"
if command -v jq >/dev/null 2>&1; then pass "jq available"; else fail "jq available"; fi
if command -v curl >/dev/null 2>&1; then pass "curl available"; else fail "curl available"; fi

# 2. miners.json is valid JSON with required fields
echo ""
echo "2. Catalog validation:"
if jq -e . miners.json >/dev/null 2>&1; then pass "miners.json parses as valid JSON"; else fail "miners.json parses as valid JSON"; fi
mcount=$(jq '.miners | length' miners.json)
pass "catalog has $mcount miners"
missing=0
while IFS= read -r mid; do
    for field in id name binary repo fee assets; do
        if ! jq -e --arg id "$mid" --arg f "$field" '.miners[] | select(.id == $id) | has($f)' miners.json >/dev/null 2>&1; then
            echo "    missing '$field' on miner '$mid'"
            missing=1
        fi
    done
done < <(jq -r '.miners[].id' miners.json)
if [ "$missing" -eq 0 ]; then pass "all miners have required fields"; else fail "all miners have required fields"; fi

# 3. --version works through the unified launcher
echo ""
echo "3. Version flag:"
ver=$(./deromine --version 2>&1 | head -1)
if [[ "$ver" =~ ^deromine\ [0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "--version prints '$ver'"
else
    fail "--version prints '$ver'"
fi

# 4. --miner=list exits 0 and renders the catalog
echo ""
echo "4. List mode:"
if ./deromine --miner=list >/dev/null 2>&1; then
    pass "--miner=list exits 0"
else
    fail "--miner=list exits 0"
fi

# 5. All catalog ids resolve a binary name for the current OS/arch
echo ""
echo "5. Binary names:"
res_ok=1
for mid in $(jq -r '.miners[].id' miners.json); do
    bin=$(jq -r --arg id "$mid" '.miners[] | select(.id == $id) | .binary // empty' miners.json)
    if [ -z "$bin" ]; then
        echo "    no binary field for '$mid'"
        res_ok=0
    fi
done
if [ "$res_ok" -eq 1 ]; then pass "all miners define a binary"; else fail "all miners define a binary"; fi

echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [ "$FAIL" -eq 0 ]; then
    echo "All smoke tests passed!"
else
    echo "Some smoke tests failed. See output above for details." >&2
    exit 1
fi
