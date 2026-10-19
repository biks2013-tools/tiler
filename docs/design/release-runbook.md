# Tiler Release Runbook: build, sign, notarize, publish, Homebrew

The procedure for producing a Tiler release, publishing it on GitHub and updating the Homebrew
tap. It follows the sibling projects screener and Jumpee:

- `scripts/build-app.sh` builds and signs `build/Tiler.app`; `scripts/package.sh` packages it.
- Release files go to `dist/` (`Tiler-<version>.zip`, `Tiler-<version>.dmg`, `SHA256SUMS`).
- Releases are tagged `v<version>`; the cask downloads `Tiler-<version>.zip`.
- The tap repository `biks2013-tools/homebrew-tiler` gets one commit `tiler <version>` per release.

Last verified: 2026-10-10 (`v0.2.0`, build 1). macOS 27.0, Xcode 27.0.

---

## 0. One-time setup

| # | What | Check | How to (re)create |
|---|------|-------|-------------------|
| 0.1 | Full Xcode | `xcode-select -p` prints `/Applications/Xcode.app/Contents/Developer` | Install Xcode, `sudo xcode-select -s …` |
| 0.2 | Developer ID Application certificate | `security find-identity -v -p codesigning` lists `Developer ID Application: GEORGIOS MARINOS (9F9H8NCAUB)` | Xcode → Settings → Accounts → Manage Certificates |
| 0.3 | notarytool profile `tiler-notary` | `xcrun notarytool history --keychain-profile tiler-notary` | See below |
| 0.4 | GitHub CLI logged in as `BikS2013` | `gh auth status` | `gh auth login` |
| 0.5 | Homebrew clone of the tap, and only one | `brew tap \| grep tiler` prints exactly `biks2013-tools/tiler` | `brew tap biks2013-tools/tiler`; `brew untap` any other clone (a second clone such as `biks2013/tiler` makes `tiler` ambiguous) |

Two Developer ID identities share the same name (`2C7D6068C232BA74073D56085DDBB04E5F14DF30` and
`CEC7876107F7ED244ACA2B9ED7D6E9DE0056931C`, both expiring 2027-02-01): sign by SHA-1. Releases
use `2C7D6068…`.

**0.3** The profile reuses the App Store Connect API key shared with untype and screener
(Key ID `8X27HG66C4`; the `.p8` lives under `~/.tool-agents/untype/` and is never committed):

```sh
xcrun notarytool store-credentials tiler-notary \
  --key ~/.tool-agents/untype/AuthKey_8X27HG66C4.p8 --key-id 8X27HG66C4 \
  --issuer 4100965f-7ed7-4a45-bd2c-3f7ffab3f1ab
```

## 1. Set the version

Edit `VERSION` and `BUILD` at the top of `scripts/build-app.sh`. `BUILD` goes up on every
packaging run.

## 2. Commit what you ship

`git status --short` must be clean: the tag points at the exact source of the build.

## 3. Test, build, sign, notarize, package

```sh
TILER_SIGN_IDENTITY=2C7D6068C232BA74073D56085DDBB04E5F14DF30 NOTARY_PROFILE=tiler-notary scripts/package.sh
```

Runs `swift test`, builds the universal app, checks the Developer ID signature and hardened
runtime, zips + notarizes + staples the app, builds + signs + notarizes + staples the disk image
(with `packaging/macos/INSTALL.txt`), writes `dist/SHA256SUMS` and `homebrew-tap/Casks/tiler.rb`.
The output must show `status: Accepted` twice and `source=Notarized Developer ID` twice.
Rejected? `xcrun notarytool log <id> --keychain-profile tiler-notary`, fix, bump `BUILD`, rerun.

## 4. Verify

```sh
codesign -dvv build/Tiler.app 2>&1 | grep -E "^Identifier|Authority=Developer ID App|flags"
xcrun stapler validate build/Tiler.app && xcrun stapler validate dist/Tiler-<version>.dmg
lipo -archs build/Tiler.app/Contents/MacOS/Tiler      # x86_64 arm64
brew style homebrew-tap/Casks/tiler.rb                # no offenses detected
```

## 5. Install on this Mac

```sh
osascript -e 'tell application id "com.giorgosmarinos.tiler" to quit'
rm -rf /Applications/Tiler.app && ditto build/Tiler.app /Applications/Tiler.app && open -a Tiler
```

Moving between certificates (e.g. the earlier Apple Development builds → Developer ID) changes
the code requirement, so macOS may ask for Accessibility again; if Tiler shows "Allow
Accessibility Access…", remove Tiler from the Accessibility list and add it again.

## 6. Publish the GitHub release

```sh
git push origin main
git tag -a v<version> -m "Tiler <version>" && git push origin v<version>
gh release create v<version> --repo biks2013-tools/tiler --title "Tiler v<version>" --notes-file <notes.md> \
  dist/Tiler-<version>.zip dist/Tiler-<version>.dmg dist/SHA256SUMS
curl -sL -o /tmp/dl.zip https://github.com/biks2013-tools/tiler/releases/download/v<version>/Tiler-<version>.zip
shasum -a 256 /tmp/dl.zip   # must equal the zip line in dist/SHA256SUMS
```

## 7. Update the Homebrew tap

```sh
TAP="$(brew --repo biks2013-tools/tiler)"
git -C "$TAP" pull -q origin main
cp homebrew-tap/Casks/tiler.rb "$TAP/Casks/tiler.rb" && cp homebrew-tap/README.md "$TAP/README.md"
git -C "$TAP" add Casks/tiler.rb README.md && git -C "$TAP" commit -m "tiler <version>" && git -C "$TAP" push origin main
brew audit --cask --online biks2013-tools/tiler/tiler
brew fetch --cask --force biks2013-tools/tiler/tiler   # downloads the release zip, checks its sha256
SCRATCH="$(mktemp -d)" && ditto -x -k "$(brew --cache --cask biks2013-tools/tiler/tiler)" "$SCRATCH"
spctl -a -vv "$SCRATCH/Tiler.app"   # accepted, source=Notarized Developer ID
rm -rf "$SCRATCH"
```

Test the cask with `brew fetch`, never with a scratch `brew install --appdir=<temp dir>`: that
leaves an install record pointing at the temp dir, which breaks the next `brew install` or
`brew upgrade`, and removing it runs the cask's `uninstall quit:`, which quits the running Tiler.

To update your own copy, `brew upgrade --cask biks2013-tools/tiler/tiler`. It quits Tiler
(`uninstall quit:`), so relaunch it afterwards. Accessibility permission carries over: it is
tied to the signature, not to the copy.

## 8. Decks (GitHub Pages)

The repository's `main` branch root is published with GitHub Pages at
https://biks2013-tools.github.io/tiler/. `index.html` links the two decks in `Project Deck/`.
Rebuild a deck's editing tools with `node "Project Deck/<deck>.rebuild.mjs"`.

## 9. Record the release

Add an entry to *Release log* in `Issues - Pending Items.md`.

## Maintenance calendar

| Item | Expires | If missed |
|------|---------|-----------|
| Developer ID certificates | 2027-02-01 | Signing fails; installed copies keep working |
| App Store Connect API key `8X27HG66C4` | No expiry; recreate if leaked, redo 0.3 | Notarization fails |
| Apple Developer Program | Yearly | Notarization stops |
