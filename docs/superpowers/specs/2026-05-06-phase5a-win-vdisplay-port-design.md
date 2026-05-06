# Design: Phase 5A — Windows Virtual Display Port

**Status**: brainstorm complete, awaiting user review
**Date**: 2026-05-06
**Author**: jokot (with Claude)
**Sub-project of**: vdisplay v1
**Implementation plan**: TBD (next via `writing-plans` skill)
**Dependency**: Phase 4 (macOS virtual extended display, merged 2026-05-05) — establishes the discovery contract (`friendly name == "vdisplay-host"`) reused here.

## Purpose

Bring vdisplay's Windows host to functional parity with the Phase 4 macOS host. After installation, the Windows host owns a persistent virtual extended monitor (1920×1080@60, positioned right of the primary). Sunshine streams that virtual monitor to Moonlight clients by default. The user drags windows onto the virtual monitor at any time (even when Sunshine is not running) — the virtual monitor is a permanent part of their desktop topology until they uninstall the driver.

Ship-level constraints: solo dev, GPL-3, no WHQL signing budget. The driver itself is **vendored**, not authored — we ship a pre-configured release of [`itsmikethetech/Virtual-Display-Driver`](https://github.com/itsmikethetech/Virtual-Display-Driver) (MIT, signed) inside our installer and prompt the user to install it on Sunshine's first launch.

## Non-Goals

- Authoring or maintaining a custom WDDM IDDCX driver (vendored only — driver source NOT in this repo)
- Bundling the driver as a silent nested install step (rejected during brainstorm — opaque failures, messy uninstall path)
- Multiple virtual displays per host (deferred to v1.5)
- Configurable virtual-display resolution at runtime (1920×1080@60 hardcoded for v1, parity with Phase 4)
- HDR / wide color gamut on the virtual monitor (deferred)
- Windows 10 support (target Win 11 24H2 first; Win 10 22H2 stretch goal)
- Per-stream driver enable/disable (driver is install-time persistent; user toggles via Win+P or Device Manager — no Sunshine-managed toggle in v1)
- Auto-update of the bundled driver (vendored release is pinned per Sunshine release; bumped manually)
- Virtual display position other than right-of-primary (v1 hardcoded)

## Architecture

Three layers, parallel to Phase 4 macOS but with the kernel driver replacing the user-mode helper subprocess:

```
┌─────────────────────────────────────────────────┐
│  Layer 1 — Installer bundle (ship-time)         │
│  vdisplay-driver-setup.exe                      │
│  ├─ itsmikethetech/Virtual-Display-Driver       │
│  │   release artifacts (.sys, .inf, .cat)       │
│  ├─ Pre-configured EDID:                        │
│  │   monitor name = "vdisplay-host"             │
│  │   default resolution = 1920x1080@60          │
│  └─ install.ps1 → pnputil /add-driver           │
└─────────────────────────────────────────────────┘
                  ↓ (one-time install via prompt at first Sunshine launch)
┌─────────────────────────────────────────────────┐
│  Layer 2 — IDDCX kernel driver (persistent)     │
│  vddrv.sys — vendored, signed, MIT              │
│  Always-on virtual monitor                      │
│  Visible in Win Display Settings as             │
│  "vdisplay-host"; positioned right of primary   │
└─────────────────────────────────────────────────┘
                  ↓ (Win DisplayConfig API exposes monitor friendly name)
┌─────────────────────────────────────────────────┐
│  Layer 3 — Sunshine Win-side (runtime)          │
│  WinVirtualDisplayManager (new, in Sunshine)    │
│  ├─ get_display_id() — DisplayConfig scan       │
│  │   for friendly name == "vdisplay-host"       │
│  ├─ probe_driver_installed() — first-launch    │
│  │   gate for the prompt                       │
│  └─ display_base.cpp — adopts ID, falls back   │
│      to primary if absent (mirror mode)         │
└─────────────────────────────────────────────────┘
```

Discovery contract preserved from Phase 4: Sunshine looks up the virtual display by friendly name `vdisplay-host`, never by hardcoded ID. The Mac and Windows codepaths share the same mental model and the same fallback semantics. This deliberately positions a future shared-platform abstraction (`VirtualDisplayManager` interface) at v1.5.

Key Win-specific simplification vs. Phase 4: **the driver is persistent, OS-managed, and decoupled from Sunshine's lifecycle.** No spawn, no fork+exec, no SIGTERM, no stderr pump, no async-teardown thread. `WinVirtualDisplayManager` is a singleton with two stateless query methods plus a one-time first-launch prompt helper.

## Components

### Layer 1 — Installer bundle (`installers/windows/vdisplay-driver-setup/`, new directory)

- Vendored `itsmikethetech/Virtual-Display-Driver` release tarball (`.sys` + `.inf` + `.cat` + signed certificate) checked in under `installers/windows/vdisplay-driver-setup/vendored/` (or downloaded at packaging time — TBD at impl time based on license attribution requirements).
- Pre-configured `options.txt` (or registry key — depends on which configuration channel the upstream driver supports at the pinned release): single monitor entry, 1920×1080@60, EDID monitor name = `vdisplay-host`, position right-of-primary.
- `install.ps1` (or `install.bat`) — wraps `pnputil /add-driver vddrv.inf /install` plus driver-service registration; reuses the upstream driver's existing install hook with our config baked in.
- Output artifact: `vdisplay-driver-setup.exe` produced by Sunshine's existing Windows packaging pipeline (NSIS most likely — confirm at impl time when the build is run on Yoga).

### Layer 2 — IDDCX driver (vendored, **not modified**)

- Signed kernel-mode WDDM IDDCX driver from upstream `itsmikethetech/Virtual-Display-Driver` at a specific pinned release tag.
- We do **not** fork the driver source. We ship its release binaries with our `options.txt` baked in and the EDID name set to `vdisplay-host`.
- Driver creates one IDDCX virtual monitor at OS boot and serves frames to WDDM via the stock `IddCxMonitorArrival` API.
- License: MIT — compatible with our GPL-3 distribution (one-way: GPL-3 redistribution is permitted by MIT terms; no GPL-bleed back to the driver project).
- Upgrade path: when upstream releases a new version, we bump the pinned tag, rebuild `vdisplay-driver-setup.exe`, ship it as a Sunshine release. No live driver update mechanism in v1.

### Layer 3 — Sunshine Win-side (new files in `upstream/host/src/platform/windows/`)

- `virtual_display_manager.h` / `.cpp` (new) — singleton class:
  - `static WinVirtualDisplayManager& instance()`
  - `std::optional<VirtualDisplayInfo> get_display_id()` where `VirtualDisplayInfo` carries `LUID adapter`, `uint32_t target_id`, and the DXGI `DeviceName`. Iterates `EnumDisplayDevices` + `DisplayConfigGetDeviceInfo(DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME)` looking for a friendly name match against `"vdisplay-host"`. Returns `std::nullopt` on absent / disabled / API failure.
  - `bool probe_driver_installed(std::chrono::milliseconds timeout)` — polling wrapper around `get_display_id()`, used during the first-launch install flow to wait for IDDCX device materialization.
  - **No spawn/teardown methods.** Driver lifecycle is OS-managed.
- `display_base.cpp::init()` (modified) — patched to call `WinVirtualDisplayManager::instance().get_display_id()` before defaulting to `IDXGIFactory::EnumAdapters[0]::EnumOutputs[0]`. If a virtual-display ID is returned AND a matching enabled DXGI output is found, that output is adopted. Otherwise primary. Mirrors Phase 4 `display.mm` probe-and-adopt pattern.
- Sunshine's display-list enumeration (used by the web UI's display picker) — prepend the virtual display ID to the listing when discovered, gated by the same probe (only advertise if capturable). Matches `display_names()` injection in `display.mm` from Phase 4.

### Sunshine first-launch prompt (new, in main app or tray UI)

- On Sunshine boot, after config load and before the main loop:
  - Read config flag `prompt_vdisplay_install_done` (default: `false`).
  - If flag is `false` AND `WinVirtualDisplayManager::probe_driver_installed(0ms)` returns `false`:
    - Show modal: **"Install vdisplay virtual driver? (Recommended)"** with Install / Skip / Remind me later buttons.
    - **Install** → spawn `vdisplay-driver-setup.exe` with `/quiet` flag (UAC prompt fires). After exit code 0, poll `probe_driver_installed(30s)` until success or timeout. Set flag = `true`. On timeout, log error + tray notification suggesting reboot.
    - **Skip** → set flag = `true` (don't re-ask).
    - **Remind me later** → flag stays `false`; prompt re-appears next launch.
  - If flag is `true` OR driver is detected: skip prompt silently.

### Existing Sunshine assets reused unchanged

- `libdisplaydevice` (third-party, already used by Sunshine on Win for resolution/topology config) — handles per-output mode-switching once the virtual output is adopted. No new abstraction needed.
- DXGI / Desktop Duplication capture pipeline (`display_vram.cpp`, `display_ram.cpp`, `display_wgc.cpp`) — virtual display becomes just another DXGI output. No capture-path changes.
- NVIDIA preference handling (`nvprefs/`) — orthogonal, untouched.

## Data Flow

### Flow A — Install-time (one-time, user-driven)

```
User downloads vdisplay-windows-setup.exe (Sunshine + assets bundle)
   → Runs Sunshine MSI/NSIS installer
      → Sunshine binary + tray app extracted to Program Files
      → vdisplay-driver-setup.exe + assets extracted to
         Program Files\vdisplay\driver\
      → Driver NOT yet installed (deferred to first Sunshine launch)
   → Installer finishes; optionally launches Sunshine
```

### Flow B — First Sunshine launch (prompt-driven)

```
Sunshine boots
   → WinVirtualDisplayManager::probe_driver_installed()
      → DisplayConfig API: any IDDCX target with friendly name "vdisplay-host"?
         → YES: skip prompt, proceed to main loop
         → NO + prompt_vdisplay_install_done == false:
            → Show modal: "Install vdisplay virtual driver?"
               → Install:
                  → Sunshine spawns vdisplay-driver-setup.exe with /quiet (UAC)
                  → Driver installed → IDDCX device materializes after ~5–30s
                  → Sunshine polls DisplayConfig until found OR 30s timeout
                  → On success: prompt_vdisplay_install_done = true
                  → On timeout: log error, tray notification suggests reboot,
                    flag stays false (re-prompt next launch)
               → Skip:
                  → prompt_vdisplay_install_done = true (don't re-ask)
                  → Sunshine continues; mirror mode only this session
               → Remind me later:
                  → flag unchanged; re-prompt next launch
         → NO + prompt_vdisplay_install_done == true: silent, no prompt
   → Main loop continues
```

### Flow C — Stream-time (runtime, per-session)

```
Moonlight client connects → Sunshine starts capture session
   → display_base.cpp::init() called
      → WinVirtualDisplayManager::instance().get_display_id()
         → DisplayConfig scan: find target friendly name == "vdisplay-host"
         → YES: return its DXGI DeviceName + adapter LUID + target id
         → NO: return std::nullopt
      → If virtual display ID returned:
         → Probe via DXGI: IDXGIFactory::EnumAdapters → IDXGIOutput
            → matching DeviceName found AND output enabled? → adopt
            → not found / disabled → fall back to primary
      → Else: fall back to primary (mirror mode)
   → Initialize Desktop Duplication / WGC against chosen output
   → Stream frames to Moonlight (existing Sunshine pipeline, unchanged)
```

No teardown flow exists — the driver persists across Sunshine sessions, even reboots, until uninstalled via Control Panel → Programs.

## Error Handling

| Failure | Detection | Response |
|---------|-----------|----------|
| User declines UAC at driver install | `vdisplay-driver-setup.exe` exit code != 0 | Log warning. Keep `prompt_vdisplay_install_done = false`. Continue mirror mode this session; re-prompt next launch. |
| Driver installs but IDDCX device doesn't materialize | 30s polling timeout in `probe_driver_installed()` | Log error with timeout marker. Don't retry install (likely OS-side issue). Continue mirror mode. Tray notification suggests reboot. |
| `DisplayConfigGetDeviceInfo` returns ERROR_GEN_FAILURE / NOT_SUPPORTED | API return code checked at every call | Treat as "no virtual display available". Mirror mode silent fallback. Log once per session. |
| Multiple devices match name `vdisplay-host` (defensive) | Scan finds >1 hit | Pick first by adapter LUID + target ID ordering (deterministic). Log warning — operator should investigate driver duplication. |
| User disables VDD mid-session via Device Manager | DXGI output enumeration drops the matching device | Sunshine's existing capture-loss recovery (`DXGI_ERROR_ACCESS_LOST`) re-inits via `display_base.cpp::init()`, which re-probes — finds no virtual display, falls back to primary. Stream continues without client disconnect. |
| User uninstalls driver while Sunshine is running | Same as above | Same handling. Next Sunshine launch starts in mirror mode. Prompt does NOT re-appear (user explicitly removed the driver — reconsider detection mechanism at impl time; see Open Questions). |
| EDID friendly-name read fails for one DXGI output | Per-target DisplayConfig query fails | Skip that target, continue scan. Don't bail on the entire enumeration. |
| Capture init succeeds but no frames flow | Existing Sunshine timeout in capture loop | Existing retry logic. If the failing output is the virtual display: mark uncapturable for session, fall back to primary. New telemetry log line (mirrors Phase 4's capability-probe). |

**Defensive principle (carried from Phase 4):** the capture pipeline must never lock onto an uncapturable output. Probe before adopt, fall back silently, log clearly. Mirror mode is always a valid degraded state.

## Testing

### Unit tests (gtest, in-tree)

- `WinVirtualDisplayManager::get_display_id()` — mock `DisplayConfigGetDeviceInfo` results, verify:
  - Single match by friendly name → returns LUID + target id
  - No match → returns `std::nullopt`
  - Multiple matches → returns first by deterministic ordering
  - DisplayConfig API failure → returns `std::nullopt` (no exception escapes)
- `WinVirtualDisplayManager::probe_driver_installed()` — verify polling honors timeout, returns true on detection, false after deadline.

### Integration tests (gtest, requires Win runner)

- End-to-end discovery against a real installed driver: skipped with `GTEST_SKIP()` when admin context is unavailable. Most kernel-mode interaction is impractical in standard CI runners; document the gap.

### Manual e2e (Yoga Windows host — must-pass before merge)

1. **Install flow:** run `vdisplay-windows-setup.exe`, accept UAC, verify driver appears in Device Manager → Display adapters as `vdisplay-host`. No reboot required.
2. **Discovery:** launch Sunshine → log shows `WinVirtualDisplayManager: vdisplay-host detected, target id=X`. Sunshine config `output_name` left empty.
3. **Capture (extend mode):** connect Moonlight Android → host streams virtual display, not main desktop. Drag a window past the right edge of main → window appears on phone.
4. **Mirror fallback:** disable VDD via Device Manager → reconnect Moonlight → host streams main display, no error popup, no infinite retry. Sunshine logs `falling back to primary`.
5. **Mid-session loss:** with stream running, disable VDD via Device Manager → stream switches to primary within 5s, no client disconnect.
6. **Reinstall path:** uninstall via Control Panel → Sunshine launch → re-prompts for install → user accepts → driver returns.
7. **First-launch prompt suppression:** user clicks Skip on prompt → restart Sunshine → no prompt re-appears (config flag honored).

### Compatibility matrix

- **Primary**: Win 11 24H2 on Yoga (Intel iGPU; possibly NVIDIA dGPU per `user_hardware.md` memo)
- **Stretch**: Win 10 22H2 (defer if v1 ships on Win 11 only)
- **Out of scope**: HDR, multiple virtual displays, multi-virtual on multi-GPU systems

### CI

- Win runner builds Sunshine + assembles installer artifact (`vdisplay-windows-setup.exe`).
- No driver install in CI (UAC unavailable in standard runners). Smoke build only.

## Open Questions (resolved at implementation time, not design time)

- Exact NSIS vs. MSI vs. WiX choice — depends on Sunshine's existing Windows packaging on Yoga. Verify at Phase 5A Task 1.
- itsmikethetech VDD's exact configuration channel (`options.txt` vs. registry vs. `.inf` overlay) at the pinned release — verify when vendoring the release artifacts.
- Whether to checkin VDD release binaries vs. download them at packaging time — license/attribution decision at Phase 5A Task 2.
- Re-prompt-after-uninstall behavior — design says "do not re-prompt on user-uninstall" but detection mechanism is unclear; reconsider at impl time once we know what API surface signals "user explicitly uninstalled" vs. "driver disappeared by accident".

## Reuse from Phase 4

- Friendly-name discovery contract (`vdisplay-host`)
- Probe-before-adopt pattern in `display_base.cpp` analog
- Mirror-mode fallback semantics (silent, never dead-end the capture pipeline)
- `display_names()` injection gating (only advertise if capturable)

## Future work (deferred to v1.5)

- Shared `VirtualDisplayManager` C++ interface across Mac and Win Sunshine code (extract once both implementations exist)
- Per-stream resolution config — drive virtual display via Moonlight's negotiated resolution
- Multiple virtual displays for multi-monitor productivity setups
- Tray UI for one-click virtual-display enable/disable (replaces the Win+P / Device Manager fallback for power users)
- HDR / wide color gamut on the virtual display
- Auto-update of the bundled driver
