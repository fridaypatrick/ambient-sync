---
status: approved
updated: 2026-08-13
---

# AmbientSync

## Overview

AmbientSync is a minimal native macOS 26 menu-bar application for Apple silicon. It reads built-in display brightness, maps that value linearly into a configured range for each connected DDC/CI-capable external display, and updates system-wide Light/Dark appearance using hysteresis. It is an unsandboxed, source-distributed open-source application because required MonitorControl-derived display transports use private macOS symbols.

## Requirements

- Use Swift and AppKit with an AppKit application lifecycle; do not use SwiftUI for the main lifecycle.
- Target macOS 26 and Apple silicon only.
- License AmbientSync as GPL-3.0-only. Keep adapted MonitorControl code under its original MIT notice and include a clearly separated third-party MonitorControl MIT license notice.
- Prepare the repository for public GitHub visibility from its first push; do not commit secrets, personal signing identities, user-specific Xcode data, or machine-local configuration.
- Run as an accessory application with no persistent Dock icon. When Settings is shown, activate the app and bring the Settings window forward.
- Use `NSStatusItem` for menu-bar presence. Users can show or fully hide the status item.
- When already running, reopening AmbientSync from Finder, Spotlight, or Launchpad opens Settings so users can recover after hiding the status item.
- On launch, enumerate active displays, identify the built-in display, and classify each external display as read-verified controllable, write-only assumed controllable, or unsupported. A display is read-verified when DDC/CI VCP brightness reading succeeds. A display whose read fails is write-only assumed only when IOAVService match confidence is high: an IODisplayLocation match or at least three independent EDID/name/serial signals.
- Poll built-in display brightness every two seconds using the minimum MonitorControl-derived `DisplayServices` adapter needed for reading.
- Treat an internal brightness change of at least 0.02 on the normalized 0...1 scale as meaningful.
- For each controllable external display, linearly map internal brightness 0...1 into its configured normalized minimum...maximum range and send DDC VCP brightness writes off the main thread.
- Coalesce writes and do not send a DDC write when the integer target brightness has not changed.
- Write only in response to meaningful internal-brightness changes; do not continuously fight manual brightness changes made on the external monitor.
- Never send DDC writes during discovery, classification, wake, or reconfiguration.
- For write-only displays, use a persisted per-display assumed DDC maximum with default 100 and support 100, 255, or a custom value from 1 through 65535.
- Label write-only control explicitly as unverified; do not claim protocol-confirmed hardware effect.
- Track consecutive DDC transport write failures per display. After three consecutive failures, pause writes to that display until re-enumeration or an explicit retry, and show a degraded state in Settings. Reset the counter after any successful transport write.
- Persist per-display minimum and maximum mapping using a stable display identity. Prefer EDID identity; fall back deterministically when EDID serial data is unavailable.
- Persist global settings: brightness sync enabled, Dark threshold, Light threshold, Launch at Login, and menu-bar icon visibility.
- First-run defaults are: brightness sync enabled, menu-bar icon visible, Launch at Login disabled, Dark threshold 0.25, Light threshold 0.40, and per-display mapping minimum 0.0 / maximum 1.0.
- Validate appearance thresholds so Dark is lower than Light with at least a 0.05 normalized gap.
- After each meaningful internal-brightness update, if brightness is at or below Dark threshold, request system-wide Dark Mode; if at or above Light threshold, request system-wide Light Mode; do nothing between thresholds.
- Evaluate appearance on the first successful built-in-brightness poll after launch and on each later meaningful brightness update.
- Read the current system appearance through System Events before requesting a change so redundant appearance requests are suppressed. A manual appearance change may be restored to the threshold-selected mode on the next qualifying brightness update.
- Request Apple Events permission on the first appearance read or switch attempt; do not prompt merely because Settings opens.
- Avoid redundant appearance requests and enforce a 60-second minimum dwell between actual mode switches.
- Switch system-wide appearance through Apple Events to System Events. Include the required usage description, handle permission denial without crashing, and show actionable status in Settings.
- Configure Launch at Login through `SMAppService.mainApp`.
- Settings window includes: brightness sync toggle; detected displays with support status and per-display write-only status; per-controllable-display minimum and maximum controls; per-write-only-display assumed-maximum control; degraded/fault status; explicit retry; Dark threshold; Light threshold; Launch at Login; menu-bar icon visibility; and appearance-automation permission/status messaging.
- Pause brightness synchronization when no built-in display is available, leaving external displays at their last values.
- Re-enumerate displays after post-change CoreGraphics reconfiguration notifications and after wake. Recreate stale DDC transport handles after wake or reconfiguration.
- Keep display probing and DDC I/O off the main thread on a bounded serial queue. Keep app idle except for the two-second poll, lifecycle events, settings changes, and needed DDC writes.
- Adapt only the minimum required MonitorControl code for display identity/enumeration, built-in brightness reading, Apple-silicon DDC transport, external brightness VCP commands, and write-only VCP operation without successful reads.
- Preserve MonitorControl MIT copyright/license notices in adapted files and include a copy of its MIT license attribution.
- Include a README covering purpose, supported hardware and macOS/Xcode requirements, clean-clone build and test commands, local/ad-hoc signing guidance, Apple Events permission behavior, private/unsupported API caveats, App Store ineligibility, and MonitorControl attribution.
- Document privacy and security plainly: AmbientSync sends Apple Events only to System Events for appearance switching, performs no network requests, includes no analytics, and collects no user data.
- Keep the checked-in Xcode project reproducible from a clean clone with no hard-coded development team. Ignore DerivedData, xcuserdata, and machine-local signing configuration.
- Add GitHub Actions source validation on the standard Apple-silicon public-repository runner label macos-26. Explicitly select Xcode 26.6, print toolchain identity, build the app without distribution signing, and run unit tests. CI must not claim physical display, DDC/CI, wake, or private-API runtime validation.
- Use no third-party runtime dependencies unless required by a verified implementation blocker.

## Acceptance Criteria

- App builds as a native arm64 macOS 26 `.app` and launches with AppKit lifecycle.
- App has no persistent Dock icon; opening Settings activates the app and brings the window forward.
- Status item opens Settings and Quit actions; hiding it removes it completely; reopening the running app opens Settings.
- On a MacBook, built-in brightness is read and normalized to 0...1 every two seconds without blocking the main thread.
- During manual hardware smoke verification, displays that answer VCP reads appear as verified controllable; displays whose reads fail but whose IOAVService match meets the confidence floor appear as write-only with explicitly unverified wording; displays below the floor appear disabled and unsupported.
- No DDC write is issued during enumeration, classification, wake, or reconfiguration.
- A write-only display with assumed maximum 100 maps 0%, 50%, and 100% targets to raw VCP 0, 50, and 100; with assumed maximum 255 it maps them to 0, 128, and 255.
- Three consecutive write transport failures stop further writes to that display until re-enumeration or explicit retry, and Settings shows the degraded state.
- Settings never labels a write-only display as verified controllable.
- Manual Samsung LS34A650U hardware validation confirms at least one bounded brightness write, synchronization with internal brightness, no redundant writes, and recovery after retry or re-enumeration.
- Given mapping 10%...80%, internal values 0%, 50%, and 100% produce external targets 10%, 45%, and 80%, respectively.
- Repeated polls with no meaningful internal change cause no DDC writes.
- Repeated mapped integer target values cause no redundant DDC writes.
- Per-display mappings and global settings survive application restart.
- A fresh preferences domain uses the documented first-run defaults, including 0...100% external mapping and Dark 25% / Light 40% thresholds.
- First successful poll evaluates appearance. Brightness at/below Dark threshold requests Dark Mode only when current system appearance differs; values between thresholds do nothing; brightness at/above Light threshold requests Light Mode only when current system appearance differs; dwell and redundant-request guards work.
- Apple Events denial leaves app running and Settings explains how to grant permission.
- Launch at Login toggle reflects and changes `SMAppService.mainApp` registration state.
- During manual hardware smoke verification when compatible hardware is available, connect/disconnect and wake trigger debounced re-enumeration and replacement of DDC handles without main-thread stalls.
- Without a built-in display, synchronization pauses without changing external brightness.
- Logic tests cover mapping, threshold validation/hysteresis/dwell, redundant-write suppression, and settings identity persistence using protocol-backed fakes.
- Manual hardware smoke verification covers DDC discovery/write, hot-plug, and sleep/wake when compatible hardware is available.
- Adapted MonitorControl-derived files carry attribution and repository includes MonitorControl MIT license text.
- Repository contains a GPL-3.0-only project license and a separate MonitorControl MIT third-party notice; adapted files retain required notices.
- Following README instructions from a clean clone builds and tests without a hard-coded personal development team or committed machine-local Xcode state.
- README discloses private APIs, unsandboxed/App Store limitations, Apple Events scope, no-network/no-analytics/no-data-collection behavior, supported toolchain, and hardware-only validation limits.
- GitHub Actions passes source build and unit-test validation on macos-26 using Xcode 26.6 (17F113) and its bundled macOS 26.5 SDK, while reporting toolchain identity and excluding signing and hardware claims.

## Out of Scope

- Intel Macs and universal binaries.
- Mac App Store or sandboxed distribution.
- Volume, contrast, keyboard shortcuts, presets, adaptive modes, hotkeys, CLI, update system, analytics, OSD overlays, software dimming, ambient-light-sensor control, schedules, or Lunar features.
- Continuously reconciling manual brightness changes made directly on external monitors.
- Private SkyLight appearance switching.
- Porting MonitorControl UI, application architecture, or unrelated display abstractions.
- Vendor or model allowlists for DDC compatibility.
- Inferring true DDC maximum, current value, or capabilities when VCP reads fail.
- Signed or notarized binary releases, release automation, and App Store distribution.
- Personal blog post content; the v1 publication artifact is the repository README.

## Open Questions

- Physical DDC/CI monitor compatibility and sleep/wake behavior require hardware smoke verification and cannot be proven by unit tests alone.
- Private `DisplayServices` and `IOAVService` symbols may change in future macOS releases; macOS 26 compatibility must be validated on the installed SDK and hardware.
- Write-only DDC transport acknowledgement cannot prove visible hardware effect; Samsung and other write-only compatibility requires manual observation.
