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

- Changing fan speed needs root. The first fan command installs
  `/Library/PrivilegedHelperTools/com.webtiara.fanbar.helper` as a launch
  daemon, behind one administrator prompt; later commands go over
  `/var/run/com.webtiara.fanbar.helper.sock`.
- The app reinstalls the helper whenever the installed copy differs from the
  one in its bundle, so an update can ship a new helper. Every local rebuild
  produces a different binary, so expect the admin prompt again after each
  rebuild, on the first fan change.
- The helper accepts only `auto` and `rpm <1000–8000>`.
- Quitting FanBar puts the fan back to Automatic.

## SMC keys

| Key | Meaning |
|---|---|
| `F0Ac` | Fan 0 measured speed; this is what the menu bar shows |
| `F0Tg` | Fan 0 target speed; presets and the slider write it |
| `F0Md` | Fan 0 mode: 0 automatic, 1 manual |
| `F0Mn` / `F0Mx` | Fan 0 hardware minimum and maximum; the slider range |
| `FNum` | Number of fans |

Only fan 0 is read and controlled, even on Macs with two fans.

## Temperature sensors

- Per-core and GPU sensors are mapped only for M1-family chips
  (`TemperatureSensor.available()`). Key meanings change between chip
  generations, so M2 and later get only the general sensors until someone maps
  them on real hardware. To see what a Mac reports, enumerate the SMC keys
  starting with `T`.
- Names follow the mapping other fan utilities use; Apple does not document it.
  Binned chips report keys for cores they don't have (an 8-core M1 Pro reports
  8 performance-core keys for 6 cores), so the app lists as many as
  `hw.perflevel0/1.physicalcpu` says exist.
- A sensor is listed only if it reads 0–130 °C at launch.

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

## Git and GitHub

- The repository is `vipinsight/fanbar` and has to stay public, or update
  downloads 404.
- This Mac has more than one GitHub account. Run `gh auth switch -u vipinsight`
  before pushing, or the push fails with "Repository not found".
