# Claude Usage Bar — build spec

This document specifies the app completely enough to rebuild it from an empty folder. To have Claude Code build it, run this in an empty directory that contains only this file:

```sh
claude "Build the macOS app described in SPEC.md. Follow it exactly, then run the tests and ./build.sh --install."
```

## 1. What it is

A native macOS menu bar app that shows how much of your Claude subscription limits you have used: the rolling **5-hour session** limit and the **weekly** limit. It reads the numbers from Anthropic's usage endpoint using the OAuth token that Claude Code already stores after `claude` login. It shows nothing from local files.

Non-goals, on purpose:

- **No login of its own.** Anthropic's Consumer Terms allow subscription OAuth only in Claude Code and claude.ai, so the app never runs an OAuth flow, never impersonates Claude Code's OAuth client, and never refreshes the token (refreshing would rotate Claude Code's refresh token and log it out).
- **No local transcript parsing, no history, no charts, no notifications.**
- **No per-model rows.** Only session and weekly are shown.

## 2. Tech and layout

- Swift 5.10 language mode, SwiftPM package, macOS 14+, no third-party dependencies.
- `Package.swift`: one `executableTarget` `ClaudeUsageBar` (`Sources/ClaudeUsageBar`) and one `testTarget` `ClaudeUsageBarTests` (`Tests/ClaudeUsageBarTests`) that uses `@testable import ClaudeUsageBar` and XCTest.
- Files:
  - `App.swift`: `@main` SwiftUI `App` with an `NSApplicationDelegateAdaptor`; status item, popover, menu bar image.
  - `UsageAPI.swift`: models, pace logic, credential reading, API client, decoding.
  - `UsageStore.swift`: `@MainActor @Observable` state, settings, refresh loop, `Format` helpers.
  - `Views.swift`: all SwiftUI views.
  - `Updater.swift`: GitHub Releases self-update.
  - `DebugRender.swift`: `#if DEBUG` only; renders screenshots with sample data.
- App bundle is assembled by `build.sh` (no Xcode project). `LSUIElement = true` (no Dock icon).

## 3. Data source

### 3.1 Credentials

Claude Code stores JSON like `{"claudeAiOauth": {"accessToken": "…", "expiresAt": <ms epoch>, "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x"}, …}`.

Lookup order:

1. macOS Keychain, generic password, service `Claude Code-credentials`.
   - First list matching items with `SecItemCopyMatching` returning **attributes only** (`kSecMatchLimitAll`, `kSecReturnAttributes`). This never prompts.
   - For each account, read the secret by running `/usr/bin/security find-generic-password -s "Claude Code-credentials" -a <account> -w`. Claude Code writes the item with that tool, so it is on the item's access list and reading through it never shows a keychain prompt, even after rebuilds or after Claude Code refreshes its token. Do **not** read the secret with `SecItemCopyMatching(kSecReturnData)`: that prompts on every rebuild and every token refresh.
   - Use the first item whose JSON has `claudeAiOauth.accessToken`.
2. `~/.claude/.credentials.json` with the same JSON shape.

Cache the credentials in memory. Re-read only when the cached token is past `expiresAt`, or after a 401/403 (Claude Code may have refreshed it). Read on a background task.

Plan badge: `rateLimitTier` containing `20x` → "Max 20x", `5x` → "Max 5x", otherwise `subscriptionType` capitalized ("Pro"), otherwise hidden.

### 3.2 Request

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-beta: oauth-2025-04-20
Accept: application/json
User-Agent: ClaudeUsageBar/<version>
```

This endpoint is undocumented and may change. Status handling: 200 → decode; 401/403 → "Token rejected (401). Use `claude` once to refresh your login." and drop cached credentials; 429 → rate limited (read `Retry-After` seconds if present); anything else → "Usage endpoint returned HTTP <code>."

### 3.3 Response (only what the app reads)

```json
{
  "five_hour": { "utilization": 18.0, "resets_at": "2026-09-24T18:10:00.428610+00:00" },
  "seven_day": { "utilization": 12.0, "resets_at": "2026-09-28T23:00:00.428677+00:00" }
}
```

- `utilization` is a **percentage** (0–100), not a fraction.
- `resets_at` is ISO 8601, with or without fractional seconds; may be null.
- Either object may be null or missing → that window is absent.
- Everything else in the response is ignored.

## 4. Pace

For a window with duration `D` (5 h for session, 7 d for weekly) and reset time `R`:

- `elapsed = clamp(1 − (R − now) / D, 0, 1)`.
- If `utilization ≥ 100` → **reached**.
- If `elapsed ≤ 0.03` → no pace (too early to tell).
- `projected = utilization / (elapsed × 100)` — usage at reset as a multiple of the limit.
- `runsOutIn = min((100 − utilization) / (utilization / (elapsed × D)), R − now)`.

| projected | pace | SF Symbol | label |
|---|---|---|---|
| < 0.75 | under | `tortoise.fill` | "Under pace" |
| ≤ 1.0 | on pace | `dog.fill` | "On pace" |
| ≤ 1.5 | ahead | `hare.fill` | "Out in ~<runsOutIn>" |
| > 1.5 | way ahead | `bird.fill` | "Out in ~<runsOutIn>" |
| (≥100% used) | reached | `exclamationmark.octagon.fill` | "Limit reached" |

Severity for picking the most urgent: under 0, on pace 1, ahead 2, way ahead 3, reached 4. Ahead and above count as a warning. Each pace has a tooltip explaining it (e.g. "Ahead of pace: at this rate you'll hit the limit before it resets.").

## 5. Menu bar

- `NSStatusItem` (variable length) whose button image is one **template** `NSImage`, 18 pt tall, drawn from parts left to right:
  - For each shown window: its symbol (`clock.fill` session, `calendar` weekly; SF Symbol 12 pt semibold), 3 pt gap, percentage text (monospaced-digit system font 13 pt medium). 8 pt gap between windows.
  - Then, if enabled, 6 pt gap and **one** pace animal: the most severe pace among the shown windows.
  - Before the first successful fetch: `sparkle` symbol, 3 pt, "–".
- Percent text: integer percent, except values below 10 that aren't whole show one decimal ("3.5%").
- Re-render whenever observed store state changes (`withObservationTracking`, re-arm in `onChange`).
- Clicking the item toggles an `NSPopover` with `behavior = .transient` (closes on any outside click), hosting the SwiftUI popover via `NSHostingController` with `sizingOptions = .preferredContentSize`. Activate the app and make the popover window key when showing it. When the popover closes, collapse the settings section.

## 6. Popover

Width 330 pt (the footer must fit inside the 14 pt insets without overflowing). Side inset 14 pt. Icons use a 16 pt wide centered column with a 6 pt gap to their text.

Colors (light / dark): brand coral `#D97857` for the header sparkle only; warning `#D48A00` / `#FAB219`; critical `#D03B3B` / `#E66767`. Everything else uses system primary/secondary label colors. Status colors are always paired with an icon and a label.

Top to bottom:

1. **Header**, 40 pt tall: `sparkle` (14 pt, coral) · plan name (13 pt semibold; "Claude" if unknown) · spacer · optional update pill (see §8) · "Updated just now" / "Updated 3m ago" (11 pt secondary) · refresh button (`arrow.clockwise` 11 pt, spins while refreshing, ⌘R). Then a divider.
2. **Body**, padded 14 pt, 16 pt between items:
   - Optional error note: warning triangle + message, 12 pt, on a warning-tinted rounded rectangle (radius 8).
   - "Loading…" with a small spinner before the first data.
   - One **limit row** per window (session, then weekly).
3. **Settings** (only when open), below a divider, padded 14 pt.
4. **Footer**, 36 pt tall, faint tinted background, top divider: "Open claude.ai ↗" (opens `https://claude.ai/settings/usage`) · spacer · "Settings ⌘," (reads "Done" when open) · "Quit ⌘Q". Shortcut keys are drawn as 16×16 keycaps with a faint fill. All footer text 12 pt medium, single line; 12 pt between footer items.

**Limit row** (vertical stack, 7 pt spacing):

- Title line, 24 pt tall, centered vertically: icon (12 pt, secondary) · title ("Session" / "Weekly", 13 pt semibold) · subtitle ("5 hours" / "All models", 12 pt secondary) · optional level badge · spacer · percentage as a large number (20 pt semibold rounded, monospaced digits) followed by a smaller "%" (12 pt, secondary).
- Bar, full width, 6 pt tall capsule: track = primary at 9% opacity; fill = primary at 78% below 70%, warning color from 70%, critical from 90% (minimum visible width 6 pt when > 0). A 2 pt wide tick (primary at 45%, 6 pt taller than the bar) marks the elapsed fraction of the window. Tooltip: "Bar: usage · Tick: N% of the window has elapsed".
- Detail line, 11 pt secondary, 3 pt extra space above: "Resets 1:28 PM · 2h 13m" (time only if the reset is today, otherwise weekday + time) · spacer · pace animal + pace label (animal tinted warning color when the pace is a warning). Single line.
- Level badge: at 70–89% a capsule "High" with `exclamationmark.circle.fill`; at ≥ 90% "Near limit" with `exclamationmark.octagon.fill`. 10 pt semibold, tinted background at 15%.

Durations format as "45m", "2h 13m", "4d 7h" (negative → "0m").

**Settings section** (4 pt between rows; each row 22 pt tall: icon · 12 pt label · spacer · control, small control size):

- Heading "Settings" (11 pt semibold secondary).
- Menu bar (`menubar.rectangle`): menu picker — "Session and weekly" (default) / "Session only" / "Weekly only".
- Pace animal in menu bar (`hare`): switch, default on.
- Check every (`arrow.clockwise`): menu picker 2 / 5 (default) / 10 / 15 / 30 min.
- Launch at login (`power`): switch, backed by `SMAppService.mainApp` register/unregister.
- Only when an update repository is configured: Check for updates (`arrow.down.circle`) switch, default on; below it "Version X.Y.Z" + optional status + a "Check now" link button.
- Heading "Pace", then a legend (3 pt spacing, 11 pt): each animal with its name and meaning — "Under pace — ends below 75%", "On pace — ends at 75–100%", "Ahead — runs out before reset", "Way ahead — over 1.5× the limit".

Settings persist in `UserDefaults` (`menuDisplay`, `showPaceInMenuBar`, `refreshMinutes`, `checkForUpdates`).

## 7. Refresh loop

- On start, fetch immediately. Then wake every 30 s: update `now` (drives countdowns), and fetch if `refreshMinutes` have passed since the last attempt and no backoff is active.
- Manual refresh fetches immediately unless in backoff (then show "Rate limited — next try in X.").
- On 429: `backoff = min(max(backoff × 2, 120 s), 1800 s)`; wait `Retry-After` if given, else `backoff`. Show "Rate limited by Anthropic — retrying in X." and keep showing the last good data.
- On success: clear the error and reset backoff.

## 8. Self-update

- `build.sh` writes `UpdateRepository` (`owner/repo`) into Info.plist. Empty → updates disabled and their settings hidden.
- Check `https://api.github.com/repos/<repo>/releases/latest` at launch and then at most every 6 hours (when enabled), plus on "Check now". Ignore drafts and prereleases. Version = `tag_name` without a leading `v`. Compare dot-separated numerically ("1.10.0" > "1.9.2").
- Release assets: `ClaudeUsageBar-<version>.zip` (the `.app`, zipped with `ditto -c -k --keepParent`) and `ClaudeUsageBar-<version>.zip.sha256` (`shasum -a 256` output).
- When newer: header shows an accent pill "Update to X.Y.Z". Clicking it:
  1. Refuse with a clear message if the app's parent folder isn't writable.
  2. Download the zip and the checksum; verify SHA-256; abort on mismatch.
  3. Unzip with `ditto -x -k` into a temp folder; take the one `.app` inside and require its bundle identifier to match.
  4. The destination is the current app's folder plus the new bundle's name (so a renamed app replaces the old one). Start a detached `/bin/sh` script that waits for this process to exit, moves any bundle at the destination aside, moves the new one into place, deletes the aside copy, the temp folder and (if the name changed) the old bundle, and `open`s the app. Then quit.

## 9. Build and release

`build.sh`:

- `VERSION` env var or the `VERSION` file (leading `v` stripped). `UPDATE_REPO` env var, else parsed from `git remote get-url origin` (GitHub SSH or HTTPS form).
- Builds release binaries for `arm64-apple-macosx14.0` and `x86_64-apple-macosx14.0`, each with its own `--scratch-path` (`.build/<arch>`), then `lipo -create` into `build/Claude Usage Bar.app/Contents/MacOS/ClaudeUsageBar`, and copies `Resources/AppIcon.icns` into `Contents/Resources`.
- Writes Info.plist: name and display name `Claude Usage Bar`, executable `ClaudeUsageBar`, `CFBundleIconFile` `AppIcon`, identifier `io.github.claude-usage-bar`, version, `LSMinimumSystemVersion 14.0`, `LSUIElement`, `UpdateRepository`.
- Ad-hoc signs (`codesign --force --sign -`).
- `--zip` writes the two release assets into `build/` (asset names have no spaces; the bundle inside is `Claude Usage Bar.app`). `--install` copies the app to `~/Applications` and launches it (killing a running copy first, and removing an old `ClaudeUsageBar.app`).

`install.sh` (one-line install: `curl -fsSL https://raw.githubusercontent.com/<repo>/main/install.sh | bash`):

- Requires macOS 14+. `REPO` env var overrides the repository; `INSTALL_DIR` overrides the destination.
- Reads the latest release tag from the GitHub API (parse JSON with `plutil -extract tag_name raw`, no Python needed), downloads the zip and `.sha256` with curl, verifies with `shasum -a 256 -c`, unzips with `ditto -x -k`.
- Destination: the folder of an existing install (current or pre-1.1 `ClaudeUsageBar.app` name), else `/Applications` if writable, else `~/Applications`.
- Quits a running copy, replaces the bundle (removing the old name too), strips any quarantine attribute, and opens the app. Because curl doesn't quarantine downloads, Gatekeeper doesn't block the first launch.

GitHub Actions:

- `ci.yml` (push to main, pull requests, `macos-latest`): `swift test`, `./build.sh --zip`, upload the zip as an artifact.
- `release.yml` (push of tag `v*`, `contents: write`): `swift test`, `VERSION=<tag> UPDATE_REPO=<repository> ./build.sh --zip`, then `gh release create <tag> <zip> <sha256> --generate-notes`.

## 10. App icon

`scripts/make-icon.swift` draws the icon with AppKit on a 1024 canvas and packs it with `iconutil` into `Resources/AppIcon.icns` (plus `docs/icon.png`): an 824 pt squircle (corner radius 186) centered per the macOS icon grid, with a soft drop shadow and a vertical coral gradient `#ED946E` → `#C76142`; two white rounded bars echoing the menu bar (top: x 232, width 560, height 120, 68% filled; bottom: height 84, 36% filled) over 28% white tracks; and a dark rounded tick (18 × 176) across the top bar at 52% marking elapsed time.

## 11. Tests

XCTest cases covering:

- Decoding: both windows parsed (fractional-second dates), null/missing windows → nil, non-object JSON throws, unrelated keys ignored.
- Pace: each band (20% projected → under, 90% and exactly 100% → on pace, 120% → ahead, 180% → way ahead, 100% used → reached), nil when too early or no reset time, runs-out estimate (60% used halfway through a 5 h window → 1 h 40 m), elapsed fraction clamped, severity ordering.
- Formatting: durations, percent, plan names.
- Updater: version comparison, release parsing (zip + checksum assets, `v` prefix), prereleases ignored, missing zip throws.

## 12. Debug render

In debug builds, `ClaudeUsageBar --render <dir> [--settings]` fills the store with sample data (session 74% resetting in 2 h 13 m, weekly 18% resetting in 4 days, plan "Max 5x"), renders the popover with `ImageRenderer` at 2× in light and dark to `light.png` / `dark.png`, renders the menu bar image tinted white on a dark strip to `menubar.png`, and exits without touching the network or keychain. Native controls render as placeholders; that's expected.
