# Releasing Breeze

## Before the first release (one-time)

| | What | Where |
|---|---|---|
| ☐ | Pick the final product name and check it isn't taken (App Store, Google, trademark search) | `AppConfig.appName`, `Info.plist`, `PRODUCT_NAME` |
| ☐ | Join the Apple Developer Program (~$99/year) and create a **Developer ID Application** certificate | developer.apple.com → Certificates |
| ☐ | Store notarization credentials: `xcrun notarytool store-credentials breeze-notary --apple-id … --team-id …` | Terminal |
| ☐ | Set the Gumroad product to pay-what-you-want (₹0+) and turn off license keys, so it works as a tip jar | Gumroad |
| ☐ | Set support email, website, privacy/terms, source, tip and update feed URLs | `Sources/Breeze/Core/AppConfig.swift` |
| ☐ | Publish `docs/PRIVACY.md` and `docs/EULA.md` on your site (GitHub Pages works) | your site |

## Every release

1. Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`
   (the build number must always go up; the update checker compares it).
2. Test on a second Mac or a fresh user account (see the checklist below).
3. `TEAM_ID=XXXXXXXXXX DOWNLOAD_BASE=https://… ./scripts/release.sh`
4. Upload `build/release/<version>/Breeze-<version>.dmg` to a GitHub Release and your download host.
5. Edit the notes in `appcast.json`, then publish it at `AppConfig.updateFeedURL`.
   Existing users see the update within a day.

## Test checklist (do it on a clean account)

- [ ] First launch: setup screen appears, Full Disk Access is detected without relaunching
- [ ] Smart Scan → Clean: totals match, Cleaning History shows every item
- [ ] Cleaning more than 1 GB works with no upgrade prompt
- [ ] Settings → Support Breeze: Source Code and Leave a Tip open the right pages
- [ ] Uninstaller removes an app + leftovers (try a small app like a text editor)
- [ ] Dev Cleanup on a project with `node_modules`; `npm install` restores it
- [ ] Duplicates keeps exactly one copy per group
- [ ] Organizer → Undo restores every file
- [ ] Privacy: quitting a browser works; bookmarks and passwords are untouched
- [ ] Security Check runs without admin prompts
- [ ] Updater lists Homebrew casks (if installed) and Sparkle apps
- [ ] Menu bar panel, low-disk alert and weekly check-up notification
- [ ] Launch at login toggles on and off
- [ ] Quit and relaunch: settings persist; no crash banner appears
- [ ] macOS 14, 15 and 26; Apple Silicon and (if possible) Intel
