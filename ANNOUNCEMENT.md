# deromine — Release Announcement Drafts

Release: v1.0.0 · https://github.com/moralpriest/deromine

---

## 1. X / Twitter (short)

Deromine is out 🚀 — one launcher for every DERO miner, on any OS.

▪️ Dirtybird C/Rust/Go/Zig + CUDA/Go-GPU
▪️ Official DeroHE, DeroLuna, TNN, Astronv
▪️ Auto-downloads releases from GitHub/GitLab
▪️ Interactive menu, CLI flags, benchmark mode, auto-restart
▪️ Linux · macOS · Windows · Termux

```bash
curl -fsSL https://raw.githubusercontent.com/moralpriest/deromine/main/install.sh | bash
```

No compilation. Just pick a miner and mine.

#DERO #DeroMining #Crypto #Mining #OpenSource

---

## 2. Reddit (r/DERO, r/CryptoCurrency — longer)

**deromine v1.0 — one launcher for all DERO miners**

I built a launcher that handles every DERO miner so you don't have to track
releases, extract archives, and fight with flags across half a dozen repos.

**What it does**

- Downloads and runs Dirtybird C/Rust/Go/Zig and Go-GPU/CUDA, the official
  DeroHE miner, DeroLuna, TNN, and Astronv straight from their GitHub/GitLab
  release pages. No manual compilation.
- One command per miner: `deromine --miner=tnn --dev-fee=1`
- Interactive menu for picking a miner, wallet, daemon, and thread count
- Hides miners your hardware can't run (checks nvidia-smi / vulkaninfo)
- Benchmark mode: times each miner and saves history so you can spot
  hashrate regressions (Δ vs last run)
- Auto-restart with per-run logs when a miner crashes

**Supported miners**

| Miner | Type | Fee |
|---|---|---|
| Dirtybird C / Rust / Go / Zig | CPU | 0% |
| Dirtybird CUDA / Go GPU | GPU | 0% |
| DeroHE default miner | CPU | 0% (official) |
| DeroLuna | CPU | 10% (closed source) |
| TNN | CPU+GPU | 2.5%, configurable |
| Astronv | GPU | 4.9% (closed source) |

Open-source 0% miners are listed first; dev-fee miners are marked clearly.

**Install**

```bash
git clone https://github.com/moralpriest/deromine
cd deromine
./deromine --miner=list
```

PowerShell 7 gives the full interactive UI; a bash fallback covers Termux and
minimal systems. Windows users run `deromine.cmd`.

Feedback, issues, and PRs welcome. Repo:
https://github.com/moralpriest/deromine

---

## 3. Discord / Telegram (medium)

🚀 **deromine v1.0 released** — one launcher for every DERO miner, on any OS.

▪️ Downloads miners automatically from official GitHub/GitLab releases
▪️ Dirtybird C/Rust/Go/Zig · CUDA/Go-GPU · DeroHE · DeroLuna · TNN · Astronv
▪️ Interactive menu + CLI flags · benchmark with history · auto-restart
▪️ Linux / macOS / Windows / Termux

```bash
curl -fsSL https://raw.githubusercontent.com/moralpriest/deromine/main/install.sh | bash
deromine
```

Open source, 0% fee miners first, dev-fee miners clearly marked.
Try it and report back — issues/PRs welcome 👇
https://github.com/moralpriest/deromine

---

## 4. Mastodon / longer-form (alt)

A single launcher for DERO mining on any OS/CPU/GPU.

deromine downloads, extracts, and runs community DERO miners directly from
their official GitHub/GitLab releases — no manual compilation. It ships an
interactive menu plus CLI flags (--miner, --wallet, --daemon, --threads,
--dev-fee, --benchmark, --auto-restart), filters miners by your actual
hardware, and logs auto-restarts so crashes are diagnosable.

Supported: Dirtybird C/Rust/Go/Zig + CUDA/Go-GPU, official DeroHE, DeroLuna,
TNN, Astronv. Open-source 0%-fee miners are listed first; dev-fee miners are
clearly marked (DeroLuna 10%, TNN 2.5% configurable, Astronv 4.9%).

Install: git clone https://github.com/moralpriest/deromine && cd deromine && ./deromine

#DERO #mining #opensource
