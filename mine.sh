#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$PROJECT_DIR/lib"
BIN_DIR="$PROJECT_DIR/bin"
CONFIG_FILE="$PROJECT_DIR/config.json"
MINERS_FILE="$PROJECT_DIR/miners.json"

# ── Parse arguments ──
DAEMON_URL="http://dero.rabidmining.com:10100"
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
DEV_FEE_OVERRIDE=""

show_help() {
    cat <<'EOF'
Usage: deromine [options]

  --version              Show version and exit
  --announce             Print the release announcement
  --miner=<id>           Miner id, or "list" to show the catalog table
  --wallet=<addr>        DERO wallet address
  --daemon=<url>         Node/pool host:port (scheme optional)
  --threads=<n>          CPU threads
  --dev-fee=<pct>        Dev fee % for miners that support it (e.g. TNN)
  --auto-restart         Restart miner on crash
  --max-restart=<n>      Max restarts (default 5)
  --delay=<sec>          Restart delay in seconds (default 10)
  --dry-run              Resolve release and print command, do not launch
  --benchmark            Benchmark all supported miners
  --bench-time=<sec>     Benchmark seconds per miner (default 30)
  -h | --help | /?       Show this help

Examples:
  deromine
  deromine --miner=list
  deromine --miner=tnn --dev-fee=1
  deromine --miner=c --dry-run
EOF
}

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
        --bench-time=*) BENCH_TIME="${1#*=}"; shift ;;
        --dev-fee=*) DEV_FEE_OVERRIDE="${1#*=}"; shift ;;
        -h|--help|help|/\?) show_help; exit 0 ;;
        --version) echo "deromine 1.0.0"; exit 0 ;;
        --announce) cat <<'ANNOUNCE'

  deromine v1.0.0 — one launcher for every DERO miner, on any OS.

    ▪ Dirtybird C / Rust / Go / Zig + CUDA / Go-GPU
    ▪ Official DeroHE, DeroLuna, TNN, Astronv
    ▪ Auto-downloads releases from GitHub/GitLab — no compilation
    ▪ Interactive menu, CLI flags, benchmark mode, auto-restart
    ▪ Linux · macOS · Windows · Termux

  Install:
    curl -fsSL https://raw.githubusercontent.com/moralpriest/deromine/main/install.sh | bash

  Repo: https://github.com/moralpriest/deromine
  Open source. 0%-fee miners first, dev-fee miners clearly marked.

ANNOUNCE
        exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

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

# ── jq check ──
if ! command -v jq &>/dev/null; then
    echo "${C_ERR}[x] jq required. Install: apt install jq (or brew install jq)${C_RESET}"
    exit 1
fi

# ── Read catalog ──
read_catalog() {
    jq -c '.miners[]' "$MINERS_FILE" 2>/dev/null || { echo "${C_ERR}[x] Failed to parse $MINERS_FILE${C_RESET}"; exit 1; }
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

get_asset_pattern() {
    local miner_json="$1"
    # One pattern per OS/arch (first match wins). Multiple entries for the
    # same OS/arch would produce a multi-line pattern that can never match
    # a real release asset name.
    echo "$miner_json" | jq -r --arg os "$OS" --arg arch "$ARCH" '.assets[] | select(.os == $os and .arch == $arch) | .pattern' | head -1
}

# Binary name: per-asset override (exact OS/arch first, then any asset for
# this OS), falling back to the miner-level .binary field. Needed because
# some releases name the binary per arch (e.g. derohe's dero-miner-linux-arm64
# on aarch64 vs dero-miner-linux-amd64 on amd64).
get_binary_name() {
    local miner_json="$1" name
    name=$(echo "$miner_json" | jq -r --arg os "$OS" --arg arch "$ARCH" '
        first(.assets[] | select(.os == $os and .arch == $arch and ((.binary // "") != ""))).binary
        // first(.assets[] | select(.os == $os and ((.binary // "") != ""))).binary
        // .binary
        // ""')
    if [ "$OS" = "windows" ] && [ -n "$name" ] && [[ "$name" != *.exe ]]; then
        name="${name}.exe"
    fi
    echo "$name"
}

get_archive_binary_name() {
    local miner_json="$1" name
    # Mirrors Get-MinerArchiveBinaryName in catalog.ps1: per-asset
    # binary_archive, then per-asset binary, then the miner-level fields.
    # Order matters: derohe's top-level binary_archive is amd64-specific, so
    # the per-asset binary must win on aarch64.
    name=$(echo "$miner_json" | jq -r --arg os "$OS" --arg arch "$ARCH" '
        first(.assets[] | select(.os == $os and .arch == $arch and ((.binary_archive // "") != ""))).binary_archive
        // first(.assets[] | select(.os == $os and .arch == $arch and ((.binary // "") != ""))).binary
        // first(.assets[] | select(.os == $os and ((.binary_archive // "") != ""))).binary_archive
        // first(.assets[] | select(.os == $os and ((.binary // "") != ""))).binary
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
# A miner binary must be a complete, platform-valid executable. This catches
# truncated/interrupted extractions that used to be cached forever — a corrupt
# binary can still run far enough to print its usage screen instead of mining.
binary_integrity_ok() {
    local path="$1" size magic
    [ -f "$path" ] || return 1
    size=$(stat -c %s "$path" 2>/dev/null || stat -f %z "$path" 2>/dev/null || echo 0)
    [ "$size" -ge 200000 ] || return 1
    magic=$(head -c 4 "$path" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    case "$OS" in
        windows) [[ "$magic" == 4d5a* ]] || return 1 ;;                                        # MZ
        macos)   [[ "$magic" == cffaedfe* || "$magic" == cafebabe* || "$magic" == feedface* || "$magic" == feedfacf* ]] || return 1 ;;  # Mach-O
        *)       [[ "$magic" == 7f454c46* ]] || return 1 ;;                                    # \x7fELF
    esac
    return 0
}

# A cached binary is usable only if its recorded release tag matches the
# currently-resolved latest tag AND it passes the integrity check.
cached_binary_usable() {
    local path="$1" tag="$2" cached=""
    [ -f "$path" ] || return 1
    [ -f "$path.tag" ] || return 1
    cached=$(cat "$path.tag" 2>/dev/null)
    [ "$cached" = "$tag" ] || return 1
    binary_integrity_ok "$path"
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
#   .fails — fast nonzero exits (within 10s); ONE confirmed failure hides it.
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
    [ "$count" -ge 1 ]
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
        ! miner_fails_on_host "$bindir" "$id"
    fi
}

# Download, extract, lift (rename to the canonical cache name), verify, and
# record the release tag next to the binary so later runs can detect a stale
# cache. Relies on the resolve_* globals: MINER_DIR, BINARY_PATH, ARCHIVE_NAME,
# ARCHIVE_BINARY, DOWNLOAD_URL, TAG.
fetch_binary() {
    local archive_path="$MINER_DIR/$ARCHIVE_NAME" found=""
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
    if ! binary_integrity_ok "$BINARY_PATH"; then
        echo "${C_ERR}[x] Extracted binary '$BINARY_PATH' failed integrity check${C_RESET}" >&2
        if [ "$OS" = "windows" ] && [ ! -f "$BINARY_PATH" ]; then
            echo "${C_DIM}  Usually Windows Defender quarantining the miner (a false positive for${C_RESET}" >&2
            echo "${C_DIM}  closed-source miners). Restore it in Windows Security > Protection${C_RESET}" >&2
            echo "${C_DIM}  history, or add an exclusion for '$MINER_DIR', then re-run.${C_RESET}" >&2
        else
            echo "${C_DIM}  Incomplete/corrupt download. Remove '$MINER_DIR' and retry.${C_RESET}" >&2
        fi
        rm -f "$BINARY_PATH" "$BINARY_PATH.tag"
        return 1
    fi
    # Record the release tag so future runs can detect a stale cache.
    printf '%s\n' "$TAG" > "$BINARY_PATH.tag"
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

draw_banner() {
    local width="${COLUMNS:-80}"
    local title="deromine"
    local inner=$((width > 12 ? width - 4 : 12))
    local top bot
    top="${TL}$(rep "$H" "$inner")${TR}"
    bot="${BL}$(rep "$H" "$inner")${BR}"
    echo "${C_BANNER}$top${C_RESET}"
    echo "${C_BANNER}${V}  ${C_NAME}${title}${C_RESET}${C_BANNER}$(rep ' ' "$((inner - 2 - ${#title}))")${V}${C_RESET}"
    echo "${C_BANNER}$bot${C_RESET}"
    echo ""
}

gitlab_id() {
    printf '%s' "$REPO" | jq -sRr @uri
}

resolve_github() {
    API_URL="https://api.github.com/repos/$REPO/releases/latest"
    API_RESP=$(curl -sf "$API_URL") || { echo "${C_ERR}[x] GitHub API failed${C_RESET}"; exit 1; }
    TAG=$(echo "$API_RESP" | jq -r '.tag_name')
    ARCHIVE_NAME=$(echo "$API_RESP" | jq -r --arg p "$ASSET_PATTERN" '.assets[].name | select(. | test($p | gsub("\\*";".*")))')
    DOWNLOAD_URL=$(echo "$API_RESP" | jq -r --arg n "$ARCHIVE_NAME" '.assets[] | select(.name == $n) | .browser_download_url')
}

resolve_gitlab_release() {
    local id api resp name path
    id=$(gitlab_id)
    api="https://gitlab.com/api/v4/projects/$id/releases/permalink/latest"
    resp=$(curl -sfL "$api") || { echo "${C_ERR}[x] GitLab API failed${C_RESET}"; exit 1; }
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
    resp=$(curl -sfL "$api?path=$RELEASE_PATH&ref=$BRANCH&per_page=100") || { echo "${C_ERR}[x] GitLab API failed (branch tree)${C_RESET}"; exit 1; }
    dirs=$(echo "$resp" | jq -r '.[] | select(.type == "tree" and (.name | test("^v?[0-9.]+$"))) | .name')
    [ -z "$dirs" ] && { echo "${C_ERR}[x] No version dirs under $RELEASE_PATH in $REPO${C_RESET}"; exit 1; }
    version=$(echo "$dirs" | awk '{ v=$0; sub(/^v/,"",v); n=split(v,a,"."); for(i=1;i<=3;i++){ a[i]=(a[i]+0)*1 }; score=a[1]*1000000+a[2]*1000+a[3]; print score, $0 }' | sort -n | tail -1 | cut -d' ' -f2-)
    TAG="$version"
    resp=$(curl -sfL "$api?path=$RELEASE_PATH/$version&ref=$BRANCH&per_page=100") || { echo "${C_ERR}[x] GitLab API failed (file list)${C_RESET}"; exit 1; }
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

# ── Collect catalog into arrays ──
MINER_JSONS=()
while IFS= read -r m; do
    [ -n "$m" ] && MINER_JSONS+=("$m")
done < <(read_catalog)
[ "${#MINER_JSONS[@]}" -eq 0 ] && { echo "${C_ERR}[x] No miners in catalog${C_RESET}"; exit 1; }

SUPPORTED=()
for m in "${MINER_JSONS[@]}"; do
    pattern=$(get_asset_pattern "$m")
    [ -z "$pattern" ] && continue
    if ! miner_hardware_ok "$m"; then continue; fi
    # Hide miners that can't actually run on this host: self-test-gated GPU
    # miners (go-gpu) are listed only once a launch proved they work here;
    # other miners are hidden after one confirmed startup failure.
    if ! miner_listable_on_host "$BIN_DIR" "$m"; then continue; fi
    SUPPORTED+=("$m")
done

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
    [ -z "$WALLET_ADDR" ] && WALLET_ADDR="deroi1qyqztaxp2cqdhtve0k0v4dv0cmkpvhs8xukkwhgr5eep9u8urxzqqqdpvf892qgwq7h23"
    LIVE_DAEMON="${DAEMON_URL#http://}"
    LIVE_DAEMON="${LIVE_DAEMON#https://}"

    if [ "${#SUPPORTED[@]}" -eq 0 ]; then
        echo "${C_ERR}[x] No miners available to benchmark on this host${C_RESET}"
        exit 1
    fi

    draw_banner
    echo "${C_HDR}Benchmarking ${#SUPPORTED[@]} miners (~${BENCH_TIME}s each, ${THREAD_COUNT} threads)...${C_RESET}"

    bench_miner() {
        local m="$1" id name fee repo host branch rpath pattern bname abin out raw
        id=$(echo "$m" | jq -r '.id')
        name=$(echo "$m" | jq -r '.name // .id')
        fee=$(echo "$m" | jq -r '.fee // "0%"')
        if [ "$(echo "$m" | jq -r 'if (.benchmark == false) then "false" else "true" end')" = "false" ]; then
            echo "  ${C_DIM}[skip] $name: benchmark disabled in catalog${C_RESET}"
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
        # Resolve always (needed for the version-aware cache check).
        REPO="$repo"; HOST="$host"; BRANCH="$branch"; RELEASE_PATH="$rpath"; ASSET_PATTERN="$pattern"
        case "$HOST" in
            gitlab-release) resolve_gitlab_release ;;
            gitlab-branch)  resolve_gitlab_branch ;;
            *)              resolve_github ;;
        esac
        if [ -z "$ARCHIVE_NAME" ] || [ -z "$DOWNLOAD_URL" ]; then
            echo "  ${C_ERR}[x] $name: no matching asset${C_RESET}"; return
        fi
        if [ ! -f "$BINARY_PATH" ]; then
            echo "  ${C_DIM}[fetch] $name ($TAG)${C_RESET}"
            ARCHIVE_BINARY="$abin"
            if ! fetch_binary; then echo "  ${C_ERR}[x] $name: fetch failed${C_RESET}"; return; fi
        elif ! cached_binary_usable "$BINARY_PATH" "$TAG"; then
            echo "  ${C_DIM}[re-fetch] $name: cached binary stale or corrupt${C_RESET}"
            rm -f "$BINARY_PATH" "$BINARY_PATH.tag"
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
    echo "${C_HDR}Available miners on $OS/$ARCH:${C_RESET}"
    draw_miner_table "${SUPPORTED[@]:-}"
    exit 0
fi

# ── Interactive menu ──
if [ -z "$MINER_ID" ] || [ "$MINER_ID" = "interactive" ]; then
    draw_banner
    echo "${C_HDR}Select a miner:${C_RESET}" >&2
    draw_miner_table "${SUPPORTED[@]:-}" >&2
    if [ "${#SUPPORTED[@]}" -eq 0 ]; then
        echo "${C_ERR}[x] No miners available on this host${C_RESET}" >&2
        exit 1
    fi
    printf "Choice (1-%d): " "${#SUPPORTED[@]}" >&2
    read -r choice
    choice=$((choice - 1))
    MINER_JSON="${SUPPORTED[$choice]:-}"
    MINER_ID=$(echo "$MINER_JSON" | jq -r '.id')
else
    MINER_JSON=$(get_miner_by_id "$MINER_ID")
fi

if [ -z "$MINER_JSON" ]; then
    echo "${C_ERR}[x] Miner '$MINER_ID' not found or unavailable${C_RESET}"
    exit 1
fi
if ! miner_hardware_ok "$MINER_JSON"; then
    echo "${C_ERR}[x] Miner '$MINER_ID' is not supported on this host${C_RESET}"
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
DEFAULT_WALLET=""
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
        printf "%s Your DERO wallet address (dero1... or deto1...): " "$ARROW" >&2
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
        DAEMON_JSONS=()
        while IFS= read -r d; do
            [ -n "$d" ] && DAEMON_JSONS+=("$d")
        done < <(jq -c '.daemons[]' "$MINERS_FILE")
        echo "" >&2
        echo "${C_HDR}Select daemon endpoint:${C_RESET}" >&2
        draw_daemon_table "${DAEMON_JSONS[@]:-}" >&2
        printf "Choice (1-%d): " "${#DAEMON_JSONS[@]}" >&2
        read -r dchoice
        dsel="${DAEMON_JSONS[$((dchoice - 1))]:-}"
        [ -z "$dsel" ] && { echo "${C_ERR}[x] Invalid choice${C_RESET}" >&2; exit 1; }
        DAEMON_URL=$(echo "$dsel" | jq -r '.url')
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

# Save config
jq -n \
    --arg w "$WALLET_ADDR" \
    --arg d "$DAEMON_URL" \
    --argjson t "$THREAD_COUNT" \
    '{wallet_address: $w, daemon_url: $d, thread_count: $t}' > "$CONFIG_FILE"
echo "${C_OK}[*] Config saved to $CONFIG_FILE${C_RESET}" >&2

# ── Resolve download ──
REPO=$(echo "$MINER_JSON" | jq -r '.repo')
HOST=$(echo "$MINER_JSON" | jq -r '.host // "github"')
BRANCH=$(echo "$MINER_JSON" | jq -r '.branch // "main"')
RELEASE_PATH=$(echo "$MINER_JSON" | jq -r '.release_path // "releases"')
echo "" >&2
echo "${C_HDR}Resolving latest release for $REPO...${C_RESET}" >&2

case "$HOST" in
    gitlab-release) resolve_gitlab_release ;;
    gitlab-branch)  resolve_gitlab_branch ;;
    *)              resolve_github ;;
esac

if [ -z "$ARCHIVE_NAME" ] || [ -z "$DOWNLOAD_URL" ]; then
    echo "${C_ERR}[x] No matching asset for pattern: $ASSET_PATTERN${C_RESET}" >&2
    if [ -n "${API_RESP:-}" ] && [ "$HOST" != "gitlab-release" ] && [ "$HOST" != "gitlab-branch" ]; then
        echo "  ${C_DIM}Available assets in the latest release:${C_RESET}" >&2
        echo "$API_RESP" | jq -r '.assets[].name' | sed 's/^/    /' >&2
    fi
    exit 1
fi
echo "  ${C_DIM}Tag:   $TAG${C_RESET}" >&2
echo "  ${C_DIM}Asset: $ARCHIVE_NAME${C_RESET}" >&2

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
MINER_DIR="$BIN_DIR/$MINER_ID"
mkdir -p "$MINER_DIR"
BINARY_PATH="$MINER_DIR/$BINARY_NAME"

if [ ! -f "$BINARY_PATH" ]; then
    fetch_binary || exit 1
elif ! cached_binary_usable "$BINARY_PATH" "$TAG"; then
    echo "${C_ERR}[x] Cached binary is stale or corrupt; re-downloading${C_RESET}" >&2
    rm -f "$BINARY_PATH" "$BINARY_PATH.tag"
    fetch_binary || exit 1
else
    echo "${C_OK}[*] Using cached binary: $BINARY_PATH ($TAG)${C_RESET}" >&2
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo "${C_ERR}[x] Binary '$BINARY_NAME' not found after extraction${C_RESET}" >&2
    find "$MINER_DIR" -type f >&2
    exit 1
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
    local pad=$((LW - ${#label} - 2))
    printf '%b' "${C_OK}${V}${C_RESET}  ${C_NAME}$label${C_RESET}  ${C_BIN}$(printf '%-*s' "$pad" "$value")${C_RESET}${C_OK}${V}${C_RESET}\n"
}
echo ""
echo "${C_OK}${TL}$(rep "$H" "$LW")${TR}${C_RESET}"
summary_line "Miner" "$MINER_NAME"
summary_line "Binary" "$BINARY_PATH"
summary_line "Daemon" "$DAEMON_ADDR"
summary_line "Wallet" "$WALLET_ADDR"
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
