# Changelog

Every pull request raises the version (`make bump`) and adds a section here for it. When
`development` is merged into `main`, the release takes every section since the last release as
its notes.

## 0.1.10 (2026-11-05)

* With no profile running, finding the fan unlock on with no fan in manual mode now waits 25
  seconds before handing the fans back to macOS. Acting at once fought other fan apps while they
  switched to manual, sent a second hand-back after every one of ThermoTune's own, and retried
  on every refresh when the hand-back failed.
* Picking a profile during a full-speed safety trip no longer slows the fans before the Mac has
  cooled down.
* A full-speed safety trip ends, handing the fans back, if every temperature stops reading.
  It used to hold the fans at full speed with nothing left to end it.
* A helper error from a profile's speed change no longer switches off a profile picked after it.
* Keyboard shortcuts stay off while one is being recorded, even when another is cleared
  meanwhile; the recorded keypress used to run its action instead.

## 0.1.9 (2026-11-05)

* The menu bar panel's Profile row highlights under the pointer like the rows around it. It
  opens the list of profiles as a menu, with a checkmark on the active one.

## 0.1.8 (2026-11-04)

* Fans are handed back to macOS if ThermoTune finds the fan unlock left on with no fan in manual
  mode. Switching two fans to Auto in quick succession could leave it that way, with every fan
  held at its minimum.
* Quitting hands the fans back even when it can't read them, instead of assuming they're fine.
* A fan whose maximum speed can't be read no longer counts as already at full speed, which kept
  the safety net from stepping in.
* A full-speed safety trip's banner goes away once the trip ends.
* Only one keyboard shortcut can be recorded at a time; a second one used to get stuck.
* Removing a point from a curve can no longer crash the profile editor.
* The security policy's removal steps hand the fans back before deleting the helper.

## 0.1.7 (2026-11-03)

* Fan control on M5 Macs that spell the fan mode key differently: every fan change on them used
  to fail. Based on how the open-source Stats app drives them; not yet confirmed on an M5.
* **Updating asks for your administrator password once:** the source files moved, which changes
  the helper's bytes even though its code is the same.

## 0.1.6 (2026-11-02)

* The Temperatures list shows each group's average as its main reading, with the hottest sensor
  beside it, the same way as the CPU and GPU readings above it. The menu bar panel's CPU and GPU
  rows lead with the average too.
* The menu bar panel's actions (Open ThermoTune, Settings, Quit and the fan commands) no longer
  look unavailable. They're drawn like the items in macOS's own menu bar panels, highlight under
  the pointer, and show their keyboard shortcuts.

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
