# Releasing

The version in `manifest.json` is the source of truth. Everything else derives
from it.

1. Update `## [Unreleased]` in `CHANGELOG.md` into a real version heading.
2. Bump `version` in `manifest.json`.
3. `python3 scripts/check-pinning.py --write`

   Rewrites the tag in every documented URL, both script markers, Panel.qml's
   `releaseTag`, and `clipd/Cargo.toml`. Then run it with no arguments to
   confirm it comes back clean.
4. Commit, push, and tag:

   ```bash
   git tag -a vX.Y.Z -m "Crossover X.Y.Z" && git push origin vX.Y.Z
   ```

   The release workflow builds three targets, writes `SHA256SUMS`, attaches a
   build provenance attestation, and publishes.
5. Check the assets actually resolve before telling anyone. GitHub's CDN lags a
   few seconds behind the API:

   ```bash
   curl -fsSL https://github.com/nwilkens/omarchy-crossover/releases/download/vX.Y.Z/SHA256SUMS
   ```

## Marketplace

The listing verifies a specific commit. After a release, file the update issue
on the marketplace repository so it re-verifies, or the listing keeps pointing
at the old SHA and shows as unverified.

Don't push to `main` between filing that issue and its approval: the check runs
against the SHA in the issue, and a push invalidates it.

## Things that bite

- `main` is what users run. `omarchy plugin update` fast-forwards it, so
  anything merged there reaches desktops without passing through a tag.
- Release immutability means a published tag cannot be moved or its assets
  replaced. Get it right or cut another version.
- Bump `clipd/Cargo.toml` even when the Rust code is unchanged, or
  `crossover-clipd --version` disagrees with the release it shipped in, and the
  macOS installer's upgrade check compares against that string.
