# Changelog

Every pull request raises the version (`make bump`) and adds a section here for it. When
`development` is merged into `main`, the release takes every section since the last release as
its notes.

## 0.1.6 (2026-11-02)

* The Temperatures list shows each group's average as its main reading, with the hottest sensor
  beside it, the same way as the CPU and GPU readings above it.

## 0.1.5 (2026-11-02)

* With the safety net set to act at any time and run the fans at full speed, a failure to reach
  full speed now hands the fans back to macOS once. It used to try full speed again, and show
  the error again, on every refresh while the Mac stayed hot.

## 0.1.4 (2026-11-02)

* No change in what ThermoTune does. The safety net and the profiles' fan decisions are now
  checked by automated tests, including full-speed trips, the 105 °C backstop and profiles
  ending, so later changes can't quietly break them.

## 0.1.3 (2026-11-02)

* After a full-speed safety trip on fans set by hand, macOS gets the fans back once the Mac has
  cooled down. They used to stay at full speed until changed by hand.
* If full speed fails during a safety trip, the fans go back to macOS instead of ThermoTune
  retrying, and showing the error, on every refresh.
* A per-fan profile from a Mac with more fans set up than this one no longer leaves a fan held at
  its minimum.
* A rule or shortcut this version can't read is skipped, not the whole list, and the saved list
  is kept so the next change can't lose it.
* Errors show in the menu bar panel too, so they're seen when ThermoTune runs from the menu bar
  only.
* Exporting history reports a failure instead of ignoring it.
* The daily log no longer stops for the rest of the day when its file can't be opened.
* Shortcuts and rules no longer switch profiles while the helper is being uninstalled.

## 0.1.2 (2026-10-28)

* A **Fans** menu in the menu bar with Set All Fans to Max, Hand All Fans to macOS and the
  profile picker, and **Help › ThermoTune Help**, which opens the README.
* Deleting a profile, or restoring the default profiles, asks first: neither can be undone.
* The buttons above the fans and temperatures are regular buttons rather than links.
* The menu bar panel says **Settings…** rather than Preferences…, as macOS does, and uses the
  same name for handing the fans back as everywhere else.
* VoiceOver reads each tile at the top of the window as one item, and can open a sensor
  group's breakdown from its count.
* Fixed "Colour by temperature", the one British spelling left in English.

## 0.1.1 (2026-10-28)

The first release, as a universal DMG for macOS 15 and later. It's tested on an M3 Pro MacBook
Pro; Intel Macs are supported in the code but untested.

* CPU and GPU temperatures from every sensor the Mac has, with readable sensor names, a chart of
  the last 1 to 60 minutes, and macOS's thermal pressure.
* Each fan on Auto, Manual or Max, or every fan at once with All Max and All Auto.
* Profiles: System Automatic, Fixed Speed, Full Speed, and Temperature Curves with as many
  points as you like, following the CPU, the GPU, the hotter of the two or any single sensor.
  Profiles can differ per fan, and fans ramp up quickly and down gently.
* A safety net that hands the fans back to macOS, or runs them at full speed, when the Mac stays
  too hot. Even switched off, it hands them back at 105 °C.
* Rules that switch profiles on battery, on the power adapter, while an app is running or when a
  temperature is high, and global keyboard shortcuts.
* Notifications when the safety net steps in, a fan isn't spinning, macOS slows the Mac to cool
  it, or a temperature stays high.
* A menu bar item with the temperature, fan speed or both, optionally coloured and with a
  10-minute graph. ThermoTune can run from the menu bar only.
* History as CSV, and an optional daily log file.
* Profiles export and import as JSON.
* English and German.
* Fans are handed back to macOS when ThermoTune quits, including when it's stopped with `kill`.
