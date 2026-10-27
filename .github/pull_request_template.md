## What and why

<!-- What does this change, and why? Link the issue it closes, if any: "Closes #12". -->

## How it was tested

- [ ] `make build` and `make release` succeed with no new warnings
- [ ] Checked in the running app (`make run`); screenshots below if the UI changed (`make shot`)

### If this touches fans or the SMC

- Mac model and macOS version tested on:
- [ ] Fan changes behave as expected on that Mac
- [ ] Ran `make fans-auto` afterwards, and `make helper-status` shows `manual=false` for every fan

### If this touches `Helper/` or `Shared/`

- [ ] The helper still only accepts its documented commands and writes only fan keys
- [ ] I understand users will be asked for their password again to update the helper

## Screenshots

<!-- Optional. -->
