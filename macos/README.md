# Crossover.app

The Mac side, as one bundle instead of five install mechanisms.

```
Crossover.app/Contents/
  MacOS/Crossover              menu bar app (Swift, AppKit)
  MacOS/crossover-clipd        clipboard daemon (Rust, this repo, MIT)
  Helpers/Crossover Input.app  lan-mouse, unmodified (GPL-3.0)
  Resources/GPL-3.0.txt, LAN-MOUSE-SOURCE.txt
```

Dragging it to the Trash is a complete uninstall.

## Why a nested helper app rather than a bare binary

The thing that installs the event tap is what macOS records in Privacy &
Security, and it can only name a bundle. Shipping lan-mouse inside
`Crossover Input.app` means the permission row reads "Crossover Input" rather
than someone else's project, and it is launched through LaunchServices
(`NSWorkspace`) rather than spawned, so macOS treats it as its own responsible
application instead of attributing its prompts to us.

## Why lan-mouse is a separate process

It is GPL-3.0 and Crossover is MIT. Running it as its own process over a Unix
socket is aggregation, which keeps the licences separate. Linking its crates
into the app would make one combined program and put the whole thing under
GPL-3.0. Shipping its binary in our download is still conveying, so the build
emits the corresponding source archive and the bundle carries the licence.

## Building

```bash
./macos/build/build-lan-mouse.sh                  # pinned tag, no GTK, + source tarball
LAN_MOUSE_BIN=macos/build/out/lan-mouse ./macos/build/build-app.sh
```

`--no-default-features` matters: the GTK frontend pulls ~40 MB of Homebrew
dylibs that would have to be bundled and re-signed. Without it the daemon is
4.4 MB and links only system frameworks.

Signing defaults to ad-hoc, which is fine locally. For distribution:

```bash
CODESIGN_IDENTITY="Developer ID Application: …" ./macos/build/build-app.sh
```

That is not cosmetic. An ad-hoc bundle's designated requirement is a bare
`cdhash` of that exact build, and TCC stores it as the client's requirement, so
**every update silently revokes the user's Accessibility grant** while the
toggle still reads on. A Developer ID requirement is identity-based and
survives updates.

## Known gap

The headless lan-mouse never raises the Accessibility prompt; the GTK frontend
did that in `lan-mouse-gtk/src/macos_privacy.rs`, which also carries a watchdog
for a revoked grant. Until that is ported, the app deep-links to the pane and
offers to reveal the helper in Finder, because the Settings "+" picker will not
descend into an app package.
