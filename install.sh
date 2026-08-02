#!/usr/bin/env bash
# install.sh — one-line installer for deromine
#
#   curl -fsSL https://raw.githubusercontent.com/moralpriest/deromine/main/install.sh | bash
#
# Clones deromine into ~/.local/share/deromine (or $XDG_DATA_HOME/deromine)
# and symlinks the launcher onto PATH at ~/.local/bin/deromine.
# Idempotent: re-running pulls the latest version.
set -euo pipefail

REPO_URL="https://github.com/moralpriest/deromine.git"
BRANCH="main"

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
bin_home="${HOME}/.local/bin"
install_dir="$data_home/deromine"

mkdir -p "$data_home" "$bin_home"

if [ -d "$install_dir/.git" ]; then
    echo "[*] deromine already installed, updating..."
    git -C "$install_dir" pull --ff-only origin "$BRANCH" || true
else
    echo "[*] Cloning deromine into $install_dir ..."
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$install_dir"
fi

ln -sfn "$install_dir/deromine" "$bin_home/deromine"

echo ""
echo "  Installed. Add ~/.local/bin to PATH if not already there:"
echo '    export PATH="$HOME/.local/bin:$PATH"'
echo ""
if command -v pwsh >/dev/null 2>&1; then
    echo "  PowerShell 7 found — full interactive UI enabled."
else
    echo "  PowerShell 7 (pwsh) not found. The bash fallback still works,"
    echo "  but for the full interactive menu install PowerShell 7 first:"
    echo "    https://learn.microsoft.com/powershell/scripting/install/installing-powershell"
fi
echo ""
echo "  Run it:  deromine"
echo "  Test:    deromine --miner=list"
