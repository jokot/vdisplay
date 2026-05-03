# Design: macOS Virtual Display POC

**Status**: approved (brainstorm complete, awaiting user review)
**Date**: 2026-05-03
**Author**: jokot (with Claude)
**Sub-project of**: vdisplay v1
**Implementation plan**: TBD (next via `writing-plans` skill)

## Purpose

Validate that macOS's private `CGVirtualDisplay` API can create an **extended** (not mirrored) virtual display on the developer's MacBook Pro M3 running macOS 14+, before committing to Phase 4 of the vdisplay project (porting Lumen's `vd_helper.m` into our forked Sunshine).

This POC is **throwaway**: a single-binary reproducible experiment that proves (or disproves) the chosen API path. Learnings inform the production port; the POC source itself is **not** the production code.

## Non-Goals

- Capturing frames from the virtual display (separate concern, validated later)
- Sunshine integration (no edits to `upstream/host/`)
- Resolution-matching to a Moonlight client request (production polish)
- Multiple simultaneous virtual displays
- Auto-create/destroy on Moonlight client connect (Lumen's signature feature)
- Audio routing
- Production code signing / notarization
- Distributable build (no `.app` bundle, no installer)
- Cross-OS-version compatibility shims (only test what the developer's machine has today)
- Helper scripts like Lumen's `/tmp/sunshine_vd_id` window-snap integration

## Architecture

```
experiments/vd-poc-mac/
├── README.md           ← what it tests, how to run, expected output
├── build.sh            ← single clang invocation, produces ./vd-poc-mac
├── src/
│   └── vd_poc.m        ← Objective-C, ~120 lines, ported from Lumen vd_helper.m
└── headers/
    └── CGVirtualDisplay.h  ← reverse-engineered private API header (from w0lfschild/macOS_headers)
```

Single binary, no IPC, no parent process. The POC binary itself fills Lumen's "helper subprocess" role — the Terminal is the launching context, which avoids the WindowServer-context bug that affects Sunshine-as-parent (per research note).

Run sequence:
```
$ ./build.sh
$ ./vd-poc-mac
```

## Components

`src/vd_poc.m` is structured as ~6 functions:

```c
load_private_symbols()                  // resolve CGVirtualDisplay* + SLS* via dlsym
print_display_state(label)              // CGGetActiveDisplayList → print count + IDs
build_descriptor(width, height, hz)     // CGVirtualDisplayDescriptor with 597×336mm physical (Lumen value)
create_virtual_display(desc)            // CGVirtualDisplayCreate + CGVirtualDisplayConfigure
position_extended(display_id, x_off)    // SLSBeginDisplayConfiguration → SLSConfigureDisplayOrigin → SLSCompleteDisplayConfiguration
install_sigterm_handler()               // SIGTERM/SIGINT → set quit flag
wait_loop()                             // sleep until quit flag set
destroy_virtual_display(display)        // CGVirtualDisplayInvalidate + CFRelease
main(argc, argv)                        // orchestrates the lifecycle below
```

Ported from Lumen's `vd_helper.m`:
- **KEEP**: `dlsym` symbol loading, descriptor builder, position via SLS, signal handler, lifecycle skeleton
- **DROP**: stdin command parsing (Lumen accepts dynamic resolution from Sunshine via stdin), Sunshine IPC framing, multi-display support, AMFI workaround comments
- **ADD**: explicit before/after display count diff (verification step), more verbose stdout for human reading

## Lifecycle (one POC run)

```
0.  Print process info (pid, macOS version)
1.  Load private symbols via dlsym                    [exit 2 if any missing]
2.  Print BEFORE state (display count + IDs)
3.  Build descriptor: 1920×1080@60, 597×336mm, name "vd-poc"
4.  Create virtual display                            [exit 3 if NULL returned]
5.  Print AFTER state (expect count = before + 1, new ID logged)
6.  Position display at x=2000 (extend right of main)
7.  Print "Created display %d at offset (2000,0). Open System Settings →
    Displays to confirm. Press Ctrl+C or send SIGTERM to destroy."
8.  Wait for SIGTERM/SIGINT
9.  Destroy display
10. Print AFTER-DESTROY state (expect count = original)
11. Exit 0
```

## Error Handling

POC = throwaway, so error handling = **report cleanly + exit non-zero**, no recovery logic. Each failure mode tells us something useful about whether the production approach is viable.

| Failure | Detection | Behavior | What it tells us |
|---|---|---|---|
| `dlsym` returns NULL for any private symbol | Check after each dlsym call | Print missing symbol name + exit 2 | Apple renamed/removed symbol on this macOS — production needs version gating |
| `CGVirtualDisplayCreate` returns NULL | Check return | Print last error, exit 3 | Descriptor rejected (probably pixel-density rule). Try Lumen's exact 597×336 mm |
| `CGVirtualDisplayConfigure` non-zero | Check return code | Print code, attempt destroy, exit 4 | Configure step buggy on this OS |
| `CGGetActiveDisplayList` count unchanged after create | Compare before/after | Print "display did not register", attempt destroy, exit 5 | Display created but WindowServer didn't pick up — context issue (the Lumen parent-process bug) |
| SLS positioning failed | Check `SLSCompleteDisplayConfiguration` return | Print warning but continue (extend mode = nice-to-have for POC; mirror still useful info) | Position-only API broken |
| SIGTERM during create (race) | Check quit flag in main loop | Skip wait, go straight to destroy | Cleanup safety |
| Crash during destroy | N/A | Process exit handles it | OS reclaims display on process exit anyway (verified per Lumen comment) |
| Permission denied / TCC prompt | macOS native dialog | User grants in System Settings, re-run | Document in README — expected first-run friction |

**Key invariant**: POC always attempts destroy on the exit path (including after errors). Even if destroy fails, the OS reclaims the display on process termination per Lumen's documented behavior. So a leaked virtual display should NOT survive past `kill -9 vd-poc-mac`.

## Verification

POC = manually executed, no test framework. Manual + programmatic verification combined.

### Pre-run checks
1. `xcode-select -p` — confirm Command Line Tools installed (provides clang + headers).
2. `sw_vers -productVersion` — note macOS version (must be ≥14.0).
3. `system_profiler SPDisplaysDataType | grep -i "display"` — note baseline display count.

### Run protocol
```bash
cd experiments/vd-poc-mac
./build.sh        # expect: ./vd-poc-mac binary, no errors
./vd-poc-mac      # POC starts; produces stdout below
```

### Expected stdout
```
[vd-poc] pid=12345 macOS=14.5
[vd-poc] loading private symbols...
[vd-poc] all symbols loaded ✓
[vd-poc] BEFORE: 1 active display(s): [1]
[vd-poc] creating virtual display 1920x1080@60Hz...
[vd-poc] AFTER:  2 active display(s): [1, 0xFFFFAAAA]   ← new ID
[vd-poc] positioning at offset (2000, 0)
[vd-poc] ✓ extend mode positioned
[vd-poc] press Ctrl+C to destroy and exit
^C
[vd-poc] received SIGINT, destroying...
[vd-poc] FINAL:  1 active display(s): [1]
[vd-poc] exit 0
```

### Manual verification (during the wait phase)
1. Open **System Settings → Displays** — should show two displays. New one labelled `vd-poc` or a generic "Virtual Display".
2. Drag a window from main monitor to right edge, past x=2000 — should appear on the virtual display.
3. Confirm cursor moves into the virtual display area.
4. Take a screenshot for the portfolio / outcome log.

### Post-run cleanup verification
```bash
system_profiler SPDisplaysDataType | grep -ic "display"   # should match baseline
```

### Test matrix
Run rows that match the developer's hardware. All applicable rows must pass for POC = SUCCESS.

| macOS | Architecture | Expected result |
|---|---|---|
| 14.x | M3 | ✓ pass (target) |
| 15.x | M3 | ✓ pass (if user has 15) |
| 26.x | M3 | ✓ pass (latest, if user has 26) |
| 13.x | any | ✗ expected fail (`CGVirtualDisplay` added 14.0 — documents min OS for extend mode) |

### Verdict criteria

| Outcome | Definition | Project consequence |
|---|---|---|
| **PASS** | All steps run; virtual display visible in System Settings; window draggable onto it; count returns to baseline after destroy | Proceed to Phase 4 production port |
| **PARTIAL** | Display creates but extend positioning fails | Proceed Phase 4 with mirror-only initially; extend deferred to v1.5 |
| **FAIL** | Symbols missing OR create returns NULL OR display count never changes | Major scope pivot — drop Mac extend from v1 (or drop Mac host) |

## Build & Toolchain

Single shell script:

```bash
# experiments/vd-poc-mac/build.sh
#!/usr/bin/env bash
set -euo pipefail
clang \
  -fobjc-arc \
  -Iheaders \
  -framework CoreGraphics \
  -framework Foundation \
  -framework AppKit \
  -Wl,-undefined,dynamic_lookup \
  src/vd_poc.m \
  -o vd-poc-mac
```

Notes:
- `-fobjc-arc` for automatic reference counting on Obj-C objects.
- `-Wl,-undefined,dynamic_lookup` lets us link against `SLS*` symbols (in private SkyLight framework) without explicitly linking the framework path; symbols are resolved at runtime via dlopen of `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`.
- No CMake, no Makefile — clang invocation is small enough.

## Signing & Permissions

Ad-hoc signing (clang default). No Apple Developer ID required.

Expected first-run behaviour:
- macOS may prompt for Screen Recording permission (TCC) under Privacy & Security. If prompted, grant and re-run.
- If no prompt appears, even simpler — proceed with POC.

If macOS Gatekeeper blocks initial run (`"vd-poc-mac" cannot be opened because the developer cannot be verified`), the developer can run `xattr -d com.apple.quarantine vd-poc-mac` once after build, then `./vd-poc-mac` works.

## Effort Estimate

| Task | Estimate |
|---|---|
| Read Lumen `vd_helper.m` + reverse-engineered headers | 1 hour |
| Strip + adapt to single-file POC | 2-4 hours |
| Write `build.sh` + `README.md` | 30 minutes |
| Run + iterate on private-API quirks | 1-3 hours |
| **Total** | **4-8 hours, single session** |

## Next Steps

After POC PASS:
1. Document outcome in `memory/` (which symbols loaded, macOS version, any quirks).
2. Brainstorm + spec the Phase 4 production port (virtual display integrated as a real subprocess of forked Sunshine, under `upstream/host/src/platform/macos/`).
3. Confirm scope memory: macOS extend min OS = whatever passed POC.

After POC PARTIAL:
1. Investigate the SLS positioning calls — check Lumen's error handling; possibly post on Apple forums / file Sunshine issue.
2. Phase 4 may proceed mirror-only for v1; extend deferred to v1.5.
3. Update scope memory.

After POC FAIL:
1. Major project pivot — drop Mac extend mode (or drop Mac host entirely).
2. Re-brainstorm `project_scope.md`.
3. Possibly cancel project if Mac extend was core differentiator.

## References

- Lumen — https://github.com/trollzem/Lumen (Sunshine fork, GPL-3, exact prior art)
- Reverse-engineered header — https://github.com/w0lfschild/macOS_headers/blob/master/macOS/Frameworks/CoreGraphics/1336/CGVirtualDisplay.h
- KhaosT/CGVirtualDisplay minimal example — https://github.com/KhaosT/CGVirtualDisplay
- Chromium `virtual_display_mac_util.mm` — https://chromium.googlesource.com/chromium/src/+/d441ddf663e568fe8383d59a31e0dfacb9d9535b/ui/display/mac/test/virtual_display_mac_util.mm
- Project memory: `memory/mac_vdisplay_research.md` (decision rationale)

## Decisions Locked

The following were settled during the brainstorming session and should not be revisited without an explicit re-spec:

- POC scope = pure validation, no Sunshine integration (Q1=A)
- Code source = copy from Lumen verbatim then strip (Q2=A)
- Location = `experiments/vd-poc-mac/` (Q3=D)
- Verification = manual + programmatic (Q4=C)
- Build system = `build.sh` with raw clang (Q5=A)
- Signing = ad-hoc only (Q6=A)
- Test target = lifecycle + extend positioning (approach B)
