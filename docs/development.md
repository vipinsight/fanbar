# Development notes

Things that are not obvious from the code. Releasing is in [release.md](release.md).

## Building and running

- `./build-app.sh` builds a universal (Apple silicon + Intel) `FanBar.app`, ad-hoc
  signed. Its updater is off: only Developer ID builds, which carry a team
  identifier, check for updates (`Updates.isSignedRelease`).
- Quit the running copy before launching a new build (`pkill -x FanBar`), or
  `open` just brings the old one forward.
- The x86_64 deprecation warning during the build is harmless; the binaries
  still target macOS 13 (`vtool -show-build FanBar.app/Contents/MacOS/FanBar`).

## The fan helper

- Changing fan speed needs root. `Contents/MacOS/FanBarHelper` is a launch
  daemon registered with `SMAppService` (`Resources/com.webtiara.fanbar.daemon.plist`).
  The first fan command registers it, and macOS asks the user once to allow
  FanBar under System Settings › General › Login Items & Extensions. No
  password. Commands go over `/var/run/com.webtiara.fanbar.daemon.sock`.
- This needs a Developer ID-signed build. Ad-hoc `./build-app.sh` builds can't
  register the daemon; for local testing, build with
  `SIGN_IDENTITY="Developer ID Application: …" ./build-app.sh`.
- After an update the daemon keeps running the old binary. On its first fan
  command the app compares the daemon's `version` with its own
  `CFBundleVersion` and sends `exit`; launchd restarts it from the new bundle.
- The daemon accepts `auto`, `max`, `rpm <1000–10000>`, `version`, and `exit`,
  and applies fan commands to every fan, each clamped to its own range.
- On first start it removes the helper FanBar 1.0.0 installed with an admin
  password (`com.webtiara.fanbar.helper`).
- Fan commands run off the main thread: on M1 to M4, taking the fans from
  thermalmonitord can mean setting `Ftst` and waiting a few seconds.
- The fans go back to Automatic whenever FanBar stops, for any reason. The app
  resets them on quit, and the daemon watches the process that last set a
  manual speed: if it exits (crash, force quit, logout), the daemon resets them
  itself. It also resets them when it starts and when launchd stops it.

## SMC keys

| Key | Meaning |
|---|---|
| `F<n>Ac` | Fan n measured speed; the menu bar shows the fastest fan |
| `F<n>Tg` | Fan n target speed; presets and the slider write it |
| `F<n>Md` | Fan n mode: 0 automatic, 1 manual (`F<n>md` on some models) |
| `F<n>Mn` / `F<n>Mx` | Fan n hardware minimum and maximum |
| `FNum` | Number of fans |
| `Ftst` | On M1 to M4, set to 1 before thermalmonitord lets go of the fans |

Any number of fans works (up to 8). The slider spans the lowest fan minimum
to the highest fan maximum, and each fan clamps a target to its own range, so
the right end runs every fan at its own top speed. On a 14" M1 Pro the two fans
top out at 5779 and 6241 rpm. Fanless Macs (`FNum` = 0) show "This Mac has no
fans".

SMC has no fan names on Apple silicon. Two-fan MacBook Pros are labelled Left
and Right (fan 0 is on the left, as other fan utilities label it); other Macs
get Fan 1, Fan 2, and so on.

## Temperature sensors

- Core and GPU keys move between chip generations. `ChipLayout` in
  `Sensors.swift` has a table for each of M1 to M5, taken from the Stats app
  (github.com/exelban/stats, MIT). Only M1 Pro has been checked on real
  hardware here.
- A chip without a table, or whose keys don't match, still gets a
  "CPU Core Average" from every `Tp*`/`Te*` key it reports. On Apple silicon
  that sensor always comes first, so it is the default.
- Apple does not document any of this. Binned chips report keys for cores they
  don't have (an 8-core M1 Pro reports 8 performance-core keys for 6 cores), so
  the app lists as many as `hw.perflevel0/1.physicalcpu` says exist.
- A sensor is listed if its key exists and isn't 0. A reading under 15 °C or
  over 130 °C shows as `--`: an idle, powered-down GPU keeps reporting about
  9 °C.
- To see what a Mac reports, enumerate the SMC keys starting with `T`.

## Menu bar

- The readout is a text field inside the status item button. It is sized to the
  drawn text, so a single line centers vertically as well as two.
- `NSStatusItemSpacing` is registered as 6 at launch, which tightens FanBar's
  slot from 8pt to 3pt per side. Registered defaults apply only to this app and
  are never written, so users don't need to run `defaults`.
- Negative `lineSpacing` is ignored by AppKit; the two-line layout uses fixed
  10pt line heights instead.
- Don't name a menu action `openSettings`: AppKit gives that selector an
  automatic gear icon, which misaligns the menu.

## Settings storage

`UserDefaults` keys: `usesFahrenheit`, `temperatureSensor` (sensor name),
`menuBarContent` (0 both, 1 temperature, 2 fan speed), `usesSingleLine`.
Sparkle keeps its own `SU*` keys.
