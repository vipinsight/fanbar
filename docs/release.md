# Releasing

A release is a local notarized build, then a GitHub upload.

## 1. Bump the version

Set the new version in `Resources/Info.plist`, as both `CFBundleShortVersionString`
and `CFBundleVersion`, then commit it to `main`. Sparkle compares `CFBundleVersion`,
so it has to go up with every release. The tag, file names, and appcast all take
the version from this file.

## 2. Build the notarized release

```bash
scripts/release.sh
```

It stops unless both of these are present:

- **Notarization** from `.env.notarization` (gitignored) or the environment:
  `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_PASSWORD` (an app-specific password), and
  `APPLE_SIGNING_IDENTITY` (the Developer ID Application certificate). Exported
  variables win over the file.
- **Sparkle signing key** at
  `~/Library/CloudStorage/OneDrive-Personal/keys/macos-dev/fanbar-sparkle.key`
  (or `FANBAR_SPARKLE_KEY`). It is also in the login keychain under the account
  `fanbar`. Its public half is `SUPublicEDKey` in `Info.plist`.

Then the script:

1. Builds a universal `FanBar.app` and signs it inside out with the Developer ID
   and the hardened runtime: Sparkle's helpers, the framework, the fan helper,
   then the app.
2. Notarizes and staples the app.
3. Zips it as the update payload, `FanBar-<version>.zip`.
4. Wraps it in `FanBar-<version>.dmg`, then signs, notarizes, and staples the
   image. Gatekeeper rejects an unnotarized image.
5. Signs the zip with the Sparkle key and writes `appcast.xml` pointing at this
   version's download URL.

Everything lands in `dist/<version>/`, and the script prints the upload command.

## 3. Publish on GitHub

```bash
gh release create v<version> --repo vipinsight/fanbar --target main \
  dist/<version>/FanBar-<version>.dmg \
  dist/<version>/FanBar-<version>.zip \
  dist/<version>/appcast.xml
```

All three have to go up together:

- `FanBar-<version>.dmg`: new installs (drag to Applications)
- `FanBar-<version>.zip`: what installed copies download
- `appcast.xml`: what installed copies read from
  `releases/latest/download/appcast.xml`

Without `appcast.xml`, nobody finds the update. Without the zip, they find it
and then fail to download it. The repository has to stay public, or the
downloads 404.

## The signing key

**That key cannot be replaced.** Every installed copy trusts exactly the public
key compiled into it. Ship an update signed by a different key and every copy
will download it, fail to verify it, and stay where it is until someone
reinstalls by hand. Do not generate a new key.

## How installed copies update

Sparkle checks every 12 hours. With "Install updates automatically" on (the
default), it downloads in the background and installs straight away, unless
the fan is under manual control; then the menu offers "Update to <version> and
Restart" instead of dropping the user's fan setting. With it off, the menu
shows "Update to <version>…".

A new release can ship a new fan helper. The app compares the installed helper
with the one in its bundle and reinstalls it on the next fan command, which
asks for administrator approval once.

Local `./build-app.sh` builds are ad-hoc signed, so their updater stays off.
