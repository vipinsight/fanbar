# FanBar

Native macOS menu bar fan utility.

FanBar installs a small root launch helper after the first fan-control action. macOS asks for administrator approval once; later presets use a local Unix socket and do not prompt again. The helper accepts only bounded RPM and Automatic commands.

Status item shows core temperature and current fan RPM stacked. Menu presets:

- Automatic
- 1000 rpm
- 2000 rpm
- 4000 rpm
- 6000 rpm

## Build

```sh
cd fanbar
./build-app.sh
open FanBar.app
```

Fan control uses Apple SMC keys through IOKit. Hardware support varies by Mac model and macOS version. Failed SMC reads show `--`; app restores Automatic mode on quit.
