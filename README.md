# Crossover

Use one mouse and keyboard across your Omarchy box and the machine next to it.
Shove the pointer off the edge of one screen and it shows up on the other. The
clipboard comes with it. If the other machine is a Mac, Cmd stops behaving like
Super.

![Crossover in use](docs/demo.gif)

The input layer is [lan-mouse](https://github.com/feschber/lan-mouse), which is
in Arch `extra` and already does the hard parts. Crossover adds the bar widget
that drives it, a clipboard channel that lan-mouse doesn't have, and the Cmd
key fix.

## Quick start

```bash
# On Omarchy
omarchy plugin add https://github.com/nwilkens/omarchy-crossover.git
omarchy plugin enable nwilkens.crossover --section right
sudo pacman -S lan-mouse

# ufw is on by default and blocks both ports
curl -fsSL https://raw.githubusercontent.com/nwilkens/omarchy-crossover/v0.4.0/scripts/open-firewall.sh \
  | bash -s -- 192.168.1.0/24

# On the Mac
curl -fsSL https://raw.githubusercontent.com/nwilkens/omarchy-crossover/v0.4.0/scripts/install-macos.sh \
  | bash -s -- <omarchy-ip>
```

For the shared clipboard, install the helper on Omarchy first (below), then
add `--ssh you@<omarchy-ip>` to the Mac command and it pairs both directions.

Open the panel from the bar and it shows you that last command with your own
address already in it.

## Requirements

Omarchy 4 (Quattro), and `lan-mouse` from `extra`. The clipboard helper is
optional and only needed if you want a shared clipboard.

## Installing the clipboard helper

The plugin can't install binaries. `omarchy plugin add` never runs an install
hook, by design. So this part is manual:

```bash
set -e
V=v0.4.0
BASE=https://github.com/nwilkens/omarchy-crossover/releases/download/$V
TMP=$(mktemp -d)
curl -fsSL "$BASE/crossover-clipd-x86_64-linux" -o "$TMP/crossover-clipd"
curl -fsSL "$BASE/SHA256SUMS" | grep crossover-clipd-x86_64-linux \
  | sed "s#crossover-clipd-x86_64-linux#$TMP/crossover-clipd#" | sha256sum -c -
mkdir -p ~/.local/bin
install -m755 "$TMP/crossover-clipd" ~/.local/bin/crossover-clipd
rm -rf "$TMP"
```

Without `set -e` a failed checksum still leaves a working binary on your PATH.

From source instead:

```bash
git clone --branch v0.4.0 --depth 1 https://github.com/nwilkens/omarchy-crossover.git /tmp/crossover-src
cargo install --path /tmp/crossover-src/clipd --locked
```

The checksum catches a corrupted or swapped download. It does not prove
provenance, since a git tag can be moved and `SHA256SUMS` is published
unsigned next to the thing it describes. If that matters to you, check out a
commit SHA and build it yourself.

Same for the plugin itself. `omarchy plugin add` clones the default branch and
takes no ref, so you track `main` and `omarchy plugin update` fast-forwards it.
Pin it yourself if you'd rather not:

```bash
git -C ~/.config/omarchy/plugins/nwilkens.crossover checkout v0.4.0
```

## Pairing

Two separate pairings, one for input and one for the clipboard. Both check
fingerprints, neither trusts on first use.

For input, add the machine in the panel and set which edge it's on. When it
first connects you get a card with its fingerprint on it. Check that against
what the other machine shows, then approve.

For the clipboard, on each machine:

```bash
crossover-clipd fingerprint
crossover-clipd pair <other-machine-fingerprint>
crossover-clipd add-peer <other-machine-address>
```

## The Mac side

```bash
curl -fsSL https://raw.githubusercontent.com/nwilkens/omarchy-crossover/v0.4.0/scripts/install-macos.sh \
  | bash -s -- 10.0.5.1
```

That pulls the official `Lan Mouse.app`, checks it against a hash recorded in
the script, clears the Gatekeeper quarantine flag that otherwise makes an
ad-hoc signed app look broken, installs the clipboard helper with a LaunchAgent,
and points Lan Mouse at your Omarchy box.

`--ssh you@10.0.5.1` pairs the clipboard both ways over ssh instead of making
you copy fingerprints around. It runs `crossover-clipd` on the Omarchy machine,
so install the helper there first. It also writes pairing state there.

`--position right` if the Omarchy machine is to the right of your Mac.

Then grant Lan Mouse permission. macOS will not let anything read your mouse
until you say so, and no script can do it for you. The installer
opens the app so you get prompted; if you don't, add
`/Applications/Lan Mouse.app` by hand under System Settings > Privacy &
Security, in both **Accessibility** and **Input Monitoring**.

The grant is per app and launchd never triggers the prompt, which is why this
runs Lan Mouse as a normal app rather than an agent. Add it to Login Items if
you want it at startup.

## Cmd instead of Super

Off by default, because the swap is right for a Mac and wrong for another Linux
box. Turn it on in Setup > Plugins.

A Mac sends Command as Super, and Omarchy binds Super to its own shortcuts, so
Cmd-C opens a workspace instead of copying. Crossover applies
`ctrl:swap_lwin_lctl` to the virtual keyboard lan-mouse creates and nothing
else, so the keyboard plugged into the Omarchy box is unaffected. Cmd becomes
Ctrl and the Mac's Control key becomes Super, which is where Omarchy's bindings
live.

Hyprland 0.56 rejects `hyprctl keyword` under its Lua parser, so the rule goes
through `hl.device` instead:

```
hyprctl eval 'hl.device({ name = "hl-virtual-keyboard-lan-mouse",
                          kb_options = "<your options>,ctrl:swap_lwin_lctl" })'
```

Your existing `input:kb_options` are read first and kept, so a compose key
stays a compose key. Nothing touches your Hyprland config; the rule is runtime
only and goes away when sharing stops.

The panel reports what actually happened rather than assuming: "Ready, waiting
for input" before the device exists, "Cmd acts as Ctrl" once Hyprland confirms
the rule on the live device, "Compositor refused the rule" if it didn't take.

## Settings

Set from Setup > Plugins, or inline on the widget entry in
`~/.config/omarchy/shell.json`.

| Key | Default | What it does |
| --- | --- | --- |
| `macKeyboard` | `false` | Translate Cmd to Ctrl on the incoming keyboard |
| `clipboardSync` | `true` | Run the clipboard helper alongside the daemon |
| `seamIndicator` | `true` | Glow the screen edge on a handover |
| `autostart` | `true` | Start lan-mouse with the shell |
| `emulationBackend` | `wlroots` | lan-mouse emulation backend |

Leave the backend alone unless you know why. The portal-based ones need an
InputCapture portal Hyprland hasn't shipped.

## Keys in the panel

| Key | Action |
| --- | --- |
| Enter | Toggle the selected machine, or approve a pairing |
| `p` | Cycle which edge the selected machine is on |
| `n` | Add a machine by hostname or IP |
| `s` | Start or stop sharing |
| `c` | Copy this machine's fingerprint |
| `r` | Refresh |
| Delete | Remove the selected machine |

The edge glow marks a handover, not every crossing. lan-mouse only reports an
entry once per connection, so that's all there is to work with. Preview it with
`omarchy-shell nwilkens.crossover testSeam left`.

## When it misbehaves

Both daemons are supervised and restarted if they die. If one keeps exiting the
panel stops respawning it, shows the last line of its stderr, and gives you a
retry button rather than looping.

A helper left behind by a previous shell gets adopted instead of fought with,
which otherwise looks like a clipboard that won't start because the port is
taken.

## Removing it

On Omarchy, disabling or removing the plugin stops both daemons:

```bash
omarchy plugin remove nwilkens.crossover
pkill -x crossover-clipd; pkill -x lan-mouse   # if either survived
sudo pacman -Rns lan-mouse                     # optional
rm -f ~/.local/bin/crossover-clipd ~/.cargo/bin/crossover-clipd
rm -rf ~/.config/crossover                     # identity and paired fingerprints
```

Stop the helper before deleting `~/.config/crossover`, or it keeps running on
the identity it already has in memory.

Firewall rules come back out with the same script:

```bash
curl -fsSL https://raw.githubusercontent.com/nwilkens/omarchy-crossover/v0.4.0/scripts/open-firewall.sh \
  | bash -s -- 192.168.1.0/24 --remove
```

Check with `sudo ufw status` afterwards. Peers you added live in
`~/.config/lan-mouse/config.toml`.

On the Mac:

```bash
curl -fsSL https://raw.githubusercontent.com/nwilkens/omarchy-crossover/v0.4.0/scripts/uninstall-macos.sh \
  | bash -s -- --yes
```

That unloads the LaunchAgent, kills the processes, removes the app and the
helper, restores any lan-mouse config it replaced, and clears its logs. Run it
without `--yes` from a terminal to be asked first, or `--keep-lan-mouse` to
leave the app alone.

If you used `--ssh`, pairing state was also written on the Omarchy machine.
`rm -rf ~/.config/crossover` there, or `crossover-clipd revoke <fingerprint>`
for just the Mac.

macOS keeps Accessibility and Input Monitoring entries after an app is deleted,
so remove "Lan Mouse" by hand under Privacy & Security. Same for Login Items.

## Security

Your clipboard has passwords in it. Both ends present a certificate and pin the other's SHA-256 fingerprint, in
both directions, with no trust-on-first-use. Traffic is TLS, negotiated by
rustls with 1.3 and 1.2 enabled. The private key is `0600` and stays put.
Payloads are size capped and digest checked, and the receiver allocates after
the cap check rather than on whatever length the sender claimed. Inbound
sessions are capped at eight, and a handshake gets a much shorter deadline than
a finished exchange so nobody can sit on a slot.

Approving a new machine needs the cursor on the approval card. A connection
attempt can't redirect a keypress you aimed at something else into granting
trust, and a fingerprint you denied stays denied for the session.

Known gaps:

The password-manager check is best effort. On Linux a selection marked
`x-kde-passwordManagerHint` is skipped, but the hint and the contents are two
separate clipboard reads, so a copy landing between them still goes out. On
macOS there's no check at all yet, because `arboard` doesn't expose pasteboard
types, so `org.nspasteboard.ConcealedType` is ignored and passwords copied on
the Mac are transmitted.

Received payloads lose the hint, so a clipboard manager on the other side may
write them to disk. And the eight-session cap is availability, not
authentication: a host on your subnet that opens sockets and says nothing can
stall inbound sync until it stops.

If a shared clipboard for passwords isn't a trade you want, set `clipboardSync`
to `false` and use Crossover for input only.

Open an issue if you find a problem.

## What it runs and what it writes

The plugin never runs `sudo` and never installs anything. The
`sudo pacman -S lan-mouse` in `Panel.qml` is a string it displays and copies to
your clipboard when you click it.

Processes it spawns, all as you: `lan-mouse ... daemon`, `crossover-clipd run`,
`hyprctl` for monitors and devices and the keyboard rule, `wl-copy` for the
copy actions, `which` and `pgrep` to find the helper, `pkill -x
crossover-clipd` to stop it, and `sh -c` for two fixed pipelines (locating the
helper, and reading this machine's LAN address with `ip`, `sed` and `head`).
Hostnames, addresses and fingerprints arriving over lan-mouse's socket are
never interpolated into any of them; commands are fixed argument arrays.

The three shell scripts are optional and the plugin never invokes them.
`open-firewall.sh` calls `sudo ufw` or `sudo firewall-cmd` to open 4242 and
4243 to one subnet you name, and reads service state with `systemctl is-active`
to pick between them. `install-macos.sh` runs on macOS, and with `--ssh` also
runs three `crossover-clipd` subcommands on the Omarchy machine.
`uninstall-macos.sh` reverses it.

Everything that gets written:

| Path | By |
| --- | --- |
| `~/.config/omarchy/plugins/nwilkens.crossover/` | `omarchy plugin add` |
| `~/.config/crossover/` | the clipboard helper, on either machine |
| `~/.config/lan-mouse/config.toml` | lan-mouse, and the Mac installer, which backs up an existing file |
| `/Applications/Lan Mouse.app` | the Mac installer |
| `~/.local/bin/crossover-clipd` | the Mac installer, and the Linux install above |
| `~/Library/LaunchAgents/com.nwilkens.crossover.clipd.plist` | the Mac installer |
| `~/Library/Logs/crossover-clipd.log` | that LaunchAgent |
| ufw or firewalld rules for 4242 and 4243 | `open-firewall.sh`, if you run it |

No sudoers changes, and no binaries committed here. Release builds come from
GitHub Actions out of the `clipd` source in this repo. Everything above has a
removal command in [Removing it](#removing-it).

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

The plugin is a control plane and never touches input events. It speaks
lan-mouse's newline-delimited JSON on
`$XDG_RUNTIME_DIR/lan-mouse-socket.sock`, so peer state, pairing requests and
crossings arrive as events instead of being polled.

The clipboard runs on its own connection rather than inside lan-mouse's,
because lan-mouse moves input over unreliable datagrams. Right for pointer
motion, wrong for a 2 MB paste, which is why upstream has had clipboard support
on the wishlist rather than in a release.

## Thanks

[lan-mouse](https://github.com/feschber/lan-mouse) by Ferdinand Schober does
the hard part: capturing input on macOS and emulating it on Wayland.

## License

MIT
