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

# 5b. Per-arch binary names (derohe regression: arm64/windows names differ).
# Replicates get_binary_name / get_archive_binary_name from mine.sh so changes
# to the helpers (not just the catalog) are caught.
echo ""
echo "5b. Per-arch binary names:"
der_he=$(jq -c '.miners[] | select(.id == "derohe")' miners.json)
while IFS= read -r combo; do
    o=${combo%% *}; rest=${combo#* }; a=${rest%% *}; want=${rest#* }
    got=$(echo "$der_he" | jq -r --arg os "$o" --arg arch "$a" '
        first(.assets[] | select(.os == $os and .arch == $arch and ((.binary // "") != ""))).binary
        // first(.assets[] | select(.os == $os and ((.binary // "") != ""))).binary
        // .binary
        // ""')
    if [ "$o" = "windows" ] && [ -n "$got" ] && [[ "$got" != *.exe ]]; then got="${got}.exe"; fi
    if [ "$got" = "$want" ]; then pass "derohe $o/$a binary -> $got"; else fail "derohe $o/$a binary -> $got (want $want)"; fi
done <<'EOF'
linux amd64 dero-miner-linux-amd64
linux aarch64 dero-miner-linux-arm64
windows amd64 dero-miner-windows-amd64.exe
EOF
# Archive name used for the nested-binary lift (must be arm64 on aarch64).
awant="dero-miner-linux-arm64"
agot=$(echo "$der_he" | jq -r --arg os "linux" --arg arch "aarch64" '
    first(.assets[] | select(.os == $os and .arch == $arch and ((.binary_archive // "") != ""))).binary_archive
    // first(.assets[] | select(.os == $os and .arch == $arch and ((.binary // "") != ""))).binary
    // first(.assets[] | select(.os == $os and ((.binary_archive // "") != ""))).binary_archive
    // first(.assets[] | select(.os == $os and ((.binary // "") != ""))).binary
    // .binary_archive
    // .binary
    // ""')
if [ "$agot" = "$awant" ]; then pass "derohe linux/aarch64 archive name -> $agot"; else fail "derohe linux/aarch64 archive name -> $agot (want $awant)"; fi

# 5c. Termux exclusions (derohe must be hidden on Android/Termux)
echo ""
echo "5c. Termux exclusions:"
fake_base=$(mktemp -d)
mkdir -p "$fake_base/com.termux/bin"
fake_prefix="$fake_base/com.termux"
# derohe must be excluded under a Termux-like environment...
if PREFIX="$fake_prefix" bash -c '
    [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] && [ -d "$PREFIX/bin" ] \
        && jq -e ".miners[] | select(.id == \"derohe\") | .unsupported | index(\"termux\")" miners.json >/dev/null 2>&1
'; then
    pass "derohe excluded on Termux"
else
    fail "derohe excluded on Termux"
fi
# ...and zig too (its arm64 build dumps usage instead of mining on Android)...
if PREFIX="$fake_prefix" bash -c '
    [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] && [ -d "$PREFIX/bin" ] \
        && jq -e ".miners[] | select(.id == \"zig\") | .unsupported | index(\"termux\")" miners.json >/dev/null 2>&1
'; then
    pass "zig excluded on Termux"
else
    fail "zig excluded on Termux"
fi
# ...while dirtybird rust stays available.
if PREFIX="$fake_prefix" bash -c '
    [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] && [ -d "$PREFIX/bin" ] \
        && jq -e ".miners[] | select(.id == \"rust\") | .unsupported | index(\"termux\")" miners.json >/dev/null 2>&1
'; then
    fail "rust excluded on Termux"
else
    pass "rust not excluded on Termux"
fi
rm -rf "$fake_base"

# 5d. Cache integrity + version-aware cache. Extracts the REAL helper functions
# from mine.sh (not a copy) so edits to them are caught.
echo ""
echo "5d. Cache integrity:"
tmpcache=$(mktemp -d)
head -c 400000 /dev/zero > "$tmpcache/good.bin"
printf '\x7fELF' | dd of="$tmpcache/good.bin" bs=1 seek=0 conv=notrunc 2>/dev/null
head -c 400000 /dev/zero > "$tmpcache/bad.bin"
printf 'NOPE' | dd of="$tmpcache/bad.bin" bs=1 seek=0 conv=notrunc 2>/dev/null
printf '\x7fELFtiny' > "$tmpcache/small.bin"
eval "$(sed -n '/^binary_integrity_ok()/,/^}/p' mine.sh)"
eval "$(sed -n '/^cached_binary_usable()/,/^}/p' mine.sh)"
OS=linux
if binary_integrity_ok "$tmpcache/good.bin"; then pass "integrity accepts valid ELF binary"; else fail "integrity accepts valid ELF binary"; fi
if binary_integrity_ok "$tmpcache/bad.bin"; then fail "integrity rejects wrong magic"; else pass "integrity rejects wrong magic"; fi
if binary_integrity_ok "$tmpcache/small.bin"; then fail "integrity rejects tiny file"; else pass "integrity rejects tiny file"; fi
cp "$tmpcache/good.bin" "$tmpcache/cached.bin"
printf 'v0.3.0\n' > "$tmpcache/cached.bin.tag"
if cached_binary_usable "$tmpcache/cached.bin" "v0.3.0"; then pass "matching tag + valid binary is usable"; else fail "matching tag + valid binary is usable"; fi
printf 'v0.2.0\n' > "$tmpcache/cached.bin.tag"
if cached_binary_usable "$tmpcache/cached.bin" "v0.3.0"; then fail "stale tag forces re-download"; else pass "stale tag forces re-download"; fi
rm -f "$tmpcache/cached.bin.tag"
if cached_binary_usable "$tmpcache/cached.bin" "v0.3.0"; then fail "missing tag forces re-download"; else pass "missing tag forces re-download"; fi
cp "$tmpcache/bad.bin" "$tmpcache/corrupt.bin"
printf 'v0.3.0\n' > "$tmpcache/corrupt.bin.tag"
if cached_binary_usable "$tmpcache/corrupt.bin" "v0.3.0"; then fail "corrupt binary forces re-download"; else pass "corrupt binary forces re-download"; fi
rm -rf "$tmpcache"

# 6. Launch loop: the miner must launch even with no log file (no --auto-restart).
# Regression: the loop used to redirect unconditionally to "$LOGFILE", which is
# empty unless --auto-restart, so bash failed the redirect ('No such file or
# directory') and the miner never executed.
echo ""
echo "6. Launch loop guard:"
if grep -q 'if \[ -n "\$LOGFILE" \]' mine.sh; then
    pass "launch loop guards empty LOGFILE"
else
    fail "launch loop guards empty LOGFILE"
fi
launch_out=$(bash -c 'set -euo pipefail
BINARY_PATH=echo
CMD_ARGS=(launched)
LOGFILE=""
AUTO_RESTART=false
RESTART_COUNT=0
MAX_RESTART=5
while true; do
    if [ -n "$LOGFILE" ]; then
        "$BINARY_PATH" "${CMD_ARGS[@]}" >> "$LOGFILE" 2>&1 || true
    else
        "$BINARY_PATH" "${CMD_ARGS[@]}"
    fi
    RESTART_COUNT=$((RESTART_COUNT + 1))
    if $AUTO_RESTART && [ $RESTART_COUNT -lt $MAX_RESTART ]; then
        :
    else
        break
    fi
done' 2>&1)
if [[ "$launch_out" == *launched* ]] && [[ "$launch_out" != *"No such file"* ]]; then
    pass "empty LOGFILE does not block miner launch"
else
    fail "empty LOGFILE does not block miner launch"
fi

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
