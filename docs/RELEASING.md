# Releasing Fluence (macOS)

How a version gets from `main` to a Mac and then updates itself (FLU-26). Read `AGENTS.md`
first: the signing identity is what keeps macOS permissions (TCC) across updates.

## What is in place

| Piece | Where | Notes |
|---|---|---|
| Version | `Resources/Info.plist` (`CFBundleShortVersionString`) | The one place it is written. The build number is derived: major × 10000 + minor × 100 + patch (0.1.0 → 100). A test (`ReleaseVersionTests`) fails if `CFBundleVersion` does not match. |
| Updater | Sparkle 2 (SwiftPM, `Package.swift`), `Support/AppUpdater.swift` | Checks at launch and once a day, downloads in the background, asks *Installer / Plus tard* only while Fluence is the active app and nothing records. *Plus tard*: installed when Fluence quits, no relaunch. |
| Update signing key | EdDSA, private half in the **login Keychain** of the release Mac (account `ed25519`, created by Sparkle's `generate_keys`); public half in `Info.plist` (`SUPublicEDKey`) | Never in the repo, never printed. |
| Code signature | `make` picks a Developer ID if there is one, else **Apple Development** | Signed with Apple Development and **not notarized**, for good: no Developer ID (decided 2026-10-08, FLU-39). |
| Feed | `FEED_URL` / `DOWNLOAD_URL_PREFIX`, stamped into the bundle | Empty by default: a dev build (`make app`, `make install`) has no updater. `make release` refuses anything but `https://` (or `http://localhost` for a test). |

## Where the feed lives (decided 2026-10-08: the `fluence` repository)

Sparkle downloads the feed and the archive **without a password, over http(s)**. A `file://`
feed is refused ("The download request URL must use http or https", tested 2026-10-08), and a
token inside the app to read a private repository was rejected (a secret in every copy).
Clement chose to make `clementvnrd/fluence` public (FLU-39), so every build uses:

```
FEED_URL=https://github.com/clementvnrd/fluence/releases/latest/download/appcast.xml
DOWNLOAD_URL_PREFIX=https://github.com/clementvnrd/fluence/releases/download/v<version>/
```

**Not live yet.** The repository stays private until FLU-43 is answered (about 17 % of the
lines are still another author's). Meanwhile the feed answers 404: a background check finds
nothing and shows nothing (the log says `updates: check ended — SUSparkleErrorDomain 2001`); a
manual *Rechercher des mises à jour…* shows an error.

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
3. Upload, as a **draft** first: `gh release create v<version> --draft --repo clementvnrd/fluence
   --target <commit> --notes-file docs/releases/<version>.md <zip> <zip>.sha256 appcast.xml`.
   A draft creates no tag; publishing does. Publishing is Clement's call; installed copies see
   it at their next check (launch, once a day, or *Rechercher des mises à jour…*).

The first copy that contains Sparkle has to be installed by hand once (copy `Fluence.app` to
`/Applications`); every later version updates itself.

## Keys: keep the EdDSA key safe

* Losing the private key strands every installed copy: Sparkle accepts an update when
  **either** the EdDSA key **or** the code-signing identity is unchanged, and the recovery path
  through a notarized disk image needs a Developer ID, which Fluence will not have (FLU-39).
* Back it up once, into a password manager, never into the repo (Clement did, 2026-10-08):
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
* **No notarization** (decided 2026-10-08, FLU-39: no Developer ID, ever). It would need a
  paid Developer ID Application certificate. A first copy on another Mac therefore needs
  *Open Anyway* once; its updates do not.

## Installing the first updatable copy on Clement's Mac (2026-10-09, FLU-41)

0.1.0 was built from `main` @ 5e2cb5b with the feed above and installed from its own archive,
in this order: no dictation or meeting in progress (no `recording.marker`, no log activity);
the previous app copied to `~/Fluence-app-backup-2026-10-09/`; Fluence quit with a normal
*quit* (no kill); the archive's `Fluence.app` copied into `/Applications`; launched. Checked:
the designated requirement is identical to the previous app's, the event tap installed
(Accessibility kept), data unchanged (dictionary, history, 5 meetings, 3 snippets), the update
check runs (404 while private). Not checked: the Microphone grant (the TCC database is not
readable without Full Disk Access).

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
