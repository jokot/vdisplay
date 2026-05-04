# vd-poc-mac — macOS virtual display POC

Single-binary proof of concept that creates an extended virtual display on
macOS via the private `CGVirtualDisplay` API. Validates the API path
before the vdisplay project commits to a Phase 4 production port.

**Spec:** [`docs/superpowers/specs/2026-05-03-mac-vdisplay-poc-design.md`](../../docs/superpowers/specs/2026-05-03-mac-vdisplay-poc-design.md)

## Requirements

- macOS 14.0 or later (`CGVirtualDisplay` was added in Sonoma).
- Apple Silicon or Intel Mac.
- Xcode Command Line Tools (`xcode-select --install`).

## Pre-run checks

```bash
xcode-select -p                                  # confirms CLT installed
sw_vers -productVersion                          # must be ≥14.0
system_profiler SPDisplaysDataType | grep -ic "display"   # baseline count (note this number)
```

## Build and run

```bash
./build.sh
./vd-poc-mac
```

While `vd-poc-mac` is running:

1. Open **System Settings → Displays**. Verify a new display named
   `vd-poc` (or generic "Virtual Display") appears alongside your main.
2. Drag a window from the main display to the right edge, past x=2000.
   The window should appear on the virtual display.
3. The mouse cursor should move into the virtual display area.

Stop the binary with `Ctrl+C`.

## Expected stdout

```
[vd-poc] pid=NNNNN macOS=14.X.X
[vd-poc] checking CGVirtualDisplay availability...
[vd-poc] all CGVirtualDisplay classes resolved ✓
[vd-poc] BEFORE: 1 active display(s): 1
[vd-poc] creating virtual display 1920x1080@60Hz...
[vd-poc] created display id=NNNNNNNNN
[vd-poc] applied modes (native 1920x1080@60 + half-res, hiDPI=1)
[vd-poc] AFTER:  1 active display(s): 1
[vd-poc] ACTIVE: 2 active display(s): 1 NNNNNNNNN
[vd-poc] no mirror cleanup needed             ← OR mirror dance lines
[vd-poc] READY:  2 active display(s): 1 NNNNNNNNN
[vd-poc] press Ctrl+C (SIGINT) or send SIGTERM to destroy and exit
^C
[vd-poc] received signal, shutting down...
[vd-poc] FINAL:  1 active display(s): 1
[vd-poc] cleanup verified: display count returned to baseline
```

Stderr carries diagnostic lines from the SLS configuration and any
un-mirror operations.

## Post-run verification

```bash
system_profiler SPDisplaysDataType | grep -ic "display"   # must match baseline
```

## Verdict criteria

- **PASS:** All steps run; virtual display visible in System Settings;
  window draggable to it; FINAL count returns to baseline.
- **PARTIAL:** Display creates but window cannot be dragged onto it OR
  positioning fails; programmatic count still increases on creation.
- **FAIL:** `[vd-poc] FATAL: ...` on stderr, exit code 2 or 3, OR display
  count never increases past BEFORE.

## Troubleshooting

- **Gatekeeper blocks first run:** `xattr -d com.apple.quarantine vd-poc-mac` once,
  then re-run.
- **System asks for Screen Recording permission:** grant under System
  Settings → Privacy & Security → Screen Recording, then re-run.
- **Stderr shows `SLSConfigureDisplayEnabled: -X` (negative):** SkyLight
  rejected the call. Note the error code and document it; this contributes
  to the FAIL outcome's diagnostic information.

## Throwaway

This binary is for one-time validation. After the Phase 4 production port
lands and is verified, the entire `experiments/vd-poc-mac/` directory may be
deleted; its git history will preserve the experiment.
