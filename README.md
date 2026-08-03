# deromine

All-encompassing DERO miners launcher for any OS/CPU/GPU. Downloads, extracts, and runs
community DERO miners (Dirtybird C/Rust/Go/Zig/CUDA/Go-GPU, official DeroHE, DeroLuna,
TNN, Astronv) straight from their official GitHub/GitLab releases — no manual compilation
required.

## Install with AI

Want your AI assistant to handle the install? Copy this prompt into Claude Code,
ChatGPT, Copilot, Gemini, or any coding assistant — it will detect your OS,
install prerequisites, run the official installer, and verify everything works:

````markdown
Install deromine (a DERO miners launcher) on this machine for me.

1. Detect the OS first (`uname -s` on Linux/macOS/Termux; `$env:OS` on Windows).
2. Run the unified PowerShell installer — the same script on every OS:
   - Windows (PowerShell 5.1 or 7, built in):
     `irm https://raw.githubusercontent.com/moralpriest/deromine/main/install.ps1 | iex`
   - Linux/macOS/Termux (PowerShell 7 required):
     `pwsh -c "irm https://raw.githubusercontent.com/moralpriest/deromine/main/install.ps1 | iex"`
3. If `pwsh` is missing on Unix, either install PowerShell 7 for their OS
   (brew/apt/dnf/pacman — winget on Windows) and re-run, or fall back to the
   bash installer:
   `curl -fsSL https://raw.githubusercontent.com/moralpriest/deromine/main/install.sh | bash`
4. Verify the install by running `deromine --miner=list` and confirm the miner
   catalog table prints. If `deromine` is not found, open a new shell first
   (the installer updates PATH); if it still fails, check
   `~/.local/share/deromine` (Linux/macOS) or
   `%USERPROFILE%\.local\share\deromine` (Windows) exists.
5. Only install and verify — do NOT configure a wallet, start mining, or run any
   miner binary without asking the user first. Miners are third-party binaries
   with dev fees, so never download anything except from the official repo
   https://github.com/moralpriest/deromine
6. Report what you did, the install location, and how to run it.
````

Short version, if you just want the essentials:

```
Install deromine from https://github.com/moralpriest/deromine using its official
installer for this OS, verify it with `deromine --miner=list`, and don't start
mining or configure a wallet without asking me.
```

## Installation

### One-liner (all OSes)

One installer script (`install.ps1`) works on every OS. Windows runs it with
its built-in PowerShell (5.1 or 7); Unix needs PowerShell 7 (`pwsh`):

Windows — from PowerShell (built in):

```powershell
irm https://raw.githubusercontent.com/moralpriest/deromine/main/install.ps1 | iex
```

...or from cmd:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/moralpriest/deromine/main/install.ps1 | iex"
```

Linux / macOS / Termux — from any shell (PowerShell 7 required):

```bash
pwsh -c "irm https://raw.githubusercontent.com/moralpriest/deromine/main/install.ps1 | iex"
```

On macOS, the PowerShell executable is spelled **`pwsh`** (p-w-s-h), not
`pswh` or `pssh`. With Homebrew already installed:

```bash
brew install --cask powershell
pwsh --version
```

If Homebrew is not installed, install it from https://brew.sh first.

Installs to `~/.local/share/deromine` (`%USERPROFILE%\.local\share\deromine` on
Windows) and puts the launcher on PATH — `~/.local/bin/deromine`
(`%USERPROFILE%\.local\bin\deromine.cmd` on Windows, `$PREFIX/bin/deromine` on
Termux). PATH is updated in the user registry on Windows or your shell profile
(bash/zsh/fish) on Unix — open a new terminal afterwards. Re-run to update.
Git is used when available; otherwise the source zip is downloaded, so git is
not required. Set `DEROMINE_SKIP_PWSH=1` when you explicitly want to keep the
bash-only fallback.

### One-liner without PowerShell (Linux/macOS/Termux)

If `pwsh` isn't installed, the bash installer offers to install PowerShell 7
using the native package manager (Ubuntu/Debian, Fedora/RHEL, macOS Homebrew,
or Termux `pkg`) before continuing. In `curl ... | bash` mode it reads the
confirmation from `/dev/tty`, so the prompt still works when stdin is the script
pipe. On Windows, `install.ps1` offers the same
choice through `winget`. Set `DEROMINE_AUTO_INSTALL_PWSH=1` to approve an
unattended install, or `DEROMINE_SKIP_PWSH=1` to skip it. Without a TTY or
explicit approval, the installer only prints the official manual install guide.

If you prefer not to install PowerShell 7, the bash installer covers the same
ground with fewer dependencies:

```bash
curl -fsSL https://raw.githubusercontent.com/moralpriest/deromine/main/install.sh | bash
```

Installs to `~/.local/share/deromine` and puts `deromine` on PATH via
`~/.local/bin/deromine`. On Termux (Android) it also links into `$PREFIX/bin`,
the one directory always on PATH there, so it works in any Termux shell.
Re-run to update. If `~/.local/bin` isn't on your PATH, the installer adds it
automatically to your shell profile (bash/zsh/fish) — open a new terminal
afterwards. Manual fallback: `export PATH="$HOME/.local/bin:$PATH"`.

### Manual (any OS)

```bash
git clone https://github.com/moralpriest/deromine.git
cd deromine
./deromine --miner=list        # first run (no install needed)
ln -s "$PWD/deromine" ~/.local/bin/deromine   # optional: put it on PATH
```

Requirements:

- **PowerShell 7+ (`pwsh`)** for the full interactive menu and all CLI modes. The
  installers attempt to add it automatically when missing; Windows uses `winget`,
  while Unix uses the native package manager where supported.

- Without `pwsh`, the `deromine` wrapper falls back to `mine.sh`
  (needs `bash`, `jq`, `curl`, `tar`/`unzip`) — fine for Termux and minimal
  systems. On macOS/BSD, benchmarking runs without GNU `timeout` (no cap).
- Windows: run `deromine.cmd` from cmd or PowerShell; `pwsh ./mine.ps1` works
  from any shell.

### Why PowerShell?

The primary runner is PowerShell 7, with `mine.sh` as a fallback. PowerShell
was chosen for the main implementation because it is:

- **Genuinely cross-platform** — runs on Windows, macOS, and Linux (and in
  Termux on Android via pwsh builds), so one codebase covers every OS the
  miners target. The `$IsLinux` / `$IsWindows` / `$IsMacOS` auto-variables
  make platform detection trivial.
- **Built-in JSON handling** — `ConvertFrom-Json` / `ConvertTo-Json` parse the
  GitHub/GitLab release APIs and the catalog with zero external dependencies.
  The bash fallback needs `jq`.
- **Rich interactive UI** — colored tables, banners, and prompts with ANSI
  escape codes come for free, giving the menu a native feel on any terminal.
- **Native process control** — `Start-Process`, exit-code checks, and error
  trapping make the auto-restart loop straightforward.
- **First-class on Windows** — Windows is a major DERO mining platform, and
  PowerShell is the one shell guaranteed to be there. `deromine.cmd` is a thin
  wrapper that picks `pwsh` or Windows PowerShell 5.1 automatically.

The bash fallback exists so Termux and minimal Linux systems without `pwsh`
still get a working (if simpler) launcher. Both paths share the same
`miners.json` catalog and CLI surface.

## Usage

### Quick start (recommended)

```bash
deromine                  # interactive menu (from anywhere)
deromine --miner=list     # show catalog table
deromine --miner=c        # start a specific miner
deromine --miner=tnn --dev-fee=1
deromine --help           # show usage (also -h, /?, help)
```

The `deromine` launcher (symlinked into `~/.local/bin`) auto-detects the best
runner: PowerShell if available, otherwise the bash script (Termux / minimal
systems). On Windows, use `deromine.cmd` from cmd or PowerShell. All flags pass
through. (Named `deromine` rather than `mine` to avoid colliding with the BSD
games minesweeper binary `/usr/games/mine`.)

### Interactive (PowerShell)

```powershell
pwsh ./mine.ps1
```

Select a miner from the menu, configure wallet/daemon/threads, and start mining.
At the daemon prompt you can pick a listed node, type `c` to enter your own
node or pool (e.g. `my.node` or `my.node:10100`; the port defaults to 10100),
or `q` to quit.

### CLI Parameters (PowerShell)

| Flag | Description |
|------|-------------|
| `--miner=<id>` | Miner id, or `list` to show the catalog table |
| `--wallet=...` / `--wallet-address=...` | DERO wallet address |
| `--daemon-url=...` / `--daemon=...` | Node/pool `host:port` (scheme optional) |
| `--threads=...` / `--thread-count=...` | CPU threads |
| `--dev-fee=...` | Developer fee % (only used by miners that support it, e.g. TNN) |
| `--auto-restart` | Restart miner on crash |
| `--max-restart=...` | Max restarts (default 5) |
| `--delay=...` | Restart delay in seconds (default 10) |
| `--dry-run` | Resolve release + print command without launching |
| `--reconfigure` | Re-run setup: ask for wallet, node, threads again (old config kept in `config.bak`) |
| `--benchmark` | Benchmark all supported miners |
| `--bench-time=...` | Benchmark seconds per miner (default 30) |
| `--output-dir=...` | Where binaries are stored (default `bin/`) |
| `--add-exclusion` | Add a Windows Defender folder exclusion for `bin/` (Windows, UAC prompt) |
| `--config=...` | Path to config file (default `config.json`) |
| `-h` / `--help` / `/?` | Show usage and exit |

```powershell
pwsh ./mine.ps1 --miner=c --wallet=deroi1... --daemon-url=http://node.derofoundation.org:10100 --threads=4
pwsh ./mine.ps1 --miner=list
pwsh ./mine.ps1 --dry-run
pwsh ./mine.ps1 --miner=tnn --dev-fee=1
```

### CLI Parameters (bash / Termux)

| Flag | Description |
|------|-------------|
| `--miner=<id>` | Miner id, or `list` |
| `--wallet=...` | DERO wallet address |
| `--daemon=...` | Node/pool `host:port` (scheme optional) |
| `--threads=...` | CPU threads |
| `--dev-fee=...` | Developer fee % (only used by miners that support it, e.g. TNN) |
| `--auto-restart` / `--max-restart=...` / `--delay=...` | Auto-restart controls |
| `--dry-run` | Resolve release + print command without launching |
| `--reconfigure` | Re-run setup: ask for wallet, node, threads again (old config kept in `config.bak`) |
| `--benchmark` / `--bench-time=...` | Benchmark mode |
| `--output-dir=...` | Where binaries are stored (default `bin/`) |
| `--config=...` | Config path (default `config.json`) |
| `-h` / `--help` / `/?` | Show usage and exit |

```bash
bash ./mine.sh --miner=c --wallet=deroi1...
bash ./mine.sh --miner=list
bash ./mine.sh --miner=tnn --dev-fee=1
```

### Dev fee

`--dev-fee` sets the developer fee for miners that support it (TNN). It overrides
the `dev_fee` value in `config.json`, which in turn overrides the catalog default.
TNN's own default is 2.5%, minimum 1%. Miners with a fixed fee (DeroLuna 10%,
Astronv 4.9%) ignore this flag.

## Project Structure

```
deromine/
├── deromine                      # Unified launcher (bash wrapper, auto-detect)
├── deromine.cmd                  # Unified launcher for Windows cmd
├── install.sh                    # One-line installer (curl | bash, Linux/macOS/Termux)
├── install.ps1                   # Unified one-line installer (PowerShell, all OSes)
├── mine.ps1                      # Main PowerShell launcher
├── mine.sh                       # Bash/Termux launcher
├── miners.json                   # Catalog of available miners and release assets
├── config.json                   # User config (wallet, daemon, threads, dev fee)
├── config.example.json           # Example config template
├── bin/                          # Downloaded miner binaries live here
├── lib/
│   ├── catalog.ps1               # Miner catalog, binary resolution, asset matching
│   ├── platform.ps1              # OS/arch detection, hardware requirements
│   ├── download.ps1              # GitHub/GitLab release download and extraction
│   ├── config.ps1                # Config read/write, wallet prompts
│   ├── run.ps1                   # Start miner and auto-restart loop
│   ├── benchmark.ps1             # Benchmark runner and hashrate parsing
│   └── ui.ps1                    # Table/banner rendering
├── scripts/
│   ├── smoke-test.ps1            # Non-interactive verification script (PowerShell)
│   └── smoke-test.sh             # Non-interactive verification script (bash)
└── README.md                     # This file
```

## Supported Miners

| ID | Miner | Binary Name | Type | Fee | Risk | Notes |
|----|-------|-------------|------|-----|------|-------|
| c | Dirtybird C++ | dirtybird-c-miner | cpu | 0% | Open source | Best compatibility |
| rust | Dirtybird Rust | dirtybird-dero-miner | cpu | 0% | Open source | Fastest CPU miner |
| go | Dirtybird Go | dirtybird-go-miner | cpu | 0% | Open source | Moderate CPU usage |
| zig | Dirtybird Zig | dirtybird-zig-miner | cpu | 0% | Open source | Small binary; not on Termux/Android |
| cuda | Dirtybird CUDA | dirtybird-openastronv_v3 | gpu | 0% | Open source | NVIDIA GPU required |
| go-gpu | Dirtybird Go GPU | dirtybird-go-gpu-miner | gpu | 0% | Open source | Any Vulkan GPU |
| derohe | DERO HE Default Miner | dero-miner-linux-amd64 | cpu | 0% | Official | Official default miner; not on Termux/Android |
| deroluna | DeroLuna | deroluna-miner | cpu | 10% | Closed source | GitLab releases |
| tnn | TNN | tnn-miner | both | 2.5% | Closed DLLs | CPU+GPU, dev fee configurable via `--dev-fee` |
| astronv | Astronv | astronv | gpu | 4.9% | Closed source | NVIDIA GPU, Linux only |

Ordering is intentional: open-source 0%-fee miners first, then the official DeroHE
miner, then closed-source / dev-fee miners at the bottom. Miners whose hardware
requirements are not met (e.g. GPU miners without the right GPU) are hidden from
the list on that host, as are miners marked `unsupported` for the platform — for
example `derohe` and `zig` on Termux/Android, whose arm64 releases are broken
there (derohe fails its own ELF self-check; zig's build dumps its usage screen
instead of mining even with correct arguments). On Termux, use the Dirtybird
`c`, `rust`, or `go` miners, which ship working Android arm64 builds.

### List columns

- **Status** — `READY` (green) when the binary is already in `bin/<id>/`, `FETCH`
  (yellow) when it will be downloaded on first use.
- **Risk** — color-coded: `Open source` (green), `Official` (green), `Closed DLLs`
  (yellow, ships closed prebuilt libraries), `Closed source` (red).
- **Fee** — color-coded: 0% (green), up to 2.5% (yellow), above 2.5% (red).

## Configuration

### config.json

```json
{
  "wallet_address": "deroi1...",
  "daemon_url": "http://node.derofoundation.org:10100",
  "thread_count": 4
}
```

- Dev fees are set per-miner in the catalog (e.g. TNN's default 2.5%). Override
  only when needed via the `--dev-fee` CLI flag. It is intentionally **not** in
  `config.json` by default, to avoid implying every miner charges a fee.
  Precedence: `--dev-fee` CLI flag > catalog default.
- Config is stored in `config.json` at the project root. Run interactively to
  create it, or copy `config.example.json`.

## Auto-restart logs

When `--auto-restart` is enabled, each miner run is captured to a per-launch log
under `bin/logs/<miner-id>-<timestamp>.log` (PowerShell and bash). So if a miner
crashes and restarts, you can see *why* instead of a black box. The final log
path is printed when the loop exits.

## Benchmark history

`--benchmark` saves each miner's effective hashrate to `bin/.benchmarks.json`.
The next run shows a **Δ vs last** column — a signed diff against your previous
benchmark (e.g. `+660.0` or `-120.5`, with `—` for miners that are new). This
makes it easy to spot hashrate regressions after an upgrade or a hardware
change, without keeping manual notes. Results are compared by miner id.

## How It Works

1. **Catalog (`miners.json`)** defines each miner: release repo (GitHub or GitLab),
   per-OS/arch asset patterns, CLI flag map, dev fee, hardware requirements, risk
   rating, and the list of known daemon endpoints.
2. **Startup validation** checks `miners.json` and the selected config file before
   entering list, benchmark, or mining modes. Malformed JSON or missing required
   fields fails with a short actionable message instead of a property-access stack
   trace. The Bash and PowerShell paths enforce the same required catalog fields.
3. **Platform detection** uses PowerShell auto-vars (`$IsLinux`, `$IsWindows`,
   `$IsMacOS`) or `uname` to determine OS/architecture.
4. **Binary resolution** prefers a per-asset binary override (for OS-specific
   names), then the miner's `binary` property, then a legacy fallback map for the
   Dirtybird ids. `.exe` is appended on Windows.
5. **Asset matching** filters `assets[]` by `os`, `arch`, and `pattern` glob.
6. **Download** queries the GitHub/GitLab latest-release API at runtime, matches
   the asset by pattern, extracts it, and places the binary in `bin/<miner-id>/`.
   Nested binaries are lifted to the top-level folder together with their
   dependencies (Windows releases ship DLLs next to the exe, e.g.
   `libstdc++-6.dll`). The cache is
   **version-aware**: the release tag is recorded next to each binary
   (`<binary>.tag`), and each binary is integrity-checked (valid
   ELF/Mach-O/PE magic, non-trivial size) before use. A stale or corrupt cached
   binary is silently re-downloaded — so a new upstream release or an
   interrupted download can never leave a broken miner in place.
7. **Command building** uses the miner's `flags` map from the catalog (daemon,
   wallet, threads, coin, port, dev fee), defaulting to the Dirtybird short-flag
   convention (`-d`, `-w`, `-t`). Any `http(s)://` scheme is stripped from the
   daemon address.
8. **Mining** launches the binary in the foreground with the built arguments.
   `--auto-restart` wraps it in a restart loop (max restarts, delay). Launch
   outcomes are remembered per miner in `bin/<id>/`: `.fails` records fast
   startup failures (nonzero exit within ~10s — missing DLLs, incompatible
   build), and `.ok` records a launch that **proved** the miner runs on this
   host (exit 0, a run that got past startup, or Ctrl+C). Under
   `--auto-restart` the elapsed time is measured **per run**, never across the
   whole session — restart delays don't count toward "got past startup", so a
   miner that fails its startup gate in seconds stays hidden even after a loop
   full of restarts. A confirmed failure
   hides a normal miner until it succeeds again; self-test-gated GPU miners
   (go-gpu) are listed only once `.ok` exists. `--miner=<id>` still force-runs
   a hidden miner.
9. **Benchmark mode** runs each supported miner for a fixed window, parses the
   reported hashrate, and prints a comparison table.

## Testing

Run the non-interactive smoke tests before opening a PR (they need no network
and never launch a miner):

```bash
pwsh ./scripts/smoke-test.ps1     # PowerShell path: catalog, modules, resolution
bash ./scripts/smoke-test.sh      # bash path: catalog, version, list mode
```

Both suites fail with exit code 1 on any regression. They cover the shared
catalog/config schema boundary, custom daemon normalization, `--reconfigure` wiring,
Defender helpers, cache integrity, launch outcomes, and the platform-specific
benchmark/help surfaces.

## Troubleshooting

- **"[x] No asset for c on linux/amd64"**: The GitHub release doesn't have an
  asset matching `dirtybird-miner-amd64-*.tar.gz`. Check the release page for the
  correct asset naming.
- **Binary not found after extraction**: The extracted archive may have a nested
  directory. The script attempts to lift nested binaries to the top-level
  `bin/<miner-id>/` folder.
- **Binary not found after extraction (per-arch names, e.g. derohe on
  Termux/Android)**: some releases name the binary per architecture — derohe
  ships `dero-miner-linux-arm64` on aarch64 but `dero-miner-linux-amd64` on
  amd64 (and `dero-miner-windows-amd64.exe` on Windows). These are handled
  automatically via per-asset `binary` overrides in `miners.json`; re-run
  `deromine` after updating.
- **Permission denied on Linux/macOS**: The script runs `chmod +x` automatically.
  If it fails, run `chmod +x bin/c/dirtybird-c-miner` manually.
- **GPU miner missing from list**: GPU miners are filtered by hardware detection
  (`nvidia-smi` for NVIDIA, `vulkaninfo` for Vulkan). Install the vendor runtime
  and try again. NVIDIA miners (cuda, astronv) also enumerate the actual
  adapters on Windows (`Win32_VideoController`), so they are hidden when no
  NVIDIA GPU is present. Vulkan miners (go-gpu) do **not** require an NVIDIA
  card — any Intel/AMD integrated GPU with a working Vulkan driver qualifies.
  On Windows, deromine does a **functional** probe: it asks the actual Vulkan
  loader (`vulkan-1.dll`) to create an instance and enumerate physical devices
  (via PowerShell on both the PS and bash paths), so go-gpu is hidden on
  machines with no usable Vulkan runtime — WARP-only renderers, older iGPU
  drivers, VMs. Some drivers are registered AND enumerate a device yet still
  miscompute under the real mining workload (the Intel Iris Xe case, where the
  miner falls back to DX12 and its own startup self-test refuses). No static
  probe can see that — only a real launch can. So go-gpu is **only listed once
  a launch has actually succeeded on this host** (deromine remembers it in
  `bin/go-gpu/.ok`). On a machine where it can never run, it never appears at
  all; `deromine --miner=go-gpu` still force-runs it if you want to try after
  updating your driver.
- **A miner disappears from the list after failing to start**: non-gated
  miners are hidden after they exit nonzero within ~10s of launch once on this
  host (the classic "listed but broken on this hardware" case — missing DLLs,
  an incompatible build). Self-test-gated GPU miners (go-gpu) are listed only
  once they have proven a successful launch here. Force-run a hidden miner
  anyway with `deromine --miner=<id>`; it reappears automatically once a
  launch actually succeeds. To reset manually, delete `bin/<id>/.fails` (or
  `bin/<id>/.ok` for gated miners).
- **Astronv fails to start**: it needs NVIDIA drivers (`libnvidia-ml.so.1`) and is
  Linux amd64 only.
- **derohe is missing from the list on Termux/Android**: derohe's arm64 release
  fails its own ELF self-check (`unexpected e_type: 2`) on Android/Termux, so it
  is marked `unsupported` there and hidden. Use the Dirtybird miners instead:
  `deromine --miner=rust` (or `c`/`go`) — they ship working Android arm64
  builds.
- **zig prints its usage screen instead of mining on Termux/Android**: the
  official Dirtybird Zig miner arm64 build (v0.3.0) rejects its own arguments on
  Android — it prints `Usage: zig-miner ...` and exits with exit code 1 even
  with correct `-d/-w/-t` flags, while the same binary mines fine on Linux and
  the Rust miner works on the same device. It is therefore marked `unsupported`
  on Termux and hidden. Use `deromine --miner=rust` (or `go`/`c`) on Android.
- **A miner prints its usage/help screen instead of mining** (e.g. the zig
  miner dumping `Usage: zig-miner ...` right after the `[*] Command:` line):
  this can happen when the cached binary in `bin/<miner-id>/` is stale or
  truncated from an interrupted download — a corrupt binary can still run far
  enough to print usage. deromine's cache is version-aware and
  integrity-checked, so it now detects and re-downloads such binaries
  automatically. To force a fresh download manually, remove the miner's cache
  and re-run: `rm -rf bin/<miner-id>` (e.g. `rm -rf bin/zig`), then
  `deromine --miner=zig`.
- **Windows Defender blocks/quarantines a miner right after download**
  (e.g. deroluna reports `failed integrity check` immediately after
  `Extracting...`): Windows Defender frequently false-positives closed-source
  miners (unsigned, CPU-heavy hashing). It can quarantine the freshly-extracted
  exe (file missing), truncate it during extraction, or briefly lock it while
  scanning — deromine retries the integrity check to ride out scan locks, and
  the error message shows what was actually found on disk (size + magic bytes).
  Fix: add an exclusion so it doesn't recur — **Windows Security → Virus &
  threat protection → Manage settings → Exclusions → Add a folder** →
  `%USERPROFILE%\.local\share\deromine\bin` — and restore the detection in
  **Protection history** if listed. Then run deromine again — it re-downloads
  the miner. deromine can do this for you: when the integrity check fails on
  Windows it offers to add the exclusion (one UAC prompt, requires admin
  consent) and then retries the download automatically in the same session.
  You can also run it standalone: `deromine --add-exclusion`.
- **Miner exits instantly on Windows with no output** (right after the
  `[*] Command:` line, prompt returns immediately): Windows releases ship
  runtime DLLs next to the exe (e.g. dirtybird-c-miner ships `libstdc++-6.dll`,
  `libgcc_s_seh-1.dll`, `libwinpthread-1.dll`, `libcrypto-3-x64.dll`,
  `libssl-3-x64.dll`). If the exe was lifted without its DLLs it cannot start.
  deromine now lifts the whole extracted folder so dependencies stay with the
  binary — re-run the installer to update, then `deromine --miner=c`. If a
  miner still fails to start, deromine prints the exit code right after the
  `[*] Command:` line (e.g. `[!] Miner exited with code 1`) instead of silently
  returning to the prompt — `0xC0000135` means a missing DLL, `0xC000007B` a
  bad image.
