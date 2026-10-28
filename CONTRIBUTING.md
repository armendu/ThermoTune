# Contributing to ThermoTune

Thanks for helping. ThermoTune changes how a Mac cools itself, so the bar for changes that touch
fans is "tested on real hardware and handed back to macOS afterwards". Everything else is
ordinary.

## Before you start

- **Bugs and small fixes:** open a pull request directly. If the bug isn't obvious, an issue
  first with your Mac model and macOS version helps.
- **New features:** open an issue (or comment on an existing one) before writing much code, so
  we can agree on the shape first.
- **Security problems:** don't open a public issue. See [SECURITY.md](SECURITY.md).

## Setting up

You need a Mac running macOS 15 or newer with Xcode 16 or newer installed.

```sh
git clone https://github.com/armendu/ThermoTune.git
cd ThermoTune
git checkout development
git config commit.template .gitmessage
make run
```

`make` on its own lists every target. Changing fan speeds needs the helper tool: click
**Install Helper…** in the app (it asks for your administrator password once).

## Branches and pull requests

```
development  →  pull request  →  CI  →  main
```

- Branch from `development` (or work on it directly if you have push access) and open your pull
  request **into `main`**.
- `main` is protected: it needs a pull request and a green `build` check.
- Keep a pull request to one change. Two unrelated fixes are two pull requests.
- Fill in the pull request template, especially the hardware section.

## Commit messages

[Conventional Commits](https://www.conventionalcommits.org):

```
type(scope): summary in the imperative, lower case, no full stop
```

- **Types:** feat, fix, docs, test, build, ci, refactor, perf, chore, revert
- **Scopes:** `smc` (Shared/), `helper` (Helper/ and the installer), `app` (ThermoTune/Model),
  `ui` (ThermoTune/Views), `build`, `ci`. Leave the scope off if a change spans everything.
- Keep the subject under about 72 characters.
- Use the body to explain *why*, when that isn't obvious from the diff.

```
fix(smc): wait for the 0x82 hand-over before giving up on manual mode
feat(app): temperature-curve profiles
```

## Testing your change

1. `make build` and `make release` both succeed with no new warnings, and `make test` passes. The
   tests need no special hardware; add one for logic you change where you can.
2. `make bump` to raise the version. Every pull request does, so the version in the window title
   says which build someone is running; CI checks it.
3. `make run` and look at what you changed. `make shot` saves screenshots of the app's windows
   to `build/screenshots/`, handy for the pull request description.
4. **If your change touches fans**, try it on your own Mac and say which model in the pull
   request. Afterwards, run `make fans-auto` and check that `make helper-status` shows every fan
   with `manual=false unlocked=false`.

Never leave a fan in manual mode after testing. While a fan is manual, macOS isn't managing that
Mac's temperature.

## Changes to the helper or `Shared/`

The helper runs as root on users' machines, so changes there get extra scrutiny:

- `Shared/` is compiled into the helper. Keep it to Foundation and IOKit: no UI frameworks and no
  third-party dependencies.
- The helper only accepts `status`, `set`, `auto`, `max-all` and `auto-all`, validates every
  argument, and writes only fan keys. Adding a command, a key it may write, or loosening an
  argument check is a security change; explain why in the pull request.
- Any change to `Shared/` or `Helper/` changes the helper binary, so every user will be asked
  for their password again after updating. Mention it in the pull request.

## Translations

ThermoTune ships in English and German. The German was written without a native speaker's
review, so corrections are very welcome, and so are new languages: open
`ThermoTune/Localizable.xcstrings` in Xcode, add a language, and fill in the column. CLAUDE.md
explains how to keep the catalog in step with the code.

## Code style

- Match the code around you: naming, structure, comment density.
- Comments explain *why*, not *what*.
- Prefer native SwiftUI/AppKit controls; use `Form` with `.formStyle(.grouped)` for settings-like
  screens.
- No third-party dependencies.

[CLAUDE.md](CLAUDE.md) lists the non-obvious traps in this codebase: SMC byte layouts, the
`Ftst` unlock delay, asynchronous writes and so on. It's worth reading before touching
`Shared/`.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind.

## License

By contributing, you agree that your contributions will be licensed under the
[MIT License](LICENSE).
