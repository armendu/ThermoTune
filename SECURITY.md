# Security policy

ThermoTune installs a helper tool, `ThermoTuneHelper`, as **setuid root** at
`/Library/PrivilegedHelperTools/com.armend.ThermoTune.Helper`, so fan speeds can be changed
without a password prompt each time. That makes the helper the part of this project where a bug
matters most.

## What the helper is supposed to allow

Any local user can run the helper. By design it can only:

- report fan status (`status`)
- set one fan to a speed, clamped to that fan's own minimum and maximum (`set <fan> <rpm>`)
- set every fan to maximum speed (`max-all`)
- hand one fan, or every fan, back to macOS (`auto <fan>`, `auto-all`)

It writes only fan-related SMC keys (`F<n>Md`, `F<n>Tg`, `Ftst`, and `FS! ` on Intel Macs).

Anything beyond that is a vulnerability: writing other SMC keys, writing values outside the
validated ranges, running code or reading or writing files as root, or affecting anything other
than fans. So is a way to make the app install something other than its own bundled helper.

## Reporting a vulnerability

**Please don't open a public issue.** Report it privately through GitHub's
[private vulnerability reporting](https://github.com/armendu/ThermoTune/security/advisories/new).

Please include:

- what an attacker can do, and what access they need to start with
- steps or a proof of concept to reproduce it
- your Mac model, chip, macOS version, and the ThermoTune commit you tested

You should get an acknowledgement within a week. Once a fix is ready, the advisory will be
published and you'll be credited unless you'd rather not be.

## Supported versions

Only the latest commit on `main` is supported. There are no maintained release branches.

## Removing the helper

To remove the helper, use **Preferences › Helper › Uninstall Helper…**, or run:

```sh
sudo rm /Library/PrivilegedHelperTools/com.armend.ThermoTune.Helper
```
