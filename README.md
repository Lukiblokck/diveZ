# diveZ

Run Diver-Office (Van Essen Instruments) under Wine with a physical Diver USB reading unit on Linux.
One small static binary (about 350 KB, about 0.5 MB RSS), no runtime dependencies.

```
Diver-Office (Wine) -> COM9 -> pty <-> [diveZ] <-> /dev/ttyUSB0 -> reading unit
                                         |
                                         +-- localhost status/settings page (on demand)
```

diveZ creates a pseudoterminal, publishes it as `<wine prefix>/dosdevices/com9`, and forwards bytes
both ways. It mirrors the baud rate and frame format Wine sets via `SetCommState` onto the physical
port, survives USB unplug/replug, and exposes a tap for protocol sniffing.

## For end users

See `LEEME.md` (Spanish) or run `./install.sh`, then open "diveZ" from the applications menu.

## What happens on a normal launch

1. Detects the USB serial device, the Wine prefix, `wine`, and the Diver-Office executable.
2. Publishes COM9 for Wine and starts Diver-Office.
3. Exits when Diver-Office exits.

The status/settings page opens automatically only if something needs attention (reader not found,
Wine missing, Diver-Office not found, no permission on the port). It is a single embedded HTML file
served on `127.0.0.1` by the same process, so there is no extra process and no toolkit. Launching
diveZ again while it runs just reopens the page.

## Command line

```
divez                      detect everything, bridge, start Diver-Office
divez --ui                 open the status / settings page
divez --service            headless daemon for init systems (no launch, no UI popup)
divez --service --detach --idle-exit   what the window runs: background, quits when unused
divez [options] -- cmd ... bridge and supervise any command (advanced)
```

| Option | Meaning |
| --- | --- |
| `--serial <path\|auto>` | USB serial device (default `auto`: `/dev/diver0`, then lowest `ttyUSB*`/`ttyACM*`) |
| `--prefix <dir>` | Wine prefix (default `$WINEPREFIX` or `~/.wine`) |
| `--link <path>` | Explicit COM symlink path (default `<prefix>/dosdevices/com9`) |
| `--capture-dir <dir>` | Captures directory (default `~/diveZ/captures`) |
| `--baud <n>` | Initial baud, 1200..115200 (default 9600; Wine's setting wins) |
| `--no-mirror` | Ignore Wine's line settings |
| `--no-dtr-rts` | Do not assert DTR/RTS on the physical port |
| `--detach` | Run in the background in its own session; the log goes to `~/diveZ/divez.log` |
| `--idle-exit` | With `--service`, quit after 15 minutes with no window, no traffic and nothing launched |
| `-v` | Hex-dump all traffic |

Settings saved by the page live in `~/.config/divez/config` (`serial`, `prefix`, `exe`,
`capture_dir`, `autolaunch`). Environment: `DIVEZ_WINE` overrides the wine binary, `DIVEZ_LOG=stderr`
keeps logging on stderr (when started without a terminal, the log goes to `~/diveZ/divez.log`).

The Wine prefix is never created by diveZ: the COM link is published once `<prefix>/dosdevices` exists.

## Settings page security

The page is served on loopback only and hardened against hostile web pages: per-run random token
required on every request, Host header check (DNS rebinding), token in a custom header plus Origin
check on POST (no CORS is ever granted), strict CSP, `no-store`, no referrer.

## Build

Zig 0.13 (builds on master with two small edits; see Notes).

```sh
zig build                                   # ReleaseSafe by default
zig build -Dstrip=true                      # smaller binary
zig build -Dtarget=x86_64-linux-musl -Dstrip=true    # static; also aarch64-linux-musl
zig build test
```

Builds target a generic CPU by default, so a binary built on one machine runs on others (a native
build would use the build machine's AVX etc. and crash with "Illegal instruction" elsewhere).
Add `-Dcpu=native` to opt out. `zig build test` also runs the unit tests of the window's logic.

Prebuilt static binaries for x86_64 and aarch64 are in `dist/` and used by `install.sh`.

### Desktop window (optional): `divez-gui`

A native window for the status, actions and settings, built with
[DVUI](https://github.com/david-vanderson/dvui) v0.2.0 (the last release for Zig 0.13). It is a
separate executable; the daemon does not depend on it. **It is the only thing a user needs to
open:** if diveZ is not running it starts it (`divez --service --detach --idle-exit`, found next
to `divez-gui`, in `~/.local/bin` or in the PATH). Closing the window leaves diveZ running, so a
Diver-Office session is not cut; it quits by itself after 15 idle minutes, or with "Quit diveZ".
If diveZ stops (for example Diver-Office was closed) the window says so and offers "Start diveZ".

```sh
zig build -Dgui=true -Dstrip=true -fsys=sdl2    # -> zig-out/bin/divez-gui
```

- Build: Zig 0.13, network access the first time (DVUI is fetched, pinned by hash in
  `build.zig.zon`, then cached), and the SDL2 development files (`libsdl2-dev` on Debian/Ubuntu).
  Without `-fsys=sdl2` DVUI builds SDL2 from source, which needs many more `-dev` packages.
  Build on the machine that will run it; cross-compiling the window is not tested.
- Run: the SDL2 library (`libsdl2-2.0-0`; `SDL2` on Void), a graphical session, and `divez`
  next to it or installed. The "Choose…" file pickers need `zenity` or `kdialog`; without them
  paths can still be typed. Ctrl and +/-/0 change the text size.
- `install.sh` installs it when it finds a built `divez-gui` (in `zig-out/bin/`, `dist/` or next
  to the script) and then the "diveZ" menu icon opens the window. If SDL2 is missing it says so
  and keeps the icon on the browser settings page. A locally built `zig-out/bin/divez` is
  installed in preference to the prebuilt one in `dist/`.
- It finds the daemon through the address file `divez-<uid>.url` in `$XDG_RUNTIME_DIR`,
  `/run/user/<uid>` or `/tmp`, whichever has it, so it works even if the window and the daemon do
  not share the same environment. When it cannot reach the daemon it shows why and one line of
  diagnostics ("Looked in: … Address file: … Process: …") to copy when asking for help.

## Install options

```sh
./install.sh               # per-user install + USB permission rule (asks for the password once)
./install.sh --service     # additionally install an init service (systemd user unit, runit, OpenRC)
./install.sh --uninstall
```

Service mode is for headless setups. It keeps the COM link ready; use the page's
"Open Diver-Office" button (or run Diver-Office yourself) to start the application.

## Sniffing and `.MON` reconstruction

`src/tap.zig` receives every chunk after it has been forwarded, so a bug there cannot stall the live
stream.

- `frames-<unix>.bin`: lossless log. Record layout, little endian:
  `u64 timestamp_us | u8 direction (0 host->device, 1 device->host) | u32 len | payload`.
- `MonReconstructor.feed` is the integration point for diveRlib-derived logic. The default only
  writes the device->host stream to `session-<unix>.raw` and does **not** produce a valid `.MON`
  file. Develop the parser offline against `frames-*.bin`, then drop it in.

## Testing without hardware

```sh
socat -d -d pty,raw,echo=0,link=/tmp/fake-dev pty,raw,echo=0,link=/tmp/fake-dev-peer &
mkdir -p /tmp/wp/dosdevices
divez --serial /tmp/fake-dev --prefix /tmp/wp --service -v &
cat /tmp/wp/dosdevices/com9 &
echo -n PING > /tmp/wp/dosdevices/com9    # shows up on /tmp/fake-dev-peer
echo -n PONG > /tmp/fake-dev-peer         # shows up on com9 and in session-*.raw
```

## Limitations

- A pty cannot carry modem-line changes made by Wine. DTR+RTS are asserted statically. If
  `WINEDEBUG=+comm` shows Diver-Office pulsing them during a handshake, symlink
  `com9 -> /dev/ttyUSB0` directly instead.
- With several USB serial adapters, "Automatic" picks the first; choose the right one in the page.
- Non-table baud rates (`BOTHER`/`termios2`) are ignored; the last good setting is kept.
- `TIOCEXCL` blocks other processes from opening the port while diveZ runs.
- diveZ closes with Diver-Office; after 15 minutes idle with nothing launched it closes by itself.
- `divez-gui` is English only (a language setting is planned), has no screen-reader support
  (DVUI 0.2.0), and has only been tried on X11. Its `--baud`, `--no-dtr-rts` and `--no-mirror`
  counterparts do not exist: those stay command-line only.

## Notes for Zig master

Change `callconv(.C)` to `callconv(.c)` in `src/main.zig`, and switch `build.zig` to
`.root_module = b.createModule(...)`. `divez-gui` additionally needs a newer DVUI release (v0.3.0
needs Zig 0.14, v0.4.0 needs 0.15.1) and its API changed between them.
