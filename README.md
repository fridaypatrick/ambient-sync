# AmbientSync

AmbientSync is a native macOS menu-bar app that polls built-in display brightness, maps it per display to supported DDC/CI external displays, and switches system Light/Dark appearance at configured thresholds.

This is a source-only project. Current support:

- Apple silicon
- macOS 26
- Xcode 26.6 (17F113)
- Bundled macOS 26.5 SDK

## Implemented scope

- Built-in brightness polling
- DDC/CI external mapping per display
- Thresholds/hysteresis appearance switching
- Launch at Login
- Hideable menu icon/relaunch recovery
- Settings persistence

Per-display mappings use stable display identities when available. First-run defaults are 0–100% external mapping, Dark at 25%, Light at 40%, brightness synchronization enabled, menu icon visible, and Launch at Login disabled.

Displays whose VCP brightness reads fail are included only when their private IOAVService match is high-confidence. AmbientSync labels these controls **unverified (write-only)** and uses a persisted assumed VCP maximum of 100 by default; Settings supports 100, 255, or a custom maximum from 1 through 65535. Three consecutive transport write failures pause that display until re-enumeration or explicit Retry. Discovery and lifecycle rebuilds do not issue brightness writes.

## Build and test

Run from repository root after a clean clone. These commands build and test the checked-in `AmbientSync` scheme without code signing:

```sh
xcodebuild build \
  -project AmbientSync.xcodeproj \
  -scheme AmbientSync \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project AmbientSync.xcodeproj \
  -scheme AmbientSync \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO
```

For interactive local use, open `AmbientSync.xcodeproj` in Xcode. Use local ad-hoc signing or your personal signing team in local Xcode settings; no development team is committed to this project. Hardware behavior must be validated on a real Mac and display setup.

## Usage

Launch AmbientSync from Xcode or a locally built app. Use the menu-bar icon for **Settings…** and **Quit AmbientSync**. Settings includes brightness synchronization, detected display status, per-display minimum and maximum mapping, write-only assumed maximum controls, degraded-state Retry, Dark and Light thresholds, Launch at Login, menu-icon visibility, and appearance-automation status.

To hide the menu icon, turn off **Show menu-bar icon** in Settings. If it is hidden, reopen the already-running app from Finder, Spotlight, or Launchpad to show Settings and recover access. A 10–80% mapping produces 10%, 45%, and 80% external targets for internal brightness values of 0%, 50%, and 100%.

## System appearance permission

AmbientSync uses Apple Events only to control **System Events** for reading and setting system Light/Dark appearance. The first threshold-triggered appearance read or switch attempt can prompt for Automation permission; opening Settings alone does not request it.

If permission is denied, open **System Settings → Privacy & Security → Automation**, expand **AmbientSync**, and allow **System Events**. AmbientSync remains running and reports the permission status in Settings.

## Privacy and security

- No network requests
- No analytics
- No telemetry
- No data collection

AmbientSync is unsandboxed and uses private or unsupported APIs: `DisplayServices`, `IOAVService`, and `CoreDisplay`. It is not eligible for the Mac App Store, and these APIs may break on future macOS updates.

DDC/CI support varies by display, adapter, and connection. Private APIs, hot-plug handling, and sleep/wake behavior require validation with real hardware; they are not proven by the automated build and unit-test workflow.

## GitHub Actions

GitHub Actions performs source build and unit-test validation only on `macos-26`, using Xcode 26.6. It selects the bundled macOS 26.5 SDK and uses the same arm64, no-signing commands above. CI does not prove physical display behavior, DDC/CI operation, hot-plug or wake recovery, or private-API runtime behavior.

## Hardware smoke checklist

- [ ] Discover a compatible external display and verify a DDC/CI brightness write.
- [ ] Verify 10–80% mapping at internal 0%, 50%, and 100% brightness.
- [ ] Hot-plug an external display and verify re-enumeration and continued mapping.
- [ ] Sleep and wake the Mac and verify display recovery and brightness writes.
- [ ] Trigger appearance automation, test the permission prompt and denial path, and verify Light/Dark switching.
- [ ] Enable Launch at Login and verify login startup.
- [ ] Hide the menu icon, then reopen AmbientSync through Finder, Spotlight, or Launchpad.

## License and attribution

AmbientSync is licensed under [GPL-3.0-only](LICENSE). Adapted MonitorControl portions remain under the MIT License. The exact pinned upstream MonitorControl commit is `f16d90f29cefbd9fff47e26fc8f99fe7a5280deb`.

See [`THIRD_PARTY_NOTICES/MonitorControl-MIT.txt`](THIRD_PARTY_NOTICES/MonitorControl-MIT.txt) for the MonitorControl attribution and license notice.
