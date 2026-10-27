#!/bin/sh
# diveZ installer. Run it as your normal user (no root needed to start):
# the only step that needs the administrator password is the USB-permission rule,
# and it asks for it with a graphical prompt when one is available.
#
#   ./install.sh               install for the current user
#   ./install.sh --service     also install an init service (advanced, headless mode)
#   ./install.sh --uninstall   remove everything this script installed

set -eu

# Locate the repository when running locally, or download it when piped to sh.
script_dir=""
case "$0" in
    install.sh|*/install.sh)
        script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
        ;;
esac

if [ -n "$script_dir" ] && [ -d "$script_dir/packaging" ]; then
    here=$script_dir
elif [ -f ./install.sh ] && [ -d ./packaging ]; then
    here=$(pwd)
else
    say_bootstrap() { printf '%s\n' "$*"; }

    if ! command -v tar >/dev/null 2>&1; then
        say_bootstrap "Error: tar is required to download diveZ."
        exit 1
    fi

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT HUP INT TERM

    archive="$tmp/source.tar.gz"
    url="https://github.com/Lukiblokck/diveZ/archive/refs/heads/main.tar.gz"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$archive"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$archive"
    else
        say_bootstrap "Error: install curl or wget first."
        exit 1
    fi

    if ! tar -xzf "$archive" -C "$tmp"; then
        say_bootstrap "Error: could not extract the diveZ archive."
        exit 1
    fi

    repo="$tmp/diveZ-main"

    if [ ! -f "$repo/install.sh" ] || [ ! -d "$repo/packaging" ]; then
        say_bootstrap "Error: the downloaded archive is incomplete."
        exit 1
    fi

    if sh "$repo/install.sh" "$@"; then
        exit 0
    else
        status=$?
        exit "$status"
    fi
fi

pk="$here/packaging"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
bindir="$HOME/.local/bin"
appdir="$data/applications"
icondir="$data/icons/hicolor/scalable/apps"

service=0; uninstall=0
for a in "$@"; do
    case "$a" in
        --service) service=1 ;;
        --uninstall) uninstall=1 ;;
        *) echo "usage: install.sh [--service] [--uninstall]" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }

if [ "$(id -u)" -eq 0 ]; then
    say "Please run this as your normal user, not as root (it asks for the password when needed)."
    exit 1
fi

# Run a command as root: graphical prompt first, then sudo/doas.
priv() {
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v pkexec >/dev/null 2>&1; then pkexec "$@"
    elif command -v sudo >/dev/null 2>&1; then sudo "$@"
    elif command -v doas >/dev/null 2>&1; then doas "$@"
    else return 127
    fi
}

detect_init() {
    if [ -d /run/systemd/system ]; then echo systemd
    elif command -v sv >/dev/null 2>&1 && { [ -d /var/service ] || [ -d /run/runit/service ] || [ -d /etc/runit/runsvdir ]; }; then echo runit
    elif command -v rc-service >/dev/null 2>&1; then echo openrc
    else echo unknown
    fi
}

if [ "$uninstall" -eq 1 ]; then
    say "Removing diveZ..."
    rm -f "$bindir/divez" "$bindir/divez-gui" "$appdir/divez.desktop" "$icondir/divez.svg"
    priv /bin/sh -c 'rm -f /etc/udev/rules.d/70-diver.rules' || say "(could not remove the udev rule; remove /etc/udev/rules.d/70-diver.rules manually)"
    priv /bin/sh "$pk/root-service.sh" uninstall 2>/dev/null || true
    say "Done. Your data in ~/diveZ and settings in ~/.config/divez were kept."
    exit 0
fi

# 1. Pick the binaries: a build made here wins, else the prebuilt static one for this CPU.
arch=$(uname -m)
case "$arch" in amd64) arch=x86_64 ;; arm64) arch=aarch64 ;; esac
src="$here/zig-out/bin/divez"
[ -x "$src" ] || src="$here/dist/divez-$arch"
if [ ! -x "$src" ]; then
    say "No diveZ binary for '$arch'. Build one with Zig 0.13:  zig build -Dstrip=true"
    exit 1
fi

# The window (divez-gui) is optional; it is built with:  zig build -Dgui=true -Dstrip=true -fsys=sdl2
gui=""
for c in "$here/zig-out/bin/divez-gui" "$here/dist/divez-gui" "$here/divez-gui"; do
    [ -x "$c" ] && { gui="$c"; break; }
done
if [ -n "$gui" ] && command -v ldd >/dev/null 2>&1 && ldd "$gui" 2>/dev/null | grep -q "not found"; then
    say "!! The diveZ window needs a library this computer does not have:"
    ldd "$gui" 2>/dev/null | grep "not found" | sed 's/^[[:space:]]*/   /'
    say "   Install SDL2 with your package manager (Debian/Ubuntu: libsdl2-2.0-0, Void: SDL2) and run this again."
    say "   Meanwhile the menu icon will open diveZ's settings page in your browser instead."
    gui=""
fi

say "==> Installing diveZ for $USER"
install -Dm755 "$src" "$bindir/divez"
launch="$bindir/divez"
if [ -n "$gui" ]; then
    install -Dm755 "$gui" "$bindir/divez-gui"
    launch="$bindir/divez-gui"   # one click: the window starts diveZ by itself
elif [ -x "$bindir/divez-gui" ]; then
    launch="$bindir/divez-gui"   # a window installed earlier is kept and used
fi
mkdir -p "$appdir" "$icondir"
sed -e "s|@LAUNCH@|$launch|g" -e "s|@BIN@|$bindir/divez|g" "$pk/desktop/divez.desktop" > "$appdir/divez.desktop"
install -Dm644 "$pk/icons/divez.svg" "$icondir/divez.svg"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$appdir" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t "$data/icons/hicolor" 2>/dev/null || true

# 2. USB permissions (needs the administrator password once).
group=$(stat -c %G /dev/ttyUSB0 2>/dev/null || true)
case "$group" in ""|root|UNKNOWN) group="" ;; esac
if [ -z "$group" ]; then
    if getent group dialout >/dev/null 2>&1; then group=dialout
    elif getent group uucp >/dev/null 2>&1; then group=uucp
    else group=root; fi
fi
say "==> USB permissions (group: $group) - you may be asked for your password"
if ! priv /bin/sh "$pk/root-setup.sh" "$USER" "$group" "$pk/udev/70-diver.rules"; then
    say "!! Could not set USB permissions automatically. Ask an administrator to run:"
    say "   sudo sh $pk/root-setup.sh $USER $group $pk/udev/70-diver.rules"
fi

# 3. Optional init service.
if [ "$service" -eq 1 ]; then
    init=$(detect_init)
    say "==> init service ($init)"
    if priv /bin/sh "$pk/root-service.sh" install "$init" "$USER" "$group" "$HOME" "$bindir/divez" "$pk"; then
        case "$init" in
            systemd) say "enable with:  systemctl --user enable --now divez" ;;
            runit)   say "enable with:  sudo ln -s /etc/sv/divez /var/service/   (or /run/runit/service/)" ;;
            openrc)  say "enable with:  sudo rc-update add divez default && sudo rc-service divez start" ;;
        esac
    else
        say "!! Service installation failed or is unsupported on this system."
    fi
fi

say
say "Done. Open \"diveZ\" from your applications menu."
command -v wine >/dev/null 2>&1 || say "Note: Wine is not installed. Install it with your distribution's package manager."
case ":$PATH:" in *":$bindir:"*) ;; *) say "Note: $bindir is not in your PATH; use the menu icon or run $launch" ;; esac
