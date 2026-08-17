#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$PROJECT_DIR/lib"
BIN_DIR="$PROJECT_DIR/bin"
CONFIG_FILE="$PROJECT_DIR/config.json"
MINERS_FILE="$PROJECT_DIR/miners.json"
DEFAULT_DAEMON_PORT=10100
DEFAULT_WALLET="deroi1qyqztaxp2cqdhtve0k0v4dv0cmkpvhs8xukkwhgr5eep9u8urxzqqqdpvf892qgwq7h23"
DEROMINE_VERSION="1.1.7"

# ── Parse arguments ──
DAEMON_URL="http://node.derofoundation.org:10100"
WALLET_ADDR=""
MINER_ID=""
THREAD_COUNT=0
DAEMON_FLAG=0
DRY_RUN=false
AUTO_RESTART=false
MAX_RESTART=5
RESTART_DELAY=10
BENCH_MODE=false
BENCH_TIME=30
INCLUDE_CLOSED_SOURCE=false
ASSUME_YES=false
DEV_FEE_OVERRIDE=""
RECONFIGURE=false
FORCE_UPDATE=false
CHECK_CATALOG=false
ALWAYS_RESOLVE=false

show_help() {
    cat <<'EOF'
Usage: deromine [options]
  cross-platform DERO miner launcher

  Flag values accept both --flag=value and --flag value
  (e.g. --threads=28 or --threads 28).

  --version              Show version and exit
  --reconfigure          Re-run setup: ask for wallet, node, threads again
  --update               Check for a new release now (bypasses the tag cache)
  --check-catalog        Audit catalog asset patterns against the latest releases
  --miner=<id>           Miner id, or "list" to show the catalog table
  --wallet=<addr>        DERO wallet address
  --daemon=<url>         Node/pool host:port (scheme optional)
  --threads=<n>          CPU threads
  --dev-fee=<pct>        Dev fee % for miners that support it (e.g. TNN)
  --auto-restart         Restart miner on crash
  --max-restart=<n>      Max restarts (default 5)
  --delay=<sec>          Restart delay in seconds (default 10)
  --dry-run              Resolve release and print command, do not launch
  --benchmark            Benchmark approved miners (closed-source miners skipped)
  --include-closed-source Include closed/partially closed miners (explicit opt-in)
  --yes                  Confirm an opt-in benchmark non-interactively
  --bench-time=<sec>     Benchmark seconds per miner (default 30)
  --output-dir=<dir>     Where binaries are stored (default ./bin)
  --config=<path>        Config file (default ./config.json)
  -h | --help | /?       Show this help

Examples:
  deromine
  deromine --miner=list
  deromine --miner c --threads 28
  deromine --miner=tnn --dev-fee=1
  deromine --miner=c --dry-run
EOF
}

# Accept values both as --flag=value and --flag value. The first pass merges
# the space form into --flag=value so the second pass handles both styles
# identically (unit-tested in scripts/smoke-test.sh).
parse_cli_args() {
    local -a norm=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --daemon|--wallet|--miner|--threads|--max-restart|--delay|--bench-time|--output-dir|--config|--dev-fee)
                if [ $# -lt 2 ]; then
                    echo "${C_ERR:-}[x] Missing value for $1${C_RESET:-}" >&2
                    exit 1
                fi
                norm+=("$1=$2")
                shift 2
                ;;
            *) norm+=("$1"); shift ;;
        esac
    done
    set -- "${norm[@]}"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --daemon=*) DAEMON_URL="${1#*=}"; DAEMON_FLAG=1; shift ;;
            --wallet=*) WALLET_ADDR="${1#*=}"; shift ;;
            --miner=*)  MINER_ID="${1#*=}"; shift ;;
            --threads=*) THREAD_COUNT="${1#*=}"; shift ;;
            --dry-run)  DRY_RUN=true; shift ;;
            --list)     MINER_ID="list"; shift ;;
            --auto-restart) AUTO_RESTART=true; shift ;;
            --max-restart=*) MAX_RESTART="${1#*=}"; shift ;;
            --delay=*) RESTART_DELAY="${1#*=}"; shift ;;
            --benchmark) BENCH_MODE=true; shift ;;
            --include-closed-source) INCLUDE_CLOSED_SOURCE=true; shift ;;
            --yes) ASSUME_YES=true; shift ;;
            --bench-time=*) BENCH_TIME="${1#*=}"; shift ;;
            --output-dir=*) BIN_DIR="${1#*=}"; shift ;;
            --config=*) CONFIG_FILE="${1#*=}"; shift ;;
            --dev-fee=*) DEV_FEE_OVERRIDE="${1#*=}"; shift ;;
            -h|--help|help|/\?) show_help; exit 0 ;;
            --version) echo "deromine $DEROMINE_VERSION"; exit 0 ;;
            --reconfigure) RECONFIGURE=true; shift ;;
            --update) FORCE_UPDATE=true; shift ;;
            --check-catalog) CHECK_CATALOG=true; shift ;;
            *) echo "Unknown: $1"; exit 1 ;;
        esac
    done
}
parse_cli_args "$@"

# ── Dev fee override: --dev-fee flag wins over config.json ──
if [ -z "$DEV_FEE_OVERRIDE" ] && [ -f "$CONFIG_FILE" ]; then
    DEV_FEE_OVERRIDE=$(jq -r '.dev_fee // ""' "$CONFIG_FILE")
fi

# ── Detect platform ──
OS="linux"
ARCH="amd64"
case "$(uname -s)" in
    Linux*)  OS="linux" ;;
    Darwin*) OS="macos" ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
esac
case "$(uname -m)" in
    aarch64|arm64) ARCH="aarch64" ;;
    armv7l|armv8l) ARCH="arm" ;;
esac

# Termux (Android): $PREFIX is set by Termux and $PREFIX/bin is the one
# directory always on PATH there (same detection as install.sh/install.ps1).
# Requiring 'com.termux' in the path avoids false positives when an unrelated
# PREFIX (e.g. Autotools) is exported on desktop Linux.
IS_TERMUX=0
if [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *com.termux* ]] && [ -d "$PREFIX/bin" ]; then
    IS_TERMUX=1
fi

# ── Terminal capabilities ──
has_unicode() {
    local charmap
    charmap="$(locale charmap 2>/dev/null || echo '')"
    [ "$charmap" = "UTF-8" ] && return 0
    [[ "${LC_ALL:-}${LANG:-}" =~ [Uu][Tt][Ff]-?8 ]] && return 0
    return 1
}

C_BANNER=''; C_BORDER=''; C_NUM=''; C_NAME=''; C_BIN=''
C_STATUS=''; C_ERR=''; C_OK=''; C_HDR=''; C_DIM=''; C_RESET=''
C_RISK_LO=''; C_RISK_MED=''; C_RISK_HI=''
C_FEE_LO=''; C_FEE_MED=''; C_FEE_HI=''
if [ -t 1 ]; then
    C_BANNER=$'\033[35m'; C_BORDER=$'\033[36m'; C_NUM=$'\033[33m'
    C_NAME=$'\033[37m'; C_BIN=$'\033[90m'; C_STATUS=$'\033[32m'
    C_ERR=$'\033[31m'; C_OK=$'\033[32m'; C_HDR=$'\033[36m'
    C_DIM=$'\033[90m'; C_RESET=$'\033[0m'
    C_RISK_LO=$'\033[32m'; C_RISK_MED=$'\033[33m'; C_RISK_HI=$'\033[31m'
    C_FEE_LO=$'\033[32m'; C_FEE_MED=$'\033[33m'; C_FEE_HI=$'\033[31m'
fi

if has_unicode; then
    TL='╔'; TR='╗'; BL='╚'; BR='╝'; H='═'; V='║'
    T_TL='┌'; T_TR='┐'; T_BL='└'; T_BR='┘'; T_LT='├'; T_RT='┤'
    T_TT='┬'; T_BT='┴'; T_X='┼'; T_H='─'; T_V='│'
    BULLET='●'; CROSS='✗'; CHECK='✓'; ARROW='▶'
else
    TL='+'; TR='+'; BL='+'; BR='+'; H='='; V='|'
    T_TL='+'; T_TR='+'; T_BL='+'; T_BR='+'; T_LT='+'; T_RT='+'
    T_TT='+'; T_BT='+'; T_X='+'; T_H='-'; T_V='|'
    BULLET='*'; CROSS='X'; CHECK='OK'; ARROW='>'
fi

# tr() only maps single bytes, so it mangles multi-byte UTF-8 box chars.
# sed handles full characters on GNU and BSD.
rep() { printf '%*s' "$2" '' | sed "s/ /$1/g"; }

# macOS/BSD lacks GNU coreutils 'timeout'. Use it when present, otherwise run
# the command directly (only used for benchmarking).
tmo() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout -k 5 "$secs" "$@"
    else
        "$@"
    fi
}

# ── jq check + startup validation ──
if ! command -v jq &>/dev/null; then
    echo "${C_ERR}[x] jq required. Install: apt install jq (or brew install jq)${C_RESET}"
    exit 1
fi

validate_catalog_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "${C_ERR:-}[x] Catalog not found: $path${C_RESET:-}" >&2
        return 1
    fi
    if ! jq -e '
        if type != "object" then false
        elif (.miners | type) != "array" or (.miners | length) == 0 then false
        elif (.daemons | type) != "array" or (.daemons | length) == 0 then false
        elif ([.miners[].id] | length) != ([.miners[].id] | unique | length) then false
        elif any(.miners[];
            ((.id | type) != "string") or ((.id | length) == 0) or
            ((.name | type) != "string") or ((.name | length) == 0) or
            ((.binary | type) != "string") or ((.binary | length) == 0) or
            ((.repo | type) != "string") or ((.repo | length) == 0) or
            ((.fee | type) != "string") or
            (has("benchmark_policy") and (.benchmark_policy | type) != "string") or
            (has("benchmark_policy") and (.benchmark_policy | IN("default", "opt-in", "disabled") | not)) or
            ((.assets | type) != "array") or
            ((.assets | length) == 0) or any(.assets[];
                ((.os | type) != "string") or ((.os | length) == 0) or
                ((.arch | type) != "string") or ((.arch | length) == 0) or
                ((.pattern | type) != "string") or ((.pattern | length) == 0))) then false
        elif any(.daemons[];
            ((.name | type) != "string") or ((.name | length) == 0) or
            ((.url | type) != "string") or ((.url | length) == 0)) then false
        else true end
    ' "$path" >/dev/null 2>&1; then
        echo "${C_ERR:-}[x] Invalid catalog: $path${C_RESET:-}" >&2
        echo "${C_DIM:-}    Expected miners[] with id/name/binary/repo/fee/assets and daemons[] with name/url.${C_RESET:-}" >&2
        return 1
    fi
}

validate_config_file() {
    local path="$1"
    if [ ! -f "$path" ]; then return 0; fi
    if ! jq -e '
        if type != "object" then false
        elif (has("wallet_address") and ((.wallet_address | type) != "string")) then false
        elif (has("daemon_url") and ((.daemon_url | type) != "string")) then false
        elif (has("thread_count") and (((.thread_count | type) != "number") or (.thread_count != (.thread_count | floor)) or (.thread_count < 0) or (.thread_count > 256))) then false
        elif (has("dev_fee") and ((.dev_fee | type) != "string" and (.dev_fee | type) != "number")) then false
        else true end
    ' "$path" >/dev/null 2>&1; then
        echo "${C_ERR:-}[x] Invalid config: $path${C_RESET:-}" >&2
        echo "${C_DIM:-}    Expected wallet_address/daemon_url strings and thread_count as an integer from 0 to 256.${C_RESET:-}" >&2
        return 1
    fi
}

if ! validate_catalog_file "$MINERS_FILE"; then exit 1; fi
if ! validate_config_file "$CONFIG_FILE"; then exit 1; fi

# ── Reconfigure: re-run the setup prompts from scratch ──
# Validate first so a malformed config is reported instead of being silently
# moved to config.bak before the user sees the actionable error.
if [ "$RECONFIGURE" = true ]; then
    if [ -f "$CONFIG_FILE" ]; then
        cp -f "$CONFIG_FILE" "$PROJECT_DIR/config.bak" && rm -f "$CONFIG_FILE"
        echo "[*] Previous config backed up to $PROJECT_DIR/config.bak; starting fresh setup" >&2
    else
        echo "[*] No existing config to reset; starting fresh setup" >&2
    fi
fi

# ── Read catalog ──
read_catalog() {
    jq -c '.miners[]' "$MINERS_FILE" 2>/dev/null || { echo "${C_ERR}[x] Failed to read $MINERS_FILE${C_RESET}"; exit 1; }
}

get_miner_by_id() {
    local id="$1"
    local m mid
    while IFS= read -r m; do
        mid=$(echo "$m" | jq -r '.id')
        if [ "$mid" = "$id" ]; then echo "$m"; return 0; fi
    done < <(read_catalog)
    return 1
}

# The catalog OS used for asset selection: on Termux/Android, prefer the
# 'termux' asset (e.g. Dirtybird's NDK-built aarch64_android binary — the
# plain 'linux' arm64 build is glibc-linked and cannot load on bionic) and
# fall back to the 'linux' build when no termux asset exists. Everywhere
# else selection is by OS exactly as before.
asset_os() {
    if [ "$IS_TERMUX" -eq 1 ]; then echo "termux"; else echo "$OS"; fi
}
asset_os_fallback() {
    if [ "$IS_TERMUX" -eq 1 ]; then echo "linux"; else echo ""; fi
}

get_asset_pattern() {
    local miner_json="$1"
    # One pattern per OS/arch (first match wins). Multiple entries for the
    # same OS/arch would produce a multi-line pattern that can never match
    # a real release asset name. On Termux, a 'termux' asset wins over the
    # matching 'linux' asset when both exist for this arch.
    echo "$miner_json" | jq -r --arg os "$(asset_os)" --arg fbos "$(asset_os_fallback)" --arg arch "$ARCH" '
        (first(.assets[] | select(.os == $os and .arch == $arch)).pattern)
        // (if $fbos != "" then first(.assets[] | select(.os == $fbos and .arch == $arch)).pattern else null end)
        // ""' | head -1
}

# Binary name: per-asset override (exact OS/arch first, then any asset for
# this OS), falling back to the miner-level .binary field. Needed because
# some releases name the binary per arch (e.g. derohe's dero-miner-linux-arm64
# on aarch64 vs dero-miner-linux-amd64 on amd64).
get_binary_name() {
    local miner_json="$1" name
    name=$(echo "$miner_json" | jq -r --arg os "$(asset_os)" --arg fbos "$(asset_os_fallback)" --arg arch "$ARCH" '
        first(.assets[] | select(.os == $os and .arch == $arch and ((.binary // "") != ""))).binary
        // (if $fbos != "" then first(.assets[] | select(.os == $fbos and .arch == $arch and ((.binary // "") != ""))).binary else null end)
        // first(.assets[] | select(.os == $os and ((.binary // "") != ""))).binary
        // (if $fbos != "" then first(.assets[] | select(.os == $fbos and ((.binary // "") != ""))).binary else null end)
        // .binary
        // ""')
    if [ "$OS" = "windows" ] && [ -n "$name" ] && [[ "$name" != *.exe ]]; then
        name="${name}.exe"
    fi
    echo "$name"
}

benchmark_policy() {
    local miner_json="$1" policy
    if [ "$(echo "$miner_json" | jq -r 'if (.benchmark == false) then "disabled" else "" end')" = "disabled" ]; then
        echo "disabled"
        return
    fi
    policy=$(echo "$miner_json" | jq -r '.benchmark_policy // "opt-in"')
    case "$policy" in
        default|opt-in|disabled) echo "$policy" ;;
        *) echo "opt-in" ;;
    esac
}

get_archive_binary_name() {
    local miner_json="$1" name
    # Mirrors Get-MinerArchiveBinaryName in catalog.ps1: per-asset
    # binary_archive, then per-asset binary, then the miner-level fields.
    # Order matters: derohe's top-level binary_archive is amd64-specific, so
    # the per-asset binary must win on aarch64.
    name=$(echo "$miner_json" | jq -r --arg os "$(asset_os)" --arg fbos "$(asset_os_fallback)" --arg arch "$ARCH" '
        first(.assets[] | select(.os == $os and .arch == $arch and ((.binary_archive // "") != ""))).binary_archive
        // (if $fbos != "" then first(.assets[] | select(.os == $fbos and .arch == $arch and ((.binary_archive // "") != ""))).binary_archive else null end)
        // first(.assets[] | select(.os == $os and .arch == $arch and ((.binary // "") != ""))).binary
        // (if $fbos != "" then first(.assets[] | select(.os == $fbos and .arch == $arch and ((.binary // "") != ""))).binary else null end)
        // first(.assets[] | select(.os == $os and ((.binary_archive // "") != ""))).binary_archive
        // (if $fbos != "" then first(.assets[] | select(.os == $fbos and ((.binary_archive // "") != ""))).binary_archive else null end)
        // first(.assets[] | select(.os == $os and ((.binary // "") != ""))).binary
        // (if $fbos != "" then first(.assets[] | select(.os == $fbos and ((.binary // "") != ""))).binary else null end)
        // .binary_archive
        // .binary
        // ""')
    # .exe is appended for Windows (previously the bash path never did this;
    # aligning with PowerShell and required for per-arch names like derohe).
    if [ "$OS" = "windows" ] && [ -n "$name" ] && [[ "$name" != *.exe ]]; then
        name="${name}.exe"
    fi
    echo "$name"
}

# ── Cache integrity & version check ──
# A miner binary must be sufficiently complete and platform-valid. The size
# floor catches truncated/interrupted extractions while allowing compact
# stripped miners such as Dirtybird C++ (~178 KiB).
binary_integrity_ok() {
    local path="$1" size magic
    [ -f "$path" ] || return 1
    size=$(stat -c %s "$path" 2>/dev/null || stat -f %z "$path" 2>/dev/null || echo 0)
    # Valid stripped miners can be smaller than 200 KB (Dirtybird C++ is
    # about 178 KB), so use a conservative 64 KiB floor and rely on the
    # platform executable magic below for the format check.
    [ "$size" -ge 65536 ] || return 1
    magic=$(head -c 4 "$path" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$OS" in
        windows) [[ "$magic" == 4d5a* ]] || return 1 ;;                                        # MZ
        macos)   [[ "$magic" == cffaedfe* || "$magic" == cafebabe* || "$magic" == feedface* || "$magic" == feedfacf* ]] || return 1 ;;  # Mach-O
        *)       [[ "$magic" == 7f454c46* ]] || return 1 ;;                                    # \x7fELF
    esac
    return 0
}

# A cached binary is usable only if its recorded release tag matches the
# currently-resolved latest tag, it passes the integrity check, AND it came
# from the same release asset we would pick now. The asset check matters on
# Termux: the cached binary may have been fetched from a 'linux' fallback
# build before a proper 'termux' asset existed (or vice versa) - the tag is
# identical either way, so only the sidecar can tell them apart.
cached_binary_usable() {
    local path="$1" tag="$2" cached=""
    [ -f "$path" ] || return 1
    [ -f "$path.tag" ] || return 1
    cached=$(cat "$path.tag" 2>/dev/null)
    [ "$cached" = "$tag" ] || return 1
    if [ -n "$ARCHIVE_NAME" ] && [ -f "$path.asset" ]; then
        [ "$(cat "$path.asset" 2>/dev/null)" = "$ARCHIVE_NAME" ] || return 1
    fi
    binary_integrity_ok "$path" || return 1
    # On Termux, a cached ELF whose PT_TLS segment bionic would abort (stale
    # build of the same release tag) must be re-downloaded, not launched into
    # a loader SIGABRT. The rebuilt release asset typically has no PT_TLS and
    # passes trivially.
    if [ "${IS_TERMUX:-0}" -eq 1 ] && ! elf_tls_bionic_ok "$path"; then
        return 1
    fi
    return 0
}

# ── Termux/Android bionic TLS layout check ──
# ARM64 bionic aborts an executable whose PT_TLS segment cannot hold the 8-word
# TCB (64 bytes) in its alignment padding before the thread pointer. The loader
# fatal is exact (bionic_elf_tls.cpp: abi_tpoff != actual_tpoff), reproduced
# here so a cached binary is re-downloaded BEFORE the loader SIGABRTs:
#   abi_tpoff    = align_checked(2 * sizeof(void*),   {align, skew})
#   actual_tpoff = align_checked(tcb_size_post = 64,  {align, skew})
#   align_checked(v,{a,s}) = ((v - s + a - 1) & ~(a - 1)) + s ;  s = p_vaddr % a
# A stale NDK build (e.g. dirtybird-c-miner v1.0.39's old aarch64_android)
# ships p_align=8; termux-elf-cleaner bumps it to 64 but CANNOT re-align the
# segment, leaving p_vaddr % 64 = 48 (skew) — still fatal. The rebuilt release
# has no PT_TLS at all and passes. Returns 0 when the loader would accept it,
# 1 when bionic would abort it.
elf_tls_bionic_ok() {
    local bin="$1"
    local magic class phoff phentsize phnum i o ptype vaddr palign
    local skew abi_tpoff actual_tpoff tcb_size
    magic=$(od -An -tx1 -j0 -N4 "$bin" 2>/dev/null | tr -d ' ')
    [ "$magic" = "7f454c46" ] || return 0          # not an ELF: nothing to check
    class=$(od -An -tu1 -j4 -N1 "$bin" 2>/dev/null | tr -d ' ')
    [ "$class" = "2" ] || return 0                  # ELF32: older ARM, no 64B rule
    phoff=$(od -An -tu8 -j32 -N8 "$bin" 2>/dev/null | tr -d ' ')
    phentsize=$(od -An -tu2 -j54 -N2 "$bin" 2>/dev/null | tr -d ' ')
    phnum=$(od -An -tu2 -j56 -N2 "$bin" 2>/dev/null | tr -d ' ')
    [ -n "$phoff" ] && [ -n "$phentsize" ] && [ -n "$phnum" ] || return 0
    [ "$phentsize" -ge 56 ] || return 0             # Elf64_Phdr is 56 bytes
    tcb_size=64                                      # 8 Bionic TLS slots * 8 bytes
    i=0
    while [ "$i" -lt "$phnum" ]; do
        o=$((phoff + i * phentsize))
        ptype=$(od -An -tu4 -j"$o" -N4 "$bin" 2>/dev/null | tr -d ' ')
        if [ "$ptype" = "7" ]; then                  # PT_TLS
            vaddr=$(od -An -tu8 -j$((o + 16)) -N8 "$bin" 2>/dev/null | tr -d ' ')
            palign=$(od -An -tu8 -j$((o + 48)) -N8 "$bin" 2>/dev/null | tr -d ' ')
            [ -n "$vaddr" ] && [ -n "$palign" ] || return 0
            [ "$palign" -eq 0 ] && palign=1          # 0 = "no alignment requirement"
            skew=$(( vaddr % palign ))
            abi_tpoff=$(( ((16 - skew + palign - 1) & ~(palign - 1)) + skew ))
            actual_tpoff=$(( ((tcb_size - skew + palign - 1) & ~(palign - 1)) + skew ))
            [ "$abi_tpoff" -eq "$actual_tpoff" ] || return 1
        fi
        i=$((i + 1))
    done
    return 0
}

# ── Release-tag cache ──
# GitHub/GitLab rate-limit unauthenticated release-API requests (GitHub:
# 60/hr per IP). Once a binary has been fetched at tag T, re-runs within
# TAG_CACHE_TTL skip the API entirely and trust the cached tag, so a normal
# user hits the API once per miner per TTL instead of on every run.
# Set DEROMINE_TAG_CACHE_TTL=0 to always check for a new release.
TAG_CACHE_TTL=${DEROMINE_TAG_CACHE_TTL:-21600}

# True when the binary exists, has a recorded release tag, and the tag was
# fetched within TAG_CACHE_TTL (timestamp written by fetch_binary into
# $BINARY_PATH.tagtime).
cached_tag_fresh() {
    local path="$1" now age
    [ -f "$path" ] || return 1
    [ -f "$path.tag" ] || return 1
    [ -f "$path.tagtime" ] || return 1
    now=$(date +%s 2>/dev/null || echo 0)
    age=$(( now - $(cat "$path.tagtime" 2>/dev/null || echo 0) ))
    [ "$age" -ge 0 ] && [ "$age" -lt "${TAG_CACHE_TTL:-21600}" ]
}

# Copy a nested extraction dir's contents up to $MINER_DIR so the canonical
# binary keeps its dependencies (Windows releases ship DLLs next to the exe,
# e.g. libstdc++-6.dll - a lone exe cannot start without them). Uses the
# globals MINER_DIR and BINARY_PATH; removes the nested dir afterwards.
lift_binary() {
    local found="$1" lift_dir base f
    [ -n "$found" ] || return 1
    lift_dir="$(dirname "$found")"
    [ "$lift_dir" != "$MINER_DIR" ] || return 0
    echo "Lifting binary and dependencies..." >&2
    cp "$found" "$BINARY_PATH"
    for f in "$lift_dir"/*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        [ "$base" = "$(basename "$found")" ] && continue
        # Fresh extraction wins over any same-named stale file in the cache.
        cp -f "$f" "$MINER_DIR/"
    done
    rm -rf "$lift_dir"
}

# ── Launch-failure memory + proven-on-host ──
# A miner that can't run on this host (missing DLLs, broken GPU driver, broken
# arm64 build) used to be listed forever and fail on every attempt. deromine
# remembers per-miner launch outcomes in bin/<id>/:
#   .fails — fast nonzero exits (within 10s); 2+ confirmed failures hide it.
#   .ok    — a launch that PROVED the miner can run here (exit 0, ran long
#            enough to get past startup, or user Ctrl+C). Miners marked
#            startup_gate in the catalog (go-gpu's self-test refuses broken
#            GPUs) are only LISTED once .ok exists — a registered-but-broken
#            driver can pass every static probe yet still refuse to mine, so
#            the only reliable proof is a real successful launch on this host.
# --miner=<id> still force-runs a hidden miner.
mark_miner_launch_outcome() {
    local bindir="$1" mid="$2" rc="$3" elapsed="$4" f ok count
    [ -d "$bindir/$mid" ] || return 0
    f="$bindir/$mid/.fails"
    ok="$bindir/$mid/.ok"
    # Successful runs, slow exits, and Ctrl+C (130) prove the miner works here.
    if [ "$rc" -eq 0 ] || [ "$elapsed" -ge 10 ] || [ "$rc" -eq 130 ]; then
        rm -f "$f"
        printf '1' > "$ok" 2>/dev/null || true
        return 0
    fi
    rm -f "$ok"
    count=0
    [ -f "$f" ] && count=$(cat "$f" 2>/dev/null || echo 0)
    count=$((count + 1))
    [ "$count" -gt 9 ] && count=9
    printf '%s' "$count" > "$f"
}

miner_fails_on_host() {
    local bindir="$1" mid="$2" f count
    f="$bindir/$mid/.fails"
    [ -f "$f" ] || return 1
    count=$(cat "$f" 2>/dev/null || echo 0)
    [ "$count" -ge 2 ]
}

miner_proven_on_host() {
    local bindir="$1" mid="$2"
    [ -f "$bindir/$mid/.ok" ]
}

# A miner is listed only when it can actually run on this host:
#   startup_gate miners (go-gpu): listed ONLY once .ok proves a real launch
#     succeeded here — static probes can't see a registered-but-broken driver.
#   other miners: hidden after ONE confirmed fast startup failure.
miner_listable_on_host() {
    local bindir="$1" m="$2" id gate
    [ -n "$bindir" ] || return 0
    id=$(echo "$m" | jq -r '.id')
    gate=$(echo "$m" | jq -r '.startup_gate // false')
    if [ "$gate" = "true" ]; then
        miner_proven_on_host "$bindir" "$id"
    else
        if miner_fails_on_host "$bindir" "$id"; then
            # A .fails verdict is stale when the recorded .asset no longer
            # glob-matches the asset the catalog would select for this host
            # today — e.g. the C miner cached a 'linux' aarch64 build that
            # failed on Termux, then the catalog gained a proper 'termux'
            # asset for the same tag. The old failure proved nothing about
            # the new binary, so clear the verdict and list the miner (it
            # re-fetches on launch and records a fresh verdict).
            miner_fails_stale_on_host "$bindir" "$m" && return 0
            return 1
        fi
        return 0
    fi
}

# True when a recorded .fails verdict was captured against a release asset
# different from the one the catalog selects for this host now (the binary's
# .asset sidecar is written by fetch_binary). Without a matching .asset we
# cannot prove staleness and treat the verdict as current.
miner_fails_stale_on_host() {
    local bindir="$1" m="$2" id bname asset pattern recorded
    [ -n "$bindir" ] || return 1
    id=$(echo "$m" | jq -r '.id')
    bname=$(get_binary_name "$m")
    [ -n "$bname" ] || return 1
    asset="$bindir/$id/$bname.asset"
    [ -f "$asset" ] || return 1
    pattern=$(get_asset_pattern "$m")
    [ -n "$pattern" ] || return 1
    recorded=$(cat "$asset" 2>/dev/null)
    [ -n "$recorded" ] || return 1
    [[ "$recorded" == $pattern ]] && return 1
    rm -f "$bindir/$id/.fails" "$bindir/$id/.ok"
    return 0
}

# Download, extract, lift (rename to the canonical cache name), verify, and
# record the release tag next to the binary so later runs can detect a stale
# cache. Relies on the resolve_* globals: MINER_DIR, BINARY_PATH, ARCHIVE_NAME,
# ARCHIVE_BINARY, DOWNLOAD_URL, TAG.
fetch_binary() {
    local archive_path="$MINER_DIR/$ARCHIVE_NAME" found="" tries ok
    echo "Downloading $ARCHIVE_NAME..." >&2
    curl -fL "$DOWNLOAD_URL" -o "$archive_path" || { echo "${C_ERR}[x] Download failed${C_RESET}" >&2; return 1; }
    echo "Extracting..." >&2
    case "$ARCHIVE_NAME" in
        *.zip)    unzip -o "$archive_path" -d "$MINER_DIR" >/dev/null 2>&1 || { echo "${C_ERR}[x] Extraction failed${C_RESET}" >&2; rm -f "$archive_path"; return 1; } ;;
        *.tar.gz|*.tgz) tar -xzf "$archive_path" -C "$MINER_DIR" || { echo "${C_ERR}[x] Extraction failed${C_RESET}" >&2; rm -f "$archive_path"; return 1; } ;;
        *.tar)    tar -xf "$archive_path" -C "$MINER_DIR" || { echo "${C_ERR}[x] Extraction failed${C_RESET}" >&2; rm -f "$archive_path"; return 1; } ;;
    esac
    rm -f "$archive_path"
    # Lift binary if nested (rename to the canonical cache name)
    found=$(find "$MINER_DIR" -type f -name "$ARCHIVE_BINARY" 2>/dev/null | head -1)
    if [ -n "$found" ]; then
        lift_binary "$found"
    fi
    if [ ! -f "$BINARY_PATH" ]; then
        echo "${C_ERR}[x] Binary '$(basename "$BINARY_PATH")' not found after extraction${C_RESET}" >&2
        find "$MINER_DIR" -type f >&2
        return 1
    fi
    chmod +x "$BINARY_PATH" 2>/dev/null || true
    # Freshly-extracted files can be briefly LOCKED by AV real-time scanning
    # (Windows Defender) - retry a few times to ride out the scan before
    # declaring the file corrupt.
    tries=0; ok=1
    while [ "$tries" -lt 3 ]; do
        if binary_integrity_ok "$BINARY_PATH"; then ok=0; break; fi
        tries=$((tries + 1))
        if [ "$tries" -lt 3 ]; then sleep 1; fi
    done
    if [ "$ok" -ne 0 ]; then
        echo "${C_ERR}[x] Extracted binary '$BINARY_PATH' failed integrity check${C_RESET}" >&2
        if [ "$OS" = "windows" ]; then
            echo "${C_DIM}  On Windows this is almost always Windows Defender interfering (a${C_RESET}" >&2
            echo "${C_DIM}  false positive for closed-source miners): it may quarantine,${C_RESET}" >&2
            echo "${C_DIM}  truncate, or briefly lock the file. Add an exclusion for${C_RESET}" >&2
            echo "${C_DIM}  '$MINER_DIR' (Windows Security > Virus & threat protection >${C_RESET}" >&2
            echo "${C_DIM}  Manage settings > Exclusions), then re-run. If it still fails,${C_RESET}" >&2
            echo "${C_DIM}  the download is corrupt - remove '$MINER_DIR' and retry.${C_RESET}" >&2
        else
            echo "${C_DIM}  Incomplete/corrupt download. Remove '$MINER_DIR' and retry.${C_RESET}" >&2
        fi
    rm -f "$BINARY_PATH" "$BINARY_PATH.tag" "$BINARY_PATH.asset" "$BINARY_PATH.cleaned"
        return 1
    fi
    # Record the release tag (and when it was fetched) so future runs can
    # detect a stale cache and skip the release API while it is fresh.
    printf '%s\n' "$TAG" > "$BINARY_PATH.tag"
    date +%s > "$BINARY_PATH.tagtime" 2>/dev/null || true
    # Record which release asset produced this binary. If a later run
    # resolves a DIFFERENT asset for the same miner (e.g. Termux gains a
    # proper 'termux' build where the cached binary came from a 'linux'
    # fallback), the cache is treated as stale and re-downloaded.
    printf '%s\n' "$ARCHIVE_NAME" > "$BINARY_PATH.asset"
    # A fresh download invalidates any launch-failure memory for this miner:
    # the old .fails/.ok verdict applied to a previous binary, not this one.
    rm -f "$MINER_DIR/.fails" "$MINER_DIR/.ok"
    # ELF patching for Termux/Android (bionic requires 64-byte TLS alignment;
    # even NDK-built 'termux' assets can ship underaligned). Runs whenever the
    # tool is available; a missing tool is installed on the spot (Termux) so a
    # fresh fetch is patched before first launch instead of aborting in the
    # bionic loader like dirtybird-c-miner v1.0.39's aarch64_android build.
    termux_patch_binary "$BINARY_PATH"
}

# Patch an ELF binary for Termux/Android: align TLS, fix missing DT_NOTE/rpath
# so bionic's loader accepts it. The tool is best-effort at fetch time AND
# before launch (covers an already-cached binary fetched before the tool
# existed). When missing on Termux, attempts `pkg install termux-elf-cleaner`
# once per run; a persistent failure is surfaced as a warning so the user
# knows WHY the miner would abort in the loader. Idempotent via a .cleaned
# marker so cached binaries are patched at most once per download.
termux_patch_binary() {
    local bin="$1" done tried=false
    [ "$IS_TERMUX" -eq 1 ] || return 0
    [ -n "$bin" ] && [ -f "$bin" ] || return 0
    done="$bin.cleaned"
    [ -f "$done" ] && return 0
    if ! command -v termux-elf-cleaner >/dev/null 2>&1; then
        if [ "${TERMUX_PATCH_AUTO_INSTALL:-1}" = "1" ] && command -v pkg >/dev/null 2>&1; then
            echo "${C_DIM}[*] Installing termux-elf-cleaner (needed to run miner binaries on Termux)...${C_RESET}" >&2
            pkg install -y termux-elf-cleaner >/dev/null 2>&1 && tried=true
        fi
        if ! command -v termux-elf-cleaner >/dev/null 2>&1; then
            echo "${C_ERR}[!] termux-elf-cleaner not available; this miner will likely abort in the bionic loader${C_RESET}" >&2
            echo "${C_DIM}    Install it once: pkg install termux-elf-cleaner${C_RESET}" >&2
            return 0
        fi
    fi
    if termux-elf-cleaner "$bin" >/dev/null 2>&1; then
        : > "$done"
    else
        echo "${C_DIM}[!] termux-elf-cleaner reported an issue patching $bin (continuing anyway)${C_RESET}" >&2
    fi
    return 0
}

# ── Hardware detection ──
has_nvidia_gpu() {
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

has_vulkan_gpu() {
    if command -v vulkaninfo >/dev/null 2>&1; then
        vulkaninfo --summary >/dev/null 2>&1 && return 0
    fi
    if [ "$OS" = "linux" ] && [ -d /dev/dri ]; then
        ls /dev/dri/card* >/dev/null 2>&1 && return 0
    fi
    if [ "$OS" = "windows" ]; then
        # Vulkan does NOT require NVIDIA (Intel/AMD iGPUs qualify), but a
        # REGISTERED ICD is not proof a driver works - a registered-but-broken
        # driver (Intel Iris Xe wgpu-DX12-fallback case) must still hide
        # go-gpu. Every Windows box ships Windows PowerShell, so delegate the
        # same functional loader probe the PS path uses (create a Vulkan
        # instance, enumerate physical devices, require >0). Only fall back to
        # the ICD registration key if PowerShell itself is somehow missing.
        if command -v powershell.exe >/dev/null 2>&1; then
            # Run via a temp script with -File: stdin (-Command -) is not
            # reliably multi-line across PS versions.
            local vkprobe vkrc
            vkprobe="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/deromine-vkprobe.$$.ps1")"
            cat > "$vkprobe" <<'VKPROBE'
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DeromineVkProbe {
    [StructLayout(LayoutKind.Sequential)]
    public struct Ci {
        public int sType; public IntPtr pNext; public uint flags;
        public IntPtr pApp; public uint lc; public IntPtr pl;
        public uint ec; public IntPtr pe;
    }
    [DllImport("vulkan-1.dll", CallingConvention = CallingConvention.Winapi)]
    public static extern int vkCreateInstance(ref Ci ci, IntPtr a, out IntPtr i);
    [DllImport("vulkan-1.dll", CallingConvention = CallingConvention.Winapi)]
    public static extern void vkDestroyInstance(IntPtr i, IntPtr a);
    [DllImport("vulkan-1.dll", CallingConvention = CallingConvention.Winapi)]
    public static extern int vkEnumeratePhysicalDevices(IntPtr i, ref uint c, IntPtr d);
    public static bool Usable() {
        Ci ci = new Ci(); ci.sType = 1; IntPtr inst;
        if (vkCreateInstance(ref ci, IntPtr.Zero, out inst) != 0) { return false; }
        uint c = 0;
        try {
            if (vkEnumeratePhysicalDevices(inst, ref c, IntPtr.Zero) != 0) { return false; }
            return c > 0;
        } finally { vkDestroyInstance(inst, IntPtr.Zero); }
    }
}
'@ -ErrorAction Stop
    if ([DeromineVkProbe]::Usable()) { exit 0 } else { exit 1 }
}
catch { exit 1 }
VKPROBE
            # Guard with ||: the probe exits 1 on machines WITHOUT Vulkan (its
            # normal result) and an unguarded nonzero would trip `set -e`.
            vkrc=1
            powershell.exe -NoProfile -NonInteractive -File "$vkprobe" >/dev/null 2>&1 && vkrc=0
            rm -f "$vkprobe"
            if [ "$vkrc" -eq 0 ]; then return 0; fi
            return 1
        fi
        if command -v reg >/dev/null 2>&1 && reg query "HKLM\SOFTWARE\Khronos\Vulkan\Drivers" >/dev/null 2>&1; then
            return 0
        fi
        return 1
    fi
    if [ "$OS" = "macos" ]; then return 0; fi
    return 1
}
# end: has_vulkan_gpu

tcp_open() {
    local port="$1"
    if command -v timeout >/dev/null 2>&1; then
        timeout 0.7 bash -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null && return 0
    else
        (exec 3<>/dev/tcp/127.0.0.1/$port) 2>/dev/null && return 0
    fi
    return 1
}

# Only TLS GETWORK mining ports can serve dirtybird miners.
is_mining_url() {
    local url="$1" port
    port="${url##*:}"
    port="${port%%/*}"
    case "$port" in
        10100|40400) return 0 ;;
        *) return 1 ;;
    esac
}

detect_local_daemon() {
    local port
    # Miners can ONLY connect via TLS to the GETWORK mining port
    # (mainnet 10100, testnet 40400). Plain-HTTP RPC ports (10102/40402/
    # 19999) are never valid miner endpoints, so they are not probed.
    for port in 10100 40400; do
        tcp_open "$port" || continue
        # GETWORK/mining listener accepts TLS (dirtybird miners always TLS)
        if curl -sk --connect-timeout 0.5 --max-time 1.2 -o /dev/null "https://127.0.0.1:$port/" 2>/dev/null; then
            echo "http://127.0.0.1:$port"
            return 0
        fi
    done
    return 1
}

miner_hardware_ok() {
    local miner_json="$1"
    local req
    local needs
    # Platform exclusions (e.g. derohe is glibc-only and fails its ELF
    # self-check on Termux/Android, so it is marked unsupported there).
    if [ "$IS_TERMUX" -eq 1 ] && echo "$miner_json" | jq -e '.unsupported | index("termux")' >/dev/null 2>&1; then
        return 1
    fi
    needs=($(echo "$miner_json" | jq -r '.requires[]? // empty'))
    for req in "${needs[@]:-}"; do
        case "$req" in
            nvidia-gpu) has_nvidia_gpu || return 1 ;;
            vulkan-gpu) has_vulkan_gpu || return 1 ;;
        esac
    done
    return 0
}

# ── Table rendering ──
draw_miner_table() {
    local -a all=("$@")
    local m name bin fee typ rnote rlv nw=4 mw=10 bw=12 tw=4 sw=8 rw=12 fw=5 i num line
    local -a names=() bins=() types=() fees=() rnotes=() rlevels=()
    for m in "${all[@]:-}"; do
        name=$(echo "$m" | jq -r '.name // "?"')
        bin=$(get_binary_name "$m")
        [ -z "$bin" ] && bin="?"
        fee=$(echo "$m" | jq -r '.fee // "0%"')
        dflg=$(echo "$m" | jq -r '.flags.dev_fee // empty')
        if [ -n "$dflg" ] && [ -n "$DEV_FEE_OVERRIDE" ]; then
            fee="${DEV_FEE_OVERRIDE}%"
        fi
        typ=$(echo "$m" | jq -r '.type // "cpu"')
        rnote=$(echo "$m" | jq -r '.risk_note // "Unknown"')
        rlv=$(echo "$m" | jq -r '.risk // "low"')
        names+=("$name"); bins+=("$bin"); types+=("$typ"); fees+=("$fee"); rnotes+=("$rnote"); rlevels+=("$rlv")
        [ "${#name}" -gt "$mw" ] && mw="${#name}"
        [ "${#bin}" -gt "$bw" ] && bw="${#bin}"
        [ "${#typ}" -gt "$tw" ] && tw="${#typ}"
        [ "${#fee}" -gt "$fw" ] && fw="${#fee}"
        [ "${#rnote}" -gt "$rw" ] && rw="${#rnote}"
    done
    [ "$mw" -lt 10 ] && mw=10
    [ "$bw" -lt 12 ] && bw=12
    [ "$tw" -lt 4 ] && tw=4
    [ "$rw" -lt 12 ] && rw=12
    [ "$fw" -lt 5 ] && fw=5
    nw="${#all[@]}"
    [ "$nw" -lt 3 ] && nw=3

    top="${T_TL}$(rep "$T_H" $((nw+2)))$T_TT$(rep "$T_H" $((mw+2)))$T_TT$(rep "$T_H" $((bw+2)))$T_TT$(rep "$T_H" $((tw+2)))$T_TT$(rep "$T_H" $((sw+2)))$T_TT$(rep "$T_H" $((rw+2)))$T_TT$(rep "$T_H" $((fw+2)))$T_TR"
    hdr="${T_V} $(printf '%-*s' "$nw" '#')${T_V} $(printf '%-*s' "$mw" 'Miner')${T_V} $(printf '%-*s' "$bw" 'Binary')${T_V} $(printf '%-*s' "$tw" 'Type')${T_V} $(printf '%-*s' "$sw" 'Status')${T_V} $(printf '%-*s' "$rw" 'Risk')${T_V} $(printf '%-*s' "$fw" 'Fee')${T_V}"
    mid="${T_LT}$(rep "$T_H" $((nw+2)))$T_X$(rep "$T_H" $((mw+2)))$T_X$(rep "$T_H" $((bw+2)))$T_X$(rep "$T_H" $((tw+2)))$T_X$(rep "$T_H" $((sw+2)))$T_X$(rep "$T_H" $((rw+2)))$T_X$(rep "$T_H" $((fw+2)))$T_RT"
    bot="${T_BL}$(rep "$T_H" $((nw+2)))$T_BT$(rep "$T_H" $((mw+2)))$T_BT$(rep "$T_H" $((bw+2)))$T_BT$(rep "$T_H" $((tw+2)))$T_BT$(rep "$T_H" $((sw+2)))$T_BT$(rep "$T_H" $((rw+2)))$T_BT$(rep "$T_H" $((fw+2)))$T_BR"

    echo "${C_BORDER}$top${C_RESET}"
    echo "${C_BORDER}$hdr${C_RESET}"
    echo "${C_BORDER}$mid${C_RESET}"
    i=0
    for m in "${all[@]:-}"; do
        i=$((i+1))
        num=$(printf '%*s' "$nw" "$i")
        name=$(printf '%-*s' "$mw" "${names[$((i-1))]}")
        bin=$(printf '%-*s' "$bw" "${bins[$((i-1))]}")
        typ=$(printf '%-*s' "$tw" "${types[$((i-1))]}")
        fee=$(printf '%-*s' "$fw" "${fees[$((i-1))]}")
        fnum="${fees[$((i-1))]%%%}"
        fcol="$C_FEE_LO"
        ftier=$(awk -v f="$fnum" 'BEGIN { if (f+0 <= 0) print "lo"; else if (f+0 <= 2.5) print "med"; else print "hi" }')
        case "$ftier" in
            med) fcol="$C_FEE_MED" ;;
            hi)  fcol="$C_FEE_HI" ;;
        esac
        rnote=$(printf '%-*s' "$rw" "${rnotes[$((i-1))]}")
        rlv="${rlevels[$((i-1))]}"
        case "$rlv" in
            high)   rcol="$C_RISK_HI" ;;
            medium) rcol="$C_RISK_MED" ;;
            *)      rcol="$C_RISK_LO" ;;
        esac
        # "Closed source" is always red regardless of the coarse risk level
        # (matches the README legend; e.g. astrox is 'medium' but ships no
        # source code, so it must not look as safe as 'Closed DLLs').
        case "${rnotes[$((i-1))]}" in
            *"Closed source"*) rcol="$C_RISK_HI" ;;
        esac
        status=$(printf '%-*s' "$sw" "$BULLET AVAIL")
        mid=$(echo "$m" | jq -r '.id // ""')
        if [ -n "$mid" ] && [ -x "$BIN_DIR/$mid/$(get_binary_name "$m")" ]; then
            status=$(printf '%-*s' "$sw" "$CHECK READY")
        fi
        line="${T_V} ${C_NUM}${num}${C_RESET} ${T_V} ${C_NAME}${name}${C_RESET} ${T_V} ${C_BIN}${bin}${C_RESET} ${T_V} ${C_DIM}${typ}${C_RESET} ${T_V} ${C_STATUS}${status}${C_RESET} ${T_V} ${rcol}${rnote}${C_RESET} ${T_V} ${fcol}${fee}${C_RESET} ${T_V}"
        echo -e "${C_BORDER}$line${C_RESET}"
    done
    echo "${C_BORDER}$bot${C_RESET}"
}

draw_daemon_table() {
    local -a names=("$@")
    local -a urls=()
    local d name url nw=4 mw=10 uw=20 i num line
    for d in "${names[@]:-}"; do
        name=$(echo "$d" | jq -r '.name // "?"')
        url=$(echo "$d" | jq -r '.url // "?"')
        urls+=("$url")
        [ "${#name}" -gt "$mw" ] && mw="${#name}"
        [ "${#url}" -gt "$uw" ] && uw="${#url}"
    done
    [ "$mw" -lt 10 ] && mw=10
    [ "$uw" -lt 20 ] && uw=20
    nw="${#names[@]}"
    [ "$nw" -lt 3 ] && nw=3

    top="${T_TL}$(rep "$T_H" $((nw+2)))$T_TT$(rep "$T_H" $((mw+2)))$T_TT$(rep "$T_H" $((uw+2)))$T_TR"
    hdr="${T_V} $(printf '%-*s' "$nw" '#')${T_V} $(printf '%-*s' "$mw" 'Name')${T_V} $(printf '%-*s' "$uw" 'URL')${T_V}"
    mid="${T_LT}$(rep "$T_H" $((nw+2)))$T_X$(rep "$T_H" $((mw+2)))$T_X$(rep "$T_H" $((uw+2)))$T_RT"
    bot="${T_BL}$(rep "$T_H" $((nw+2)))$T_BT$(rep "$T_H" $((mw+2)))$T_BT$(rep "$T_H" $((uw+2)))$T_BR"

    echo "${C_BORDER}$top${C_RESET}"
    echo "${C_BORDER}$hdr${C_RESET}"
    echo "${C_BORDER}$mid${C_RESET}"
    i=0
    for d in "${names[@]:-}"; do
        i=$((i+1))
        num=$(printf '%*s' "$nw" "$i")
        name=$(printf '%-*s' "$mw" "$(echo "$d" | jq -r '.name // "?"')")
        url=$(printf '%-*s' "$uw" "${urls[$((i-1))]}")
        line="${T_V} ${C_NUM}${num}${C_RESET} ${T_V} ${C_NAME}${name}${C_RESET} ${T_V} ${C_BIN}${url}${C_RESET} ${T_V}"
        echo -e "${C_BORDER}$line${C_RESET}"
    done
    echo "${C_BORDER}$bot${C_RESET}"
}

# Accepts a custom node the user typed at the daemon prompt: optional
# http(s):// scheme, hostname / IPv4 / bracketed IPv6, an optional port
# (defaults to $DEFAULT_DAEMON_PORT), and an optional path. Prints the
# normalized URL and returns 0; returns 1 for anything unusable.
normalize_daemon_url() {
    local url="$1" scheme="" host="" port="" path=""
    if [[ ! "$url" =~ ^(https?://)?(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+)(:[0-9]+)?(/.*)?$ ]]; then
        return 1
    fi
    scheme="${BASH_REMATCH[1]}"
    host="${BASH_REMATCH[2]}"
    port="${BASH_REMATCH[3]}"
    path="${BASH_REMATCH[4]}"
    [ -z "$port" ] && port=":$DEFAULT_DAEMON_PORT"
    printf '%s%s%s%s\n' "$scheme" "$host" "$port" "$path"
}

valid_daemon_url() {
    normalize_daemon_url "$1" >/dev/null
}

# Daemon endpoint prompt. Picks a number from the catalog table, lets the user
# type a custom node (host:port) with 'c', or quit with 'q'. Sets DAEMON_URL
# and returns 0 on success; returns 1 when the user quits.
select_daemon() {
    local daemon_jsons=() d dchoice custom
    while IFS= read -r d; do
        [ -n "$d" ] && daemon_jsons+=("$d")
    done < <(jq -c '.daemons[]' "$MINERS_FILE")
    while true; do
        echo "" >&2
        draw_section "SELECT DAEMON ENDPOINT" >&2
        draw_daemon_table "${daemon_jsons[@]:-}" >&2
        printf "Choice (1-%d), c for a custom node, q to quit: " "${#daemon_jsons[@]}" >&2
        read -r dchoice || return 1
        case "$dchoice" in
            q|Q|quit|x|exit) return 1 ;;
            c|C|custom)
                printf "Custom node (host:port, e.g. 192.168.1.10:10100, port defaults to 10100): " >&2
                read -r custom || continue
                if [ -n "$custom" ] && url=$(normalize_daemon_url "$custom"); then
                    DAEMON_URL="$url"
                    return 0
                fi
                echo "${C_ERR}[x] Invalid node. Use host:port (e.g. node.example.org:10100).${C_RESET}" >&2
                ;;
            *)
                if [[ "$dchoice" =~ ^[0-9]+$ ]] && [ "$dchoice" -ge 1 ] && [ "$dchoice" -le "${#daemon_jsons[@]}" ]; then
                    DAEMON_URL=$(echo "${daemon_jsons[$((dchoice - 1))]}" | jq -r '.url')
                    return 0
                fi
                echo "${C_ERR}[x] Invalid choice '$dchoice'${C_RESET}" >&2
                ;;
        esac
    done
}

draw_banner() {
    local width="${COLUMNS:-80}"
    local title="deromine"
    local subtitle="cross-platform DERO miner launcher"
    local inner=$((width - 4))
    [ "$inner" -lt 30 ] && inner=30
    local top bot title_pad subtitle_pad
    top="${TL}$(rep "$H" "$inner")${TR}"
    bot="${BL}$(rep "$H" "$inner")${BR}"
    title_pad=$((inner - 4 - ${#title})); [ "$title_pad" -lt 0 ] && title_pad=0
    subtitle_pad=$((inner - 4 - ${#subtitle})); [ "$subtitle_pad" -lt 0 ] && subtitle_pad=0
    echo "${C_BANNER}$top${C_RESET}"
    echo "${C_BANNER}${V}  ${C_NAME}${title}${C_RESET}${C_BANNER}$(rep ' ' "$title_pad")  ${V}${C_RESET}"
    echo "${C_BANNER}${V}  ${C_DIM}${subtitle}${C_RESET}${C_BANNER}$(rep ' ' "$subtitle_pad")  ${V}${C_RESET}"
    echo "${C_BANNER}$bot${C_RESET}"
    echo "${C_DIM}  [ MENU ]  list  ·  benchmark  ·  help  ·  quit${C_RESET}"
    echo ""
}

draw_section() {
    local label="$1" width="${COLUMNS:-80}" inner
    inner=$((width - 4))
    [ "$inner" -lt 30 ] && inner=30
    echo "${C_BORDER}${T_LT}$(rep "$T_H" "$((inner - 2))")${T_RT}${C_RESET}"
    local label_pad=$((inner - 6 - ${#label})); [ "$label_pad" -lt 0 ] && label_pad=0
    printf '%b\n' "${C_HDR}${T_V}  $label$(rep ' ' "$label_pad")  ${T_V}${C_RESET}"
}

gitlab_id() {
    printf '%s' "$REPO" | jq -sRr @uri
}

resolve_github() {
    API_URL="https://api.github.com/repos/$REPO/releases/latest"
    # GitHub's API requires (and its terms encourage) a User-Agent; identify
    # the app so the request is clearly a real deromine user, not a scraper.
    if ! API_RESP=$(curl -sf -H "User-Agent: deromine/$DEROMINE_VERSION" -H "Accept: application/vnd.github.v3+json" "$API_URL"); then
        echo "${C_ERR}[x] GitHub API failed${C_RESET}"
        return 1
    fi
    TAG=$(echo "$API_RESP" | jq -r '.tag_name')
    ARCHIVE_NAME=$(echo "$API_RESP" | jq -r --arg p "$ASSET_PATTERN" '.assets[].name | select(. | test($p | gsub("\\*";".*")))')
    DOWNLOAD_URL=$(echo "$API_RESP" | jq -r --arg n "$ARCHIVE_NAME" '.assets[] | select(.name == $n) | .browser_download_url')
}

resolve_gitlab_release() {
    local id api resp name path
    id=$(gitlab_id)
    api="https://gitlab.com/api/v4/projects/$id/releases/permalink/latest"
    if ! resp=$(curl -sfL "$api"); then
        echo "${C_ERR}[x] GitLab API failed${C_RESET}"
        return 1
    fi
    TAG=$(echo "$resp" | jq -r '.tag_name')
    ARCHIVE_NAME=""
    DOWNLOAD_URL=""
    while IFS= read -r name; do
        if [[ "$name" == $ASSET_PATTERN ]]; then
            ARCHIVE_NAME="$name"
            DOWNLOAD_URL=$(echo "$resp" | jq -r --arg n "$name" '.assets.links[] | select(.name == $n) | .direct_asset_url')
            break
        fi
    done < <(echo "$resp" | jq -r '.assets.links[].name')
}

resolve_gitlab_branch() {
    local id api resp dirs version name path
    id=$(gitlab_id)
    api="https://gitlab.com/api/v4/projects/$id/repository/tree"
    if ! resp=$(curl -sfL "$api?path=$RELEASE_PATH&ref=$BRANCH&per_page=100"); then
        echo "${C_ERR}[x] GitLab API failed (branch tree)${C_RESET}"
        return 1
    fi
    dirs=$(echo "$resp" | jq -r '.[] | select(.type == "tree" and (.name | test("^v?[0-9.]+$"))) | .name')
    if [ -z "$dirs" ]; then
        echo "${C_ERR}[x] No version dirs under $RELEASE_PATH in $REPO${C_RESET}"
        return 1
    fi
    version=$(echo "$dirs" | awk '{ v=$0; sub(/^v/,"",v); n=split(v,a,"."); for(i=1;i<=3;i++){ a[i]=(a[i]+0)*1 }; score=a[1]*1000000+a[2]*1000+a[3]; print score, $0 }' | sort -n | tail -1 | cut -d' ' -f2-)
    TAG="$version"
    if ! resp=$(curl -sfL "$api?path=$RELEASE_PATH/$version&ref=$BRANCH&per_page=100"); then
        echo "${C_ERR}[x] GitLab API failed (file list)${C_RESET}"
        return 1
    fi
    ARCHIVE_NAME=""
    DOWNLOAD_URL=""
    while IFS= read -r name; do
        if [[ "$name" == $ASSET_PATTERN ]]; then
            ARCHIVE_NAME="$name"
            path=$(echo "$resp" | jq -r --arg n "$name" '.[] | select(.type == "blob" and .name == $n) | .path')
            DOWNLOAD_URL="https://gitlab.com/$REPO/-/raw/$BRANCH/$path"
            break
        fi
    done < <(echo "$resp" | jq -r '.[] | select(.type == "blob") | .name')
}

# Dispatch to the host-specific resolver. Returns 1 when the release API call
# fails (rate-limited, offline) so resolve_release can fall back to a cached
# tag instead of failing outright.
resolve_for_host() {
    case "$HOST" in
        gitlab-release) resolve_gitlab_release ;;
        gitlab-branch)  resolve_gitlab_branch ;;
        *)              resolve_github ;;
    esac
}

# Resolve the latest release tag + asset, skipping the release API entirely
# while the cached binary's tag is fresh (cached_tag_fresh). On API failure,
# falls back to the last recorded tag when the binary is cached. Requires
# BINARY_PATH and the resolve_* globals; sets TAG (+ ARCHIVE_NAME and
# DOWNLOAD_URL when a release was actually resolved). Sets RESOLVED_FRESH=true
# when the release API was actually queried (so callers can distinguish a
# fresh resolve from a cached/fallback tag).
resolve_release() {
    local cached=""
    RESOLVED_FRESH=false
    # A direct launch always checks the release API (ALWAYS_RESOLVE) so a new
    # release is picked up even while the tag cache is fresh. The cache-skip
    # applies only to fan-out modes (benchmark) and is bypassed by --update.
    # The skip also requires the binary to still pass its integrity check: a
    # corrupt binary inside the TTL must NOT be silently trusted.
    if [ "${ALWAYS_RESOLVE:-false}" != true ] && [ "${FORCE_UPDATE:-false}" != true ] \
        && [ "$DRY_RUN" != true ] && cached_tag_fresh "$BINARY_PATH" && binary_integrity_ok "$BINARY_PATH"; then
        TAG=$(cat "$BINARY_PATH.tag")
        echo "${C_DIM}  Using cached tag $TAG (release API skipped for ${TAG_CACHE_TTL}s)${C_RESET}" >&2
        return 0
    fi
    [ -f "$BINARY_PATH.tag" ] && cached=$(cat "$BINARY_PATH.tag")
    echo "${C_HDR}Resolving latest release for $REPO...${C_RESET}" >&2
    if ! resolve_for_host; then
        if [ -n "$cached" ] && [ -f "$BINARY_PATH" ]; then
            echo "${C_DIM}  (release API unreachable; using cached tag $cached)${C_RESET}" >&2
            TAG="$cached"
            return 0
        fi
        return 1
    fi
    RESOLVED_FRESH=true
    return 0
}

# ── Collect catalog into arrays ──
MINER_JSONS=()
while IFS= read -r m; do
    [ -n "$m" ] && MINER_JSONS+=("$m")
done < <(read_catalog)
[ "${#MINER_JSONS[@]}" -eq 0 ] && { echo "${C_ERR}[x] No miners in catalog${C_RESET}"; exit 1; }

ALL_SUPPORTED=()
SUPPORTED=()
BENCH_OPT_IN=()
for m in "${MINER_JSONS[@]}"; do
    pattern=$(get_asset_pattern "$m")
    [ -z "$pattern" ] && continue
    if ! miner_hardware_ok "$m"; then continue; fi
    # Hide miners that can't actually run on this host: self-test-gated GPU
    # miners (go-gpu) are listed only once a launch proved they work here;
    # other miners are hidden after one confirmed startup failure.
    if ! miner_listable_on_host "$BIN_DIR" "$m"; then continue; fi
    policy=$(benchmark_policy "$m")
    ALL_SUPPORTED+=("$m")
    if [ "$policy" = "disabled" ]; then
        continue
    fi
    if [ "$policy" = "opt-in" ]; then
        BENCH_OPT_IN+=("$m")
        if [ "$INCLUDE_CLOSED_SOURCE" = false ]; then continue; fi
    fi
    SUPPORTED+=("$m")
done

# ── Check-catalog mode ──
# Audit every catalog asset pattern against the LIVE latest release for the
# current OS/arch, without downloading anything. Flags a pattern that matched
# no asset (so a stale miners.json stops masquerading as "latest").
if [ "$CHECK_CATALOG" = true ]; then
    draw_banner
    draw_section "CATALOG CHECK · LATEST RELEASES vs MINERS.JSON PATTERNS"
    ok=0; bad=0; apifail=0
    for m in "${MINER_JSONS[@]}"; do
        id=$(echo "$m" | jq -r '.id')
        name=$(echo "$m" | jq -r '.name // .id')
        pattern=$(get_asset_pattern "$m")
        [ -z "$pattern" ] && { echo "  ${C_DIM}[skip] $name: no asset for $OS/$ARCH${C_RESET}"; continue; }
        REPO=$(echo "$m" | jq -r '.repo')
        HOST=$(echo "$m" | jq -r '.host // "github"')
        BRANCH=$(echo "$m" | jq -r '.branch // "main"')
        RELEASE_PATH=$(echo "$m" | jq -r '.release_path // "releases"')
        ASSET_PATTERN="$pattern"
        ARCHIVE_NAME=""; DOWNLOAD_URL=""; API_RESP=""
        if ! resolve_for_host; then
            echo "  ${C_ERR}[api] $name ($REPO): release API failed${C_RESET}"
            apifail=$((apifail + 1))
            continue
        fi
        if [ -z "$ARCHIVE_NAME" ]; then
            echo "  ${C_ERR}[MISMATCH] $name ($REPO): pattern '$pattern' matched no asset in $TAG${C_RESET}"
            bad=$((bad + 1))
        else
            echo "  ${C_OK}[ok] $name ($REPO): $TAG -> $ARCHIVE_NAME${C_RESET}"
            ok=$((ok + 1))
        fi
    done
    echo ""
    echo "${C_OK}[*] $ok patterns match the latest release${C_RESET}"
    [ "$bad" -gt 0 ] && echo "${C_ERR}[x] $bad patterns match NO asset in the latest release — update miners.json${C_RESET}"
    [ "$apifail" -gt 0 ] && echo "${C_DIM}[!] $apifail release API calls failed (rate-limited/offline)${C_RESET}"
    exit 0
fi

# ── Benchmark mode ──
parse_hashrate() {
    local out="$1" val num unit mult
    val=$(grep -aoE '[0-9]+(\.[0-9]+)? ?[kKmM]? ?H/s' "$out" | tail -1)
    [ -z "$val" ] && { echo ""; return; }
    num=$(echo "$val" | grep -aoE '[0-9]+(\.[0-9]+)?')
    unit=$(echo "$val" | grep -aoE '[kKmM][ ]?H/s' | tail -1 | cut -c1)
    mult=1
    case "$unit" in
        k|K) mult=1000 ;;
        m|M) mult=1000000 ;;
    esac
    awk -v n="$num" -v m="$mult" 'BEGIN{ printf "%.2f", n*m }'
}

parse_tnn() {
    local out="$1" val
    val=$(grep -aoE 'threads @ [0-9]+(\.[0-9]+)?' "$out" | tail -1 | sed 's/threads @ //')
    [ -z "$val" ] && { echo ""; return; }
    awk -v n="$val" 'BEGIN{ printf "%.2f", n*1000 }'
}

parse_derohe() {
    local out="$1" val num unit mult
    val=$(grep -aoE 'MINING @ [0-9]+(\.[0-9]+)?[ ]?[kKmM]?[ ]?H/s' "$out" | tail -1)
    [ -z "$val" ] && { echo ""; return; }
    num=$(echo "$val" | grep -aoE '[0-9]+(\.[0-9]+)?')
    unit=$(echo "$val" | grep -aoE '[kKmM][ ]?H/s' | tail -1 | cut -c1)
    mult=1
    case "$unit" in
        k|K) mult=1000 ;;
        m|M) mult=1000000 ;;
    esac
    awk -v n="$num" -v m="$mult" 'BEGIN{ printf "%.2f", n*m }'
}

if $BENCH_MODE; then
    [ "$BENCH_TIME" -lt 1 ] && BENCH_TIME=30
    if [ "$THREAD_COUNT" -eq 0 ] && [ -f "$CONFIG_FILE" ]; then
        THREAD_COUNT=$(jq -r '.thread_count // 0' "$CONFIG_FILE")
    fi
    [ "$THREAD_COUNT" -eq 0 ] && THREAD_COUNT=$(( ($(nproc 2>/dev/null || echo 4)) - 1 ))
    [ "$THREAD_COUNT" -lt 1 ] && THREAD_COUNT=1
    if [ -f "$CONFIG_FILE" ]; then
        [ -z "$DAEMON_URL" ] && DAEMON_URL=$(jq -r '.daemon_url // "http://127.0.0.1:10100"' "$CONFIG_FILE")
        [ -z "$WALLET_ADDR" ] && WALLET_ADDR=$(jq -r '.wallet_address // ""' "$CONFIG_FILE")
    fi
    [ -z "$DAEMON_URL" ] && DAEMON_URL="http://127.0.0.1:10100"
    [ -z "$WALLET_ADDR" ] && WALLET_ADDR="$DEFAULT_WALLET"
    LIVE_DAEMON="${DAEMON_URL#http://}"
    LIVE_DAEMON="${LIVE_DAEMON#https://}"

    if [ "${#BENCH_OPT_IN[@]}" -gt 0 ] && [ "$INCLUDE_CLOSED_SOURCE" = true ]; then
        echo "" >&2
        echo "${C_ERR}WARNING: this will download and execute closed-source or partially closed-source miners.${C_RESET}" >&2
        opt_names=()
        for opt_m in "${BENCH_OPT_IN[@]}"; do opt_names+=("$(echo "$opt_m" | jq -r '.name')"); done
        echo "${C_ERR}Affected miners: ${opt_names[*]}${C_RESET}" >&2
        if [ "$ASSUME_YES" = true ]; then
            echo "Non-interactive confirmation supplied with --yes." >&2
        else
            if [ ! -t 0 ]; then
                echo "${C_ERR}Non-interactive input detected; rerun with --yes only after reviewing the risk.${C_RESET}" >&2
                exit 1
            fi
            printf "Continue with these miners? [y/N] " >&2
            read -r answer || answer=""
            if [[ ! "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; then
                echo "Benchmark cancelled; no opt-in miners were run." >&2
                exit 0
            fi
        fi
    fi
    if [ "${#BENCH_OPT_IN[@]}" -gt 0 ] && [ "$INCLUDE_CLOSED_SOURCE" = false ]; then
        opt_names=()
        for opt_m in "${BENCH_OPT_IN[@]}"; do opt_names+=("$(echo "$opt_m" | jq -r '.name')"); done
        echo "Skipped untrusted miners: ${opt_names[*]}" >&2
        echo "Use --include-closed-source to opt in; add --yes for non-interactive confirmation." >&2
    fi

    if [ "${#SUPPORTED[@]}" -eq 0 ]; then
        echo "${C_ERR}[x] No miners available to benchmark on this host${C_RESET}"
        exit 1
    fi

    draw_banner
    draw_section "BENCHMARK  ·  ${#SUPPORTED[@]} MINERS  ·  ${BENCH_TIME}s EACH"
    echo "${C_HDR}  Running with ${THREAD_COUNT} threads...${C_RESET}"

    bench_miner() {
        local m="$1" id name fee repo host branch rpath pattern bname abin out raw
        id=$(echo "$m" | jq -r '.id')
        name=$(echo "$m" | jq -r '.name // .id')
        fee=$(echo "$m" | jq -r '.fee // "0%"')
        policy=$(benchmark_policy "$m")
        if [ "$policy" = "disabled" ]; then
            echo "  ${C_DIM}[skip] $name: benchmark disabled in catalog${C_RESET}"
            return
        fi
        if [ "$policy" = "opt-in" ] && [ "$INCLUDE_CLOSED_SOURCE" = false ]; then
            echo "  ${C_DIM}[skip] $name: closed/partially closed miner requires --include-closed-source${C_RESET}"
            return
        fi
        repo=$(echo "$m" | jq -r '.repo')
        host=$(echo "$m" | jq -r '.host // "github"')
        branch=$(echo "$m" | jq -r '.branch // "main"')
        rpath=$(echo "$m" | jq -r '.release_path // "releases"')
        bname=$(get_binary_name "$m")
        abin=$(get_archive_binary_name "$m")
        pattern=$(get_asset_pattern "$m")
        [ -z "$pattern" ] && { echo "  ${C_DIM}[skip] $name: no asset for $OS/$ARCH${C_RESET}"; return; }

        MINER_DIR="$BIN_DIR/$id"
        mkdir -p "$MINER_DIR"
        BINARY_PATH="$MINER_DIR/$bname"
        # Resolve (skips the release API while the cached tag is fresh).
        REPO="$repo"; HOST="$host"; BRANCH="$branch"; RELEASE_PATH="$rpath"; ASSET_PATTERN="$pattern"
        if ! resolve_release; then
            echo "  ${C_ERR}[x] $name: release resolve failed (no cached tag)${C_RESET}"; return
        fi
        if [ -z "$ARCHIVE_NAME" ] || [ -z "$DOWNLOAD_URL" ]; then
            if [ "$RESOLVED_FRESH" = true ] && [ -f "$BINARY_PATH" ] && [ -f "$BINARY_PATH.tag" ]; then
                TAG=$(cat "$BINARY_PATH.tag")
                echo "  ${C_ERR}[!] $name: catalog pattern '$pattern' matched no asset in the latest release; using cached binary (tag $TAG)${C_RESET}"
            elif [ ! -f "$BINARY_PATH" ]; then
                echo "  ${C_ERR}[x] $name: no matching asset${C_RESET}"; return
            fi
        fi
        if [ ! -f "$BINARY_PATH" ]; then
            echo "  ${C_DIM}[fetch] $name ($TAG)${C_RESET}"
            ARCHIVE_BINARY="$abin"
            if ! fetch_binary; then echo "  ${C_ERR}[x] $name: fetch failed${C_RESET}"; return; fi
        elif ! cached_binary_usable "$BINARY_PATH" "$TAG"; then
            echo "  ${C_DIM}[re-fetch] $name: cached binary stale or corrupt${C_RESET}"
            rm -f "$BINARY_PATH" "$BINARY_PATH.tag" "$BINARY_PATH.cleaned"
            ARCHIVE_BINARY="$abin"
            if ! fetch_binary; then echo "  ${C_ERR}[x] $name: fetch failed${C_RESET}"; return; fi
        fi
        if [ ! -f "$BINARY_PATH" ]; then
            echo "  ${C_ERR}[x] $name: binary not found after extraction${C_RESET}"; return
        fi

        echo -n "  ${C_NAME}$name${C_RESET}: "
        out=$(mktemp)
        case "$id" in
            tnn)     tmo "$((BENCH_TIME + 15))" "$BINARY_PATH" --DERO --daemon-address "$LIVE_DAEMON" --wallet "$WALLET_ADDR" --threads "$THREAD_COUNT" --mine-time "$BENCH_TIME" --no-gpu >"$out" 2>&1 || true ;;
            go)      tmo "$((BENCH_TIME + 20))" "$BINARY_PATH" --sustained --secs "$BENCH_TIME" -t "$THREAD_COUNT" >"$out" 2>&1 || true ;;
            zig)     tmo 20 "$BINARY_PATH" --bench >"$out" 2>&1 || true ;;
            rust)    tmo "$((BENCH_TIME + 20))" "$BINARY_PATH" --sustained -t "$THREAD_COUNT" >"$out" 2>&1 || true ;;
            go-gpu)  tmo 45 "$BINARY_PATH" -benchpipe 8000 -batch 400 >"$out" 2>&1 || true ;;
            c|deroluna) tmo "$((BENCH_TIME + 10))" "$BINARY_PATH" -d "$LIVE_DAEMON" -w "$WALLET_ADDR" -t "$THREAD_COUNT" >"$out" 2>&1 || true ;;
            derohe)
                if command -v script >/dev/null 2>&1; then
                    ( cd "$MINER_DIR" && tmo "$((BENCH_TIME + 30))" script -qec "$BINARY_PATH --wallet-address $WALLET_ADDR --daemon-rpc-address $LIVE_DAEMON --mining-threads $THREAD_COUNT" /dev/null ) >"$out" 2>&1 || true
                else
                    echo "${C_ERR}no pty (script) for derohe${C_RESET}"; rm -f "$out"; return
                fi
                ;;
            *) rm -f "$out"; echo "${C_ERR}no benchmark method${C_RESET}"; return ;;
        esac
        if [ "$id" = "derohe" ]; then
            raw=$(parse_derohe "$out")
        elif [ "$id" = "tnn" ]; then
            raw=$(parse_tnn "$out")
        else
            raw=$(parse_hashrate "$out")
        fi
        tail_txt=""
        if [ -s "$out" ]; then
            tail_txt=$(tail -c 600 "$out" | sed 's/\x1b\[[0-9;]*m//g' | tr -s ' ' | tail -2)
        fi
        rm -f "$out"
        if [ -z "$raw" ]; then
            echo "${C_ERR}no hashrate reported${C_RESET}"
            [ -n "$tail_txt" ] && echo "  output tail: $tail_txt"
            return
        fi
        fee_num=${fee%%%}
        eff=$(awk -v r="$raw" -v f="$fee_num" 'BEGIN{ printf "%.2f", r*(1-f/100) }')
        echo "${C_OK}${raw} H/s${C_RESET} (fee ${fee}, effective ${eff})"
        BENCH_ROWS+=("$eff|$raw|$fee|$name|$id")
    }

    BENCH_ROWS=()
    for m in "${SUPPORTED[@]:-}"; do
        bench_miner "$m"
        sleep 3
    done

    echo ""
    if [ "${#BENCH_ROWS[@]}" -eq 0 ]; then
        echo "${C_ERR}[x] No benchmark results collected${C_RESET}"
        exit 1
    fi
    BENCH_CACHE="$BIN_DIR/.benchmarks.json"
    declare -A PREV_IDX=()
    if [ -f "$BENCH_CACHE" ]; then
        while IFS='=' read -r mid val; do
            PREV_IDX["$mid"]="$val"
        done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' "$BENCH_CACHE" 2>/dev/null)
    fi
    printf '%s\n' "${BENCH_ROWS[@]}" | sort -t'|' -k1 -rn > "$BIN_DIR/._bench_sorted" 2>/dev/null || true
    printf '%-4s %-30s %12s %8s %14s %10s\n' '#' 'Miner' 'H/s' 'Fee' 'Eff. H/s' 'Δ vs last'
    while IFS='|' read -r beff braw bfee bname bid; do
        delta="—"
        if [ -n "${PREV_IDX[$bid]:-}" ]; then
            last="${PREV_IDX[$bid]}"
            d=$(awk -v e="$beff" -v l="$last" 'BEGIN{ printf "%+.1f", e-l }')
            delta="$d"
        fi
        printf '%-4d %-30s %12s %8s %14s %10s\n' "$(( ++_brow ))" "$bname" "$braw" "$bfee" "$beff" "$delta"
    done < "$BIN_DIR/._bench_sorted"
    rm -f "$BIN_DIR/._bench_sorted"
    echo ""
    winner=$(printf '%s\n' "${BENCH_ROWS[@]}" | sort -t'|' -k1 -rn | head -1)
    echo "${C_OK}Best miner: ${C_NAME}$(echo "$winner" | cut -d'|' -f4)${C_RESET} (effective ${C_OK}$(echo "$winner" | cut -d'|' -f1) H/s${C_RESET}, raw $(echo "$winner" | cut -d'|' -f2) H/s)"
    # Save results for next run
    {
        printf '{'
        first=1
        for row in "${BENCH_ROWS[@]}"; do
            effv=$(echo "$row" | cut -d'|' -f1)
            idv=$(echo "$row" | cut -d'|' -f5)
            if [ "$first" -ne 1 ]; then printf ','; fi
            printf '"%s":%s' "$idv" "$effv"
            first=0
        done
        printf '}\n'
    } > "$BENCH_CACHE"
    echo "[*] Saved to ${C_DIM}$BENCH_CACHE${C_RESET}"
    exit 0
fi

# ── List mode ──
if [ "$MINER_ID" = "list" ]; then
    draw_banner
    draw_section "MINER CATALOG  ·  $OS/$ARCH"
    draw_miner_table "${ALL_SUPPORTED[@]:-}"
    exit 0
fi

# ── Interactive menu ──
if [ -z "$MINER_ID" ] || [ "$MINER_ID" = "interactive" ]; then
    draw_banner
    draw_section "SELECT A MINER  ·  $OS/$ARCH" >&2
    draw_miner_table "${ALL_SUPPORTED[@]:-}" >&2
    if [ "${#ALL_SUPPORTED[@]}" -eq 0 ]; then
        echo "${C_ERR}[x] No miners available on this host${C_RESET}" >&2
        exit 1
    fi
    printf "Choice (1-%d): " "${#ALL_SUPPORTED[@]}" >&2
    read -r choice
    choice=$((choice - 1))
    MINER_JSON="${ALL_SUPPORTED[$choice]:-}"
    MINER_ID=$(echo "$MINER_JSON" | jq -r '.id')
else
    MINER_JSON=$(get_miner_by_id "$MINER_ID")
fi

if [ -z "$MINER_JSON" ]; then
    echo "${C_ERR}[x] Miner '$MINER_ID' not found or unavailable${C_RESET}"
    exit 1
fi
if ! miner_hardware_ok "$MINER_JSON"; then
    # Refuse BEFORE any resolve/download (an unsupported miner must never be
    # fetched, even when force-run with --miner=<id>).
    if [ "$IS_TERMUX" -eq 1 ]; then
        echo "${C_ERR}[x] Miner '$MINER_ID' is not supported on Termux/Android; nothing was downloaded.${C_RESET}"
    else
        echo "${C_ERR}[x] Miner '$MINER_ID' is not supported on this host${C_RESET}"
    fi
    exit 1
fi

BINARY_NAME=$(get_binary_name "$MINER_JSON")
ARCHIVE_BINARY=$(get_archive_binary_name "$MINER_JSON")
ASSET_PATTERN=$(get_asset_pattern "$MINER_JSON")
if [ -z "$ASSET_PATTERN" ]; then
    echo "${C_ERR}[x] No asset for $MINER_ID on $OS/$ARCH${C_RESET}"
    exit 1
fi

# ── Config ──
mkdir -p "$BIN_DIR"

# Wallet
if [ -f "$PROJECT_DIR/config.bak" ]; then
    DEFAULT_WALLET=$(jq -r '.wallet_address // ""' "$PROJECT_DIR/config.bak")
fi
if [ -z "$WALLET_ADDR" ]; then
    if [ -f "$CONFIG_FILE" ]; then
        WALLET_ADDR=$(jq -r '.wallet_address // ""' "$CONFIG_FILE")
    fi
fi
while [ -z "$WALLET_ADDR" ]; do
    echo "" >&2
    if [ -n "$DEFAULT_WALLET" ]; then
        printf "%s Your DERO wallet address (default: %s, leave empty to use it): " "$ARROW" "$DEFAULT_WALLET" >&2
    else
        printf "%s Your DERO wallet address (dero1..., deroi1..., or deto1...): " "$ARROW" >&2
    fi
    read -r addr
    if [ -z "$addr" ] && [ -n "$DEFAULT_WALLET" ]; then
        WALLET_ADDR="$DEFAULT_WALLET"
    elif [ -z "$addr" ]; then
        echo "${C_ERR}[x] No address, exiting${C_RESET}" >&2; exit 1
    else
        WALLET_ADDR="$addr"
    fi
done

# Daemon: --daemon flag > live localhost > saved config > prompt
if [ "$DAEMON_FLAG" -eq 0 ]; then
    LOCAL_DAEMON=$(detect_local_daemon) || true
    if [ -n "$LOCAL_DAEMON" ]; then
        echo "${C_OK}[*] Local DERO daemon detected: $LOCAL_DAEMON${C_RESET}" >&2
        DAEMON_URL="$LOCAL_DAEMON"
    else
        if [ -f "$CONFIG_FILE" ]; then
            CFGD=$(jq -r '.daemon_url // ""' "$CONFIG_FILE")
            if [ -n "$CFGD" ] && is_mining_url "$CFGD"; then
                DAEMON_URL="$CFGD"
            else
                # stale saved config pointing at a non-mining port (e.g. HTTP
                # JSON-RPC 10102/40402/19999) — never hand it to the miner
                DAEMON_URL=""
            fi
        fi
        if [ -z "$DAEMON_URL" ]; then
            if ! select_daemon; then
                exit 0
            fi
        fi
    fi
fi

# Threads
if [ "$THREAD_COUNT" -eq 0 ]; then
    if [ -f "$CONFIG_FILE" ]; then
        THREAD_COUNT=$(jq -r '.thread_count // 0' "$CONFIG_FILE")
    fi
fi
if [ "$THREAD_COUNT" -eq 0 ]; then
    DEFAULT_TC=$(( ($(nproc 2>/dev/null || echo 4)) - 1 ))
    [ "$DEFAULT_TC" -lt 1 ] && DEFAULT_TC=1
    echo "" >&2
    printf "%s Thread count (default: %s): " "$ARROW" "$DEFAULT_TC" >&2
    read -r tc
    THREAD_COUNT="${tc:-$DEFAULT_TC}"
fi

# Save config. A dry-run is read-only: it must never persist whatever
# --wallet/--daemon/--threads were passed on the command line, or it would
# clobber the real saved config (the dry-run exit happens later, after the
# LAUNCH PLAN is printed).
if ! $DRY_RUN; then
    jq -n \
        --arg w "$WALLET_ADDR" \
        --arg d "$DAEMON_URL" \
        --argjson t "$THREAD_COUNT" \
        '{wallet_address: $w, daemon_url: $d, thread_count: $t}' > "$CONFIG_FILE"
    echo "${C_OK}[*] Config saved to $CONFIG_FILE${C_RESET}" >&2
    draw_section "CONFIGURATION READY" >&2
fi
printf '%b\n' "${C_DIM}${T_V}  wallet  ${C_NAME}${WALLET_ADDR:0:8}…${WALLET_ADDR: -6}${C_RESET}"
printf '%b\n' "${C_DIM}${T_V}  daemon  ${C_NAME}${DAEMON_URL}${C_RESET}"
printf '%b\n' "${C_DIM}${T_V}  threads ${C_NAME}${THREAD_COUNT}${C_RESET}"

# ── Resolve download ──
# A direct launch always checks the release API (ALWAYS_RESOLVE) so a new
# release is picked up even while the tag cache is fresh; MINER_DIR/BINARY_PATH
# are still needed up front for the cached-tag fallback.
ALWAYS_RESOLVE=true
REPO=$(echo "$MINER_JSON" | jq -r '.repo')
HOST=$(echo "$MINER_JSON" | jq -r '.host // "github"')
BRANCH=$(echo "$MINER_JSON" | jq -r '.branch // "main"')
RELEASE_PATH=$(echo "$MINER_JSON" | jq -r '.release_path // "releases"')
MINER_DIR="$BIN_DIR/$MINER_ID"
mkdir -p "$MINER_DIR"
BINARY_PATH="$MINER_DIR/$BINARY_NAME"
echo "" >&2

if ! resolve_release; then
    echo "${C_ERR}[x] Could not resolve latest release for $REPO (release API failed and no cached tag)${C_RESET}" >&2
    exit 1
fi
if [ -n "$ARCHIVE_NAME" ] && [ -n "$DOWNLOAD_URL" ]; then
    echo "  ${C_DIM}Tag:   $TAG${C_RESET}" >&2
    echo "  ${C_DIM}Asset: $ARCHIVE_NAME${C_RESET}" >&2
fi
if [ -z "$ARCHIVE_NAME" ] || [ -z "$DOWNLOAD_URL" ]; then
    if [ "$RESOLVED_FRESH" = true ] && [ -f "$BINARY_PATH" ] && [ -f "$BINARY_PATH.tag" ]; then
        # The latest release resolved, but the catalog pattern matched no
        # asset in it. Fail LOUD — a stale pattern silently pins the user to
        # an old binary while masquerading as "latest". Keep the cached
        # binary usable (so mining still works) by falling back to its tag,
        # but never attempt a download with an empty URL.
        fresh_tag="$TAG"
        TAG=$(cat "$BINARY_PATH.tag")
        echo "${C_ERR}[!] Catalog pattern '$ASSET_PATTERN' matched no asset in release $fresh_tag of $REPO${C_RESET}" >&2
        echo "    Update the pattern in miners.json to keep picking up new releases." >&2
        if [ -n "${API_RESP:-}" ] && [ "$HOST" != "gitlab-release" ] && [ "$HOST" != "gitlab-branch" ]; then
            echo "  ${C_DIM}Available assets in the latest release:${C_RESET}" >&2
            echo "$API_RESP" | jq -r '.assets[].name' | sed 's/^/    /' >&2
        fi
        echo "  ${C_DIM}Using cached binary (tag $TAG) while the pattern is broken.${C_RESET}" >&2
    elif [ ! -f "$BINARY_PATH" ]; then
        echo "${C_ERR}[x] No matching asset for pattern: $ASSET_PATTERN${C_RESET}" >&2
        if [ -n "${API_RESP:-}" ] && [ "$HOST" != "gitlab-release" ] && [ "$HOST" != "gitlab-branch" ]; then
            echo "  ${C_DIM}Available assets in the latest release:${C_RESET}" >&2
            echo "$API_RESP" | jq -r '.assets[].name' | sed 's/^/    /' >&2
        fi
        exit 1
    fi
fi

# ── Dry-run ──
if $DRY_RUN; then
    DAEMON_ADDR="${DAEMON_URL#http://}"
    DAEMON_ADDR="${DAEMON_ADDR#https://}"
    echo ""
    echo "--- DRY RUN ---"
    echo "Miner:   $MINER_ID"
    echo "Binary:  $BINARY_NAME"
    echo "Tag:     $TAG"
    echo "Asset:   $ARCHIVE_NAME"
    echo "URL:     $DOWNLOAD_URL"
    echo "Wallet:  $WALLET_ADDR"
    echo "Daemon:  $DAEMON_ADDR"
    echo "Threads: $THREAD_COUNT"
    FLAG_DEV_FEE=$(echo "$MINER_JSON" | jq -r '.flags.dev_fee // empty')
    if [ -n "$FLAG_DEV_FEE" ] && [ -n "$DEV_FEE_OVERRIDE" ]; then
        echo "Dev fee: $DEV_FEE_OVERRIDE%"
    fi
    exit 0
fi

# ── Download & extract (version-aware cache: a stale or corrupt cached
#    binary is re-downloaded instead of being used forever) ──
if [ ! -f "$BINARY_PATH" ]; then
    fetch_binary || exit 1
elif ! cached_binary_usable "$BINARY_PATH" "$TAG"; then
    echo "${C_ERR}[x] Cached binary is stale or corrupt; re-downloading${C_RESET}" >&2
    rm -f "$BINARY_PATH" "$BINARY_PATH.tag" "$BINARY_PATH.asset" "$BINARY_PATH.cleaned"
    fetch_binary || exit 1
else
    echo "${C_OK}[*] Using cached binary: $BINARY_PATH ($TAG)${C_RESET}" >&2
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo "${C_ERR}[x] Binary '$BINARY_NAME' not found after extraction${C_RESET}" >&2
    find "$MINER_DIR" -type f >&2
    exit 1
fi

# ELF-patch for Termux/Android before launch. fetch_binary patches a fresh
# download, but a cached binary fetched before termux-elf-cleaner existed (or
# before the patch step was added) still needs it — otherwise bionic aborts in
# the loader (e.g. dirtybird-c-miner's aarch64_android build: TLS underaligned,
# needs 64). Idempotent via the .cleaned marker.
termux_patch_binary "$BINARY_PATH"
# Launch-time self-heal for Termux: even after patching, a cached binary may
# still fail bionic's TLS layout check (termux-elf-cleaner can raise p_align to
# 64 but cannot re-align a skewed segment, e.g. stale dirtybird-c-miner
# v1.0.39's p_vaddr % 64 = 48). Detect it statically and re-download once
# instead of letting the loader SIGABRT — the rebuilt release asset ships no
# PT_TLS and passes. Guarded so a genuinely broken release can't loop forever.
if [ "${IS_TERMUX:-0}" -eq 1 ] && [ -f "$BINARY_PATH" ] && ! elf_tls_bionic_ok "$BINARY_PATH"; then
    echo "${C_ERR}[x] Cached binary fails bionic's TLS layout check; re-downloading${C_RESET}" >&2
    rm -f "$BINARY_PATH" "$BINARY_PATH.tag" "$BINARY_PATH.asset" "$BINARY_PATH.cleaned"
    if fetch_binary; then
        termux_patch_binary "$BINARY_PATH"
    fi
fi

# ── Build args ──
DAEMON_ADDR="${DAEMON_URL#http://}"
DAEMON_ADDR="${DAEMON_ADDR#https://}"

FLAG_COIN=$(echo "$MINER_JSON" | jq -r '.flags.coin // empty')
FLAG_DAEMON=$(echo "$MINER_JSON" | jq -r '.flags.daemon // "-d"')
FLAG_WALLET=$(echo "$MINER_JSON" | jq -r '.flags.wallet // "-w"')
FLAG_THREADS=$(echo "$MINER_JSON" | jq -r '.flags.threads // "-t"')
FLAG_PORT=$(echo "$MINER_JSON" | jq -r '.flags.port // empty')
FLAG_DEV_FEE=$(echo "$MINER_JSON" | jq -r '.flags.dev_fee // empty')
if [ -n "$FLAG_DEV_FEE" ] && [ -n "$DEV_FEE_OVERRIDE" ]; then
    DEV_FEE="$DEV_FEE_OVERRIDE"
else
    DEV_FEE=$(echo "$MINER_JSON" | jq -r '.fee // ""' | tr -d '%')
fi

CMD_ARGS=()
if [ -n "$FLAG_COIN" ]; then CMD_ARGS+=("$FLAG_COIN"); fi
if [ -n "$FLAG_PORT" ]; then
    DAEMON_HOST="${DAEMON_ADDR%:*}"
    DAEMON_PORT="${DAEMON_ADDR##*:}"
    CMD_ARGS+=("$FLAG_DAEMON" "$DAEMON_HOST" "$FLAG_PORT" "$DAEMON_PORT")
else
    CMD_ARGS+=("$FLAG_DAEMON" "$DAEMON_ADDR")
fi
CMD_ARGS+=("$FLAG_WALLET" "$WALLET_ADDR")
case "$MINER_ID" in
    cuda|go-gpu) ;;  # GPU miners: no -t flag
    *) CMD_ARGS+=("$FLAG_THREADS" "$THREAD_COUNT") ;;
esac
if [ -n "$FLAG_DEV_FEE" ] && [ -n "$DEV_FEE" ]; then CMD_ARGS+=("$FLAG_DEV_FEE" "$DEV_FEE"); fi

# ── Launch summary ──
MINER_NAME=$(echo "$MINER_JSON" | jq -r '.name // "$MINER_ID"')
LW=7
[ "${#MINER_NAME}" -gt "$LW" ] && LW="${#MINER_NAME}"
[ "${#BINARY_PATH}" -gt "$LW" ] && LW="${#BINARY_PATH}"
[ "${#DAEMON_ADDR}" -gt "$LW" ] && LW="${#DAEMON_ADDR}"
[ "${#WALLET_ADDR}" -gt "$LW" ] && LW="${#WALLET_ADDR}"
[ "${#THREAD_COUNT}" -gt "$LW" ] && LW="${#THREAD_COUNT}"
LW=$((LW + 3))
term_w="${COLUMNS:-80}"
[ "$LW" -gt "$((term_w - 4))" ] && LW=$((term_w - 4))

summary_line() {
    local label="$1" value="$2"
    local value_width=$((LW - ${#label} - 4))
    [ "$value_width" -lt 4 ] && value_width=4
    if [ "${#value}" -gt "$value_width" ]; then
        value="${value:0:$((value_width - 1))}…"
    fi
    local pad=$((LW - ${#label} - 4))
    printf '%b' "${C_OK}${V}${C_RESET}  ${C_NAME}$label${C_RESET}  ${C_BIN}$(printf '%-*s' "$pad" "$value")${C_RESET}${C_OK}${V}${C_RESET}\n"
}
echo ""
echo "${C_OK}${TL}$(rep "$H" "$LW")${TR}${C_RESET}"
  printf '%b\n' "${C_OK}${V}${C_RESET}  ${C_NAME}LAUNCH PLAN${C_RESET}$(rep ' ' "$((LW - 13))")${C_OK}${V}${C_RESET}"
  echo "${C_OK}${T_LT}$(rep "$T_H" "$LW")${T_RT}${C_RESET}"
  summary_line "Miner" "$MINER_NAME"
  summary_line "Binary" "$BINARY_PATH"
summary_line "Daemon" "$DAEMON_ADDR"
summary_line "Wallet" "${WALLET_ADDR:0:8}…${WALLET_ADDR: -6}"
summary_line "Threads" "$THREAD_COUNT"
echo "${C_OK}${BL}$(rep "$H" "$LW")${BR}${C_RESET}"
echo ""

# ── Preflight: never launch a miner with an empty value ──
if [ -z "$WALLET_ADDR" ]; then
    echo "${C_ERR}[x] No wallet address to pass to the miner${C_RESET}" >&2
    exit 1
fi
if [ -z "$DAEMON_ADDR" ]; then
    echo "${C_ERR}[x] No daemon address to pass to the miner${C_RESET}" >&2
    exit 1
fi
if [ -z "$THREAD_COUNT" ] || ! [ "$THREAD_COUNT" -ge 1 ] 2>/dev/null; then
    echo "${C_ERR}[x] No valid thread count: '${THREAD_COUNT:-}'${C_RESET}" >&2
    exit 1
fi
echo "  ${C_DIM}[*] Command: $BINARY_PATH ${CMD_ARGS[*]}${C_RESET}" >&2

# ── Launch loop ──
RESTART_COUNT=0
LOGFILE=""
if $AUTO_RESTART; then
    LOGDIR="$BIN_DIR/logs"
    mkdir -p "$LOGDIR" 2>/dev/null || true
    LOGFILE="$LOGDIR/$MINER_ID-$(date +%Y%m%d-%H%M%S).log"
fi
while true; do
    launch_start=$(date +%s)
    if [ -n "$LOGFILE" ]; then
        echo "=== $(date +%H:%M:%S) run $((RESTART_COUNT + 1))/$MAX_RESTART ($MINER_ID) ===" >> "$LOGFILE" 2>/dev/null || true
        # Report how the launch ended (a silent instant exit - missing DLLs,
        # corrupt binary - used to be a black box). SIGINT (130) is a normal
        # stop, not a crash.
        if "$BINARY_PATH" "${CMD_ARGS[@]}" >> "$LOGFILE" 2>&1; then
            rc=0
            echo "[*] Miner stopped (exit code 0)" >&2
        else
            rc=$?
            if [ "$rc" -eq 130 ]; then
                echo "[*] Miner stopped (interrupted)" >&2
                echo "Miner stopped (interrupted, code 130)" >> "$LOGFILE" 2>/dev/null || true
            else
                echo "[!] Miner exited with code $rc (log: $LOGFILE)" >&2
                echo "Miner exited with code $rc" >> "$LOGFILE" 2>/dev/null || true
                if [ "$rc" = "-1073741515" ] || [ "$rc" = "3221225781" ]; then
                    echo "  A required DLL is missing next to the miner (stale cache)." >&2
                    echo "  Fix: rm -rf \"$MINER_DIR\", then run deromine again (it re-downloads the DLLs)." >&2
                fi
            fi
        fi
    else
        # No log file: run in the foreground so output stays on the terminal.
        if "$BINARY_PATH" "${CMD_ARGS[@]}"; then
            rc=0
            echo "[*] Miner stopped (exit code 0)" >&2
        else
            rc=$?
            if [ "$rc" -eq 130 ]; then
                echo "[*] Miner stopped (interrupted)" >&2
            else
                echo "[!] Miner exited with code $rc" >&2
                if [ "$rc" = "-1073741515" ] || [ "$rc" = "3221225781" ]; then
                    echo "  A required DLL is missing next to the miner (stale cache)." >&2
                    echo "  Fix: rm -rf \"$MINER_DIR\", then run deromine again (it re-downloads the DLLs)." >&2
                fi
            fi
        fi
    fi
    launch_end=$(date +%s)
    mark_miner_launch_outcome "$BIN_DIR" "$MINER_ID" "$rc" "$((launch_end - launch_start))"
    # Foreground launches still propagate a nonzero exit to the caller.
    if [ -z "$LOGFILE" ] && [ "$rc" -ne 0 ]; then exit "$rc"; fi

    RESTART_COUNT=$((RESTART_COUNT + 1))
    if $AUTO_RESTART && [ $RESTART_COUNT -lt $MAX_RESTART ]; then
        echo "[*] Restarting in ${RESTART_DELAY}s (attempt $RESTART_COUNT/$MAX_RESTART)..."
        echo "Restarting in ${RESTART_DELAY}s (attempt $RESTART_COUNT/$MAX_RESTART)" >> "$LOGFILE" 2>/dev/null || true
        sleep "$RESTART_DELAY"
    else
        break
    fi
done
if $AUTO_RESTART; then
    echo "[*] Log: $LOGFILE"
fi
