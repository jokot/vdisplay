# Phase 4 — macOS Virtual Display Production Port: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate a `vd_helper` subprocess into the forked Sunshine so that on Moonlight stream session start, Sunshine spawns the helper to create a macOS virtual extended display matching the client's resolution; helper is killed and display destroyed on session end.

**Architecture:** Two binaries shipped in `Sunshine.app/Contents/MacOS/`. New `MacVirtualDisplayManager` C++ class in Sunshine spawns/manages the helper via fork+exec, reads displayID over stdout, forwards stderr to `BOOST_LOG`, kills helper on session end. `display_names()` injects the virtual displayID. Stream lifecycle hooks live in `stream.cpp::start` / `stream.cpp::session::stop` Mac-only paths.

**Tech Stack:**
- Languages: C++17 (manager class), Objective-C ARC (helper)
- Frameworks: CoreGraphics, Foundation, AppKit (linked to helper); SkyLight (dynamic-lookup)
- Build: CMake + Ninja (Sunshine's existing toolchain)
- Test: gtest (Sunshine's existing harness)
- Logging: Boost.Log via `BOOST_LOG(severity)` macros (Sunshine pattern)

**Spec:** `docs/superpowers/specs/2026-05-04-phase4-mac-vdisplay-port-design.md`

---

## File Structure

| File | Responsibility | New / Modified |
|---|---|---|
| `upstream/host/src/platform/macos/vd_helper.m` | Helper subprocess. Parses W/H/fps argv, creates virtual display via private `CGVirtualDisplay`, prints displayID on stdout, blocks on `CFRunLoop` until SIGTERM. ~280 lines. Verbatim port of `experiments/vd-poc-mac/src/vd_poc.m` minus snapshot/lifecycle prints, plus argv parsing. | New |
| `upstream/host/src/platform/macos/virtual_display_manager.h` | Public C++ header for `class MacVirtualDisplayManager`. Singleton API: `spawn(w,h,fps)`, `teardown()`, `get_display_id()`. | New |
| `upstream/host/src/platform/macos/virtual_display_manager.mm` | Implementation. fork+exec helper, parse stdout, retry, stderr pump thread, mutex-guarded lifecycle. | New |
| `upstream/host/src/platform/macos/display.mm` | Inject virtual displayID at top of `display_names()` (line 196). | Modified |
| `upstream/host/src/stream.cpp` | Spawn at `stream::session::start` (line 1990 area, Mac-only via `#ifdef __APPLE__`); teardown at `stream::session::stop` (line 1957 area, Mac-only). | Modified |
| `upstream/host/CMakeLists.txt` | Add `vd_helper` executable target (Apple-only); add `virtual_display_manager.mm` to existing `sunshine` target Apple-only sources. | Modified |
| `upstream/host/tests/unit/platform/macos/test_virtual_display_manager.cpp` | One gtest integration test: spawn → assert active → teardown → assert reaped. | New |
| `upstream/host/tests/unit/platform/macos/CMakeLists.txt` (or wherever Apple unit tests are wired — check during Task 1 research) | Wire in new test source. | Modified |

Single-purpose files: helper binary stays standalone (~280 lines), manager class header + impl split (50 + 250 lines), test in its own file. Each unit independently understandable.

---

## Note on TDD

Sunshine's existing platform code (`display.mm`, `av_video.m`, etc.) does not have unit tests — typical for OS-specific code where mocking is unrealistic. We follow that pattern: only one automated test (gtest integration test for the manager class round-trip), verified manually e2e for the full streaming path. Tasks 2-9 use the pattern: write small change → build → smoke check → commit. Task 10 is "run the gtest." Task 11 is manual e2e.

---

## Task 1: Bootstrap worktree + research integration points

**Files:**
- No file changes. This task confirms integration points by reading existing Sunshine code in the worktree, and creates a worktree branch from main.

- [ ] **Step 1: Create the feat/phase4-mac-vdisplay worktree from main**

```bash
cd /Users/jokot/dev/vdisplay
git fetch origin
git worktree add ../vdisplay-phase4 -b feat/phase4-mac-vdisplay origin/main
cd ../vdisplay-phase4
```

Expected: worktree at `/Users/jokot/dev/vdisplay-phase4`, on branch `feat/phase4-mac-vdisplay`.

- [ ] **Step 2: Bootstrap submodules in the new worktree**

```bash
./scripts/bootstrap.sh
```

Expected: completes without errors. Sunshine submodules under `upstream/host/third-party/` populated.

- [ ] **Step 3: Smoke-build Sunshine baseline (sanity, no edits yet)**

```bash
cd upstream/host
cmake -B build -G Ninja -S . -DBUILD_DOCS=OFF
ninja -C build
file build/Sunshine.app/Contents/MacOS/Sunshine
```

Expected: builds clean; `file` reports `Mach-O 64-bit executable arm64`.

- [ ] **Step 4: Verify the integration points from the spec**

Run from `/Users/jokot/dev/vdisplay-phase4`:

```bash
sed -n '194,210p' upstream/host/src/platform/macos/display.mm
sed -n '1950,1965p' upstream/host/src/stream.cpp
sed -n '1985,2000p' upstream/host/src/stream.cpp
grep -n "video::config_t" upstream/host/src/video.h | head -5
```

Confirm in your report:
- `display_names()` is at line 196 of `display.mm` (returns `std::vector<std::string>`).
- `streaming_will_stop()` is called near line 1957 in `stream.cpp::session::stop`.
- `streaming_will_start()` is called near line 1996 in `stream.cpp::session::start`, and `session.config.monitor` (typed `video::config_t`) is available there.
- `video::config_t` declares `int width;`, `int height;`, `int framerate;` (in `video.h:23-26`).

Capture the exact line numbers — they will be referenced in Tasks 8 and 9.

- [ ] **Step 5: Commit a placeholder file documenting the research**

Create `upstream/host/src/platform/macos/PHASE4_INTEGRATION_NOTES.md` with the following content (adjust line numbers if Step 4 shows different ones):

```markdown
# Phase 4 integration points (research output for plan Task 1)

These are the exact file:line locations the implementation tasks below modify.
If any have shifted relative to those captured here at branch creation time,
re-verify before editing.

- `upstream/host/src/platform/macos/display.mm:196`
  `display_names()` — return a `std::vector<std::string>`. We will inject the
  virtual display name here in Task 8.

- `upstream/host/src/stream.cpp:~1990`
  `stream::session::start()` — `session.config.monitor` (type `video::config_t`)
  is available here, with fields `width`, `height`, `framerate`. Spawn the
  helper here, Apple-only, in Task 9.

- `upstream/host/src/stream.cpp:~1957`
  `stream::session::stop()` calls `platf::streaming_will_stop()`. We add
  `MacVirtualDisplayManager::teardown()` next to it (Apple-only) in Task 9.

- `upstream/host/src/video.h:23-28`
  `video::config_t` struct — fields used by spawn(): width, height, framerate.

This file is for our own bookkeeping during Phase 4 implementation.
Delete after Phase 4 lands.
```

```bash
git add upstream/host/src/platform/macos/PHASE4_INTEGRATION_NOTES.md
git commit -m "docs(host/macos): document Phase 4 integration line numbers

Captures display_names(), stream::start, and stream::stop locations
referenced by the Phase 4 implementation plan. Will be deleted at the
end of Phase 4 once the integration is in place.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Port vd_helper.m + add CMake target; verify it builds and runs standalone

**Files:**
- Create: `upstream/host/src/platform/macos/vd_helper.m`
- Modify: `upstream/host/CMakeLists.txt`

- [ ] **Step 1: Copy the POC source as the starting point**

```bash
cp experiments/vd-poc-mac/src/vd_poc.m upstream/host/src/platform/macos/vd_helper.m
```

- [ ] **Step 2: Strip POC-specific code; rewrite for production helper**

Replace the entire contents of `upstream/host/src/platform/macos/vd_helper.m` with:

```objc
/**
 * @file src/platform/macos/vd_helper.m
 * @brief Helper subprocess for vdisplay's macOS virtual extended display.
 *
 * Spawned by Sunshine on stream session start. Creates one virtual display
 * via the private CGVirtualDisplay API matching the requested resolution
 * and refresh rate, prints its CGDirectDisplayID on stdout, then blocks
 * on a CFRunLoop until SIGTERM. WindowServer reclaims the display when
 * the process exits.
 *
 * Usage: vd_helper <width> <height> <fps>
 *
 * stdout (one line, terminated):
 *   <CGDirectDisplayID as decimal>\n   on success
 *   0\n                                on failure (exits non-zero)
 *
 * stderr: free-form diagnostic lines forwarded to Sunshine's BOOST_LOG.
 *
 * Exit codes:
 *   0 = clean SIGTERM/SIGINT shutdown
 *   1 = bad CLI args (non-numeric or zero W/H/fps)
 *   2 = CGVirtualDisplay class not available (macOS < 14)
 *   3 = display creation failed (CGVirtualDisplayCreate returned nil)
 *   4 = SLS configure step failed (Begin returned non-success)
 */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <signal.h>
#include <stdlib.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// Private CGVirtualDisplay API (macOS 14+) — declarations only; classes are
// resolved at runtime from CoreGraphics.
// ---------------------------------------------------------------------------

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) unsigned int hiDPI;
@property (retain, nonatomic) NSArray *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (retain, nonatomic) dispatch_queue_t queue;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

extern CGError SLSBeginDisplayConfiguration(CGDisplayConfigRef *);
extern CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool);
extern CGError SLSConfigureDisplayOrigin(CGDisplayConfigRef, CGDirectDisplayID, int32_t, int32_t);
extern CGError SLSCompleteDisplayConfiguration(CGDisplayConfigRef, CGConfigureOption, uint32_t);

// ---------------------------------------------------------------------------
// Module state
// ---------------------------------------------------------------------------

static CGVirtualDisplay *g_display = nil;
static CGVirtualDisplayDescriptor *g_descriptor = nil;
static volatile sig_atomic_t g_should_exit = 0;

static void on_signal(int sig) {
  g_should_exit = 1;
  dispatch_async(dispatch_get_main_queue(), ^{
    CFRunLoopStop(CFRunLoopGetMain());
  });
  (void)sig;
}

// ---------------------------------------------------------------------------
// Helpers (ported from POC, comment trimmed for production)
// ---------------------------------------------------------------------------

static uint32_t create_virtual_display(int width, int height, int fps) {
  CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
  desc.name              = @"vdisplay-host";
  desc.vendorID          = 0xF0F0;
  desc.productID         = 0x5678;
  desc.serialNum         = arc4random();
  desc.maxPixelsWide     = (unsigned int)width;
  desc.maxPixelsHigh     = (unsigned int)height;
  // Fixed 27" physical size — required to satisfy CGVirtualDisplay's
  // pixel-density rule. Do NOT scale with width/height.
  desc.sizeInMillimeters = CGSizeMake(597, 336);
  desc.whitePoint        = CGPointMake(0.3127, 0.3290);
  desc.redPrimary        = CGPointMake(0.64, 0.33);
  desc.greenPrimary      = CGPointMake(0.30, 0.60);
  desc.bluePrimary       = CGPointMake(0.15, 0.06);
  [desc setDispatchQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)];
  desc.terminationHandler = ^(id s, id d) {
    fprintf(stderr, "[vd_helper] WindowServer terminated our virtual display\n");
    (void)s; (void)d;
  };

  CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
  if (!display) {
    fprintf(stderr, "[vd_helper] initWithDescriptor returned nil; trying background thread\n");
    __block CGVirtualDisplay *bg = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
      bg = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
      dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC));
    display = bg;
  }
  if (!display || display.displayID == 0) {
    return 0;
  }

  g_display    = display;
  g_descriptor = desc;
  return display.displayID;
}

static BOOL apply_settings(CGVirtualDisplay *display, int width, int height, int fps) {
  CGVirtualDisplayMode *native = [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)width
                                                                      height:(unsigned int)height
                                                                 refreshRate:(double)fps];
  if (!native) return NO;
  CGVirtualDisplayMode *half = [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)(width / 2)
                                                                    height:(unsigned int)(height / 2)
                                                               refreshRate:(double)fps];
  CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
  settings.hiDPI = 1;
  settings.modes = half ? @[native, half] : @[native];
  return [display applySettings:settings];
}

static int sls_activate(uint32_t virtualID) {
  CGDisplayConfigRef cfg = NULL;
  CGError err = SLSBeginDisplayConfiguration(&cfg);
  if (err != kCGErrorSuccess || !cfg) {
    fprintf(stderr, "[vd_helper] SLSBeginDisplayConfiguration failed: %d\n", err);
    return 4;
  }
  err = SLSConfigureDisplayEnabled(cfg, virtualID, true);
  fprintf(stderr, "[vd_helper] SLSConfigureDisplayEnabled(%u): %d\n", virtualID, err);

  CGDirectDisplayID main_id = CGMainDisplayID();
  size_t main_w = CGDisplayPixelsWide(main_id);
  int32_t origin_x = (int32_t)main_w > 2000 ? (int32_t)main_w : 2000;
  err = SLSConfigureDisplayOrigin(cfg, virtualID, origin_x, 0);
  fprintf(stderr, "[vd_helper] SLSConfigureDisplayOrigin(%u, %d, 0): %d\n",
          virtualID, origin_x, err);

  err = SLSCompleteDisplayConfiguration(cfg, kCGConfigureForSession, 0);
  fprintf(stderr, "[vd_helper] SLSCompleteDisplayConfiguration: %d\n", err);
  usleep(500000);
  return 0;
}

static void force_extend_mode(CGDirectDisplayID virtualID) {
  CGDirectDisplayID main_id = CGMainDisplayID();

  if (CGDisplayMirrorsDisplay(main_id) == virtualID) {
    fprintf(stderr, "[vd_helper] un-mirror: main %u mirroring virtual %u\n",
            main_id, virtualID);
    CGDisplayConfigRef cfg = NULL;
    CGBeginDisplayConfiguration(&cfg);
    if (cfg) {
      CGConfigureDisplayMirrorOfDisplay(cfg, main_id, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    }
  }
  if (CGDisplayIsInMirrorSet(virtualID)) {
    fprintf(stderr, "[vd_helper] un-mirror: virtual %u in mirror set\n", virtualID);
    CGDisplayConfigRef cfg = NULL;
    CGBeginDisplayConfiguration(&cfg);
    if (cfg) {
      CGConfigureDisplayMirrorOfDisplay(cfg, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    }
  }
  if (CGDisplayMirrorsDisplay(virtualID) != 0) {
    fprintf(stderr, "[vd_helper] un-mirror: virtual %u mirroring %u\n",
            virtualID, CGDisplayMirrorsDisplay(virtualID));
    CGDisplayConfigRef cfg = NULL;
    CGBeginDisplayConfiguration(&cfg);
    if (cfg) {
      CGConfigureDisplayMirrorOfDisplay(cfg, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    }
  }

  CGDisplayConfigRef cfg = NULL;
  CGBeginDisplayConfiguration(&cfg);
  if (cfg) {
    size_t main_w = CGDisplayPixelsWide(main_id);
    CGConfigureDisplayOrigin(cfg, virtualID, (int32_t)main_w, 0);
    CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
  }

  if (CGMainDisplayID() == virtualID && main_id != virtualID) {
    fprintf(stderr, "[vd_helper] virtual became main, restoring %u as main\n", main_id);
    CGDisplayConfigRef cfg2 = NULL;
    CGBeginDisplayConfiguration(&cfg2);
    if (cfg2) {
      CGConfigureDisplayOrigin(cfg2, main_id, 0, 0);
      CGCompleteDisplayConfiguration(cfg2, kCGConfigureForAppOnly);
    }
  }
}

static void switch_to_native_1x(CGDirectDisplayID display_id, int width, int height) {
  NSDictionary *opts = @{ (NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
  CFArrayRef modes = CGDisplayCopyAllDisplayModes(display_id, (CFDictionaryRef)opts);
  if (!modes) return;
  CGDisplayModeRef target = NULL;
  CFIndex n = CFArrayGetCount(modes);
  for (CFIndex i = 0; i < n; i++) {
    CGDisplayModeRef m = (CGDisplayModeRef)CFArrayGetValueAtIndex(modes, i);
    size_t lw = CGDisplayModeGetWidth(m);
    size_t lh = CGDisplayModeGetHeight(m);
    size_t pw = CGDisplayModeGetPixelWidth(m);
    size_t ph = CGDisplayModeGetPixelHeight(m);
    if ((int)lw == width && (int)lh == height && pw == lw && ph == lh) {
      target = m;
      break;
    }
  }
  if (target) {
    CGError err = CGDisplaySetDisplayMode(display_id, target, NULL);
    fprintf(stderr, "[vd_helper] switched to native %dx%d (1x): %d\n", width, height, err);
  } else {
    fprintf(stderr, "[vd_helper] native %dx%d 1x mode not found; staying retina 2x\n",
            width, height);
  }
  CFRelease(modes);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc != 4) {
      fprintf(stderr, "[vd_helper] usage: vd_helper <width> <height> <fps>\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }
    int width  = atoi(argv[1]);
    int height = atoi(argv[2]);
    int fps    = atoi(argv[3]);
    if (width <= 0 || height <= 0 || fps <= 0) {
      fprintf(stderr, "[vd_helper] bad args: %d %d %d\n", width, height, fps);
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 1;
    }

    if (!NSClassFromString(@"CGVirtualDisplay")) {
      fprintf(stderr, "[vd_helper] CGVirtualDisplay unavailable on this macOS\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 2;
    }

    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP,  on_signal);

    uint32_t id = create_virtual_display(width, height, fps);
    if (id == 0) {
      fprintf(stderr, "[vd_helper] CGVirtualDisplay creation failed\n");
      fprintf(stdout, "0\n");
      fflush(stdout);
      return 3;
    }
    if (!apply_settings(g_display, width, height, fps)) {
      fprintf(stderr, "[vd_helper] applySettings returned NO\n");
    }
    int sls_rc = sls_activate(id);
    if (sls_rc != 0) {
      fprintf(stdout, "0\n");
      fflush(stdout);
      g_display = nil; g_descriptor = nil;
      return sls_rc;
    }
    if (CGDisplayIsInMirrorSet(id) || CGDisplayMirrorsDisplay(id) != 0) {
      force_extend_mode(id);
      usleep(500000);
    }
    switch_to_native_1x(id, width, height);
    usleep(500000);

    fprintf(stdout, "%u\n", id);
    fflush(stdout);

    while (!g_should_exit) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
    }

    fprintf(stderr, "[vd_helper] received signal, releasing display %u\n", id);
    g_display = nil;
    g_descriptor = nil;
  }
  return 0;
}
```

- [ ] **Step 3: Add the `vd_helper` target to CMake**

First, check where the existing `sunshine` Apple-only sources live in `upstream/host/CMakeLists.txt`. Run:

```bash
grep -nE "APPLE|MACOSX|MacOS|platform/macos" upstream/host/CMakeLists.txt | head -10
grep -nE "APPLE|platform/macos" upstream/host/cmake/*.cmake 2>/dev/null | head -10
```

The existing Apple display source `display.mm` is wired in (since the baseline build at Task 1 produces a working `Sunshine.app`). Identify the file containing the `if(APPLE)` block — typically `upstream/host/CMakeLists.txt` or a file under `cmake/`. Note its path.

Then add the helper target. In whichever file has the existing `if(APPLE)` block (most likely `upstream/host/CMakeLists.txt`), append the following AT THE END of that `if(APPLE)` block (still inside the `if(APPLE) ... endif()` scope):

```cmake
  # Phase 4: vd_helper subprocess for virtual extended display.
  add_executable(vd_helper
    src/platform/macos/vd_helper.m
  )
  set_source_files_properties(
    src/platform/macos/vd_helper.m
    PROPERTIES COMPILE_FLAGS "-fobjc-arc"
  )
  target_link_libraries(vd_helper PRIVATE
    "-framework CoreGraphics"
    "-framework Foundation"
    "-framework AppKit"
  )
  target_link_options(vd_helper PRIVATE
    "-Wl,-undefined,dynamic_lookup"
  )
  # Place vd_helper alongside Sunshine in the .app bundle's MacOS dir.
  set_target_properties(vd_helper PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}"
  )
  add_dependencies(sunshine vd_helper)
```

If the existing `if(APPLE)` block is in a sub-cmake file (e.g. `cmake/macos.cmake`), put the target there instead.

- [ ] **Step 4: Build and verify the helper binary**

```bash
cd upstream/host
cmake --build build --target vd_helper 2>&1 | tail -10
file build/vd_helper
```

Expected: `Mach-O 64-bit executable arm64`. May get `unused parameter` warnings for `fps` parameter in `create_virtual_display` — those are expected (Lumen pattern, the parameter is consumed in `apply_settings`). No errors.

- [ ] **Step 5: Smoke-run the helper standalone**

```bash
./build/vd_helper 1920 1080 60 &
HELPER_PID=$!
sleep 2
ps -p $HELPER_PID >/dev/null && echo "helper alive" || echo "helper dead"
kill -TERM $HELPER_PID
sleep 1
```

Expected: `helper alive` printed; helper exits cleanly within 1s of SIGTERM.

- [ ] **Step 6: Commit**

```bash
git add upstream/host/src/platform/macos/vd_helper.m upstream/host/CMakeLists.txt
# (or whichever cmake file actually changed)
git commit -m "host(macos): vd_helper subprocess for virtual extended display

Ports the validated POC vd_helper into the forked Sunshine, parameterised
on argv (width, height, fps) so Sunshine can spawn it per stream session
with the Moonlight client's negotiated resolution. Build target is a
separate Mach-O executable that lands next to Sunshine in
Sunshine.app/Contents/MacOS/. Linked with -Wl,-undefined,dynamic_lookup
so the SkyLight SLS* private symbols resolve at runtime.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: MacVirtualDisplayManager skeleton header + helper-path resolution

**Files:**
- Create: `upstream/host/src/platform/macos/virtual_display_manager.h`
- Create: `upstream/host/src/platform/macos/virtual_display_manager.mm`
- Modify: `upstream/host/CMakeLists.txt` (add `.mm` to `sunshine` target's APPLE-only sources)

- [ ] **Step 1: Write the header**

Create `upstream/host/src/platform/macos/virtual_display_manager.h`:

```cpp
/**
 * @file src/platform/macos/virtual_display_manager.h
 * @brief Manages the lifecycle of a vd_helper subprocess that creates a
 *        macOS virtual extended display for streaming.
 */
#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <sys/types.h>

namespace platf::macos {

  class MacVirtualDisplayManager {
  public:
    static MacVirtualDisplayManager &instance();

    /**
     * Spawn vd_helper with the given parameters. Blocks until either:
     *   - helper prints its displayID on stdout (returns the ID, > 0)
     *   - helper exits or 5 s timeout elapses (returns 0)
     * Retries up to 3 times with 200 ms backoff on spawn-syscall failures.
     * Thread-safe; concurrent spawn() calls serialise via mutex_.
     */
    uint32_t spawn(int width, int height, int fps);

    /**
     * Send SIGTERM to the helper, waitpid, reset state. Idempotent;
     * no-op if no helper is running.
     */
    void teardown();

    /**
     * Current virtual display ID, or 0 if no helper is running.
     */
    uint32_t get_display_id() const;

  private:
    MacVirtualDisplayManager() = default;
    ~MacVirtualDisplayManager();
    MacVirtualDisplayManager(const MacVirtualDisplayManager &) = delete;
    MacVirtualDisplayManager &operator=(const MacVirtualDisplayManager &) = delete;

    std::string helper_path_() const;
    std::string read_line_(int fd, int timeout_ms) const;
    void stderr_pump_(int fd);

    mutable std::mutex mutex_;
    pid_t       helper_pid_   = -1;
    uint32_t    display_id_   = 0;
    std::thread stderr_thread_;
    int         stderr_fd_    = -1;
  };

}  // namespace platf::macos
```

- [ ] **Step 2: Write the implementation skeleton with only `instance()`, `helper_path_()`, and `get_display_id()`**

Create `upstream/host/src/platform/macos/virtual_display_manager.mm`:

```objc
/**
 * @file src/platform/macos/virtual_display_manager.mm
 * @brief Implementation of MacVirtualDisplayManager.
 */
#include "virtual_display_manager.h"

#include "src/logging.h"  // BOOST_LOG

#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>

#include <chrono>
#include <thread>
#include <vector>

namespace platf::macos {

  MacVirtualDisplayManager &MacVirtualDisplayManager::instance() {
    static MacVirtualDisplayManager s;
    return s;
  }

  MacVirtualDisplayManager::~MacVirtualDisplayManager() {
    teardown();
  }

  uint32_t MacVirtualDisplayManager::get_display_id() const {
    std::lock_guard<std::mutex> lk(mutex_);
    return display_id_;
  }

  std::string MacVirtualDisplayManager::helper_path_() const {
    // Resolve the running Sunshine binary's path, then sibling-locate vd_helper.
    char buf[PATH_MAX];
    uint32_t size = sizeof(buf);
    if (_NSGetExecutablePath(buf, &size) != 0) {
      BOOST_LOG(error) << "vd_helper: _NSGetExecutablePath failed (size needed " << size << ")";
      return {};
    }
    // Use NSString to canonicalise (strip "./" / resolve symlinks).
    @autoreleasepool {
      NSString *self_path  = [[NSString stringWithUTF8String:buf] stringByResolvingSymlinksInPath];
      NSString *self_dir   = [self_path stringByDeletingLastPathComponent];
      NSString *helper     = [self_dir stringByAppendingPathComponent:@"vd_helper"];
      return std::string(helper.UTF8String);
    }
  }

  // teardown(), spawn(), read_line_(), stderr_pump_() are filled in by Tasks 4-6.
  void MacVirtualDisplayManager::teardown() {
    // Implemented in Task 5.
  }

  uint32_t MacVirtualDisplayManager::spawn(int width, int height, int fps) {
    // Implemented in Task 4.
    (void)width; (void)height; (void)fps;
    BOOST_LOG(warning) << "vd_helper: MacVirtualDisplayManager::spawn() not yet implemented";
    return 0;
  }

  std::string MacVirtualDisplayManager::read_line_(int fd, int timeout_ms) const {
    // Implemented in Task 4.
    (void)fd; (void)timeout_ms;
    return {};
  }

  void MacVirtualDisplayManager::stderr_pump_(int fd) {
    // Implemented in Task 6.
    (void)fd;
  }

}  // namespace platf::macos
```

- [ ] **Step 3: Wire `virtual_display_manager.mm` into the `sunshine` target**

In whichever file has the `if(APPLE)` block (per Task 2 Step 3 research), find the source list for the existing `sunshine` target's APPLE-only sources (where `display.mm`, `av_video.m`, etc. are added). Append:

```cmake
  src/platform/macos/virtual_display_manager.mm
```

Verify by grepping after edit:

```bash
grep -n "virtual_display_manager.mm" upstream/host/CMakeLists.txt upstream/host/cmake/*.cmake 2>/dev/null
```

Expected: one match.

- [ ] **Step 4: Build (full sunshine target)**

```bash
cd upstream/host
cmake --build build 2>&1 | tail -10
```

Expected: builds clean (zero new warnings beyond pre-existing). If you see `error: 'BOOST_LOG' was not declared`, the `#include "src/logging.h"` path is relative differently on Sunshine — re-check by reading any other `.mm`/`.cpp` in `src/platform/macos/` that uses `BOOST_LOG` and copy their include line.

- [ ] **Step 5: Commit**

```bash
git add upstream/host/src/platform/macos/virtual_display_manager.h \
        upstream/host/src/platform/macos/virtual_display_manager.mm \
        upstream/host/CMakeLists.txt
# (or whichever cmake file was edited)
git commit -m "host(macos): MacVirtualDisplayManager skeleton

Adds the C++ singleton that will own vd_helper's lifecycle. This commit
lands the header, implementation skeleton with helper-path resolution
via _NSGetExecutablePath, and the get_display_id accessor. spawn(),
teardown(), and the stderr pump are stubbed; subsequent tasks fill them
in. Wires the .mm into the sunshine CMake target's Apple-only sources.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Implement spawn() — fork+exec + stdout displayID parse + retry

**Files:**
- Modify: `upstream/host/src/platform/macos/virtual_display_manager.mm`

- [ ] **Step 1: Replace the stub `spawn()` and stub `read_line_()` with full implementations**

In `upstream/host/src/platform/macos/virtual_display_manager.mm`, replace the existing stub `spawn()` and `read_line_()` definitions with:

```objc
  std::string MacVirtualDisplayManager::read_line_(int fd, int timeout_ms) const {
    using clock = std::chrono::steady_clock;
    auto deadline = clock::now() + std::chrono::milliseconds(timeout_ms);
    std::string line;
    char ch;

    while (clock::now() < deadline) {
      auto remaining = std::chrono::duration_cast<std::chrono::microseconds>(
                         deadline - clock::now())
                         .count();
      struct timeval tv;
      tv.tv_sec  = remaining / 1'000'000;
      tv.tv_usec = remaining % 1'000'000;
      fd_set rset;
      FD_ZERO(&rset);
      FD_SET(fd, &rset);
      int rc = ::select(fd + 1, &rset, nullptr, nullptr, &tv);
      if (rc <= 0) {
        return {};  // timeout or error
      }
      ssize_t n = ::read(fd, &ch, 1);
      if (n <= 0) {
        return line;  // EOF
      }
      if (ch == '\n') {
        return line;
      }
      line.push_back(ch);
    }
    return {};
  }

  uint32_t MacVirtualDisplayManager::spawn(int width, int height, int fps) {
    std::lock_guard<std::mutex> lk(mutex_);

    if (helper_pid_ > 0) {
      BOOST_LOG(warning) << "vd_helper: spawn() called while helper already running (pid="
                         << helper_pid_ << "); tearing down first";
      // Inline teardown without re-locking: see Task 5 for the full version;
      // this path runs only on programmer error and is safe enough.
      ::kill(helper_pid_, SIGTERM);
      ::waitpid(helper_pid_, nullptr, 0);
      helper_pid_ = -1;
      display_id_ = 0;
      if (stderr_fd_ >= 0) { ::close(stderr_fd_); stderr_fd_ = -1; }
      if (stderr_thread_.joinable()) stderr_thread_.join();
    }

    std::string helper = helper_path_();
    if (helper.empty()) {
      BOOST_LOG(error) << "vd_helper: cannot resolve helper binary path";
      return 0;
    }

    char width_buf[16], height_buf[16], fps_buf[16];
    std::snprintf(width_buf,  sizeof(width_buf),  "%d", width);
    std::snprintf(height_buf, sizeof(height_buf), "%d", height);
    std::snprintf(fps_buf,    sizeof(fps_buf),    "%d", fps);

    for (int attempt = 1; attempt <= 3; ++attempt) {
      int stdout_pipe[2];
      int stderr_pipe[2];
      if (::pipe(stdout_pipe) < 0) {
        BOOST_LOG(warning) << "vd_helper: pipe() failed (attempt " << attempt << "): " << ::strerror(errno);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        continue;
      }
      if (::pipe(stderr_pipe) < 0) {
        BOOST_LOG(warning) << "vd_helper: pipe() failed (attempt " << attempt << "): " << ::strerror(errno);
        ::close(stdout_pipe[0]); ::close(stdout_pipe[1]);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        continue;
      }

      pid_t pid = ::fork();
      if (pid < 0) {
        BOOST_LOG(warning) << "vd_helper: fork() failed (attempt " << attempt << "): " << ::strerror(errno);
        ::close(stdout_pipe[0]); ::close(stdout_pipe[1]);
        ::close(stderr_pipe[0]); ::close(stderr_pipe[1]);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        continue;
      }
      if (pid == 0) {
        // Child: redirect stdout and stderr, exec helper.
        ::dup2(stdout_pipe[1], STDOUT_FILENO);
        ::dup2(stderr_pipe[1], STDERR_FILENO);
        ::close(stdout_pipe[0]); ::close(stdout_pipe[1]);
        ::close(stderr_pipe[0]); ::close(stderr_pipe[1]);

        const char *argv[] = {
          helper.c_str(),
          width_buf,
          height_buf,
          fps_buf,
          nullptr,
        };
        ::execv(helper.c_str(), const_cast<char **>(argv));
        // execv only returns on error.
        std::fprintf(stderr, "[vd_helper-child] execv failed: %s\n", ::strerror(errno));
        ::fprintf(stdout, "0\n");
        ::fflush(stdout);
        ::_exit(127);
      }

      // Parent
      ::close(stdout_pipe[1]);
      ::close(stderr_pipe[1]);

      std::string id_line = read_line_(stdout_pipe[0], 5000);
      ::close(stdout_pipe[0]);

      uint32_t parsed = 0;
      if (!id_line.empty()) {
        char *end = nullptr;
        unsigned long val = std::strtoul(id_line.c_str(), &end, 10);
        if (end != id_line.c_str() && val != 0 && val <= UINT32_MAX) {
          parsed = static_cast<uint32_t>(val);
        }
      }

      if (parsed != 0) {
        helper_pid_ = pid;
        display_id_ = parsed;
        stderr_fd_  = stderr_pipe[0];
        stderr_thread_ = std::thread([this, fd = stderr_pipe[0]]() {
          stderr_pump_(fd);
        });
        BOOST_LOG(info) << "vd_helper: virtual display id=" << display_id_
                        << " created (" << width << "x" << height << "@" << fps << ")";
        return display_id_;
      }

      // Spawn or parse failed; clean up and retry.
      BOOST_LOG(warning) << "vd_helper: spawn attempt " << attempt
                         << " produced no displayID (pid=" << pid << ")";
      ::kill(pid, SIGKILL);
      ::waitpid(pid, nullptr, 0);
      ::close(stderr_pipe[0]);
      if (attempt < 3) std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    BOOST_LOG(error) << "vd_helper: gave up after 3 spawn attempts";
    return 0;
  }
```

Note: the `<cstring>`, `<cstdio>`, `<cerrno>`, `<climits>` headers used (`strerror`, `snprintf`, `errno`, `UINT32_MAX`) are pulled in via `<Foundation/Foundation.h>` and `<mach-o/dyld.h>` already in this file, so no new `#include`s are required. If a build error reports a missing symbol, add the matching standard header at the top.

- [ ] **Step 2: Build**

```bash
cd upstream/host
cmake --build build 2>&1 | tail -10
```

Expected: clean build. If you see `error: 'errno' undeclared`, add `#include <cerrno>` at the top of `virtual_display_manager.mm`.

- [ ] **Step 3: Sanity smoke (manual)**

Write a tiny scratch program that calls the manager directly (only used for manual verification — do NOT commit this file):

```bash
cat > /tmp/spawn_smoke.mm <<'EOF'
#include "src/platform/macos/virtual_display_manager.h"
#include <cstdio>
#include <unistd.h>

int main() {
  auto &m = platf::macos::MacVirtualDisplayManager::instance();
  uint32_t id = m.spawn(1920, 1080, 60);
  std::printf("got id=%u\n", id);
  if (id) {
    sleep(2);
    m.teardown();
  }
  return id == 0 ? 1 : 0;
}
EOF
```

Skip this if it requires too much CMake plumbing; the gtest in Task 7 will exercise the same path. Just confirm the build is clean.

- [ ] **Step 4: Commit**

```bash
git add upstream/host/src/platform/macos/virtual_display_manager.mm
git commit -m "host(macos): MacVirtualDisplayManager::spawn implementation

Implements fork+exec spawn of vd_helper with stdout pipe for displayID
parsing (5 s select() timeout) and stderr pipe stashed for the pump
thread (added in a later task). Retries up to 3x with 200 ms backoff on
spawn-syscall failures or empty/zero displayID. Logs structured events
via BOOST_LOG: info on success, warning per failed attempt, error on
final exhaustion. Stub teardown() inside spawn handles the
already-running case without re-entrant locking.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Implement teardown()

**Files:**
- Modify: `upstream/host/src/platform/macos/virtual_display_manager.mm`

- [ ] **Step 1: Replace the stub `teardown()`**

Replace the existing stub `teardown()` body with:

```objc
  void MacVirtualDisplayManager::teardown() {
    pid_t pid_to_reap = -1;
    int   fd_to_close = -1;
    std::thread thread_to_join;
    {
      std::lock_guard<std::mutex> lk(mutex_);
      if (helper_pid_ <= 0) {
        return;  // nothing to do
      }
      pid_to_reap = helper_pid_;
      fd_to_close = stderr_fd_;
      thread_to_join = std::move(stderr_thread_);
      helper_pid_ = -1;
      display_id_ = 0;
      stderr_fd_  = -1;
    }
    // Outside the mutex so the stderr pump thread (which may be blocked on
    // read()) can be unblocked by closing its fd, then joined.
    if (::kill(pid_to_reap, SIGTERM) != 0 && errno != ESRCH) {
      BOOST_LOG(warning) << "vd_helper: kill(SIGTERM) failed: " << ::strerror(errno);
    }
    int status = 0;
    if (::waitpid(pid_to_reap, &status, 0) < 0) {
      BOOST_LOG(warning) << "vd_helper: waitpid failed: " << ::strerror(errno);
    }
    if (fd_to_close >= 0) {
      ::close(fd_to_close);
    }
    if (thread_to_join.joinable()) {
      thread_to_join.join();
    }
    BOOST_LOG(info) << "vd_helper: virtual display destroyed (pid=" << pid_to_reap
                    << " status=" << status << ")";
  }
```

Also: now that `teardown()` is real, simplify the inline cleanup inside `spawn()` (the block under `if (helper_pid_ > 0)`). Replace those 7 inline lines with a call:

Find this in `spawn()`:

```cpp
    if (helper_pid_ > 0) {
      BOOST_LOG(warning) << "vd_helper: spawn() called while helper already running (pid="
                         << helper_pid_ << "); tearing down first";
      // Inline teardown without re-locking: ...
      ::kill(helper_pid_, SIGTERM);
      ::waitpid(helper_pid_, nullptr, 0);
      helper_pid_ = -1;
      display_id_ = 0;
      if (stderr_fd_ >= 0) { ::close(stderr_fd_); stderr_fd_ = -1; }
      if (stderr_thread_.joinable()) stderr_thread_.join();
    }
```

Replace with (note: we hold the lock here, but `teardown()` re-acquires it; we must release first):

```cpp
    if (helper_pid_ > 0) {
      BOOST_LOG(warning) << "vd_helper: spawn() called while helper already running (pid="
                         << helper_pid_ << "); tearing down first";
    }
```

…then move the body of `spawn()` after the lock-release point. Restructure: remove the `std::lock_guard<std::mutex> lk(mutex_);` from the top of `spawn()`. Instead, immediately after the duplicate-helper check, do:

```cpp
    // Drop the lock before calling teardown(), which re-acquires.
    bool need_teardown = false;
    {
      std::lock_guard<std::mutex> lk(mutex_);
      if (helper_pid_ > 0) {
        need_teardown = true;
        BOOST_LOG(warning) << "vd_helper: spawn() called while helper already running (pid="
                           << helper_pid_ << "); tearing down first";
      }
    }
    if (need_teardown) {
      teardown();
    }

    std::lock_guard<std::mutex> lk(mutex_);
    // ... rest of spawn (helper_path_ resolution, retry loop, etc.)
```

The cleanest structure: `spawn()` opens with the duplicate-detect-under-tiny-lock + conditional `teardown()`, then re-takes the lock for the actual fork+exec work.

Reproduce the full final `spawn()` to avoid ambiguity. Replace the entire `spawn()` body (added in Task 4) with:

```objc
  uint32_t MacVirtualDisplayManager::spawn(int width, int height, int fps) {
    // Detect a still-running helper without holding the lock through
    // teardown() (which re-acquires).
    {
      std::lock_guard<std::mutex> lk(mutex_);
      if (helper_pid_ > 0) {
        BOOST_LOG(warning) << "vd_helper: spawn() called while helper already running (pid="
                           << helper_pid_ << "); tearing down first";
      }
    }
    teardown();  // idempotent

    std::lock_guard<std::mutex> lk(mutex_);

    std::string helper = helper_path_();
    if (helper.empty()) {
      BOOST_LOG(error) << "vd_helper: cannot resolve helper binary path";
      return 0;
    }

    char width_buf[16], height_buf[16], fps_buf[16];
    std::snprintf(width_buf,  sizeof(width_buf),  "%d", width);
    std::snprintf(height_buf, sizeof(height_buf), "%d", height);
    std::snprintf(fps_buf,    sizeof(fps_buf),    "%d", fps);

    for (int attempt = 1; attempt <= 3; ++attempt) {
      int stdout_pipe[2];
      int stderr_pipe[2];
      if (::pipe(stdout_pipe) < 0) {
        BOOST_LOG(warning) << "vd_helper: pipe() failed (attempt " << attempt << "): " << ::strerror(errno);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        continue;
      }
      if (::pipe(stderr_pipe) < 0) {
        BOOST_LOG(warning) << "vd_helper: pipe() failed (attempt " << attempt << "): " << ::strerror(errno);
        ::close(stdout_pipe[0]); ::close(stdout_pipe[1]);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        continue;
      }

      pid_t pid = ::fork();
      if (pid < 0) {
        BOOST_LOG(warning) << "vd_helper: fork() failed (attempt " << attempt << "): " << ::strerror(errno);
        ::close(stdout_pipe[0]); ::close(stdout_pipe[1]);
        ::close(stderr_pipe[0]); ::close(stderr_pipe[1]);
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
        continue;
      }
      if (pid == 0) {
        ::dup2(stdout_pipe[1], STDOUT_FILENO);
        ::dup2(stderr_pipe[1], STDERR_FILENO);
        ::close(stdout_pipe[0]); ::close(stdout_pipe[1]);
        ::close(stderr_pipe[0]); ::close(stderr_pipe[1]);
        const char *argv[] = {
          helper.c_str(), width_buf, height_buf, fps_buf, nullptr,
        };
        ::execv(helper.c_str(), const_cast<char **>(argv));
        std::fprintf(stderr, "[vd_helper-child] execv failed: %s\n", ::strerror(errno));
        ::fprintf(stdout, "0\n");
        ::fflush(stdout);
        ::_exit(127);
      }

      ::close(stdout_pipe[1]);
      ::close(stderr_pipe[1]);

      std::string id_line = read_line_(stdout_pipe[0], 5000);
      ::close(stdout_pipe[0]);

      uint32_t parsed = 0;
      if (!id_line.empty()) {
        char *end = nullptr;
        unsigned long val = std::strtoul(id_line.c_str(), &end, 10);
        if (end != id_line.c_str() && val != 0 && val <= UINT32_MAX) {
          parsed = static_cast<uint32_t>(val);
        }
      }

      if (parsed != 0) {
        helper_pid_ = pid;
        display_id_ = parsed;
        stderr_fd_  = stderr_pipe[0];
        stderr_thread_ = std::thread([this, fd = stderr_pipe[0]]() {
          stderr_pump_(fd);
        });
        BOOST_LOG(info) << "vd_helper: virtual display id=" << display_id_
                        << " created (" << width << "x" << height << "@" << fps << ")";
        return display_id_;
      }

      BOOST_LOG(warning) << "vd_helper: spawn attempt " << attempt
                         << " produced no displayID (pid=" << pid << ")";
      ::kill(pid, SIGKILL);
      ::waitpid(pid, nullptr, 0);
      ::close(stderr_pipe[0]);
      if (attempt < 3) std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    BOOST_LOG(error) << "vd_helper: gave up after 3 spawn attempts";
    return 0;
  }
```

- [ ] **Step 2: Build**

```bash
cd upstream/host
cmake --build build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add upstream/host/src/platform/macos/virtual_display_manager.mm
git commit -m "host(macos): MacVirtualDisplayManager::teardown implementation

Implements idempotent teardown: SIGTERM the helper, waitpid, close the
stderr pipe (which unblocks the pump thread's read()), join the pump
thread. State (pid, display_id, fd, thread) is captured under the mutex
and reset, then the OS calls run lock-free so the pump thread joining
doesn't deadlock against a teardown caller. Restructures spawn() to
call teardown() (now public/idempotent) instead of inlining cleanup, so
both code paths use the same machinery.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Implement stderr pump thread → BOOST_LOG forwarder

**Files:**
- Modify: `upstream/host/src/platform/macos/virtual_display_manager.mm`

- [ ] **Step 1: Replace the stub `stderr_pump_()`**

Replace the existing stub with:

```objc
  void MacVirtualDisplayManager::stderr_pump_(int fd) {
    pid_t my_pid;
    {
      std::lock_guard<std::mutex> lk(mutex_);
      my_pid = helper_pid_;  // captured for prefix
    }

    std::string buf;
    char read_buf[256];
    for (;;) {
      ssize_t n = ::read(fd, read_buf, sizeof(read_buf));
      if (n <= 0) {
        // EOF or error: helper exited or fd was closed by teardown().
        if (!buf.empty()) {
          BOOST_LOG(debug) << "[vd_helper child=" << my_pid << "] " << buf;
        }
        return;
      }
      for (ssize_t i = 0; i < n; ++i) {
        char ch = read_buf[i];
        if (ch == '\n') {
          BOOST_LOG(debug) << "[vd_helper child=" << my_pid << "] " << buf;
          buf.clear();
        } else {
          buf.push_back(ch);
        }
      }
    }
  }
```

- [ ] **Step 2: Build**

```bash
cd upstream/host
cmake --build build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add upstream/host/src/platform/macos/virtual_display_manager.mm
git commit -m "host(macos): MacVirtualDisplayManager stderr pump

Reads helper.stderr line-by-line and forwards each line to BOOST_LOG[debug]
with a [vd_helper child=PID] prefix. The thread blocks on read() and is
unblocked by teardown() closing the fd, which produces a 0-byte read
that exits the loop cleanly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: gtest integration test

**Files:**
- Create: `upstream/host/tests/unit/platform/macos/test_virtual_display_manager.cpp`
- Modify: whichever CMake file lists Apple-only test sources (typically `upstream/host/tests/unit/platform/macos/CMakeLists.txt`, or a parent that scans the directory)

- [ ] **Step 1: Find the existing macOS test wiring**

```bash
ls upstream/host/tests/unit/platform/macos/
cat upstream/host/tests/unit/platform/macos/CMakeLists.txt 2>/dev/null
grep -rn "test_common.cpp\|platform/macos" upstream/host/tests/CMakeLists.txt upstream/host/tests/unit 2>/dev/null | head -10
```

Identify how `tests/unit/platform/macos/test_common.cpp` is wired in. We'll add ours alongside it.

- [ ] **Step 2: Write the test**

Create `upstream/host/tests/unit/platform/macos/test_virtual_display_manager.cpp`:

```cpp
/**
 * Integration test for platf::macos::MacVirtualDisplayManager.
 * Skipped on macOS < 14 (CGVirtualDisplay was added in Sonoma).
 */
#include <gtest/gtest.h>

#include <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <chrono>
#include <thread>

#include "src/platform/macos/virtual_display_manager.h"

namespace {

  long macos_major_version() {
    @autoreleasepool {
      NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
      return (long)v.majorVersion;
    }
  }

}  // namespace

TEST(MacVirtualDisplayManagerTest, SpawnAndTeardownRoundtrip) {
  if (macos_major_version() < 14) {
    GTEST_SKIP() << "CGVirtualDisplay requires macOS 14+";
  }

  auto &m = platf::macos::MacVirtualDisplayManager::instance();
  uint32_t id = m.spawn(1920, 1080, 60);
  ASSERT_NE(id, 0u) << "vd_helper failed to create virtual display";

  // Allow WindowServer a moment to register the new display.
  std::this_thread::sleep_for(std::chrono::milliseconds(500));

  CGDirectDisplayID active[16];
  uint32_t count = 0;
  CGGetActiveDisplayList(16, active, &count);
  bool found = std::any_of(active, active + count,
                           [&](CGDirectDisplayID d) { return d == id; });
  EXPECT_TRUE(found) << "Virtual display id=" << id
                     << " not visible to CGGetActiveDisplayList";

  m.teardown();
  EXPECT_EQ(m.get_display_id(), 0u);
}
```

- [ ] **Step 3: Wire the test source into CMake**

Based on Step 1's findings, add `test_virtual_display_manager.cpp` to the test target. The exact line depends on Sunshine's test CMake structure:

- If `upstream/host/tests/unit/platform/macos/CMakeLists.txt` exists with a `target_sources(...)` or `add_test(...)` call, append the new file there.
- Otherwise, find where `test_common.cpp` is added (likely `upstream/host/tests/CMakeLists.txt`) and add `test_virtual_display_manager.cpp` next to it inside the existing `if(APPLE)` block.

Verify after edit:

```bash
grep -rn "test_virtual_display_manager.cpp" upstream/host/tests/ upstream/host/CMakeLists.txt | head -5
```

Expected: one match.

- [ ] **Step 4: Build the test target**

```bash
cd upstream/host
cmake --build build 2>&1 | tail -10
```

Expected: clean build, the test binary (often `tests` or `sunshine_tests`) is up-to-date.

- [ ] **Step 5: Run the new test**

```bash
cd upstream/host
ctest --test-dir build -R MacVirtualDisplayManagerTest --output-on-failure
```

Expected: `1/1 Test #N: ... Passed`. If the test binary's name differs, run via:

```bash
./build/tests --gtest_filter=MacVirtualDisplayManagerTest.*
```

If the test SKIPs because macOS < 14: this is acceptable, the dev's M3 should be on 14+. If FAIL: read the error message and check that `vd_helper` is co-located with the test binary (it lives in `build/`, the test binary also lives in `build/`, so `helper_path_()` should resolve correctly).

- [ ] **Step 6: Commit**

```bash
git add upstream/host/tests/unit/platform/macos/test_virtual_display_manager.cpp
# plus whichever CMake file was edited
git commit -m "host(macos): gtest integration test for MacVirtualDisplayManager

One round-trip test: spawn helper, sleep 500 ms for WindowServer settle,
assert displayID present in CGGetActiveDisplayList, teardown, assert
display_id back to 0. Skipped on macOS < 14 since CGVirtualDisplay
requires Sonoma.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Inject virtual display in display.mm::display_names()

**Files:**
- Modify: `upstream/host/src/platform/macos/display.mm`

- [ ] **Step 1: Add the include and inject the virtual display ID**

In `upstream/host/src/platform/macos/display.mm`, near the top of the file, add (alongside other `#include`s):

```objc
#include "src/platform/macos/virtual_display_manager.h"
```

Then locate `display_names()` (line ~196, function returns `std::vector<std::string>`). Replace its body with:

```objc
  std::vector<std::string> display_names(mem_type_e hwdevice_type) {
    __block std::vector<std::string> display_names;

    auto display_array = [AVVideo displayNames];

    display_names.reserve([display_array count] + 1);

    // Phase 4: if a virtual extended display is active, prepend it so it
    // appears as the first/preferred display for streaming.
    uint32_t vd_id = platf::macos::MacVirtualDisplayManager::instance().get_display_id();
    if (vd_id != 0) {
      display_names.emplace_back(std::to_string(vd_id));
    }

    [display_array enumerateObjectsUsingBlock:^(NSDictionary *_Nonnull obj, NSUInteger idx, BOOL *_Nonnull stop) {
      NSString *name = obj[@"name"];
      display_names.emplace_back(name.UTF8String);
    }];

    return display_names;
  }
```

The virtual display ID is added as a string (matching how Sunshine's display_names returns string identifiers; AVVideo returns names like `"1"` or `"Built-in Retina Display"`, which are CGDirectDisplayID-derived). Adding the numeric ID at index 0 makes it the default that Sunshine selects when no display is explicitly chosen.

- [ ] **Step 2: Build**

```bash
cd upstream/host
cmake --build build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add upstream/host/src/platform/macos/display.mm
git commit -m "host(macos): display.mm::display_names injects virtual display

If MacVirtualDisplayManager is currently managing a virtual extended
display, prepend that display's CGDirectDisplayID (as a string) to the
returned list so Sunshine's display-selection logic prefers it for
streaming. Falls back transparently to the built-in display list when
no virtual display is active.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Stream lifecycle hooks (spawn at session start, teardown at session stop)

**Files:**
- Modify: `upstream/host/src/stream.cpp`

- [ ] **Step 1: Add the include**

Near the top of `upstream/host/src/stream.cpp`, alongside other platform includes (search for `#include "platform/common.h"` and add immediately after), wrap with `#ifdef __APPLE__`:

```cpp
#ifdef __APPLE__
#include "platform/macos/virtual_display_manager.h"
#endif
```

- [ ] **Step 2: Hook spawn at `stream::session::start`, just before `platf::streaming_will_start()`**

Locate (near line 1996):

```cpp
      // If this is the first session, invoke the platform callbacks
      if (++running_sessions == 1) {
        platf::streaming_will_start();
```

Replace with:

```cpp
      // If this is the first session, invoke the platform callbacks
      if (++running_sessions == 1) {
#ifdef __APPLE__
        // Phase 4: spawn the macOS virtual extended display helper.
        platf::macos::MacVirtualDisplayManager::instance().spawn(
          session.config.monitor.width,
          session.config.monitor.height,
          session.config.monitor.framerate);
#endif
        platf::streaming_will_start();
```

The spawn returning 0 is non-fatal — we still call `streaming_will_start()`, and `display_names()` from Task 8 falls back to the main display.

- [ ] **Step 3: Hook teardown at `stream::session::stop`, alongside `platf::streaming_will_stop()`**

Locate (near line 1957):

```cpp
        if (revert_display_config) {
          display_device::revert_configuration();
        }

        platf::streaming_will_stop();
      }
```

Replace with:

```cpp
        if (revert_display_config) {
          display_device::revert_configuration();
        }

        platf::streaming_will_stop();

#ifdef __APPLE__
        // Phase 4: tear down the macOS virtual extended display helper.
        platf::macos::MacVirtualDisplayManager::instance().teardown();
#endif
      }
```

Note: this puts teardown AFTER `streaming_will_stop()` so any platform
cleanup that might depend on the virtual display still being alive runs first.

- [ ] **Step 4: Build the full sunshine target**

```bash
cd upstream/host
cmake --build build 2>&1 | tail -10
file build/Sunshine.app/Contents/MacOS/Sunshine
file build/vd_helper
```

Expected: clean build, both binaries are arm64 Mach-O executables.

- [ ] **Step 5: Commit**

```bash
git add upstream/host/src/stream.cpp
git commit -m "host(stream): wire MacVirtualDisplayManager into session lifecycle

On stream session start (first session of a connection), spawn the
vd_helper subprocess with the client's negotiated width/height/framerate.
On stream session stop, send SIGTERM to the helper. Apple-only via
#ifdef __APPLE__. Fallback path (helper spawn returns 0) is silent —
display_names() simply does not see a virtual display and Sunshine
streams the main display.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Run the integration test on the target machine

**Files:** none (verification step).

- [ ] **Step 1: Re-run the gtest integration test against the full build**

```bash
cd upstream/host
ctest --test-dir build -R MacVirtualDisplayManagerTest --output-on-failure
```

Expected: PASS.

- [ ] **Step 2: Verify post-test cleanup (no leaked display)**

```bash
# Wait a moment for OS to reclaim, then count displays.
sleep 2
system_profiler SPDisplaysDataType | grep -ic "display"
```

Expected: matches the baseline display count from before the test ran.

- [ ] **Step 3: Capture the test log into the integration notes**

Append to `upstream/host/src/platform/macos/PHASE4_INTEGRATION_NOTES.md`:

```markdown

## gtest run log (Task 10)

Date: <today, YYYY-MM-DD>
Result: PASS / FAIL / SKIP — fill in.
```

Replace the template with the actual outcome.

- [ ] **Step 4: Commit (only if Step 3 added content)**

```bash
git add upstream/host/src/platform/macos/PHASE4_INTEGRATION_NOTES.md
git commit -m "docs(host/macos): record Task 10 gtest result

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Manual end-to-end test

**Files:** none (manual verification by the developer).

This task is executed by the developer (jokot) on the target hardware (MacBook Pro M3 + Oppo Reno 14, network = boarding-house WiFi 5GHz or similar).

- [ ] **Step 1: Run the forked Sunshine**

```bash
cd /Users/jokot/dev/vdisplay-phase4/upstream/host
./build/Sunshine.app/Contents/MacOS/Sunshine
```

If first run, complete the admin user/pass setup at https://localhost:47990.

- [ ] **Step 2: Pair Moonlight Android (Oppo Reno 14)**

On the Oppo: Moonlight → add PC → Mac IP → pair (PIN dance in Sunshine UI).

- [ ] **Step 3: Stream Desktop**

Set Moonlight to 1920x1080, 60fps, HEVC, 50 Mbps. Start streaming "Desktop".

- [ ] **Step 4: Visual verification**

While streaming:
1. On the Mac, open System Settings → Displays. Confirm two displays in the arrangement panel: built-in + virtual.
2. On the phone, the streamed content should be of the **virtual** display, not the main Mac display. (The desktop wallpaper / contents will NOT match what's on the Mac main screen.)
3. Drag a window from main to past x=2000. The window should appear on the phone stream.

Take a screenshot of System Settings showing both displays.

- [ ] **Step 5: Disconnect and verify cleanup**

Stop the Moonlight stream. Within 30 s of disconnect:

```bash
system_profiler SPDisplaysDataType | grep -ic "display"
```

Expected: returns to the baseline (1 if no external monitor).

Verify Sunshine logs (browse to `https://localhost:47990` → Logs, or tail Sunshine's log file):

- `[info] vd_helper: virtual display id=NNN created (1920x1080@60)` should appear at stream start.
- `[info] vd_helper: virtual display destroyed` at stream end.
- Several `[debug] [vd_helper child=PID] ...` lines from the helper's stderr forwarded.

- [ ] **Step 6: Repeat with different resolutions**

Repeat Step 3 with these settings, verifying each:

- 1280x720 @ 60 fps
- 2560x1440 @ 60 fps (if phone supports)
- 1920x1080 @ 30 fps

For each, confirm:
- Sunshine log shows `created (W x H @ fps)` matching the request.
- The virtual display in System Settings shows the requested resolution.

- [ ] **Step 7: Negative test — kill helper externally**

```bash
# In another terminal while a stream is active:
pkill -INT vd_helper
```

Expected:
- Sunshine logs `[warning] vd_helper: ...` (helper exited unexpectedly).
- The active stream may go blank or revert to the main display (acceptable for v1; just verify Sunshine itself does not crash).
- Disconnecting the stream cleanly succeeds; reconnecting respawns the helper.

- [ ] **Step 8: Record outcome in memory**

Create `/Users/jokot/.claude/projects/-Users-jokot-dev-vdisplay/memory/phase4_outcome.md`:

```markdown
---
name: Phase 4 production port outcome
description: Result of integrating vd_helper + MacVirtualDisplayManager into forked Sunshine — verdict, observed quirks, follow-ups for v1.5
type: project
---

## Verdict
<PASS / PARTIAL / FAIL>

## Environment
- Date run: <YYYY-MM-DD>
- Hardware: MacBook Pro M3
- macOS version: <version>
- Phone: Oppo Reno 14 (Moonlight Android)
- Network: <which one>

## Observed behaviour
- Stream started → vd_helper spawned, displayID logged: <yes/no, value>
- Stream content on phone matched virtual display (not Mac main): <yes/no>
- Drag window past x=2000 visible on phone: <yes/no>
- Resolutions tested: <list>
- Cleanup baseline restored within 30s of disconnect: <yes/no>
- Negative test (pkill vd_helper) — Sunshine survived: <yes/no>

## Notes
<anything surprising, error codes, helper crashes, retry-loop firing, etc.>

**Why:** Phase 4 is the last big derisk for vdisplay v1's Mac extend mode. PASS here means the project's biggest unknown is fully solved end to end.
**How to apply:** Use this file as the starting point when writing Phase 4 release notes / portfolio writeup. Carry follow-ups (config toggle, multi-client, hot-resolution-change) into v1.5 brainstorming.
```

Append a one-line entry to `/Users/jokot/.claude/projects/-Users-jokot-dev-vdisplay/memory/MEMORY.md`:

```markdown
- [Phase 4 outcome](phase4_outcome.md) — <PASS/PARTIAL/FAIL> on macOS <version>
```

(No git commit for memory files — they live outside the repo.)

- [ ] **Step 9: Final cleanup of `PHASE4_INTEGRATION_NOTES.md`**

Once the manual e2e passes, delete the temporary notes file:

```bash
git rm upstream/host/src/platform/macos/PHASE4_INTEGRATION_NOTES.md
git commit -m "docs(host/macos): remove Phase 4 integration notes

Phase 4 implementation complete; the temporary research/log file
served its purpose during the implementation and is no longer needed.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Plan task |
|---|---|
| Architecture (two binaries, lifecycle diagram) | Tasks 2 (helper binary), 3-6 (manager class), 9 (lifecycle wiring) |
| Components & Files (3 new + 2 modified + 1 test) | Tasks 2, 3, 7, 8, 9 |
| IPC Protocol (CLI contract, exit codes) | Task 2 (helper main + exit codes) |
| C++ Interface (`MacVirtualDisplayManager`) | Tasks 3 (header + skeleton), 4-6 (impl) |
| Integration Call Sites | Tasks 8 (display.mm), 9 (stream.cpp) |
| Error Handling table (11 rows) | Task 4 (retry loop, fork/exec failures), Task 5 (teardown idempotency, ESRCH), Task 6 (stderr EOF) |
| Verification (gtest + manual e2e) | Task 7 (gtest), Tasks 10-11 (run + manual) |
| Build & Toolchain (CMake additions) | Tasks 2 + 3 (CMake edits), Task 9 (full build verification) |
| Signing & Permissions | Inherited from existing Sunshine signing pipeline; no new entitlements (covered in spec, no plan task needed since it's a no-op for our build) |
| Decisions Locked (Q1-Q5 + Approach B) | Tasks honour all 6 decisions |

**Type / name consistency:**

- `MacVirtualDisplayManager` — class name consistent across header (Task 3), impl (Tasks 3-6), test (Task 7), and integration sites (Tasks 8-9).
- Method signatures `spawn(int, int, int)`, `teardown()`, `get_display_id()` — consistent.
- Member field names `helper_pid_`, `display_id_`, `stderr_thread_`, `stderr_fd_`, `mutex_` — used identically in Tasks 3 (declaration) and Tasks 4-6 (implementation).
- Namespace `platf::macos` — used in header (Task 3), impl (Tasks 3-6), test (Task 7), display.mm (Task 8), stream.cpp (Task 9). Note: Sunshine's existing platform code uses `platf::` (confirmed in the existing `platf::streaming_will_start` calls). Using `platf::macos` is a sub-namespace; if Sunshine's actual existing convention is to put Mac-specific code at top level under `platf::`, the implementer may need to drop the `::macos` sub-namespace. Verify in Task 3 Step 4 (full build); if it conflicts, adjust the namespace consistently across all files in this plan.
- Helper binary name `vd_helper` — consistent in CMake target name (Task 2), helper-path-resolution (Task 3), test (Task 7 implicit — same dir), and stream.cpp comments (Task 9).
- Exit codes 0/1/2/3/4 from spec — implemented in Task 2's `main()`.

**Placeholder scan:**

- "exact line depends on Sunshine's test CMake structure" in Task 7 Step 3: this is a one-shot research instruction, not a TBD in delivered code. The implementer reads existing structure and adds the file in the matching place. Acceptable per writing-plans skill guidance ("research-during-task" is OK when followed by concrete instructions).
- "if it conflicts, adjust the namespace consistently across all files in this plan" in Self-Review type-consistency note: this is a fall-back in case Sunshine's existing convention differs from `platf::macos`. Should be caught at Task 3 Step 4's build check; if it triggers, the implementer applies the same rename across Tasks 3-9.

No "TODO", "implement later", or empty steps remaining.
