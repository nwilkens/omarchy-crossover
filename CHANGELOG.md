# Changelog

Notable changes, newest first. `omarchy plugin update` shows you a diff of the
default branch before it applies anything, so entries land here in the same
commit as the change they describe rather than at release time.

## [Unreleased]

## [0.4.0]

### Fixed

- A machine attempting to connect could turn any Enter keypress in the panel
  into approving it. Cursor placement no longer follows a network event, and a
  denied fingerprint stays denied for the session.
- Turning sharing off left the clipboard helper running. `stop()` assigned to a
  readonly property, threw, and never reached the code that stops it.
- `open-firewall.sh` opened the ports when given a typo of `--remove`.
- `--ssh` accepted a value starting with `-`, which ssh reads as an option.
- A clipboard change made while a peer was unreachable was recorded as
  delivered and never retried.
- The clipboard helper started at login even with `autostart` off, and the
  power switch could not stop it.
- Disabling or removing the plugin now stops both daemons.

### Changed

- An inbound TLS handshake gets a much shorter deadline than a completed
  exchange, so an unauthenticated peer cannot hold a session slot.
- README no longer claims TLS 1.3 only, that the macOS installer never touches
  the Omarchy machine, that nothing is written outside three directories, or
  that a marked password selection is never transmitted. The real limits are
  written down instead.

## [0.3.0]

### Added

- `scripts/uninstall-macos.sh`, and a removal section covering the LaunchAgent,
  the app, binaries, configuration, and firewall rules.
- `--remove` for `open-firewall.sh`.
- Releases publish `SHA256SUMS`, and the installer verifies against it.

### Changed

- Every documented install path is pinned to a release tag instead of tracking
  `main` or `latest`.

## [0.2.0]

### Added

- Machines currently driving this screen are tracked and shown, separately from
  the outgoing link.
- Both daemons are supervised, with backoff and a retry button.
- "Add a machine" takes a hostname or IP.
- Tests for the wire decoding and peer bookkeeping.

### Fixed

- An orphaned clipboard helper from a previous shell is adopted instead of
  losing a race for the port.

## [0.1.0]

First release. Bar widget and panel driving lan-mouse over its IPC socket, plus
`crossover-clipd` for mutually authenticated clipboard sync.
