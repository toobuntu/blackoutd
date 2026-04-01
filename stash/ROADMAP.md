# Roadmap

## v0.2 — Stability
- [ ] Mach port presence detection (replaces launchctl print parsing)
- [ ] Non-technical user launcher (Blackout stub app in /Applications)
- [ ] `make clean; make; make reinstall` dev cycle fully working without interaction
- [ ] Verified SIGKILL recovery path documented in onboarding

## v0.3 — Display control
- [ ] F1/F2 brightness control for external display when built-in is blacked out
- [ ] Optional ALS-based brightness sync (built-in ambient sensor → external)
- [ ] Keyboard backlight toggle option

## v0.4 — UX
- [ ] Click menu bar icon to toggle blackout; right-click for options menu
- [ ] Second-launch highlights menu bar icon and opens menu
- [ ] FaceTime mode: built-in shows solid white at full brightness instead of black

## v1.0 — Distribution
- [ ] Bundle ID `com.github.toobuntu.blackoutd`
- [ ] Homebrew formula
- [ ] `.pkg` installer for non-technical users
- [ ] Signed with Developer ID (if Apple Developer Program enrolled)

## Future / under consideration
- SMAppService migration if packaged as Blackout.app (see README tech notes)
- Intel Mac support (untested; display ID assumptions may differ)
