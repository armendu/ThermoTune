# ThermoTune

A SwiftUI macOS app that shows your CPU and GPU temperatures and lets you set fan speeds by hand. It reads from the System Management Controller (SMC) directly.

- **Temperatures**: finds every SMC temperature sensor on its own. Shows the max and average for the CPU (split into performance and efficiency cores on Apple Silicon) and for the GPU, plus a 5-minute history chart. You can expand each group to see every individual sensor.
- **Fans**: shows the current, minimum and maximum RPM of each fan. You can switch any fan between Automatic and Manual, and choose a target RPM with a slider.
- **Profiles**: named fan behaviors that apply to every fan. Each profile is one of four kinds: *System Automatic* (macOS manages the fans), *Fixed Speed* (a percentage of each fan's speed range), *Temperature Curve* (fan speed rises from minimum to maximum between two temperatures of the CPU, the GPU or whichever is hotter) or *Full Speed*. ThermoTune comes with Automatic, Balanced, Cool and Full Speed. You choose the active profile from the Fans header or the menu bar. Changing a fan by hand turns the active profile off.
- **Preferences (⌘,)**:
  - **General**: launch at login, restore automatic control on quit, show or hide the menu bar item and choose which temperature it shows, °C or °F, refresh rate.
  - **Profiles**: create, duplicate, edit and delete profiles, with a live preview of each temperature curve.
  - **Helper**: install, update or uninstall the helper tool.
- **Menu bar**: shows a temperature in the menu bar, with a popover that has a summary, the profile picker and a Max button. The app keeps running there after you close the window.

Built and tested on Apple Silicon (M3 Pro). Intel SMC key formats (`sp78`, `fpe2`, `FS! `) are handled in the code but have not been tested.

## Build

Open `ThermoTune.xcodeproj` in Xcode and run the **ThermoTune** scheme, or from the command line:

```sh
xcodebuild -project ThermoTune.xcodeproj -scheme ThermoTune -configuration Release -derivedDataPath build build
open build/Build/Products/Release/ThermoTune.app
```

The app is not sandboxed, because it needs direct IOKit access to `AppleSMC`. It is signed ad hoc so it runs locally.

## How fan control works

Any user can read the SMC, but only root can write to it. The app therefore includes a small command-line tool, `ThermoTuneHelper`. The first time you click **Install Helper…**, macOS asks for your administrator password and the app copies the tool to `/Library/PrivilegedHelperTools/com.armend.ThermoTune.Helper` as setuid root. After that, changing fan speeds does not ask for a password again.

The helper accepts only these commands, and it only ever writes fan keys:

```
ThermoTuneHelper status
ThermoTuneHelper set <fan> <rpm>   # rpm is clamped to the fan's min/max
ThermoTuneHelper auto <fan>
ThermoTuneHelper auto-all
```

On Apple Silicon, manual mode is enabled by setting the `Ftst` unlock key, then `F<n>Md = 1` and `F<n>Tg = <rpm>`. Switching back to automatic clears both keys.

After `Ftst` is set, the SMC rejects the mode change with error `0x82` for roughly 5–10 seconds (measured on an M3 Pro), so the first switch to Manual or Max takes that long. While `Ftst` is set, macOS's thermal control is paused for *every* fan, so the app shows every fan as manual until the last one is switched back to Automatic.

**Safety:** whenever ThermoTune quits, all fans go back to automatic control. This includes a quit from `kill` (SIGTERM). You can turn this off in Preferences. A Fixed or Curve profile that was active when you quit is applied again on the next launch. To remove the helper, use **Preferences › Helper › Uninstall Helper…**.

## Layout

| Path | Contents |
| --- | --- |
| `Shared/SMC.swift` | AppleSMC client: raw packet I/O, key enumeration, value decoding and encoding |
| `Shared/Fans.swift` | Fan reads and writes, and temperature-key discovery (used by both targets) |
| `Helper/main.swift` | The privileged helper tool |
| `ThermoTune/Model` | `HardwareMonitor` (polling, state and the profile engine), `FanProfile` and `ProfileStore`, `HelperInstaller`, preference keys, sensor model |
| `ThermoTune/Views` | SwiftUI views for the main window, Preferences and the menu bar |
