# Power Metrics, Extra Stats and Widget Row Toggles

Date: 2026-07-04
Status: Approved

## Goal

Add live power consumption (watts) to MacMonitor, plus three companion metrics
(power breakdown, swap and memory pressure, disk I/O speed), and let the user
show or hide widget rows (power, network speed, IP addresses) from the menu
bar menu.

## Background

The SMC probe on the target M4 Mac mini confirmed power keys are readable
without root through the existing SMC layer:

| Key  | Type | Meaning                     | Probed value |
|------|------|-----------------------------|--------------|
| PSTR | flt  | System total power (W)      | 17.5         |
| PDTR | flt  | DC input power (W)          | 19.5         |
| PD0R | flt  | DC input power, rail 0 (W)  | 19.5         |
| PHPC | flt  | CPU package power (W)       | 15.4         |

Approach chosen: reuse the existing `readSMCValue` infrastructure with
candidate-list discovery, exactly like temperature keys. IOReport was
rejected (semi-documented API, unnecessary complexity) and a menu-only
solution was rejected (does not satisfy the widget requirement).

## Data Layer (SystemMonitor.swift)

### Power
- Discover keys once per launch from candidate lists, cache the valid ones:
  - System power: `PSTR` -> published as `systemPowerW: Double`.
  - CPU package power: `PHPC` -> published as `cpuPowerW: Double`.
  - DC input power: `PDTR`, fallback `PD0R` -> published as `dcInPowerW: Double`.
- Read on the existing 5 second tick via `readSMCValue`.
- Publish only when the value changes (existing rule). All publishes go
  through `publishOnMain`.
- Missing key: the published value stays 0 and the UI hides the related row.
  Never show a fake or frozen value.

### Swap and memory pressure
- Swap used/total from `sysctl vm.swapusage` (struct `xsw_usage`).
- Pressure level from `sysctl kern.memorystatus_vm_pressure_level`
  (1 normal, 2 warning, 4 critical).
- Read on the 5 second tick. No root required.
- If the pressure sysctl is unavailable (older macOS), show only swap.

### Disk I/O speed
- Iterate `IOBlockStorageDriver` services, sum the `Statistics` dictionary
  counters "Bytes (Read)" and "Bytes (Written)".
- Compute MB/s from the delta between two ticks using UInt64 sums with
  wrap-safe deltas (same pattern as CPU ticks).
- If a delta is negative (drive ejected, counters reset), skip that tick and
  recover on the next one.

### History
- Add a system power buffer to `HistoryStore` (rolling 60 samples at 5 s),
  consumed by the Thermals power graph.

## UI

### Widget power row (ContentView.swift)
- New compact row directly above the network stats row: `bolt.fill` icon and
  the value formatted with `String(format: "%.1f W", value)`.
- Shows system power only; the breakdown lives in Thermals.
- Hidden entirely on Macs with no power key.

### Menu bar menu (MacMonitorApp.swift)
- New stats line "Power:  17.5 W" after the Fan line, built with
  `makeStatsItem` and a bolt icon. Hidden when no power data exists (same
  pattern as the fan line on fanless Macs).
- New "Widget Rows" submenu next to Theme with three check-marked items:
  - Power
  - Network Speed
  - IP Addresses
- All default to visible. Persisted in UserDefaults under `widgetRow_power`,
  `widgetRow_network`, `widgetRow_ip`.
- On Macs with no power data the widget power row stays hidden regardless of
  the toggle, and the "Power" item is removed from the Widget Rows submenu
  (same rule as the hidden fan line).

### Widget row visibility
- ContentView reads the three flags with `@AppStorage`.
- Hiding a row shrinks the window through the existing `.mmResizeWindow`
  notification path.
- `UILayout` fixed heights become a function of the visible row count. The
  bottom-edge anchoring and position restore behavior must not change
  (known regression area: widget drifting from its corner).

### Thermals detail
- New "Power" section above the fan cards: System / CPU Package / DC In
  values on one line, plus a 5 minute `HistoryGraph` of system power with
  min/max labels (same component as the temperature graph).

### RAM detail
- One row above the process list: swap usage ("Swap: 1.2 / 2.0 GB") and a
  memory pressure dot (green normal, orange warning, red critical).

### Disk detail
- One row above the cleanup categories: live read/write speed
  ("R 12.4 MB/s, W 3.1 MB/s").

## Non-goals (deliberate)

- Menu bar text mode ("CPU% temp") stays unchanged.
- No notification threshold for power.
- No fifth gauge in the dial grid; the 2x2 symmetry stays.
- No per-app power usage.

## Error Handling

- Every new metric is optional: if its SMC key, sysctl, or IOKit statistic is
  unavailable, the row is hidden. Honest UI rule: no fake values.
- Disk I/O negative deltas are skipped (see Data Layer).
- All publishes use `publishOnMain`; no `DispatchQueue.main.async` (menu
  tracking stall regression).

## Verification

- Build with `./build.sh` after each stage (Components.swift is compiled in
  both build scripts; keep them in sync).
- Visual check via window-id `screencapture`; detail sections via
  `open MacMonitor.app --args -debugDetail ram|disk|fan`.
- Toggle test: turn each of the three rows off and on, verify the window
  height shrinks and grows correctly and the position does not drift.
- Sanity-check PSTR against Activity Monitor / powermetrics output.
- Update memory.md and architecture.md when done.
