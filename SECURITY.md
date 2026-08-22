# Security

Crossover moves your keyboard, your mouse, and your clipboard across a network.
The clipboard part regularly carries passwords. Treat a bug here as worth
reporting.

## Reporting

Use [private vulnerability reporting](https://github.com/nwilkens/omarchy-crossover/security/advisories/new).
That keeps the details off the public tracker until there is a fix.

Please don't open a public issue for anything that lets another machine read a
clipboard, write one, or get input into a session it wasn't paired with.

Expect a first response within a week. If a fix is warranted it ships as a
release with the advisory published alongside it.

## What's supported

The QML plugin is supported at the default branch, because that's what users
actually run: `omarchy plugin add` clones it and `omarchy plugin update`
fast-forwards it. There's no way to hold an older revision.

`crossover-clipd` is supported at the latest release tag. Older tags stay up
for reproducibility but don't get fixes.

## Known limits

These are design limits, not bugs, and they're documented in the README under
[Security](README.md#security):

- The password-manager check is best effort. The hint and the contents are two
  separate clipboard reads, so a copy landing between them still goes out.
- macOS has no concealed-type check at all yet, so passwords copied there are
  transmitted.
- A received payload arrives as plain text, so a clipboard manager on the far
  side may write it to disk.
- The inbound session cap is availability, not authentication.

If any of those matter to you, set `clipboardSync` to `false` and use Crossover
for input only.

## Scope

In scope: the QML plugin, `crossover-clipd`, and the install scripts in this
repository.

Out of scope: [lan-mouse](https://github.com/feschber/lan-mouse), which is a
separate project with its own reporting process. Crossover runs it as an
external process and does not vendor or patch it.
