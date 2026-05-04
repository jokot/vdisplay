# Design: Phase 4 — macOS Virtual Display Production Port

**Status**: brainstorm complete, awaiting user review
**Date**: 2026-05-04
**Author**: jokot (with Claude)
**Sub-project of**: vdisplay v1
**Implementation plan**: TBD (next via `writing-plans` skill)
**Dependency**: POC at `experiments/vd-poc-mac/` (PR #1) — validated `CGVirtualDisplay` path on macOS 26.4.1

## Purpose

Integrate a production-grade macOS virtual extended display feature into the forked Sunshine. When a Moonlight client begins a stream, the forked Sunshine spawns a `vd_helper` subprocess that creates a virtual display matching the client's requested resolution and refresh rate. Sunshine streams that virtual display's framebuffer to the client. On stream end, the helper is killed and the display destroyed.

This phase converts Lumen's verbatim Obj-C reference (`upstream/lumen/src/platform/macos/{vd_helper.m, virtual_display.m, virtual_display.h}`) and the POC's empirical findings into a robust feature shipped inside the forked Sunshine binary.

## Non-Goals

- Multi-client virtual displays (single client only — concurrent connections deferred to v1.5)
- Config UI toggle (always-on for v1; opt-out toggle deferred to v1.5)
- Resolution hot-swap mid-stream (helper dies + respawn instead, if ever needed)
- Win IDD provisioner abstraction (Phase 5+; refactor when 2nd platform forces it)
- Sparkle auto-update for hot-fixing private API breakage
- iOS / tvOS Moonlight client paths (Android + Mac/Win desktop only per v1 scope)
- Window-snap launch scripts (Lumen's `/tmp/sunshine_vd_id`)
- Audio routing changes (Sunshine's existing audio path is independent of the visual display)
- Display arrangement persistence across Sunshine restarts

## Architecture

Two binaries shipped inside `Sunshine.app/Contents/MacOS/`:

| Binary | Role |
|--------|------|
| `sunshine` (modified) | Main server. Adds `MacVirtualDisplayManager` C++ class that spawns/manages the helper. |
| `vd_helper` (new, ~280 lines Obj-C) | Subprocess. Creates one virtual display, prints displayID on stdout, blocks on `CFRunLoop` until SIGTERM. |

```
┌─────────────────────────────────┐         ┌─────────────────────────────────┐
│  sunshine (parent process)      │  fork+  │  vd_helper (child process)      │
│                                 │  exec   │                                 │
│  MacVirtualDisplayManager:      │ ──────► │  Lumen-derived:                 │
│   - spawn(width, height, fps)   │         │   - dlsym + create CGVirtualDisplay
│   - read displayID from stdout  │         │   - apply hiDPI modes           │
│   - inject ID into display list │         │   - SLS activate at x=2000      │
│   - SIGTERM on stream end       │         │   - un-mirror (if needed)       │
│   - log helper stderr           │ ◄────── │   - switch to native 1x         │
│                                 │ stdout  │   - block on CFRunLoop          │
│                                 │ stderr  │                                 │
└─────────────────────────────────┘         └─────────────────────────────────┘
```

### Lifecycle

```
Sunshine receives RTSP stream-start (client params known)
  │
  ▼
MacVirtualDisplayManager::spawn(W, H, fps)
  │  ├─ fork()
  │  ├─ child: execve("Sunshine.app/Contents/MacOS/vd_helper", ["W","H","fps"])
  │  ├─ parent: reads pipe(stdout) line "<NNNN>\n"  → display_id_ = NNNN
  │  ├─ parent: spawns reader thread for child stderr → BOOST_LOG[debug] each line
  │  └─ parent: stores child PID for SIGTERM later
  │
  ▼
Sunshine display capture targets display_id_ (existing av_video.m / AVCaptureScreenInput)
  │
  ▼
Stream runs normally
  │
  ▼
Client disconnects → RTSP teardown
  │
  ▼
MacVirtualDisplayManager::teardown()
  │  ├─ kill(child_pid, SIGTERM)
  │  ├─ waitpid(child_pid, NULL, 0) — reaps child
  │  ├─ join stderr reader thread
  │  └─ display_id_ = 0
  │
  ▼
Sunshine display capture falls back to CGMainDisplayID() (main display)
```

### Constraints carried from POC findings

- Helper MUST be a separate process (`CGVirtualDisplay` calls fail from Sunshine's main proc context per Lumen + POC)
- Helper exits cleanly on SIGTERM/SIGINT; OS reclaims the display at process exit (verified via `system_profiler` post-exit)
- `kCGConfigureForSession` for activate; `kCGConfigureForAppOnly` for un-mirror dance
- macOS 14+ (Sonoma) minimum for extend mode; older macOS falls back to main display
- 597×336 mm physical size in descriptor (Lumen value, satisfies pixel-density rule)
- Background-thread alloc fallback if main-thread alloc returns nil (Lumen-observed quirk)
- macOS 26.4.1 surfaces the display via `applySettings` alone; SLS calls return error 1001 (no-op rejection) but are kept verbatim for older macOS compatibility

## Components & Files

### New files (all under `upstream/host/src/platform/macos/`)

| File | Purpose | Lines | Source |
|------|---------|-------|--------|
| `vd_helper.m` | Helper subprocess entry point. Parses `argv[1..3]` = width/height/fps; creates virtual display; prints displayID on stdout; holds via `CFRunLoop` until SIGTERM. | ~280 | Port from `upstream/lumen/src/platform/macos/vd_helper.m` (verbatim minus Sunshine-specific stdin command parsing already absent from POC; carry POC's stripped form forward) |
| `virtual_display_manager.h` | C++ header. `class MacVirtualDisplayManager { spawn, teardown, get_display_id }`. Thread-safe singleton. | ~50 | New, our authorship |
| `virtual_display_manager.mm` | C++/Obj-C++ implementation. Wraps fork+exec, stdout reader, helper-stderr→`BOOST_LOG` forwarder, lifecycle mutex, retry-on-spawn-failure (3× with 200 ms backoff). | ~250 | New, our authorship |

### Modified files

| File | Change |
|------|--------|
| `upstream/host/CMakeLists.txt` | Add second binary target `vd_helper` (deps: `Foundation`, `AppKit`, `CoreGraphics`; linker flag `-Wl,-undefined,dynamic_lookup`). Add new `.mm` to main `sunshine` target. Both targets land in `Sunshine.app/Contents/MacOS/` per existing CMake install rules. |
| `upstream/host/src/platform/macos/display.mm` | At top of `display_names()` (line 196 area), consult `MacVirtualDisplayManager::instance().get_display_id()`. If non-zero, prepend that display to the returned vector so Sunshine streams it instead of the main display. |
| `upstream/host/src/rtsp.cpp` *(or wherever stream session start fires — exact file:line TBD during plan)* | Hook stream-start: call `MacVirtualDisplayManager::spawn(W, H, fps)` with client's negotiated resolution. Hook stream-end: call `MacVirtualDisplayManager::teardown()`. |

### Tests

| File | Purpose |
|------|---------|
| `upstream/host/tests/unit/platform/macos/test_virtual_display_manager.cpp` | Single integration test (gtest): spawn helper, verify displayID parsed and visible in `CGGetActiveDisplayList`, teardown, verify helper PID reaped. Skip on non-macOS / macOS < 14. |

## IPC Protocol

### Helper CLI contract

```
vd_helper <width> <height> <fps>

# stdout (single line, terminated):
<CGDirectDisplayID as uint32_t decimal>\n
  OR
0\n   (failure: helper writes "0", exits non-zero)

# stderr (multiple lines during lifetime):
[vd_helper] <free-form diagnostic line>\n
[vd_helper] <free-form diagnostic line>\n
...

# exit codes:
0 = clean SIGTERM/SIGINT shutdown (after creating + holding display)
1 = bad CLI args (non-numeric or zero W/H/fps)
2 = CGVirtualDisplay class not available (macOS too old)
3 = display creation failed (CGVirtualDisplayCreate returned nil)
4 = SLS configure step failed (Begin returned non-success)
```

### Why simple stdout = ID line

Matches Lumen exactly. Parser is one `parse_uint32(line)` call. No JSON, no length-prefix, no protocol versioning. If we ever need bidirectional control (mid-stream resolution change), we'd version the protocol — but Q1 said single-client-no-hot-swap, so unidirectional is fine for v1.

### Why stderr is unstructured

Helper diagnostics are operator-facing (POC pattern). Parent forwards verbatim to `BOOST_LOG[debug]` with a `[vd_helper child=PID]` prefix.

## C++ Interface

```cpp
// upstream/host/src/platform/macos/virtual_display_manager.h
#pragma once
#include <cstdint>
#include <mutex>
#include <thread>
#include <string>
#include <sys/types.h>

namespace platform::macos {

class MacVirtualDisplayManager {
 public:
  static MacVirtualDisplayManager& instance();

  // Spawn vd_helper with the given parameters. Blocks until either:
  //   - helper prints its displayID on stdout (success: returns the ID)
  //   - helper exits or 5 s timeout elapses (failure: returns 0)
  // Retries up to 3 times with 200 ms backoff on spawn-syscall failures.
  // Thread-safe; concurrent spawn() calls serialise via mutex_.
  uint32_t spawn(int width, int height, int fps);

  // Send SIGTERM to the helper, waitpid, reset state. Idempotent.
  // No-op if no helper is running.
  void teardown();

  // Current virtual display ID, or 0 if no helper running.
  uint32_t get_display_id() const;

 private:
  MacVirtualDisplayManager() = default;
  ~MacVirtualDisplayManager() { teardown(); }
  MacVirtualDisplayManager(const MacVirtualDisplayManager&) = delete;
  MacVirtualDisplayManager& operator=(const MacVirtualDisplayManager&) = delete;

  std::string helper_path_() const;                         // resolves Sunshine.app/Contents/MacOS/vd_helper
  std::string read_line_(int fd, int timeout_ms) const;     // first line of fd or "" on timeout/EOF
  void stderr_pump_(int fd);                                // forwards child stderr lines to BOOST_LOG

  mutable std::mutex mutex_;
  pid_t       helper_pid_   = -1;
  uint32_t    display_id_   = 0;
  std::thread stderr_thread_;
  int         stderr_fd_    = -1;
};

}  // namespace platform::macos
```

## Integration Call Sites

### Stream session start (exact file/line TBD during plan)

```cpp
auto& mgr = platform::macos::MacVirtualDisplayManager::instance();
uint32_t vd_id = mgr.spawn(client_w, client_h, client_fps);
if (vd_id == 0) {
  BOOST_LOG(warning) << "Virtual display unavailable; falling back to main display";
  // Existing capture path uses CGMainDisplayID() — no change needed
}
// Capture pipeline reads display_id_ via display_names() — returns vd_id if non-zero
```

### Stream session end

```cpp
platform::macos::MacVirtualDisplayManager::instance().teardown();
```

### Display enumeration (`display.mm` ~line 196 — `display_names()`)

```cpp
auto vd_id = platform::macos::MacVirtualDisplayManager::instance().get_display_id();
if (vd_id != 0) {
  // Prepend vd_id as the first/preferred display so Sunshine streams it
  // instead of the main display.
}
// ... existing enumeration code ...
```

## Error Handling

### Failure modes

| When | What | Detection | Behaviour | Sunshine UX |
|------|------|-----------|-----------|-------------|
| `fork()` returns -1 | OS resource limit | `errno` set | Retry up to 3× with 200 ms backoff. Final: `BOOST_LOG[error]`, return 0. | Stream falls back to main display (mirror) |
| `execve()` fails (helper binary missing) | Bad install | `errno=ENOENT` in child | Child writes `0\n` + exits 127. Parent reads 0, returns 0. | Same fallback, log "vd_helper binary not found at <path>" |
| Helper exits code 1 (bad args) | Bug | Child exits before stdout | Parent reads EOF, returns 0. | Logged + fallback. Indicates programming error in `spawn()`. |
| Helper exits code 2 (API gone) | macOS rev breaks private SPI | Helper writes `0\n`, exits 2. | Parent reads "0", returns 0. | Logged "CGVirtualDisplay unavailable on this macOS"; fallback (mirror still works) |
| Helper exits code 3 (create fail) | Pixel-density rejection or transient | Helper writes `0\n`, exits 3. | Same as code 2. | Same. |
| Helper exits code 4 (SLS fail) | WindowServer state issue | Helper writes `0\n`, exits 4. | Same. | Same. |
| Helper hangs > 5 s without producing line | OS ground state weird | `select()` timeout in parent | Kill child (SIGKILL), reap, retry up to 3×. Final: return 0. | Logged, fallback. |
| Helper crashes mid-stream | Random system failure | Parent waitpid via SIGCHLD, or stderr EOF | Log to `BOOST_LOG[warning]`. **Do NOT auto-respawn during stream.** Stream continues using last known display ID; capture pipeline may produce blank frames — acceptable for v1, surfaces failure to user. |
| Stream-end called but helper already dead | Stale state | `helper_pid_ != -1` but `kill` returns ESRCH | Treat as success; reset state. | None |
| `spawn()` called twice without `teardown()` | Race / bug | mutex held; second call sees `helper_pid_ != -1` | Log warning, call `teardown()` then re-spawn. | Self-healing |
| Sunshine itself crashes / SIGKILL'd | Catastrophe | OS reaps both processes | OS reclaims display per POC finding (verified via `system_profiler`). | None — clean exit even on hard kill |

### Retry policy (spawn only)

```cpp
for (int attempt = 1; attempt <= 3; attempt++) {
  pid_t pid = try_fork_exec_();
  if (pid > 0) {
    uint32_t id = read_displayid_with_timeout_(stdout_fd, 5000ms);
    if (id != 0) return id;          // success
    kill(pid, SIGKILL); waitpid(pid, NULL, 0);  // cleanup before retry
  }
  if (attempt < 3) std::this_thread::sleep_for(200ms);
}
return 0;  // exhausted retries
```

Retry only the spawn — not the post-spawn lifecycle. Once a helper is running successfully, no auto-respawn.

### Logging categories

- `BOOST_LOG[info]`: spawn success "Virtual display id=NNN created (W×H@fps)"; teardown "Virtual display destroyed"
- `BOOST_LOG[warning]`: retry-able failures (one log line per attempt + a final failure log)
- `BOOST_LOG[error]`: non-retry-able (binary not found, repeated 3× retry exhaustion)
- `BOOST_LOG[debug]`: helper stderr lines forwarded with `[vd_helper child=PID] ...` prefix

### Helper-side error handling

Already exists in POC code (FATAL stderr + exit codes 2/3). Port unchanged. Helper's own background-thread alloc fallback (Lumen pattern) stays.

### Race / concurrency

Single `std::mutex mutex_` covers the manager state. All public methods lock. The stderr-pump thread reads from a fd that's not under the mutex (separate kernel buffer); only joins back to manager state on teardown.

## Verification

### Test 1 — gtest integration test (only automated test)

`upstream/host/tests/unit/platform/macos/test_virtual_display_manager.cpp`. Single test case ~40 lines. Skipped on non-macOS / macOS < 14.

```cpp
TEST(MacVirtualDisplayManagerTest, SpawnAndTeardownRoundtrip) {
  if (macos_version() < 14) GTEST_SKIP();

  auto& mgr = MacVirtualDisplayManager::instance();
  uint32_t id = mgr.spawn(1920, 1080, 60);
  ASSERT_NE(id, 0u) << "vd_helper failed to create virtual display";

  CGDirectDisplayID active[8]; uint32_t count = 0;
  CGGetActiveDisplayList(8, active, &count);
  bool found = std::any_of(active, active + count,
                           [&](auto d) { return d == id; });
  EXPECT_TRUE(found);

  mgr.teardown();
  EXPECT_EQ(mgr.get_display_id(), 0u);
}
```

Wired into Sunshine's existing CMake test target. Run via `ctest` after build.

### Test 2 — manual end-to-end (the verdict gate)

1. Build forked Sunshine: `cmake -B build -G Ninja -S . -DBUILD_DOCS=OFF && ninja -C build`.
2. Run: `./build/Sunshine.app/Contents/MacOS/Sunshine`.
3. Pair Moonlight Android (Oppo Reno 14) with this Sunshine.
4. Stream Desktop at 1080p60 HEVC.
5. **Verify on phone**: should see virtual display content (NOT a mirror of the Mac main).
6. **Verify on Mac**: System Settings → Displays shows two displays during stream, returns to one after disconnect.
7. **Repeat 3× with different resolutions** (720p30, 1440p60, 1080p120 if phone supports) to verify resolution match.
8. **Verify cleanup**: `system_profiler SPDisplaysDataType | grep -ic "display"` returns to baseline 30 s post-disconnect.
9. **Negative test**: kill helper externally during stream (`pkill vd_helper`); verify Sunshine logs warning, stream continues (possibly blank or reverts to main).

PASS criteria: steps 1–7 succeed; step 9 gracefully degrades. PARTIAL: step 7 fails (resolution mismatch). FAIL: step 5 doesn't show virtual display.

## Build & Toolchain

CMake additions to `upstream/host/CMakeLists.txt`:

```cmake
if(APPLE)
  add_executable(vd_helper
    src/platform/macos/vd_helper.m
  )
  target_link_libraries(vd_helper PRIVATE
    "-framework CoreGraphics"
    "-framework Foundation"
    "-framework AppKit"
  )
  target_link_options(vd_helper PRIVATE
    "-Wl,-undefined,dynamic_lookup"
  )
  set_target_properties(vd_helper PROPERTIES
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
  )
  # Install vd_helper alongside Sunshine in the app bundle's MacOS dir.
  install(TARGETS vd_helper RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

  # Add the manager .mm to the main sunshine target.
  target_sources(sunshine PRIVATE
    src/platform/macos/virtual_display_manager.mm
  )
endif()
```

(Exact lines TBD during plan; the existing CMake structure may impose integration tweaks.)

## Signing & Permissions

- Sign both binaries with developer ID + `--options runtime`.
- No special entitlements required (private SPI use is unenforced for non-MAS distribution).
- TCC: Sunshine already prompts for Screen Recording on first run (existing behaviour). Helper inherits no special needs since CGVirtualDisplay creation does not capture frames.

## Effort Estimate

| Task | Estimate |
|---|---|
| Read/understand Sunshine stream-lifecycle code; identify exact integration point | 1-2 days |
| Port `vd_helper.m` from Lumen + POC; adapt to CMake build | 1 day |
| Implement `MacVirtualDisplayManager` C++ class | 2-3 days |
| Wire into `display.mm` + stream lifecycle hooks | 1-2 days |
| Integration test + manual e2e + iterate | 2-3 days |
| **Total** | **7-11 days (~2 weeks)** |

Aligns with brainstorm Q1 (Option C, "2-3 weeks").

## Rollout Plan

1. All work on `feat/phase4-mac-vdisplay` worktree branch.
2. Implementation plan splits into ~10 bite-sized tasks (`writing-plans` skill output).
3. Each task = one commit, two-stage review (subagent-driven-development pattern).
4. Manual e2e at end of plan on developer's MBP M3 + Oppo Reno 14.
5. Open PR; manual review on GitHub.
6. Merge to main after successful e2e + PR review.
7. Tag `v0.1-mac-extend` for portfolio milestone.

## Decisions Locked

The following were settled during brainstorming and should not be revisited without an explicit re-spec:

- Feature scope = match-resolution single-client (Q1=C)
- Config toggle = always-on, no toggle for v1 (Q2=A)
- Sunshine integration = direct hook in Mac display path, not platform abstraction (Q3=A)
- Binary deployment = two binaries (sunshine + vd_helper) inside `Sunshine.app/Contents/MacOS/` (Q4=A)
- Testing = hybrid: one gtest integration test + manual e2e (Q5=C)
- Robustness = production-grade (`MacVirtualDisplayManager` with retry, structured logging, race-safe lifecycle) (Approach=B)

## References

- POC: `experiments/vd-poc-mac/` (PR #1)
- POC outcome memory: `memory/vd_poc_outcome.md`
- Mac vdisplay research memory: `memory/mac_vdisplay_research.md`
- Architecture v1 memory: `memory/architecture_v1.md`
- Lumen reference: `upstream/lumen/src/platform/macos/{vd_helper.m, virtual_display.m, virtual_display.h}`
- Sunshine integration target: `upstream/host/src/platform/macos/display.mm`, `upstream/host/src/rtsp.cpp` (or stream.cpp — TBD during plan)
- Spec for the prior POC: `docs/superpowers/specs/2026-05-03-mac-vdisplay-poc-design.md`
