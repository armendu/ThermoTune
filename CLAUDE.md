# Working on ThermoTune

A SwiftUI macOS app that reads CPU/GPU temperatures and fan speeds straight from the System
Management Controller (SMC), and changes fan speeds through a small setuid-root helper. See
[README.md](README.md) for the user-facing picture and [CONTRIBUTING.md](CONTRIBUTING.md) for
the contributor-facing one; this file is the part neither of them says out loud.

Everything here was measured on an **M3 Pro MacBook Pro (2 fans, 2317–6800 RPM) running
macOS 27**. Intel code paths exist and have never run. A claim about another machine is a guess
until someone with that machine confirms it.

## How work happens here

**Work on `development`; `main` is what ships.** `main` is protected, changes arrive by pull
request, and the `build` check has to be green before one can merge. It is also the only branch
CI builds on push.

```
development  →  pull request  →  CI  →  main
```

Pushing to `development` deliberately spends no CI run. What matters about a commit there is
whether it survives the pull request, which is where the build runs.

Two things about that protection are worth knowing rather than discovering. **Admins bypass
it.** `enforce_admins` is off, so a direct push to `main` from the repository owner still goes
through, git prints `Bypassed rule violations` and does it anyway. The rule is a guard rail for
the normal path, not a lock. And **`build` is the only required check.**

**No AI attribution.** Commits and pull requests carry no `Co-Authored-By: Claude` trailer and
no "Generated with Claude Code" line. The trailer makes GitHub list Claude as a contributor,
and the owner has asked for that not to happen. This overrides any default that says otherwise.

### Commit messages

**[Conventional Commits](https://www.conventionalcommits.org).**

```
type(scope): summary in the imperative, lower case, no full stop
```

`type` is one of **feat, fix, docs, test, build, ci, refactor, perf, chore, revert**. `scope` is
the part of the repo it lands in, **smc, helper, app, ui, build, ci**, and is left off when a
change spans everything. Keep the subject under about 72 characters.

| Scope | Covers |
|---|---|
| `smc` | `Shared/`: the SMC client, fan reads and writes, sensor discovery |
| `helper` | `Helper/` and `HelperInstaller.swift`: anything that runs as root or installs it |
| `app` | `ThermoTune/Model`: polling, state, profiles, preferences |
| `ui` | `ThermoTune/Views` |

```
fix(smc): wait for the 0x82 hand-over before giving up on manual mode
feat(app): temperature-curve profiles
docs: explain the helper's install path in the README
```

**A body is for *why*, and only when why is not obvious.** A one-line change does not need one;
a decision, a trap, or a bug whose cause is not visible in the diff does. What the change does
is already in the diff.

`git config commit.template .gitmessage` puts the format in front of you while you write.

## Commands

Xcode is only needed for its toolchain; everything runs from the Makefile, and `make` on its
own lists every target.

```sh
make build          # Debug build, a compile check
make release        # Release build, what CI builds and what users run
make run            # Release build, then launch it
make shot           # Release build, launch, PNGs of its windows in build/screenshots
make shot TAB=profiles   # …plus Preferences on that tab (general | profiles | menuBar | advanced | about)
make helper-status  # what the installed helper reports for each fan
make fans-auto      # hand every fan back to macOS, whatever state they were left in
```

**`run` and `shot` build Release on purpose.** See the helper-comparison trap below.

## Layout

```
Shared/       SMC client (SMC.swift) and fan/sensor logic (Fans.swift). Compiled into BOTH targets.
Helper/       main.swift of ThermoTuneHelper, the setuid-root tool. The only code that writes the SMC.
ThermoTune/   the app: Model/ (HardwareMonitor, profiles, preferences, HelperInstaller), Views/
docs/         README images
ThermoTune.xcodeproj   hand-written; uses synchronized folders
```

**`Shared/` is linked into a binary that runs as root, and must stay small and boring.**
Foundation and IOKit only: no SwiftUI, no AppKit, no networking, no dependencies. Everything
added there is attack surface on a setuid binary. If something in `Shared/` seems to need UI
types, the part that needs them belongs in `ThermoTune/`.

**The helper's command list is the security boundary.** `status`, `set <fan> <rpm>`,
`auto <fan>`, `max-all`, `auto-all`, nothing else, every argument validated, RPM clamped to the
fan's own min/max, and only fan keys ever written. Any local user can run it, that is the
trade for not asking for a password on every change. A new command, a new key it may write, or
a looser parse is a security change and is reviewed as one. Never add a command that writes an
arbitrary key or value.

**The project uses synchronized folders** (`PBXFileSystemSynchronizedRootGroup`, object version
77). A file dropped into `ThermoTune/`, `Helper/` or `Shared/` is part of the build with no
pbxproj edit; there are no per-file references to keep in sync. The pbxproj was written by
hand, its object IDs are the readable `A1000000000000000000Fxxx` series. After editing it,
`xcodebuild -list -project ThermoTune.xcodeproj` is the quickest way to know it still parses.

## The build

| | Value | Why |
|---|---|---|
| Xcode | 16 or newer (developed on 27) | synchronized folders need object version 77 |
| Deployment target | macOS 15.0 | `symbolEffect(.rotate)` |
| Swift language mode | 5 | `SMC` is not `Sendable`; the monitor opens a second connection off the main thread instead of sharing one |
| App Sandbox | off | IOKit access to `AppleSMC` is not possible from a sandbox |
| Hardened runtime | off | |
| Signing | ad hoc (`-`) | nobody has a Developer ID in this repo; there is no release pipeline |

The helper is embedded by the **Embed Helper** copy-files phase into `Contents/MacOS/`, and the
app finds it with `Bundle.main.url(forAuxiliaryExecutable:)`.

`xcodebuild` prints `IDERunDestination: Supported platforms for the buildables in the current
scheme is empty` on every build. It comes from the auto-generated scheme and changes nothing.

## Things that will bite you

Most of these fail *silently*: no crash, no error, a wrong number on screen or a fan doing the
wrong thing. Several cost real time to find.

**The SMC packet is a raw 80-byte buffer at C offsets, and must stay one.** The kernel expects
`SMCKeyData_t`. Swift lays out a nested struct by its *size*, not its stride, so a Swift mirror
of the C struct puts every field after `keyInfo` three bytes early. Every SMC tool written in
Swift either pads by hand or does what `SMC.swift` does. Don't "tidy" the buffer into a struct.

**`.map(Double.init)` on an integer picks `Double(bitPattern:)`.** It compiles, it runs, and
`#KEY` (2422 keys) decodes as `1.2e-320`, so key enumeration finds nothing and every integer
reading is garbage. Write the closure: `.map { Double($0) }`.

**Byte order depends on the type.** `flt ` is little-endian. `sp78`, `fpe2`, `fp88` and the
`ui*` types are big-endian. Decoding needs the key's type from `keyInfo`, never a guess from
the key name.

**Manual mode on Apple Silicon needs `Ftst = 1`, and then a wait.** After `Ftst` is set the SMC
answers `F<n>Md` writes with **`0x82`** (bad command) for roughly **5-10 seconds**, measured at
5.9 s and at 8-10 s on this machine. The helper retries only on `0x82`, for up to 20 seconds.
The first switch to Manual or Max is therefore slow, the UI shows a spinner, and helper calls
are **serialized**, because two concurrent unlocks each wait out the hand-over.

**SMC writes apply asynchronously; reading back straight away returns the old value.** This
shipped a real bug: switching a fan to Auto wrote `Md = 0`, then asked "is any fan still
manual?" before the write landed, saw the fan it had just switched, and left `Ftst = 1`. macOS
thermal control stayed off with fans pinned near minimum while the UI said *Auto*. So the
relock decision excludes the fan just written, and the UI holds a requested mode in
`pendingModes` for a grace period instead of trusting the next read.

**`Ftst = 1` suspends thermal control for every fan, not just the one you set.** A fan whose own
mode is automatic is then held at its minimum speed, not managed. `FanInfo` keeps the two facts
apart: `isManual` is the fan's own mode, `isControlUnlocked` is `Ftst`, and
`isSystemControlled` needs both false. They used to be one flag, so after *All Max*, setting one
fan to Auto made it read as manual again and the switch snapped back: there was no visible way
to stop the fans. Now that fan shows Auto with a "held at minimum" note, and *All Auto* is the
way out. Never leave `Ftst = 1` with no fan in manual mode.

**Mode values are not just 0 and 1.** This M3 Pro has reported `F0Md = 3` with its fans stopped
at idle, and `0` while macOS was running them. ThermoTune writes `1` for manual and `0` for
automatic. Manual means `== 1`, not "anything but 0"; whether macOS is in charge is `Ftst == 0`
plus a mode other than 1.

**The `TC*` package sensors read well above the cores, even at idle.** `TCMz` sat at ~72° while
the hottest core read 59°. Counting them made the CPU tile ~14° too hot and would have spun
curve profiles up early. The CPU reading uses the per-core `Tp*`/`Te*` sensors whenever the
machine has them, and falls back to `TC*` only where it doesn't (Intel).

**Most `T*` keys are junk.** Negative values, constant zeros, `ioft` types. Discovery keeps
`flt `/`sp78` keys reading 5…130 °C, once, at launch. A sensor that happens to read outside
that range at launch is never discovered; that trade-off is deliberate.

**Fans on Apple Silicon laptops stop at idle.** They read 0 RPM, below their own 2317 minimum.
Manual speeds can't go below the minimum, so a curve profile keeps fans spinning where macOS
would have stopped them. That is expected, not a bug.

**The helper check compares bytes, so Debug and Release don't match.** `HelperInstaller.state()`
calls the installed helper out of date whenever its bytes differ from the bundled one. The
installed helper normally comes from a Release build, so a Debug app always shows "Update
Helper…". That is why `make run` and `make shot` build Release. It also means **any change to
`Shared/` or `Helper/` makes every user re-enter their password** after updating; say so in the
pull request.

**Quitting must give the fans back.** `applicationWillTerminate` runs `auto-all`, and a SIGTERM
handler routes `kill`/`pkill` through it, because SIGTERM otherwise skips it, which is exactly
how a test once left a fan in manual mode. SIGKILL and crashes can't be caught: `make
fans-auto` is the recovery. The preference "Restore automatic fan control when quitting" can
turn this off for users who want a profile to outlive the app. Quitting first waits for a helper
call still running: it would otherwise land after the decision, and since its writes apply
asynchronously, the fans read straight after it can still look automatic.

**Whenever ThermoTune stops driving the fans, they go back to macOS.** `profileHoldsFans` marks
a Fixed, Curve or Max profile in charge. If that profile ends by any route other than the user
taking a fan over (None, deleted, Restore Defaults, a helper error), the next refresh sends
`auto-all`; otherwise the fans stay at the profile's last speed with thermal control suspended.
Fixed and Curve profiles also go to full speed past 95 °C, and hand back to macOS when no
temperature can be read. Uninstall blocks helper calls, waits for the queue, and hands the fans
back before removing the helper, refusing if it can't: once the helper is gone, nothing can. A
new way for a profile to end goes through this, not around it.

**A profile can't leave one fan on Auto while another is manual.** `Ftst = 1` suspends thermal
control for every fan, so the "automatic" one would just be held at its minimum. Per-fan
settings therefore offer only Fixed, Curve and Max (`FanBehavior.perFanKinds`).

**Profile speed changes are smoothed in the app, not the helper.** `smoothedRPM` ramps towards
the curve's speed (fast up, slow down) and makes a falling temperature drop 3° before fans slow.
The ramp state resets whenever a profile ends or the user takes a fan over.

**Saved profiles are migrated on read.** Before per-fan settings, a profile's fields sat at the
top level with a two-point curve as `lowTemperature`/`highTemperature`; `FanProfile.init(from:)`
still reads that shape, from UserDefaults and from version 1 export files.

**Default profiles are saved on first launch.** `FanProfile.defaults` mints fresh UUIDs per
process, so unsaved defaults had new IDs every launch and an active default profile was
forgotten on restart.

**Other fan-control apps fight over the same keys.** Macs Fan Control is installed on the
development machine with its own helper. Quit it before testing, or two apps take turns
overwriting each other's settings.

**Agents can't take normal screenshots here.** There is no Screen Recording permission:
`screencapture -l` fails with "could not create image from window", and `CGWindowList` hides
window titles. `make shot` works around it, the app renders its own windows with
`cacheDisplay` (`WindowSnapshot.swift`, triggered by environment variables). Opening
Preferences that way goes through the ⌘, menu item; sending `showSettingsWindow:` through the
responder chain does nothing for SwiftUI's Settings scene. AppleScript to System Events is not
authorized either.

**Never `pkill ThermoTune` while testing.** The owner is often running the app at the same time,
and `pkill -x ThermoTune` quits their copy too. It looked like a bug: they picked a profile and
the app "just quit", because `make shot` began with exactly that pkill. `make shot` now starts
its own copy, stops only that one by PID, and in snapshot mode never writes the fans, so it can
run beside theirs. Stop anything else you launch by its PID.

**Launch at login is untested.** `SMAppService.mainApp.register()` may refuse an ad-hoc signed
app; the toggle surfaces whatever error it returns.

## Testing

There is no automated suite yet. The first ones worth writing are `SMC.decode`/`SMC.encode` for
every type (the `Double.init` bug would have been caught there) and
`FanProfile.speedFraction`; neither needs hardware or root.

Until then, a change is verified by:

| What | How |
|---|---|
| it compiles | `make build` and `make release` |
| it looks right | `make shot`, then read the PNGs |
| fan writes work | run the installed helper directly: `make helper-status`, then `set 0 3000`, `max-all`, `auto 0`, `auto-all` |
| fans were given back | `make fans-auto`; every fan reports `manual=false unlocked=false` |

**Always end hardware testing with `make fans-auto` and check the result.** This is somebody's
actual laptop. A fan left in manual mode, or `Ftst` left at 1, means macOS is no longer
protecting it from heat.

## CI

`.github/workflows/ci.yml` runs `make build` and `make release` on a macOS runner for every pull
request and every push to `main`. No hardware is involved; CI proves the project compiles, not
that fans move.

Actions are pinned to commit SHAs, not tags: a tag is mutable, so `@v5` is a promise the
action's owner can rewrite. The trailing comment is the human-readable version. Dependabot
keeps them current.

## Style

Explain *why* in comments, not *what*; the code already says what. A comment that survives is
one that records a decision or a trap, not one that narrates the line below it.

Match the surrounding code: naming, comment density, idiom. Native SwiftUI and AppKit controls
over custom ones; `Form` with `.formStyle(.grouped)` for anything that looks like settings.

No third-party dependencies. The app doesn't need any, and the helper runs as root, so it never
gets any.
