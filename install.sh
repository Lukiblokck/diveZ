
#!/bin/sh
# diveZ installer
#
# Local:
#   sh install.sh
#   sh install.sh --service
#   sh install.sh --uninstall
#
# Remote:
#   curl -fsSL https://raw.githubusercontent.com/Lukiblokck/diveZ/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/Lukiblokck/diveZ/main/install.sh | sh -s -- --service

set -eu

say() {
    printf '%s\n' "$*"
}

# Locate repository or bootstrap it when invoked through curl | sh.
script_dir=""
case "$0" in
    */install.sh|install.sh)
        script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
        ;;
esac

if [ -n "$script_dir" ] && [ -d "$script_dir/packaging" ]; then
    here=$script_dir
elif [ -f ./install.sh ] && [ -d ./packaging ]; then
    here=$(pwd)
else
    command -v tar >/dev/null 2>&1 || {
        say "Error: tar is required."
        exit 1
    }

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' 0
    trap 'exit 1' HUP INT TERM

    archive="$tmp/source.tar.gz"
    url="https://github.com/Lukiblokck/diveZ/archive/refs/heads/main.tar.gz"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$archive"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$archive"
    else
        say "Error: install curl or wget first."
        exit 1
    fi

    tar -xzf "$archive" -C "$tmp"
    repo="$tmp/diveZ-main"

    if [ ! -f "$repo/install.sh" ] || [ ! -d "$repo/packaging" ]; then
        say "Error: invalid diveZ archive."
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

service=0
uninstall=0

for arg in "$@"; do
    case "$arg" in
        --service) service=1 ;;
        --uninstall) uninstall=1 ;;
        *)
            say "Usage: install.sh [--service] [--uninstall]" >&2
            exit 2
            ;;
    esac
done

if [ "$(id -u)" -eq 0 ]; then
    say "Please run this as your normal user, not as root."
    exit 1
fi

# Privilege helper: graphical prompt, sudo, or doas.
priv() {
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] &&
       command -v pkexec >/dev/null 2>&1; then
        pkexec "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    else
        return 127
    fi
}

detect_init() {
    if [ -d /run/systemd/system ]; then
        echo systemd
    elif command -v sv >/dev/null 2>&1 &&
         { [ -d /var/service ] ||
           [ -d /run/runit/service ] ||
           [ -d /etc/runit/runsvdir ]; }; then
        echo runit
    elif command -v rc-service >/dev/null 2>&1; then
        echo openrc
    else
        echo unknown
    fi
}

# Uninstall.
if [ "$uninstall" -eq 1 ]; then
    say "==> Removing diveZ..."

    rm -f \
        "$bindir/divez" \
        "$bindir/divez-gui" \
        "$appdir/divez.desktop" \
        "$icondir/divez.svg"

    if ! priv /bin/sh -c \
        'rm -f /etc/udev/rules.d/70-diver.rules'; then
        say "Warning: could not remove the USB rule automatically."
    fi

    priv /bin/sh "$pk/root-service.sh" uninstall 2>/dev/null || true

    say "diveZ uninstalled. User data was kept."
    exit 0
fi

# 1. Locate the CLI binary.
arch=$(uname -m)

case "$arch" in
    amd64) arch=x86_64 ;;
    arm64) arch=aarch64 ;;
esac

src="$here/zig-out/bin/divez"
[ -x "$src" ] || src="$here/dist/divez-$arch"

if [ ! -x "$src" ]; then
    say "Error: no diveZ binary for '$arch'."
    say "Build it with Zig 0.13: zig build -Dstrip=true"
    exit 1
fi

# 2. Locate or build the GUI.
gui=""

for candidate in \
    "$here/zig-out/bin/divez-gui" \
    "$here/dist/divez-gui" \
    "$here/dist/divez-gui-$arch" \
    "$here/divez-gui"; do
    if [ -x "$candidate" ]; then
        gui=$candidate
        break
    fi
done

if [ -z "$gui" ]; then
    if ! command -v zig >/dev/null 2>&1; then
        say "Error: divez-gui is missing and Zig is not installed."
        say "Install Zig 0.13 and SDL2 development files, then retry."
        exit 1
    fi

    say "==> Building diveZ GUI (this may take a while)..."

    if ! (cd "$here" && zig build -Dgui=true -Dstrip=true -Dfsys=sdl2); then
        say "Error: GUI build failed."
        say "Check Zig 0.13, network access and SDL2 development files."
        exit 1
    fi

    gui="$here/zig-out/bin/divez-gui"

    if [ ! -x "$gui" ]; then
        say "Error: the GUI binary was not produced."
        exit 1
    fi
fi

# Check GUI runtime dependencies when ldd is available.
if command -v ldd >/dev/null 2>&1 &&
   ldd "$gui" 2>/dev/null | grep -q "not found"; then
    say "Error: the GUI needs missing runtime libraries:"
    ldd "$gui" 2>/dev/null | grep "not found" |
        sed 's/^[[:space:]]*/   /'
    say "Install the missing libraries, then run this installer again."
    exit 1
fi

# 3. Install CLI and GUI.
say "==> Installing diveZ for $USER"

install -Dm755 "$src" "$bindir/divez"
install -Dm755 "$gui" "$bindir/divez-gui"

# Make commands available in future login shells.
profile="$HOME/.profile"

if ! grep -Fq '.local/bin' "$profile" 2>/dev/null; then
    cat >> "$profile" <<'PROFILE'

# User-installed applications
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH
PROFILE
fi

# The GUI is the main desktop entry.
launch="$bindir/divez-gui"

mkdir -p "$appdir" "$icondir"

sed \
    -e "s|@LAUNCH@|$launch|g" \
    -e "s|@BIN@|$bindir/divez|g" \
    "$pk/desktop/divez.desktop" > "$appdir/divez.desktop"

install -Dm644 "$pk/icons/divez.svg" "$icondir/divez.svg"

if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$appdir" 2>/dev/null || true
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -q -t "$data/icons/hicolor" 2>/dev/null || true
fi

# 4. Configure USB permissions.
group=$(stat -c %G /dev/ttyUSB0 2>/dev/null || true)

case "$group" in
    ""|root|UNKNOWN) group="" ;;
esac

if [ -z "$group" ]; then
    if getent group dialout >/dev/null 2>&1; then
        group=dialout
    elif getent group uucp >/dev/null 2>&1; then
        group=uucp
    else
        group=root
    fi
fi

say "==> Configuring USB permissions (group: $group)"

if ! priv /bin/sh "$pk/root-setup.sh" \
    "$USER" "$group" "$pk/udev/70-diver.rules"; then
    say "Warning: automatic USB permission setup failed."
    say "An administrator can run:"
    say "sudo sh \"$pk/root-setup.sh\" \"$USER\" \"$group\" \"$pk/udev/70-diver.rules\""
fi

# 5. Optional init service.
if [ "$service" -eq 1 ]; then
    init=$(detect_init)
    say "==> Installing init service ($init)"

    if priv /bin/sh "$pk/root-service.sh" install \
        "$init" "$USER" "$group" "$HOME" "$bindir/divez" "$pk"; then
        case "$init" in
            systemd)
                say "Enable with: systemctl --user enable --now divez"
                ;;
            runit)
                say "Enable with: sudo ln -s /etc/sv/divez /var/service/"
                say "Use your configured runit service directory if different."
                ;;
            openrc)
                say "Enable with: sudo rc-update add divez default"
                say "Start with: sudo rc-service divez start"
                ;;
        esac
    else
        say "Warning: service installation failed or is unsupported."
    fi
fi

say ""
say "diveZ installation complete."
say "GUI command: divez-gui"
say "CLI command: divez"

if ! command -v wine >/dev/null 2>&1; then
    say "Note: Wine is not installed. Install it using your package manager."
fi

case ":$PATH:" in
    *":$bindir:"*) ;;
    *)
        say "Note: $bindir is not currently in PATH."
        say "Open a new login shell or run:"
        say "export PATH=\"$bindir:\$PATH\""
        ;;
esac
