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

run_privileged() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "  [x] Root privileges are required to install PowerShell, but sudo was not found." >&2
        return 1
    fi
}

show_pwsh_install_guide() {
    case "$(uname -s)" in
        Darwin*)
            echo "      brew install --cask powershell" >&2
            echo "      Verify with: pwsh --version   (p-w-s-h)" >&2 ;;
        *)
            if $is_termux; then
                echo "      pkg install -y powershell" >&2
            elif command -v apt-get >/dev/null 2>&1; then
                echo "      Install PowerShell from the Microsoft apt repository:" >&2
                echo "      https://learn.microsoft.com/powershell/scripting/install/install-ubuntu" >&2
            elif command -v dnf >/dev/null 2>&1; then
                echo "      Install PowerShell from the Microsoft rpm repository:" >&2
                echo "      https://learn.microsoft.com/powershell/scripting/install/install-fedora" >&2
            fi
            ;;
    esac
    echo "      https://learn.microsoft.com/powershell/scripting/install/installing-powershell" >&2
}

install_pwsh_if_missing() {
    command -v pwsh >/dev/null 2>&1 && return 0
    [ "${DEROMINE_SKIP_PWSH:-0}" = "1" ] && {
        echo "  [!] Skipping automatic PowerShell 7 install (DEROMINE_SKIP_PWSH=1)." >&2
        return 1
    }

    if [ "${DEROMINE_AUTO_INSTALL_PWSH:-0}" != "1" ]; then
        # In `curl ... | bash`, stdout is a pipe, so do not use `-t 1` here.
        # A controlling terminal is still safe to prompt through /dev/tty.
        if [ -r /dev/tty ]; then
            printf '  PowerShell 7 (pwsh) is missing. Install it now? [Y/n] ' >&2
            read -r answer </dev/tty || answer='n'
            case "$answer" in
                n|N|no|NO) return 1 ;;
            esac
        else
            echo "  [!] PowerShell 7 is missing; not installing automatically without a TTY." >&2
            echo "      Set DEROMINE_AUTO_INSTALL_PWSH=1 to approve unattended installation." >&2
            show_pwsh_install_guide
            return 1
        fi
    fi

    echo "  [*] PowerShell 7 (pwsh) is missing; attempting to install it..."
    if $is_termux; then
        pkg install -y powershell || return 1
    elif [ "$(uname -s)" = "Darwin" ]; then
        brew_cmd="$(command -v brew 2>/dev/null || true)"
        if [ -z "$brew_cmd" ]; then
            for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
                if [ -x "$candidate" ]; then brew_cmd="$candidate"; break; fi
            done
        fi
        if [ -z "$brew_cmd" ]; then
            echo "  [!] Homebrew is required on macOS: https://brew.sh" >&2
            return 1
        fi
        brew_prefix="$($brew_cmd --prefix 2>/dev/null || true)"
        [ -d "$brew_prefix/bin" ] && export PATH="$brew_prefix/bin:$PATH"
        "$brew_cmd" install --cask powershell || {
            echo "  [!] Homebrew could not install PowerShell." >&2
            echo "      Check existing installs with:" >&2
            echo "      $brew_cmd list --formula powershell; $brew_cmd list --cask powershell" >&2
            echo "      Then resolve any formula/cask conflict and retry:" >&2
            echo "      $brew_cmd install --cask powershell" >&2
            return 1
        }
        if ! command -v pwsh >/dev/null 2>&1; then
            echo "  [!] Homebrew reported success, but 'pwsh' is not on PATH yet." >&2
            echo "      Open a new terminal, then verify with: pwsh --version" >&2
            return 1
        fi
    elif command -v apt-get >/dev/null 2>&1; then
        # Prefer an existing package; otherwise register Microsoft's official
        # repository for Debian/Ubuntu before installing.
        if command -v apt-cache >/dev/null 2>&1 && apt-cache show powershell >/dev/null 2>&1; then
            run_privileged apt-get update || return 1
            run_privileged apt-get install -y powershell || return 1
        elif [ -r /etc/os-release ] && command -v curl >/dev/null 2>&1; then
            . /etc/os-release
            case "$ID" in
                ubuntu|debian)
                    repo_pkg="$(mktemp "${TMPDIR:-/tmp}/packages-microsoft-prod.XXXXXX.deb")"
                    curl -fsSL "https://packages.microsoft.com/config/$ID/$VERSION_ID/packages-microsoft-prod.deb" -o "$repo_pkg" || { rm -f "$repo_pkg"; return 1; }
                    run_privileged dpkg -i "$repo_pkg" || { rm -f "$repo_pkg"; return 1; }
                    rm -f "$repo_pkg"
                    run_privileged apt-get update || return 1
                    run_privileged apt-get install -y powershell || return 1
                    ;;
                *)
                    echo "  [!] Automatic apt setup is supported for Ubuntu/Debian only." >&2
                    return 1
                    ;;
            esac
        else
            return 1
        fi
    elif command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
        if ! dnf info powershell >/dev/null 2>&1; then
            if [ -r /etc/os-release ]; then
                . /etc/os-release
                case "$ID" in
                    fedora)
                        if [[ "$VERSION_ID" =~ ^[0-9]+$ ]]; then
                            repo_url="https://packages.microsoft.com/config/fedora/$VERSION_ID/packages-microsoft-prod.rpm"
                        else
                            repo_url=""
                        fi
                        ;;
                    rhel|centos|rocky|almalinux)
                        repo_major="${VERSION_ID%%.*}"
                        if [[ "$repo_major" =~ ^[0-9]+$ ]]; then
                            repo_url="https://packages.microsoft.com/config/rhel/$repo_major/packages-microsoft-prod.rpm"
                        else
                            repo_url=""
                        fi
                        ;;
                    *)
                        repo_url="" ;;
                esac
                if [ -n "$repo_url" ]; then
                    run_privileged dnf install -y "$repo_url" || return 1
                fi
            fi
        fi
        dnf info powershell >/dev/null 2>&1 || {
            echo "  [!] PowerShell is not available in the configured dnf repositories." >&2
            return 1
        }
        run_privileged dnf install -y powershell || return 1
    elif command -v snap >/dev/null 2>&1; then
        run_privileged snap install powershell --classic || return 1
    else
        return 1
    fi
    command -v pwsh >/dev/null 2>&1
}

if ! install_pwsh_if_missing; then
    echo "  [!] PowerShell 7 was not installed; the bash fallback remains available." >&2
    show_pwsh_install_guide
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
