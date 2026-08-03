#!/usr/bin/env bash
# install.sh — one-line installer for deromine (pwsh-free fallback)
#
#   curl -fsSL https://raw.githubusercontent.com/moralpriest/deromine/main/install.sh | bash
#
# install.ps1 is the unified installer for all OSes (run via pwsh on Unix);
# this script is the fallback for systems without PowerShell 7.
#
# Clones deromine into ~/.local/share/deromine (or $XDG_DATA_HOME/deromine)
# and symlinks the launcher onto PATH at ~/.local/bin/deromine. On Termux
# (Android) it ALSO symlinks into $PREFIX/bin, the one directory guaranteed
# to be on PATH there. Everywhere else it adds ~/.local/bin to your shell's
# PATH persistently (bash / zsh / fish) when it isn't already there.
# Idempotent: re-running pulls the latest version.
set -euo pipefail

REPO_URL="https://github.com/moralpriest/deromine.git"
BRANCH="main"

data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
bin_home="${HOME}/.local/bin"
install_dir="$data_home/deromine"

is_termux=false
if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/bin" ]; then
    is_termux=true
fi

mkdir -p "$data_home" "$bin_home"

if [ -d "$install_dir/.git" ]; then
    echo "[*] deromine already installed, updating..."
    git -C "$install_dir" pull --ff-only origin "$BRANCH" || true
else
    echo "[*] Cloning deromine into $install_dir ..."
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$install_dir"
fi

ln -sfn "$install_dir/deromine" "$bin_home/deromine"

on_path=false
case ":${PATH:-}:" in
    *":$bin_home:"*) on_path=true ;;
esac

shell_name="$(basename "${SHELL:-}")"
rc=""
if $is_termux && [ -w "$PREFIX/bin" ]; then
    # $PREFIX/bin is the only dir always on PATH in Termux, and it's
    # user-writable — drop a symlink there so it works in ANY shell.
    ln -sfn "$install_dir/deromine" "$PREFIX/bin/deromine"
    echo "  [*] Linked deromine into $PREFIX/bin — on PATH in every Termux shell"
elif ! $on_path; then
    # Non-Termux: persist ~/.local/bin on PATH for the user's shell.
    case "$shell_name" in
        fish) rc="${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
        zsh)  rc="$HOME/.zshrc"; [ -f "$rc" ] || rc="$HOME/.zshenv" ;;
        bash) rc="$HOME/.bashrc"
              [ "$(uname -s)" = "Darwin" ] && rc="$HOME/.bash_profile" ;;
    esac
    if [ -n "$rc" ] && ! grep -qsF '# deromine' "$rc" 2>/dev/null; then
        mkdir -p "$(dirname "$rc")"
        case "$shell_name" in
            fish) printf '\n# deromine\nfish_add_path "$HOME/.local/bin"\n' >> "$rc" ;;
            *)    printf '\n# deromine\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$rc" ;;
        esac
        echo "  [*] Added ~/.local/bin to your PATH in $rc"
    fi
fi

echo ""
if $is_termux; then
    echo "  deromine is on PATH now — just run it:  deromine"
elif $on_path || [ -n "$rc" ]; then
    echo "  Run it:  deromine   (restart your shell first if PATH was just updated)"
else
    echo "  Add ~/.local/bin to PATH if not already there:"
    echo '    export PATH="$HOME/.local/bin:$PATH"'
fi
echo ""
if command -v pwsh >/dev/null 2>&1; then
    echo "  PowerShell 7 found — full interactive UI enabled."
else
    echo "  PowerShell 7 (pwsh) not found. The bash fallback still works,"
    echo "  but for the full interactive menu install PowerShell 7 first:"
    echo "    https://learn.microsoft.com/powershell/scripting/install/installing-powershell"
fi
echo ""
echo "  Test:    deromine --miner=list"
