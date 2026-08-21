# Crossover

Drive your Omarchy machine with the mouse and keyboard of the computer next to
it. Push the cursor off the edge of one screen and it lands on the other, the
clipboard follows, and a Mac keyboard stops fighting you about which key is
Control.

It is Universal Control, for a Linux box you actually own.

![Crossover panel](docs/panel.png)

## What it does

- **One mouse and keyboard, two machines.** Built on
  [lan-mouse](https://github.com/feschber/lan-mouse), which is packaged in Arch
  `extra` and encrypts everything it sends.
- **Shared clipboard.** Copy on the Mac, paste on Omarchy, and back. lan-mouse
  does not do this; `crossover-clipd` adds it over its own mutually
  authenticated TLS connection.
- **Mac keyboard translation.** Cmd-C, Cmd-Tab and Cmd-L behave the way your
  fingers expect, applied only to the incoming virtual keyboard so the keyboard
  physically attached to the Omarchy box is untouched.
- **Pairing that shows you the fingerprint.** An unknown machine asking to
  connect gets a confirmation card, not a silent accept.
- **A seam.** The screen edge glows briefly when the cursor crosses in, so a
  pointer arriving from nowhere does not feel like a glitch.

## Requirements

- Omarchy 4 (Quattro) with `omarchy-shell`
- `lan-mouse` (`sudo pacman -S lan-mouse`)
- `crossover-clipd`, only if you want the shared clipboard

## Install

```bash
omarchy plugin add https://github.com/nwilkens/omarchy-crossover.git
omarchy plugin enable nwilkens.crossover --section right
```

If `lan-mouse` is missing the panel says so and hands you the command.

### The clipboard helper

The plugin cannot install binaries: `omarchy plugin add` deliberately never
runs an install hook. Grab a release build, or compile it yourself:

```bash
# prebuilt
curl -sSL https://github.com/nwilkens/omarchy-crossover/releases/latest/download/crossover-clipd-x86_64-linux \
  -o ~/.cargo/bin/crossover-clipd && chmod +x ~/.cargo/bin/crossover-clipd

# or from source
cargo install --path ~/.config/omarchy/plugins/nwilkens.crossover/clipd
```

## Pairing

Two independent pairings, one for input and one for the clipboard. Both are
fingerprint based, and neither trusts on first use.

**Input.** Start Crossover from the bar, add the other machine, and set which
edge it sits on. The first connection attempt raises a confirmation card
showing the peer's fingerprint. Compare it with the one that machine shows and
approve it.

**Clipboard.** On each machine:

```bash
crossover-clipd fingerprint          # read this one
crossover-clipd pair <other-machine-fingerprint>
crossover-clipd add-peer <other-machine-address>
```

Then leave it running. On Omarchy the plugin starts it for you; on macOS the
setup script installs a LaunchAgent.

## Setting up the Mac side

```bash
./scripts/macos-setup.sh <omarchy-host-or-ip>
```

That installs lan-mouse and the clipboard agent and walks you through pairing.
Two things it cannot do for you:

1. macOS will not let anything read your mouse and keyboard until you grant
   permission. System Settings > Privacy & Security, under **Accessibility**
   and again under **Input Monitoring**.
2. lan-mouse needs to know which edge the Omarchy machine sits on. Set that in
   the lan-mouse window.

## Mac keyboard translation

A Mac sends Command as Super. Omarchy binds Super to its own shortcuts, so
without translation Cmd-C opens a workspace instead of copying.

Crossover applies `ctrl:swap_lwin_lctl` to the virtual keyboard that lan-mouse
creates, and to nothing else:

```
hyprctl keyword 'device[hl-virtual-keyboard-lan-mouse]:kb_options' ctrl:swap_lwin_lctl
```

Cmd becomes Ctrl, and the Mac's Control key becomes Super, which is where you
reach for Omarchy's own bindings. The keyboard attached to the Omarchy machine
keeps its normal layout.

Hyprland honours per-device options for some virtual keyboards and keeps the
client-supplied keymap for others. Crossover applies the option, reads the
device back, and reports **"Compositor kept its own keymap"** if it did not
take, rather than claiming a translation that is not happening.

## Settings

Set these from Setup > Plugins, or inline on the widget's entry in
`~/.config/omarchy/shell.json`.

| Key | Default | What it does |
| --- | --- | --- |
| `macKeyboard` | `true` | Translate Cmd to Ctrl on the incoming keyboard |
| `clipboardSync` | `true` | Run the clipboard helper alongside the daemon |
| `seamIndicator` | `true` | Glow the screen edge on a crossing |
| `autostart` | `true` | Start lan-mouse with the shell |
| `emulationBackend` | `wlroots` | lan-mouse emulation backend |

`wlroots` is the right backend on Hyprland today. The portal-based backends
depend on an InputCapture portal that Hyprland has not shipped yet.

## In the panel

| Key | Action |
| --- | --- |
| Enter | Toggle the selected machine, or approve a pairing |
| `p` | Cycle which edge the selected machine sits on |
| `n` | Add a machine |
| `s` | Start or stop sharing |
| `c` | Copy this machine's fingerprint |
| `r` | Refresh |
| Delete | Remove the selected machine |

## Security

The clipboard carries passwords, so `crossover-clipd` is built to be boring
about it:

- Both ends present a certificate and pin the other's SHA-256 fingerprint.
  Unknown peers are refused. There is no trust-on-first-use path.
- Traffic is TLS 1.3. The private key is written `0600` and never leaves the
  machine.
- A selection marked `x-kde-passwordManagerHint` is never transmitted, which is
  the hint password managers set for exactly this reason. On macOS, `arboard`
  does not expose pasteboard types yet, so the equivalent
  `org.nspasteboard.ConcealedType` check is not in place on that side.
- Payloads are size capped, digest checked, and the receiver allocates only
  after the cap check, never on the sender's claimed length.
- Inbound sessions are limited so a peer cannot exhaust file descriptors.

Report anything that looks wrong by opening an issue.

## How it works

```
  macOS                                  Omarchy / Hyprland
  ─────                                  ──────────────────
  lan-mouse (capture)  ── DTLS/UDP ──▶  lan-mouse (wlroots emulation)
                                                │
  crossover-clipd      ── TLS/TCP ───▶  crossover-clipd
  (NSPasteboard)                        (wlr-data-control)
                                                │
                                         Crossover (QML)
                                         bar widget + panel
```

The plugin is a control plane. It speaks lan-mouse's newline-delimited JSON
protocol on `$XDG_RUNTIME_DIR/lan-mouse-socket.sock`, so peer state, pairing
requests, and crossing events arrive as events rather than being polled.

Clipboard runs on its own connection rather than inside lan-mouse's, because
lan-mouse moves input over unreliable datagrams. That is the right shape for
pointer motion and the wrong one for a 2 MB paste, which is why upstream has
had clipboard support on its wishlist rather than in a release.

## Thanks

[lan-mouse](https://github.com/feschber/lan-mouse) by Ferdinand Schober does
the hard part: capturing input on macOS and emulating it on Wayland. Crossover
would be a much larger project without it.

## License

MIT
