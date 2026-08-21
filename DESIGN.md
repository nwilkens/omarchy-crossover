# Crossover: Universal Control for Omarchy

Drive an Omarchy machine from a Mac's mouse and keyboard, with a shared
clipboard, so the Linux box behaves like another monitor that happens to run
its own OS.

## Constraints discovered

**Omarchy plugin API (Quattro).** A plugin is a git repo with `manifest.json`
plus QML, cloned to `~/.config/omarchy/plugins/<id>/`. Kinds: `bar-widget`,
`panel`, `overlay`, `menu`, `service`, `bar`. The installer never runs install
hooks and never asks for sudo. Plugins run unsandboxed inside the long-lived
`omarchy-shell` process, may spawn processes (`Quickshell.Io.Process`), ship
helper scripts (the first-party clipboard plugin ships `capture.sh`), register
IPC targets, and persist settings inline in `~/.config/omarchy/shell.json`.

**Wayland input emulation needs a native client.** QML cannot bind
`zwp_virtual_pointer_v1` / `zwp_virtual_keyboard_v1`. A helper daemon is
mandatory on the Linux side. The plugin is a control plane, never a data plane.

**The input layer is already solved.** `lan-mouse` 0.11.0 ships in Arch `extra`.
It has a macOS CGEventTap capture backend, a wlroots emulation backend that
Hyprland supports natively, and DTLS-encrypted transport with fingerprint
pinning. Its `Xdp` and `Libei` emulation backends depend on portal support that
Hyprland still lacks, so `wlroots` is the backend to pin.

**The gaps lan-mouse leaves.** No clipboard sync. No Cmd/Ctrl translation, so a
Mac keyboard drives Hyprland with the wrong modifier under every shortcut. No
discovery or pairing UX. No visual feedback about which machine owns the cursor.
Those four gaps are the product.

## Architecture

Three layers, each independently useful.

```
  macOS                                  Omarchy / Hyprland
  ─────                                  ──────────────────
  lan-mouse (capture)  ── DTLS/UDP ──▶  lan-mouse (wlroots emulation)
                                                │
  crossover-clipd           ── TLS/TCP ───▶  crossover-clipd
  (arboard/NSPasteboard)                (wl-clipboard-rs)
                                                │
                                         seam plugin (QML)
                                         bar widget + panel + service
```

1. **Input transport: stock lan-mouse.** Not vendored, not forked. The plugin
   manages its lifecycle and config.
2. **Clipboard: `crossover-clipd`.** One small Rust binary, same source on both
   platforms. Rides its own TLS/TCP connection because clipboard payloads are
   large and need reliable ordered delivery, which DTLS datagrams are wrong for.
   That is also precisely why upstream has not shipped it.
3. **Control plane and UX: the Seam plugin.** QML only.

### Layer 3, the plugin

- `service` kind: owns lan-mouse lifecycle, polls state, watches Hyprland
  events, applies the keyboard remap.
- `bar-widget` + `panel`: link state, peer list, activate/deactivate, edge
  assignment, pairing fingerprints, clipboard toggle, dependency install path.

**Mac keyboard mode.** The lan-mouse virtual keyboard is a distinct Hyprland
input device, so per-device xkb options apply to it alone:

```
hyprctl keyword 'device[<virtual-kb>]:kb_options' ctrl:swap_lwin_lctl
```

Cmd-C, Cmd-Tab and Cmd-L then behave as Ctrl on the Linux side while the
physical keyboard attached to the Omarchy box keeps its normal layout. This is
the single feature that makes a Mac keyboard actually usable and it costs one
`hyprctl` call.

**Edge assignment from real geometry.** Read `hyprctl monitors -j` and offer
edges that physically exist rather than lan-mouse's abstract left/right/top/
bottom, then write the matching `position` into lan-mouse's config.

**Seam indicator.** A thin accent-colored edge glow on the monitor bordering
the Mac, brightening when the cursor leaves and when it returns. This is what
sells "another monitor" rather than "a remote control".

### Layer 2, crossover-clipd

- Transport: `tokio-rustls`, self-signed cert via `rcgen`, both ends pin the
  peer's SHA-256 fingerprint. Mutual auth. No plaintext on the wire, ever.
- Peers: read `~/.config/lan-mouse/config.toml` so pairing happens once, in
  lan-mouse, and the clipboard follows.
- Clipboard access: `wl-clipboard-rs` on Linux, `arboard` on macOS. No
  subprocess shelling for clipboard reads.
- Loop suppression: content hash of the last applied payload, skip echoes.
- Refuse to sync when the source advertises `x-kde-passwordManagerHint` or
  `CLIPBOARD_STATE=sensitive`, matching what omarchy's own clipboard plugin
  already does for its history.
- Size cap, text first, images behind a setting.

Distribution: `cargo install --git` for v1, AUR package after.

## Threat model

Assume a hostile host on the same LAN.

- Both channels authenticated by pinned self-signed certificate fingerprints.
  An unpinned peer is refused, never trusted-on-first-use silently.
- The clipboard listener binds only to interfaces the user selects and defaults
  to refusing any peer absent from the pin list.
- The plugin never writes a fingerprint it was not shown in a pairing dialog.
- Clipboard payloads are capped and never written to disk on the receiving side.
- The plugin runs inside `omarchy-shell` with full user privilege, so it shells
  out only to fixed argv arrays, never to a shell string built from peer data.
  Peer hostnames arriving over the network are treated as untrusted input.

## Milestones

- **M1 Plugin skeleton.** manifest, service, bar widget, panel, lan-mouse
  detection and install prompt, start/stop, peer list, state polling.
- **M2 Mac keyboard mode.** virtual-device discovery, per-device xkb remap,
  toggle and persistence.
- **M3 Edge assignment and seam indicator.** monitor geometry, config write,
  edge glow, crossing feedback.
- **M4 crossover-clipd.** protocol, pinning, both clipboard backends, plugin
  integration and status.
- **M5 Packaging.** README with a Mac setup walkthrough, demo GIF, marketplace
  submission.

M1 through M3 are the competition entry and stand alone without a Mac; any
lan-mouse peer works, including another Omarchy box. M4 is the differentiator
and the thing that makes daily Mac use bearable.

## Open risks

- macOS capture requires Accessibility and Input Monitoring permission, granted
  by hand. Unavoidable, document it.
- lan-mouse's release binding on the Omarchy side is a key chord; verify it does
  not collide with Hyprland bindings.
- Hyprland's per-device xkb keyword name must be discovered at runtime by
  diffing `hyprctl devices -j` around daemon start.
- Judges without a second machine can only evaluate the plugin's UI, so the
  README must carry a demo GIF that shows the crossing.
