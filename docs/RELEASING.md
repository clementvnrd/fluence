# Releasing Fluence (macOS)

How a version gets from `main` to a Mac and then updates itself (FLU-26). Read `AGENTS.md`
first: the signing identity is what keeps macOS permissions (TCC) across updates.

## What is in place

| Piece | Where | Notes |
|---|---|---|
| Version | `Resources/Info.plist` (`CFBundleShortVersionString`) | The one place it is written. The build number is derived: major × 10000 + minor × 100 + patch (0.1.0 → 100). A test (`ReleaseVersionTests`) fails if `CFBundleVersion` does not match. |
| Updater | Sparkle 2 (SwiftPM, `Package.swift`), `Support/AppUpdater.swift` | Checks at launch and once a day, downloads in the background, asks *Installer / Plus tard* only while Fluence is the active app and nothing records. *Plus tard*: installed when Fluence quits, no relaunch. |
| Update signing key | EdDSA, private half in the **login Keychain** of the release Mac (account `ed25519`, created by Sparkle's `generate_keys`); public half in `Info.plist` (`SUPublicEDKey`) | Never in the repo, never printed. |
| Code signature | `make` picks a Developer ID if there is one, else **Apple Development** | v0.1 is signed with Apple Development and **not notarized**. |
| Feed | `FEED_URL` / `DOWNLOAD_URL_PREFIX`, stamped into the bundle | Empty by default: a dev build (`make app`, `make install`) has no updater. `make release` refuses anything but `https://` (or `http://localhost` for a test). |

## Where the feed lives (Clement decides — grouped Decision issue under FLU-25)

Sparkle downloads the feed and the archive **without a password, over http(s)**. A `file://`
feed is refused ("The download request URL must use http or https", tested 2026-10-08), and the
source repository is private (its release files answer 404 without a token).

| Option | Updates work for | What it needs |
|---|---|---|
| A public **`fluence-releases`** repository holding only the releases (recommended once the licence question is settled) | Anyone with the app | The binary becomes downloadable by anyone: upstream licence and third-party notices first. `FEED_URL=https://github.com/clementvnrd/fluence-releases/releases/latest/download/appcast.xml`, `DOWNLOAD_URL_PREFIX=https://github.com/clementvnrd/fluence-releases/releases/download/v<version>/` |
| `clementvnrd/fluence` made public | Anyone | Same prerequisites, and the source becomes public. |
| No feed yet | — | Each version is installed by hand. |
| A token inside the app to read the private repo | — | Rejected: a secret in every copy. |

The feed URL is baked into each build: a copy only ever looks where its own build said. A copy
built with no feed, or with another feed, needs one manual install of a build that points to
the right place. With the `releases/latest/download/` form, a **draft** release is invisible to
installed apps: nothing reaches them until the release is published.

## Making a release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` (the test
   tells you the build number), write `docs/releases/<version>.html` (French, a few lines,
   shown in the update question — headings are dropped there) and
   `docs/releases/<version>.md` (French + English, for GitHub). Merge to `main`.
2. From a clean checkout of that commit:

   ```bash
   make release FEED_URL=https://… DOWNLOAD_URL_PREFIX=https://…/v<version>/
   ```

   It builds in release mode, signs inside out with a secure timestamp, zips with `ditto`,
   writes the SHA-256, and runs Sparkle's `generate_appcast`, which signs the archive with the
   Keychain key (no prompt) and writes `appcast.xml` — all into
   `~/Library/Fluence Releases/<version>/`. It refuses an ad-hoc signature (every update would
   then lose the permissions), a feed that is not https, and uncommitted changes.
3. Upload, as a **draft** first: `gh release create v<version> --draft --repo <feed repo>
   --notes-file docs/releases/<version>.md <zip> <zip>.sha256 appcast.xml`. Publishing it is
   Clement's call; installed copies see it at their next check (launch, once a day, or
   *Rechercher des mises à jour…*).

The first copy that contains Sparkle has to be installed by hand once (copy `Fluence.app` to
`/Applications`); every later version updates itself.

## Keys: keep the EdDSA key safe

* Losing the private key while the app is signed with Apple Development strands every
  installed copy: Sparkle accepts an update when **either** the EdDSA key **or** the
  code-signing identity is unchanged, and the recovery path through a notarized disk image
  needs a Developer ID.
* Back it up once, into a password manager, never into the repo:
  `generate_keys -x fluence-sparkle-key.txt`, store the file's content, then delete the file.
  (`generate_keys` is in SwiftPM's artifacts:
  `~/Library/Caches/FluenceBuild/<checkout>/scratch/artifacts/sparkle/Sparkle/bin/`.)

## Signing, permissions and Gatekeeper

* macOS keeps Microphone, Accessibility, System Audio and Calendar grants against the app's
  **designated requirement**, which names the certificate. Same certificate from one version
  to the next: grants stay. Moving to a Developer ID certificate changes it: every permission
  is asked again, once — say so in that release's notes.
* Sparkle refuses an update whose EdDSA signature does not match `SUPublicEDKey`, or whose code
  signature does not match the running app's (unless the key matches — the rotation rule above).
* Gatekeeper, measured on 2026-10-08: `spctl -a -vv` answers *rejected* for an Apple Development
  signature, yet every update installed by Sparkle launched — it carries no
  `com.apple.quarantine`, so Gatekeeper never assesses it. A first copy downloaded by a browser
  *is* quarantined and is refused until System Settings › Privacy & Security › *Open Anyway*
  (not re-tested here).
* Notarization (v0.2) needs a **Developer ID Application** certificate (paid Apple Developer
  Program), a secure timestamp (`make release` already asks for one), then
  `xcrun notarytool submit Fluence-<v>.zip --keychain-profile <profile> --wait`,
  `xcrun stapler staple Fluence.app`, re-zip, and `spctl -a -vv Fluence.app` must say
  *accepted, source=Notarized Developer ID*.

## Testing an update without touching the installed app

A copy built under another bundle ID keeps its own data folder, settings, Keychain item and
permissions (`AppPaths.isolatedBundleID`), so it can be installed anywhere and updated for
real. The feed is served on this Mac only:

```bash
T=<a scratch folder>; ID=io.github.clementvnrd.fluence.updatetest; U=http://localhost:8765
make release ALLOW_DIRTY=1 APP_VERSION=0.1.1 BUNDLE_ID=$ID RELEASE_FEED=$T/feed \
     FEED_URL=$U/appcast.xml DOWNLOAD_URL_PREFIX=$U/          # needs docs/releases/0.1.1.*
make app APP_VERSION=0.1.0 BUNDLE_ID=$ID FEED_URL=$U/appcast.xml
ditto ~/Library/Caches/FluenceBuild/<checkout>/Fluence.app $T/app/Fluence.app
python3 -m http.server 8765 --bind 127.0.0.1 --directory $T/feed &
open -g $T/app/Fluence.app     # background: downloads, no question until it is brought forward
```

Sparkle checks at the first launch; for another check without waiting a day,
`defaults delete $ID SULastCheckTime` before relaunching. The log tells each step:
`/usr/bin/log stream --predicate 'subsystem == "io.github.clementvnrd.fluence.updatetest"'`
(`downloaded and verified`, `asking about`, `installing … now`, `left for the next quit`).

Afterwards: quit the copy, stop the server, delete the scratch folder and the temporary
`docs/releases/0.1.1.*`, then the copy's traces:
`~/Library/Application Support/Fluence-$ID`, `~/Library/Caches/$ID`,
`~/Library/HTTPStorages/$ID`, `defaults delete $ID`, and
`security delete-generic-password -s $ID.vault`.

### Result on 2026-10-08 (MacBook Air M2, macOS 26)

0.1.0 → 0.1.1 → … → 0.1.7 through this procedure: check at launch, download, EdDSA check
(`OK: EdDSA signature is correct`), *Installer* → quit and relaunch on the new version,
*Plus tard* → no second question, installed at quit without relaunch, signature still valid
(same team, secure timestamp). Details and outputs in FLU-26.
