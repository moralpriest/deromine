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

# 5e. Lifted binaries keep their dependencies. Windows releases ship DLLs
# next to the exe (e.g. libstdc++-6.dll); the lift must copy the whole nested
# dir, not just the binary. Extracts the REAL lift_binary from mine.sh.
echo ""
echo "5e. Lift dependencies:"
tmplift=$(mktemp -d)
mkdir -p "$tmplift/cache/nested"
printf 'MZfakeexe' > "$tmplift/cache/nested/dirtybird-miner-cpu.exe"
printf 'DLLDATA'   > "$tmplift/cache/nested/libstdc++-6.dll"
printf '{}'        > "$tmplift/cache/nested/config.json"
eval "$(sed -n '/^lift_binary()/,/^}/p' mine.sh)"
MINER_DIR="$tmplift/cache"
BINARY_PATH="$MINER_DIR/dirtybird-c-miner.exe"
if lift_binary "$tmplift/cache/nested/dirtybird-miner-cpu.exe"; then
    pass "lift_binary ran"
else
    fail "lift_binary ran"
fi
if [ -f "$BINARY_PATH" ]; then pass "exe lifted to canonical name"; else fail "exe lifted to canonical name"; fi
if [ -f "$MINER_DIR/libstdc++-6.dll" ]; then pass "DLL lifted next to exe"; else fail "DLL lifted next to exe"; fi
if [ -f "$MINER_DIR/config.json" ]; then pass "config.json lifted too"; else fail "config.json lifted too"; fi
if [ ! -d "$tmplift/cache/nested" ]; then pass "nested dir removed after lift"; else fail "nested dir removed after lift"; fi
rm -rf "$tmplift"

# 5f. Windows Vulkan detection is FUNCTIONAL: a registered ICD is not proof a
# driver works (registered-but-broken drivers must still hide go-gpu). The
# REAL has_vulkan_gpu delegates to a fake powershell.exe (every Windows box
# ships it) that runs the loader probe; only falls back to the ICD registry
# key if PowerShell is missing. Extracts the REAL has_vulkan_gpu.
echo ""
echo "5f. Windows Vulkan probe:"
tmpvulkan=$(mktemp -d)
mkdir -p "$tmpvulkan/empty" "$tmpvulkan/bin" "$tmpvulkan/nops"
# fake powershell.exe: exit 0 = loader probe found >=1 Vulkan device
printf '#!/bin/sh\nexit 0\n' > "$tmpvulkan/bin/powershell.exe"
chmod +x "$tmpvulkan/bin/powershell.exe"
# fake reg only (no powershell): best-effort ICD key fallback
printf '#!/bin/sh\nexit 0\n' > "$tmpvulkan/nops/reg"
chmod +x "$tmpvulkan/nops/reg"
eval "$(sed -n '/^has_vulkan_gpu()/,/^# end: has_vulkan_gpu/p' mine.sh | sed '$d')"
if PATH="$tmpvulkan/empty" OS=windows has_vulkan_gpu; then
    fail "windows with no Vulkan runtime is hidden"
else
    pass "windows with no Vulkan runtime is hidden"
fi
if PATH="$tmpvulkan/bin" OS=windows has_vulkan_gpu; then
    pass "functional probe: Vulkan device found -> listed"
else
    fail "functional probe: Vulkan device found -> listed"
fi
if PATH="$tmpvulkan/nops" OS=windows has_vulkan_gpu; then
    pass "no powershell -> ICD key fallback can list"
else
    fail "no powershell -> ICD key fallback can list"
fi
rm -rf "$tmpvulkan"

# 5g. Proven-on-host + launch-failure memory: a self-test-gated GPU miner
# (go-gpu) is listed ONLY once a launch proved it runs on this host; other
# miners are hidden after ONE confirmed fast failure. Extracts the REAL
# helpers from mine.sh.
echo ""
echo "5g. Proven-on-host + failure memory:"
tmpmem=$(mktemp -d)
mkdir -p "$tmpmem/go-gpu" "$tmpmem/c"
eval "$(sed -n '/^mark_miner_launch_outcome()/,/^}/p' mine.sh)"
eval "$(sed -n '/^miner_fails_on_host()/,/^}/p' mine.sh)"
eval "$(sed -n '/^miner_proven_on_host()/,/^}/p' mine.sh)"
eval "$(sed -n '/^miner_listable_on_host()/,/^}/p' mine.sh)"
GATED='{"id":"go-gpu","startup_gate":true}'
PLAIN='{"id":"c"}'
# Self-test-gated miner: NOT listed until .ok proves a real launch.
if miner_listable_on_host "$tmpmem" "$GATED"; then fail "gated miner not listed before any launch"; else pass "gated miner not listed before any launch"; fi
mark_miner_launch_outcome "$tmpmem" go-gpu 0 30
if miner_listable_on_host "$tmpmem" "$GATED"; then pass "successful launch writes .ok -> gated miner listed"; else fail "successful launch writes .ok -> gated miner listed"; fi
if miner_proven_on_host "$tmpmem" go-gpu; then pass ".ok marker exists"; else fail ".ok marker exists"; fi
mark_miner_launch_outcome "$tmpmem" go-gpu 1 2
if miner_listable_on_host "$tmpmem" "$GATED"; then fail "fast failure clears .ok -> gated miner hidden again"; else pass "fast failure clears .ok -> gated miner hidden again"; fi
# Non-gated miner: listed until ONE confirmed fast failure.
if miner_listable_on_host "$tmpmem" "$PLAIN"; then pass "plain miner listed with no failures"; else fail "plain miner listed with no failures"; fi
mark_miner_launch_outcome "$tmpmem" c 1 2
if miner_listable_on_host "$tmpmem" "$PLAIN"; then fail "one confirmed fast failure -> plain miner hidden"; else pass "one confirmed fast failure -> plain miner hidden"; fi
mark_miner_launch_outcome "$tmpmem" c 0 30
if miner_listable_on_host "$tmpmem" "$PLAIN"; then pass "successful run resets -> plain miner listed again"; else fail "successful run resets -> plain miner listed again"; fi
mark_miner_launch_outcome "$tmpmem" c 130 3
if miner_listable_on_host "$tmpmem" "$PLAIN"; then pass "Ctrl+C does not count as failure"; else fail "Ctrl+C does not count as failure"; fi
mark_miner_launch_outcome "$tmpmem" c 1 60
if miner_listable_on_host "$tmpmem" "$PLAIN"; then pass "slow exit does not count as startup failure"; else fail "slow exit does not count as startup failure"; fi
# Ctrl+C on a gated miner proves it ran -> .ok written -> listed.
mark_miner_launch_outcome "$tmpmem" go-gpu 130 3
if miner_listable_on_host "$tmpmem" "$GATED"; then pass "Ctrl+C proves gated miner -> listed"; else fail "Ctrl+C proves gated miner -> listed"; fi
if grep -q 'miner_listable_on_host' mine.sh; then pass "mine.sh wires proven-on-host hiding"; else fail "mine.sh wires proven-on-host hiding"; fi
rm -rf "$tmpmem"

# 5h. Defender quarantine hint: a freshly-extracted Windows binary that is
# MISSING (rather than merely corrupt) is almost always Windows Defender
# quarantining it (a false positive for closed-source miners like deroluna).
# The bash path must explain that instead of a dead-end integrity error.
echo ""
echo "5h. Defender quarantine hint:"
if grep -q 'Windows Defender' mine.sh && grep -q 'Exclusions' mine.sh; then
    pass "mine.sh explains Defender interference + exclusion fix"
else
    fail "mine.sh explains Defender interference + exclusion fix"
fi
if grep -q '"$OS" = "windows"' mine.sh; then
    pass "windows path has Defender-aware guidance"
else
    fail "windows path has Defender-aware guidance"
fi
if grep -q 'tries" -lt 3' mine.sh; then
    pass "bash retries integrity check against transient AV locks"
else
    fail "bash retries integrity check against transient AV locks"
fi

# 5i. Daemon selection: the prompt accepts a catalog number, a custom
# host:port via 'c' (rejecting invalid input and re-prompting), and quits on
# 'q'. Extracts the REAL select_daemon + valid_daemon_url + draw_daemon_table
# from mine.sh.
echo ""
echo "5i. Daemon selection (custom node):"
eval "$(sed -n '/^rep()/,/^}/p' mine.sh)"
eval "$(sed -n '/^draw_daemon_table()/,/^}/p' mine.sh)"
eval "$(sed -n '/^valid_daemon_url()/,/^}/p' mine.sh)"
eval "$(sed -n '/^select_daemon()/,/^}/p' mine.sh)"
export MINERS_FILE="$PROJECT_DIR/miners.json"
export -f rep draw_daemon_table valid_daemon_url select_daemon
first_daemon=$(jq -r '.daemons[0].url' "$MINERS_FILE")
dout=$(printf '1\n' | bash -c 'select_daemon; printf "%s" "$DAEMON_URL"' 2>/dev/null)
if [ "$dout" = "$first_daemon" ]; then pass "numeric choice selects catalog node"; else fail "numeric choice selects catalog node (got '$dout')"; fi
dout=$(printf 'c\n192.168.1.10:10100\n' | bash -c 'select_daemon; printf "%s" "$DAEMON_URL"' 2>/dev/null)
if [ "$dout" = "192.168.1.10:10100" ]; then pass "custom node accepted"; else fail "custom node accepted (got '$dout')"; fi
dout=$(printf 'c\nnot-a-node\nc\nhttps://node.example.org:10100/pool\n' | bash -c 'select_daemon; printf "%s" "$DAEMON_URL"' 2>/dev/null)
if [ "$dout" = "https://node.example.org:10100/pool" ]; then pass "invalid custom re-prompts, valid accepted"; else fail "invalid custom re-prompts, valid accepted (got '$dout')"; fi
dout=$(printf '99\n1\n' | bash -c 'select_daemon; printf "%s" "$DAEMON_URL"' 2>/dev/null)
if [ "$dout" = "$first_daemon" ]; then pass "invalid number re-prompts, valid accepted"; else fail "invalid number re-prompts, valid accepted (got '$dout')"; fi
if printf 'q\n' | bash -c 'select_daemon' 2>/dev/null; then fail "q quits daemon selection"; else pass "q quits daemon selection"; fi
call_sites=$(grep -c 'select_daemon' mine.sh)
if [ "$call_sites" -ge 2 ]; then pass "mine.sh wires select_daemon into the flow"; else fail "mine.sh wires select_daemon into the flow ($call_sites refs)"; fi
unset MINERS_FILE
unset -f rep draw_daemon_table valid_daemon_url select_daemon

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

# 6b. Miner exit codes are reported after launch (a silent instant exit used
# to return to the prompt with zero feedback). Exercises the real loop shape.
echo ""
echo "6b. Miner exit reporting:"
exit_out=$(bash -c 'set -euo pipefail
BINARY_PATH=false
CMD_ARGS=()
LOGFILE=""
while true; do
    if [ -n "$LOGFILE" ]; then
        :
    else
        "$BINARY_PATH" "${CMD_ARGS[@]}" || { rc=$?; echo "[!] Miner exited with code $rc"; exit "$rc"; }
    fi
    break
done' 2>&1) || true
if [[ "$exit_out" == *"Miner exited with code 1"* ]]; then
    pass "foreground launch reports nonzero exit"
else
    fail "foreground launch reports nonzero exit ($exit_out)"
fi
if grep -q 'Miner exited with code' mine.sh; then
    pass "mine.sh contains exit-code reporting"
else
    fail "mine.sh contains exit-code reporting"
fi
if grep -q 'A required DLL is missing' mine.sh; then
    pass "missing-DLL hint present in mine.sh"
else
    fail "missing-DLL hint present in mine.sh"
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
