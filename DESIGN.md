# Architecture Decisions

## ADR-001 — High-confidence write-only DDC support
Date: 2026-08-13
Status: Accepted

### Context
Some Apple-silicon USB-C external displays, including the observed Samsung LS34A650U, match a DCPAVServiceProxy/IOAVService reliably and acknowledge DDC I2C writes but return invalid VCP Get replies. Requiring a successful VCP brightness read rejects displays that accept brightness writes. Lunar source and local state show DDC read and write behavior are tracked separately for this monitor.

### Decision
Classify external displays as read-verified, write-only assumed, or unsupported. A failed VCP read may become write-only assumed only when IOAVService matching has high confidence: an IODisplayLocation match or at least three independent EDID/name/serial signals. Discovery, wake, and reconfiguration never write brightness. Write-only displays use a persisted assumed DDC maximum, default 100 with 100/255/custom override, and are labeled unverified. Three consecutive transport write failures degrade and pause that display until re-enumeration or explicit retry. Vendor/model allowlists are not used.

### Alternatives
- Require successful VCP reads: rejected because it excludes verified write-only hardware behavior.
- Enable every matched service: rejected because weak matches can target the wrong display.
- Maintain vendor/model allowlists: rejected because lists are brittle and incomplete.
- Use Apple Native control: rejected for this Samsung because DisplayServices failed and CoreDisplay writes had no effect.
