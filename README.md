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

Installs to `~/.local/share/deromine` (`%USERPROFILE%\.local\share\deromine` on
Windows) and puts the launcher on PATH — `~/.local/bin/deromine`
(`%USERPROFILE%\.local\bin\deromine.cmd` on Windows, `$PREFIX/bin/deromine` on
Termux). PATH is updated in the user registry on Windows or your shell profile
(bash/zsh/fish) on Unix — open a new terminal afterwards. Re-run to update.
Git is used when available; otherwise the source zip is downloaded, so git is
not required.

### One-liner without PowerShell (Linux/macOS/Termux)

If `pwsh` isn't installed, the bash installer covers the same ground with fewer
dependencies:

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

- **PowerShell 7+ (`pwsh`)** for the full interactive menu and all CLI modes.
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
| `--benchmark` | Benchmark all supported miners |
| `--bench-time=...` | Benchmark seconds per miner (default 30) |
| `--output-dir=...` | Where binaries are stored (default `bin/`) |
| `--config=...` | Path to config file (default `config.json`) |
| `-h` / `--help` / `/?` | Show usage and exit |

```powershell
pwsh ./mine.ps1 --miner=c --wallet=dero1... --daemon-url=http://dero.rabidmining.com:10100 --threads=4
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
| `--benchmark` / `--bench-time=...` | Benchmark mode |
| `-h` / `--help` / `/?` | Show usage and exit |

```bash
bash ./mine.sh --miner=c --wallet=dero1...
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
| zig | Dirtybird Zig | dirtybird-zig-miner | cpu | 0% | Open source | Small binary |
| cuda | Dirtybird CUDA | dirtybird-openastronv_v3 | gpu | 0% | Open source | NVIDIA GPU required |
| go-gpu | Dirtybird Go GPU | dirtybird-go-gpu-miner | gpu | 0% | Open source | Any Vulkan GPU |
| derohe | DERO HE Default Miner | dero-miner-linux-amd64 | cpu | 0% | Official | Official default miner |
| deroluna | DeroLuna | deroluna-miner | cpu | 10% | Closed source | GitLab releases |
| tnn | TNN | tnn-miner | both | 2.5% | Closed DLLs | CPU+GPU, dev fee configurable via `--dev-fee` |
| astronv | Astronv | astronv | gpu | 4.9% | Closed source | NVIDIA GPU, Linux only |

Ordering is intentional: open-source 0%-fee miners first, then the official DeroHE
miner, then closed-source / dev-fee miners at the bottom. Miners whose hardware
requirements are not met (e.g. GPU miners without the right GPU) are hidden from
the list on that host.

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
  "wallet_address": "dero1...",
  "daemon_url": "http://dero.rabidmining.com:10100",
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
2. **Platform detection** uses PowerShell auto-vars (`$IsLinux`, `$IsWindows`,
   `$IsMacOS`) or `uname` to determine OS/architecture.
3. **Binary resolution** prefers a per-asset binary override (for OS-specific
   names), then the miner's `binary` property, then a legacy fallback map for the
   Dirtybird ids. `.exe` is appended on Windows.
4. **Asset matching** filters `assets[]` by `os`, `arch`, and `pattern` glob.
5. **Download** queries the GitHub/GitLab latest-release API at runtime, matches
   the asset by pattern, extracts it, and places the binary in `bin/<miner-id>/`.
   Nested binaries are lifted to the top-level folder.
6. **Command building** uses the miner's `flags` map from the catalog (daemon,
   wallet, threads, coin, port, dev fee), defaulting to the Dirtybird short-flag
   convention (`-d`, `-w`, `-t`). Any `http(s)://` scheme is stripped from the
   daemon address.
7. **Mining** launches the binary in the foreground with the built arguments.
   `--auto-restart` wraps it in a restart loop (max restarts, delay).
8. **Benchmark mode** runs each supported miner for a fixed window, parses the
   reported hashrate, and prints a comparison table.

## Testing

Run the non-interactive smoke tests before opening a PR (they need no network
and never launch a miner):

```bash
pwsh ./scripts/smoke-test.ps1     # PowerShell path: catalog, modules, resolution
bash ./scripts/smoke-test.sh      # bash path: catalog, version, list mode
```

Both suites fail with exit code 1 on any regression.

## Troubleshooting

- **"[x] No asset for c on linux/amd64"**: The GitHub release doesn't have an
  asset matching `dirtybird-miner-amd64-*.tar.gz`. Check the release page for the
  correct asset naming.
- **Binary not found after extraction**: The extracted archive may have a nested
  directory. The script attempts to lift nested binaries to the top-level
  `bin/<miner-id>/` folder.
- **Permission denied on Linux/macOS**: The script runs `chmod +x` automatically.
  If it fails, run `chmod +x bin/c/dirtybird-c-miner` manually.
- **GPU miner missing from list**: GPU miners are filtered by hardware detection
  (`nvidia-smi` for NVIDIA, `vulkaninfo` for Vulkan). Install the vendor runtime
  and try again.
- **Astronv fails to start**: it needs NVIDIA drivers (`libnvidia-ml.so.1`) and is
  Linux amd64 only.
