# macOS Virtual Display POC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single-binary macOS POC that creates a virtual extended display via the private `CGVirtualDisplay` API, validating the API path before committing to Phase 4 of the vdisplay project.

**Architecture:** One Objective-C source file under `experiments/vd-poc-mac/`, built by a single `build.sh` clang invocation, run from Terminal. The binary acts as Lumen's "helper subprocess" — Terminal is the launching context, avoiding the WindowServer-context bug that affects Sunshine-as-parent. Uses Objective-C `@interface` declarations of private CGVirtualDisplay classes and `extern` declarations of SkyLight `SLS*` C functions, resolved at link time via `-Wl,-undefined,dynamic_lookup`.

**Tech Stack:**
- Language: Objective-C (ARC)
- Compiler: clang from Xcode Command Line Tools
- Frameworks: CoreGraphics, Foundation, AppKit (linked); SkyLight (dynamic lookup)
- Build: `build.sh` shell script
- Test framework: none — manual verification via stdout assertions and visual inspection of System Settings → Displays
- Source of truth for the port: `upstream/lumen/src/platform/macos/vd_helper.m`

**Spec:** `docs/superpowers/specs/2026-05-03-mac-vdisplay-poc-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `experiments/vd-poc-mac/README.md` | Pre-run checks, run protocol, expected stdout, manual verification steps, verdict criteria |
| `experiments/vd-poc-mac/build.sh` | Single clang invocation producing `./vd-poc-mac` binary |
| `experiments/vd-poc-mac/src/vd_poc.m` | Entire POC implementation: private-API declarations, lifecycle, signal handling, verification snapshots |

Single Obj-C file (~250 lines) keeps the POC scannable and matches its throwaway nature. No headers split out; private API `@interface` declarations live inline in the .m file (matching Lumen's pattern). Header file mentioned in the spec architecture section is unnecessary — Lumen's `virtual_display.h` is the production-side interface, irrelevant for a standalone POC binary.

---

## Note on TDD

The spec explicitly states: "POC = manually executed, no test framework." There are no unit tests in this plan; the "test" of each increment is **building, running the binary, and observing that the printed output and System Settings state match the expected values**. Each task therefore follows the pattern: edit code → build → run → assert against expected stdout (and where applicable, observe Displays panel) → commit.

---

## Task 1: Skeleton — directory structure + minimal binary that builds and runs

**Files:**
- Create: `experiments/vd-poc-mac/src/vd_poc.m`
- Create: `experiments/vd-poc-mac/build.sh`

- [ ] **Step 1: Create the directory structure**

```bash
mkdir -p experiments/vd-poc-mac/src
```

- [ ] **Step 2: Write the minimal `vd_poc.m`**

Create `experiments/vd-poc-mac/src/vd_poc.m`:

```objc
/**
 * vd_poc.m — macOS virtual display proof-of-concept.
 *
 * Validates that private CGVirtualDisplay + SkyLight SLS APIs can create
 * an extended virtual display on macOS 14+. Throwaway — informs Phase 4
 * production port of Lumen's vd_helper.m into the forked Sunshine.
 */

#import <Foundation/Foundation.h>

int main(void) {
  @autoreleasepool {
    fprintf(stdout, "[vd-poc] hello, world\n");
    fflush(stdout);
  }
  return 0;
}
```

- [ ] **Step 3: Write `build.sh`**

Create `experiments/vd-poc-mac/build.sh`:

```bash
#!/usr/bin/env bash
# Build the macOS virtual display POC.
# Single clang invocation; uses dynamic-lookup so SLS* symbols resolve at runtime
# from /System/Library/PrivateFrameworks/SkyLight.framework/SkyLight.

set -euo pipefail

cd "$(dirname "$0")"

clang \
  -fobjc-arc \
  -Wall -Wextra \
  -framework CoreGraphics \
  -framework Foundation \
  -framework AppKit \
  -Wl,-undefined,dynamic_lookup \
  src/vd_poc.m \
  -o vd-poc-mac

echo "Built ./vd-poc-mac"
```

- [ ] **Step 4: Make `build.sh` executable**

```bash
chmod +x experiments/vd-poc-mac/build.sh
```

- [ ] **Step 5: Build**

```bash
./experiments/vd-poc-mac/build.sh
```

Expected: prints `Built ./vd-poc-mac`, exit 0, no compiler warnings.

- [ ] **Step 6: Run**

```bash
./experiments/vd-poc-mac/vd-poc-mac
```

Expected stdout: `[vd-poc] hello, world`, exit 0.

- [ ] **Step 7: Add experiments build artifacts to .gitignore**

Append to `/Users/jokot/dev/vdisplay/.gitignore`:

```
# experiments/ POC binaries
experiments/**/vd-poc-mac
experiments/**/*.dSYM/
```

- [ ] **Step 8: Commit**

```bash
git add experiments/vd-poc-mac/src/vd_poc.m experiments/vd-poc-mac/build.sh .gitignore
git commit -m "experiment(vd-poc-mac): skeleton — empty Obj-C binary that builds and runs

Smallest possible step: a hello-world Obj-C source file under
experiments/vd-poc-mac/src/, plus build.sh that drives clang with the
flags we'll need (ARC, dynamic_lookup linker flag for SkyLight). Verifies
that Xcode Command Line Tools clang produces a working ARM64 binary on
macOS 14+ before we touch the private CGVirtualDisplay API.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Private API declarations + runtime availability check

**Files:**
- Modify: `experiments/vd-poc-mac/src/vd_poc.m`

- [ ] **Step 1: Add private API @interface declarations and SLS extern declarations**

Replace the contents of `experiments/vd-poc-mac/src/vd_poc.m` with:

```objc
/**
 * vd_poc.m — macOS virtual display proof-of-concept.
 *
 * Validates that private CGVirtualDisplay + SkyLight SLS APIs can create
 * an extended virtual display on macOS 14+. Throwaway — informs Phase 4
 * production port of Lumen's vd_helper.m into the forked Sunshine.
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#include <signal.h>
#include <unistd.h>

// ---------------------------------------------------------------------------
// Private CGVirtualDisplay API (macOS 14+) — declarations only; classes are
// resolved at runtime from CoreGraphics. Field layout reverse-engineered from
// Lumen / w0lfschild/macOS_headers.
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

// SkyLight private C functions — resolved at link time via -Wl,-undefined,dynamic_lookup
extern CGError SLSBeginDisplayConfiguration(CGDisplayConfigRef *);
extern CGError SLSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool);
extern CGError SLSConfigureDisplayOrigin(CGDisplayConfigRef, CGDirectDisplayID, int32_t, int32_t);
extern CGError SLSCompleteDisplayConfiguration(CGDisplayConfigRef, CGConfigureOption, uint32_t);

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(void) {
  @autoreleasepool {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    fprintf(stdout, "[vd-poc] pid=%d macOS=%ld.%ld.%ld\n",
            getpid(), (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion);
    fflush(stdout);

    fprintf(stdout, "[vd-poc] checking CGVirtualDisplay availability...\n");
    fflush(stdout);

    if (!NSClassFromString(@"CGVirtualDisplay")) {
      fprintf(stderr, "[vd-poc] FATAL: CGVirtualDisplay class not available on this macOS\n");
      return 2;
    }
    if (!NSClassFromString(@"CGVirtualDisplayDescriptor")) {
      fprintf(stderr, "[vd-poc] FATAL: CGVirtualDisplayDescriptor class not available\n");
      return 2;
    }
    if (!NSClassFromString(@"CGVirtualDisplayMode")) {
      fprintf(stderr, "[vd-poc] FATAL: CGVirtualDisplayMode class not available\n");
      return 2;
    }
    if (!NSClassFromString(@"CGVirtualDisplaySettings")) {
      fprintf(stderr, "[vd-poc] FATAL: CGVirtualDisplaySettings class not available\n");
      return 2;
    }
    fprintf(stdout, "[vd-poc] all CGVirtualDisplay classes resolved ✓\n");
    fflush(stdout);
  }
  return 0;
}
```

- [ ] **Step 2: Build**

```bash
./experiments/vd-poc-mac/build.sh
```

Expected: builds clean. Compiler may emit warnings about unused `extern` declarations — that's fine; we'll use them in later tasks.

- [ ] **Step 3: Run**

```bash
./experiments/vd-poc-mac/vd-poc-mac
```

Expected stdout (version digits will vary):
```
[vd-poc] pid=NNNNN macOS=14.X.X
[vd-poc] checking CGVirtualDisplay availability...
[vd-poc] all CGVirtualDisplay classes resolved ✓
```

If any class is missing, the binary exits 2 and prints which class — that is the FAIL outcome from the spec ("API path dead on this OS").

- [ ] **Step 4: Commit**

```bash
git add experiments/vd-poc-mac/src/vd_poc.m
git commit -m "experiment(vd-poc-mac): private API declarations + availability check

Adds the reverse-engineered @interface declarations for CGVirtualDisplay,
CGVirtualDisplayMode, CGVirtualDisplaySettings, and CGVirtualDisplayDescriptor,
plus extern C declarations for the four SkyLight SLS* configuration functions.
NSClassFromString runtime checks fail fast with exit 2 if Apple has renamed
or removed any of the four classes on the current macOS — that's the spec's
defined FAIL outcome.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Display state snapshot helper

**Files:**
- Modify: `experiments/vd-poc-mac/src/vd_poc.m`

- [ ] **Step 1: Add the snapshot helper above `main`**

Insert this function just before `int main(...)`:

```objc
/**
 * Print the current active display list and return its count.
 * Used to verify before/after display creation.
 */
static uint32_t print_display_state(const char *label) {
  CGDirectDisplayID displays[32];
  uint32_t count = 0;
  CGError err = CGGetActiveDisplayList(32, displays, &count);
  if (err != kCGErrorSuccess) {
    fprintf(stderr, "[vd-poc] CGGetActiveDisplayList failed (err=%d)\n", err);
    return 0;
  }
  fprintf(stdout, "[vd-poc] %-7s %u active display(s):", label, count);
  for (uint32_t i = 0; i < count; i++) {
    fprintf(stdout, " %u", displays[i]);
  }
  fprintf(stdout, "\n");
  fflush(stdout);
  return count;
}
```

- [ ] **Step 2: Call the snapshot inside `main` (immediately before the `return 0;`)**

In `main`, after the "all CGVirtualDisplay classes resolved" log line and before `return 0;`, add:

```objc
    print_display_state("BEFORE:");
    print_display_state("AFTER:");
```

The two calls back-to-back will, at this stage, return the same count — that's expected; we haven't created anything yet.

- [ ] **Step 3: Build**

```bash
./experiments/vd-poc-mac/build.sh
```

Expected: clean build.

- [ ] **Step 4: Run**

```bash
./experiments/vd-poc-mac/vd-poc-mac
```

Expected stdout (number of displays depends on whether external monitors are connected):
```
[vd-poc] pid=NNNNN macOS=14.X.X
[vd-poc] checking CGVirtualDisplay availability...
[vd-poc] all CGVirtualDisplay classes resolved ✓
[vd-poc] BEFORE: 1 active display(s): 1
[vd-poc] AFTER:  1 active display(s): 1
```

The two lines must show the same count and the same display IDs. If they don't, the snapshot helper has a bug.

- [ ] **Step 5: Commit**

```bash
git add experiments/vd-poc-mac/src/vd_poc.m
git commit -m "experiment(vd-poc-mac): add display state snapshot helper

print_display_state() wraps CGGetActiveDisplayList and prints a labelled
line with count + IDs. Called twice in main with no work between calls,
so both lines show identical state — sanity check before we start creating
displays. This is the programmatic half of the spec's manual+programmatic
verification (verification approach C).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Build descriptor + create virtual display

**Files:**
- Modify: `experiments/vd-poc-mac/src/vd_poc.m`

- [ ] **Step 1: Add static storage above `main`**

Just before `int main(...)`, add:

```objc
// Static storage so ARC keeps these objects alive for the lifetime of the
// process. Setting them to nil at exit triggers display destruction.
static CGVirtualDisplay *g_display = nil;
static CGVirtualDisplayDescriptor *g_descriptor = nil;

// Hardcoded POC parameters.
static const int kWidth  = 1920;
static const int kHeight = 1080;
static const int kFPS    = 60;
static const int32_t kExtendOriginX = 2000;
```

- [ ] **Step 2: Add a creation helper**

Place this above `main`:

```objc
/**
 * Build the CGVirtualDisplayDescriptor, alloc the display, apply the mode
 * settings, and stash both in g_display / g_descriptor for keep-alive.
 *
 * Returns the new CGDirectDisplayID, or 0 on failure.
 */
static uint32_t create_virtual_display(int width, int height, int fps) {
  CGVirtualDisplayDescriptor *desc = [[CGVirtualDisplayDescriptor alloc] init];
  desc.name              = @"vd-poc";
  desc.vendorID          = 0xF0F0;
  desc.productID         = 0x5678;
  desc.serialNum         = arc4random();
  desc.maxPixelsWide     = (unsigned int)width;
  desc.maxPixelsHigh     = (unsigned int)height;
  // Fixed 27" physical size — Lumen's value. CGVirtualDisplay rejects
  // descriptors whose resolution-vs-physical-size ratio implies an
  // unreasonable pixel density, so DO NOT scale this with width/height.
  desc.sizeInMillimeters = CGSizeMake(597, 336);
  desc.whitePoint        = CGPointMake(0.3127, 0.3290);
  desc.redPrimary        = CGPointMake(0.64, 0.33);
  desc.greenPrimary      = CGPointMake(0.30, 0.60);
  desc.bluePrimary       = CGPointMake(0.15, 0.06);
  [desc setDispatchQueue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0)];
  desc.terminationHandler = ^(id s, id d) {
    fprintf(stderr, "[vd-poc] WindowServer terminated our virtual display\n");
  };

  CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
  if (!display) {
    fprintf(stderr, "[vd-poc] initWithDescriptor returned nil (main thread); trying background thread\n");
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
    fprintf(stderr, "[vd-poc] CGVirtualDisplay creation failed\n");
    return 0;
  }

  g_display    = display;
  g_descriptor = desc;
  return display.displayID;
}
```

- [ ] **Step 3: Wire the helper into `main`**

Replace the back-to-back `print_display_state` calls with:

```objc
    uint32_t before = print_display_state("BEFORE:");

    fprintf(stdout, "[vd-poc] creating virtual display %dx%d@%dHz...\n", kWidth, kHeight, kFPS);
    fflush(stdout);
    uint32_t newID = create_virtual_display(kWidth, kHeight, kFPS);
    if (newID == 0) {
      fprintf(stderr, "[vd-poc] FATAL: virtual display creation failed\n");
      return 3;
    }
    fprintf(stdout, "[vd-poc] created display id=%u\n", newID);
    fflush(stdout);

    uint32_t after = print_display_state("AFTER:");
    if (after <= before) {
      fprintf(stderr, "[vd-poc] WARN: display count did not increase (before=%u after=%u)\n",
              before, after);
    }
```

- [ ] **Step 4: Build**

```bash
./experiments/vd-poc-mac/build.sh
```

Expected: clean build.

- [ ] **Step 5: Run**

```bash
./experiments/vd-poc-mac/vd-poc-mac
```

Expected stdout (display IDs vary):
```
[vd-poc] pid=NNNNN macOS=14.X.X
[vd-poc] checking CGVirtualDisplay availability...
[vd-poc] all CGVirtualDisplay classes resolved ✓
[vd-poc] BEFORE: 1 active display(s): 1
[vd-poc] creating virtual display 1920x1080@60Hz...
[vd-poc] created display id=NNNNNNNNNN
[vd-poc] AFTER:  1 active display(s): 1     ← may still be 1; activate step is in Task 6
```

Important: at this stage `AFTER` may still be 1 (count unchanged) because the display has been allocated but not yet activated via `SLSConfigureDisplayEnabled` — that comes in Task 6. What matters here is: the WARN line about count-not-increased may print, AND `created display id=` shows a non-zero ID. If `id=0` or the program exits 3, the descriptor was rejected — see error handling table in spec.

- [ ] **Step 6: Commit**

```bash
git add experiments/vd-poc-mac/src/vd_poc.m
git commit -m "experiment(vd-poc-mac): create virtual display via private CGVirtualDisplay

Builds the descriptor with Lumen's exact 27\" physical size (597x336mm)
to satisfy the API's pixel-density rule, then allocs CGVirtualDisplay
and falls back to a background-thread alloc if the main-thread alloc
returns nil (Lumen-observed quirk). Static g_display / g_descriptor
storage retains them for the process lifetime — ARC will release on
exit. Display is allocated but NOT yet visible to the rest of the
system; activation comes in Task 6.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Apply mode settings (native + half-res with hiDPI)

**Files:**
- Modify: `experiments/vd-poc-mac/src/vd_poc.m`

- [ ] **Step 1: Add a settings helper above `main`**

Just below `create_virtual_display`, add:

```objc
/**
 * Apply native + half-resolution modes with hiDPI=1. Without the half-res
 * mode + hiDPI flag, macOS only delivers half the requested pixel
 * resolution. With them, native mode becomes the retina backing store
 * and half-res becomes the logical resolution (2x scaling).
 */
static BOOL apply_settings(CGVirtualDisplay *display, int width, int height, int fps) {
  CGVirtualDisplayMode *native = [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)width
                                                                      height:(unsigned int)height
                                                                 refreshRate:(double)fps];
  if (!native) {
    fprintf(stderr, "[vd-poc] failed to build native CGVirtualDisplayMode\n");
    return NO;
  }
  CGVirtualDisplayMode *half = [[CGVirtualDisplayMode alloc] initWithWidth:(unsigned int)(width / 2)
                                                                    height:(unsigned int)(height / 2)
                                                               refreshRate:(double)fps];

  CGVirtualDisplaySettings *settings = [[CGVirtualDisplaySettings alloc] init];
  settings.hiDPI = 1;
  settings.modes = half ? @[native, half] : @[native];

  return [display applySettings:settings];
}
```

- [ ] **Step 2: Call `apply_settings` inside `main` immediately after `create_virtual_display` succeeds**

After the line `fprintf(stdout, "[vd-poc] created display id=%u\n", newID);` and the subsequent fflush, add:

```objc
    if (!apply_settings(g_display, kWidth, kHeight, kFPS)) {
      fprintf(stderr, "[vd-poc] WARN: applySettings returned NO — continuing\n");
    } else {
      fprintf(stdout, "[vd-poc] applied modes (native %dx%d@%d + half-res, hiDPI=1)\n",
              kWidth, kHeight, kFPS);
      fflush(stdout);
    }
```

- [ ] **Step 3: Build**

```bash
./experiments/vd-poc-mac/build.sh
```

Expected: clean build.

- [ ] **Step 4: Run**

```bash
./experiments/vd-poc-mac/vd-poc-mac
```

Expected new line in stdout:
```
[vd-poc] applied modes (native 1920x1080@60 + half-res, hiDPI=1)
```

If WARN appears instead, applySettings returned NO. Note in the run log; the next task (SLS activate) may still surface the display anyway.

- [ ] **Step 5: Commit**

```bash
git add experiments/vd-poc-mac/src/vd_poc.m
git commit -m "experiment(vd-poc-mac): apply hiDPI mode settings

Adds a CGVirtualDisplaySettings with two CGVirtualDisplayMode entries
(native + half-resolution) and hiDPI=1. Without this combination,
macOS delivers half the requested pixel resolution. Lumen's pattern
verbatim. Logs WARN but continues if applySettings returns NO — the
display is still alloc'd and the next step (SLS activate) may still
register it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: SLS activate the display

**Files:**
- Modify: `experiments/vd-poc-mac/src/vd_poc.m`

- [ ] **Step 1: Add an SLS activate helper above `main`**

Below `apply_settings`, add:

```objc
/**
 * Activate the virtual display in WindowServer's display list and seed
 * its position to the right of the main display. Without this step,
 * CGGetActiveDisplayList does not see the display.
 */
static void sls_activate(uint32_t virtualID) {
  CGDisplayConfigRef cfg = NULL;
  CGError err = SLSBeginDisplayConfiguration(&cfg);
  fprintf(stderr, "[vd-poc] SLSBeginDisplayConfiguration: %d\n", err);
  if (err != kCGErrorSuccess || !cfg) {
    fprintf(stderr, "[vd-poc] cannot begin SLS configuration\n");
    return;
  }

  err = SLSConfigureDisplayEnabled(cfg, virtualID, true);
  fprintf(stderr, "[vd-poc] SLSConfigureDisplayEnabled(%u, true): %d\n", virtualID, err);

  CGDirectDisplayID main_id = CGMainDisplayID();
  size_t main_w = CGDisplayPixelsWide(main_id);
  int32_t origin_x = (int32_t)main_w > kExtendOriginX ? (int32_t)main_w : kExtendOriginX;
  err = SLSConfigureDisplayOrigin(cfg, virtualID, origin_x, 0);
  fprintf(stderr, "[vd-poc] SLSConfigureDisplayOrigin(%u, %d, 0): %d\n",
          virtualID, origin_x, err);

  err = SLSCompleteDisplayConfiguration(cfg, kCGConfigureForSession, 0);
  fprintf(stderr, "[vd-poc] SLSCompleteDisplayConfiguration: %d\n", err);

  // Give WindowServer time to process the new display.
  usleep(500000);
}
```

- [ ] **Step 2: Call `sls_activate` from `main`, right after the apply-settings block**

After the apply-settings block in `main`, add:

```objc
    sls_activate(newID);
    print_display_state("ACTIVE:");
```

- [ ] **Step 3: Build**

```bash
./experiments/vd-poc-mac/build.sh
```

Expected: clean build.

- [ ] **Step 4: Run**

```bash
./experiments/vd-poc-mac/vd-poc-mac
```

Expected new lines on stderr:
```
[vd-poc] SLSBeginDisplayConfiguration: 0
[vd-poc] SLSConfigureDisplayEnabled(NNN, true): 0
[vd-poc] SLSConfigureDisplayOrigin(NNN, 2000, 0): 0
[vd-poc] SLSCompleteDisplayConfiguration: 0
```

And on stdout, `ACTIVE: 2 active display(s): 1 NNN` (the new ID joins the list). If the count stays at 1, the display did not register — likely the macOS auto-mirror behaviour Lumen documents; Task 7 fixes this.

Open System Settings → Displays during the binary's run (it will exit immediately for now; ignore visual check until Task 9 adds the keep-alive loop). For this task, the programmatic stdout assertion is the validation.

- [ ] **Step 5: Commit**

```bash
git add experiments/vd-poc-mac/src/vd_poc.m
git commit -m "experiment(vd-poc-mac): SLS activate the virtual display

SLSBeginDisplayConfiguration → SLSConfigureDisplayEnabled(true) →
SLSConfigureDisplayOrigin (placed to right of main display) →
SLSCompleteDisplayConfiguration with kCGConfigureForSession. After a
500ms settle, the new ID should appear in CGGetActiveDisplayList. If
not, macOS may have auto-mirrored — Task 7 handles that.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Force extend mode (un-mirror dance)

**Files:**
- Modify: `experiments/vd-poc-mac/src/vd_poc.m`

- [ ] **Step 1: Add the un-mirror helper above `main`**

Below `sls_activate`, add (port of Lumen's `forceExtendMode` with logging adjusted for POC):

```objc
/**
 * macOS may auto-mirror a freshly-created virtual display, which hides
 * it from CGGetActiveDisplayList. This walks the three mirror-pair
 * configurations Lumen observed and un-mirrors each, then re-positions
 * the virtual display to the right of main.
 *
 * Caller should re-check CGGetActiveDisplayList after this returns.
 */
static void force_extend_mode(CGDirectDisplayID virtualID) {
  CGDirectDisplayID main_id = CGMainDisplayID();

  // Case 1: main is mirroring our virtual display.
  if (CGDisplayMirrorsDisplay(main_id) == virtualID) {
    fprintf(stderr, "[vd-poc] un-mirror: main %u is mirroring virtual %u\n",
            main_id, virtualID);
    CGDisplayConfigRef cfg = NULL;
    CGBeginDisplayConfiguration(&cfg);
    if (cfg) {
      CGConfigureDisplayMirrorOfDisplay(cfg, main_id, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    }
  }

  // Case 2: virtual is in a mirror set.
  if (CGDisplayIsInMirrorSet(virtualID)) {
    fprintf(stderr, "[vd-poc] un-mirror: virtual %u is in mirror set\n", virtualID);
    CGDisplayConfigRef cfg = NULL;
    CGBeginDisplayConfiguration(&cfg);
    if (cfg) {
      CGConfigureDisplayMirrorOfDisplay(cfg, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    }
  }

  // Case 3: virtual is mirroring main.
  if (CGDisplayMirrorsDisplay(virtualID) != 0) {
    fprintf(stderr, "[vd-poc] un-mirror: virtual %u is mirroring %u\n",
            virtualID, CGDisplayMirrorsDisplay(virtualID));
    CGDisplayConfigRef cfg = NULL;
    CGBeginDisplayConfiguration(&cfg);
    if (cfg) {
      CGConfigureDisplayMirrorOfDisplay(cfg, virtualID, kCGNullDirectDisplay);
      CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
    }
  }

  // Re-position virtual to right of main.
  CGDisplayConfigRef cfg = NULL;
  CGBeginDisplayConfiguration(&cfg);
  if (cfg) {
    size_t main_w = CGDisplayPixelsWide(main_id);
    CGConfigureDisplayOrigin(cfg, virtualID, (int32_t)main_w, 0);
    CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
  }

  // If the virtual display became the new main, restore the original main.
  if (CGMainDisplayID() == virtualID && main_id != virtualID) {
    fprintf(stderr, "[vd-poc] virtual became main, restoring %u as main\n", main_id);
    CGDisplayConfigRef cfg2 = NULL;
    CGBeginDisplayConfiguration(&cfg2);
    if (cfg2) {
      CGConfigureDisplayOrigin(cfg2, main_id, 0, 0);
      CGCompleteDisplayConfiguration(cfg2, kCGConfigureForAppOnly);
    }
  }
}
```

- [ ] **Step 2: Call `force_extend_mode` from `main` if the display is missing or mirroring**

After the `print_display_state("ACTIVE:")` call in `main`, add:

```objc
    BOOL needFix = CGDisplayIsInMirrorSet(newID) || CGDisplayMirrorsDisplay(newID) != 0;
    if (needFix) {
      fprintf(stderr, "[vd-poc] mirror state detected, forcing extend mode\n");
      force_extend_mode(newID);
      usleep(500000);
      print_display_state("EXTEND:");
    } else {
      fprintf(stdout, "[vd-poc] no mirror cleanup needed\n");
      fflush(stdout);
    }
```

- [ ] **Step 3: Build**

```bash
./experiments/vd-poc-mac/build.sh
```

Expected: clean build.

- [ ] **Step 4: Run**

```bash
./experiments/vd-poc-mac/vd-poc-mac
```

Expected: one of two paths.

Path A (no auto-mirror — cleanest):
```
[vd-poc] no mirror cleanup needed
```

Path B (auto-mirror seen):
```
[vd-poc] mirror state detected, forcing extend mode
[vd-poc] un-mirror: ... (one or more cases)
[vd-poc] EXTEND:  2 active display(s): 1 NNN
```

Both paths are acceptable. The verdict is whether the EXTEND line shows two displays.

- [ ] **Step 5: Commit**

```bash
git add experiments/vd-poc-mac/src/vd_poc.m
git commit -m "experiment(vd-poc-mac): force extend mode (un-mirror dance)

Ports Lumen's forceExtendMode verbatim: walks the three mirror
configurations (main mirrors virtual / virtual in mirror set / virtual
mirrors main), un-mirrors each, repositions virtual right of main,
and restores main if it got swapped. Only runs when CGDisplayIsInMirrorSet
or CGDisplayMirrorsDisplay reports a mirror — otherwise prints
'no mirror cleanup needed'.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Switch to native 1x scale mode

**Files:**
- Modify: `experiments/vd-poc-mac/src/vd_poc.m`

- [ ] **Step 1: Add a mode-switch helper above `main`**

Below `force_extend_mode`, add:

```objc
/**
 * The display starts in retina 2x mode (logical resolution = half of pixel
 * resolution). For streaming workloads this adds compositor overhead. We
 * search the available modes for the 1x native one (logical == pixel) and
 * switch to it. Best-effort — logs and continues on failure.
 */
static void switch_to_native_1x(CGDirectDisplayID id, int width, int height) {
  NSDictionary *opts = @{ (NSString *)kCGDisplayShowDuplicateLowResolutionModes: @YES };
  CFArrayRef modes = CGDisplayCopyAllDisplayModes(id, (CFDictionaryRef)opts);
  if (!modes) {
    fprintf(stderr, "[vd-poc] CGDisplayCopyAllDisplayModes returned NULL\n");
    return;
  }

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
    CGError err = CGDisplaySetDisplayMode(id, target, NULL);
    fprintf(stderr, "[vd-poc] switched to native %dx%d (1x): %d\n", width, height, err);
  } else {
    fprintf(stderr, "[vd-poc] native %dx%d 1x mode not found; staying retina 2x\n", width, height);
  }
  CFRelease(modes);
}
```

- [ ] **Step 2: Call `switch_to_native_1x` from `main` after `force_extend_mode` block**

After the if/else block from Task 7, add:

```objc
    switch_to_native_1x(newID, kWidth, kHeight);
    usleep(500000);
    print_display_state("READY:");
```

- [ ] **Step 3: Build**

```bash
./experiments/vd-poc-mac/build.sh
```

Expected: clean build.

- [ ] **Step 4: Run**

```bash
./experiments/vd-poc-mac/vd-poc-mac
```

Expected new stderr line (one of):
```
[vd-poc] switched to native 1920x1080 (1x): 0
```
or
```
[vd-poc] native 1920x1080 1x mode not found; staying retina 2x
```

The first is preferred. The second is acceptable — the display still works for the POC's "extend" verdict; just at retina 2x.

- [ ] **Step 5: Commit**

```bash
git add experiments/vd-poc-mac/src/vd_poc.m
git commit -m "experiment(vd-poc-mac): switch to native 1x scale display mode

Without this, the display defaults to retina 2x — logical resolution
is half of pixel resolution and the compositor pays a 2x scaling cost.
Iterates CGDisplayCopyAllDisplayModes (with low-res duplicates included)
to find the mode where logical == pixel == requested resolution, then
calls CGDisplaySetDisplayMode. Best-effort; logs and continues if the
exact 1x mode isn't found.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Signal handling + CFRunLoop keep-alive

**Files:**
- Modify: `experiments/vd-poc-mac/src/vd_poc.m`

- [ ] **Step 1: Add signal handler state and function above `main`**

Just below the `kExtendOriginX` constant (above `print_display_state`), add:

```objc
static volatile sig_atomic_t g_should_exit = 0;

static void on_signal(int sig) {
  g_should_exit = 1;
  // Wake the main thread's CFRunLoop so it can observe the flag.
  dispatch_async(dispatch_get_main_queue(), ^{
    CFRunLoopStop(CFRunLoopGetMain());
  });
  (void)sig;
}
```

- [ ] **Step 2: Initialize NSApplication and signal handlers in `main`**

Inside `@autoreleasepool` at the top of `main`, after the macOS-version log line, add:

```objc
    // Required for AppKit framework calls below; activation prohibited so we
    // don't appear in the Dock.
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP,  on_signal);
```

- [ ] **Step 3: Replace the immediate `return 0;` at the end of `main` with the keep-alive loop**

After the `print_display_state("READY:");` call from Task 8, add:

```objc
    fprintf(stdout, "[vd-poc] press Ctrl+C (SIGINT) or send SIGTERM to destroy and exit\n");
    fflush(stdout);

    while (!g_should_exit) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
    }

    fprintf(stdout, "[vd-poc] received signal, shutting down...\n");
    fflush(stdout);
```

The pre-existing `return 0;` stays at the very end of `@autoreleasepool`.

- [ ] **Step 4: Build**

```bash
./experiments/vd-poc-mac/build.sh
```

Expected: clean build.

- [ ] **Step 5: Run, verify it stays alive, send SIGINT**

```bash
./experiments/vd-poc-mac/vd-poc-mac
```

Expected: the binary prints up through the "press Ctrl+C" line and then **does not exit**. Verify with `ps -p $(pgrep vd-poc-mac)` in another terminal.

While it is running, perform the spec's manual verification:
1. Open **System Settings → Displays** — should show 2 displays. New one labelled `vd-poc` (or generic).
2. Drag a window from main to the right edge past x=2000 — it should appear on the virtual display.
3. Cursor should move into the virtual display area.

Then press `Ctrl+C` in the original terminal.

Expected after Ctrl+C:
```
^C
[vd-poc] received signal, shutting down...
```

Process should exit within ~1 second (the CFRunLoopRunInMode timeout window).

- [ ] **Step 6: Commit**

```bash
git add experiments/vd-poc-mac/src/vd_poc.m
git commit -m "experiment(vd-poc-mac): keep display alive until SIGINT/SIGTERM

Initializes NSApplication (required for AppKit calls used elsewhere in
the binary), prohibits Dock activation, installs SIGINT/SIGTERM/SIGHUP
handlers that flip g_should_exit and wake the run loop. Main loops on
CFRunLoopRunInMode with a 1s timeout so the flag is observed promptly.
At this point the manual verification from the spec (open System
Settings → Displays, drag window to virtual screen) becomes possible.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Destroy display + final state verification

**Files:**
- Modify: `experiments/vd-poc-mac/src/vd_poc.m`

- [ ] **Step 1: Add cleanup after the run loop**

After the `[vd-poc] received signal, shutting down...` print in `main`, replace the end of `@autoreleasepool` with:

```objc
    g_display    = nil;   // ARC releases — triggers WindowServer detach
    g_descriptor = nil;
    // Allow WindowServer a beat to update its display list.
    usleep(500000);
    uint32_t final_count = print_display_state("FINAL:");
    if (final_count != before) {
      fprintf(stderr, "[vd-poc] WARN: final display count (%u) differs from before (%u)\n",
              final_count, before);
    } else {
      fprintf(stdout, "[vd-poc] cleanup verified: display count returned to baseline\n");
      fflush(stdout);
    }
```

The existing `return 0;` stays at the end.

- [ ] **Step 2: Build**

```bash
./experiments/vd-poc-mac/build.sh
```

Expected: clean build.

- [ ] **Step 3: Run, then SIGINT, observe FINAL line**

```bash
./experiments/vd-poc-mac/vd-poc-mac
```

While running, manually verify (System Settings → Displays). Then `Ctrl+C`.

Expected stdout tail:
```
[vd-poc] received signal, shutting down...
[vd-poc] FINAL:  1 active display(s): 1
[vd-poc] cleanup verified: display count returned to baseline
```

If the FINAL count does not match baseline, the WARN line prints. From a fresh shell, run:
```bash
system_profiler SPDisplaysDataType | grep -ic "display"
```
to double-check that the OS itself reports the original count after the binary has exited (per spec, the OS reclaims even on abrupt exit).

- [ ] **Step 4: Commit**

```bash
git add experiments/vd-poc-mac/src/vd_poc.m
git commit -m "experiment(vd-poc-mac): destroy display + verify final state

Setting g_display and g_descriptor to nil under ARC releases the last
strong references to CGVirtualDisplay, which detaches it from
WindowServer. After a 500ms settle, print_display_state with FINAL
label compares against the BEFORE snapshot and either confirms cleanup
or warns of a leak. POC is now end-to-end testable.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: README — pre-run checks, run protocol, verdict criteria

**Files:**
- Create: `experiments/vd-poc-mac/README.md`

- [ ] **Step 1: Write the README**

Create `experiments/vd-poc-mac/README.md`:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add experiments/vd-poc-mac/README.md
git commit -m "experiment(vd-poc-mac): README documenting run protocol

Pre-run checks (CLT, macOS version, baseline display count), expected
stdout transcript, manual verification steps, post-run cleanup check,
and the spec's verdict criteria (PASS/PARTIAL/FAIL). Calls out
troubleshooting for Gatekeeper quarantine and TCC prompt.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Final test pass + outcome memory note

**Files:**
- Create: `/Users/jokot/.claude/projects/-Users-jokot-dev-vdisplay/memory/vd_poc_outcome.md`
- Modify: `/Users/jokot/.claude/projects/-Users-jokot-dev-vdisplay/memory/MEMORY.md`

This task is **executed manually** by the developer running the POC end-to-end and recording the result. It is not committed to git — only the memory files (which live outside the repo).

- [ ] **Step 1: Run the full POC end-to-end on the developer's M3**

Follow the README's run protocol exactly. Observe and record:

- macOS version reported on first stdout line
- BEFORE / ACTIVE / EXTEND (if printed) / READY / FINAL counts and IDs
- Whether mirror cleanup was triggered
- Whether `switch_to_native_1x` succeeded or fell back to retina 2x
- Whether the manual visual checks succeeded (window drag, cursor move)
- Any unexpected stderr lines

- [ ] **Step 2: Decide PASS / PARTIAL / FAIL using the spec's criteria**

- **PASS:** All steps run; virtual display visible in System Settings;
  window draggable; FINAL count returns to baseline.
- **PARTIAL:** Some steps fail (e.g. positioning) but creation works.
- **FAIL:** Symbols missing OR create returns NULL OR display count never increases.

- [ ] **Step 3: Write the outcome to memory**

Create `/Users/jokot/.claude/projects/-Users-jokot-dev-vdisplay/memory/vd_poc_outcome.md`:

```markdown
---
name: vd-poc-mac POC outcome
description: Result of running experiments/vd-poc-mac on the developer's M3 — verdict, observed quirks, next steps
type: project
---

## Verdict
<PASS / PARTIAL / FAIL>

## Environment
- Date run: <YYYY-MM-DD>
- Hardware: MacBook Pro M3
- macOS version: <e.g. 14.5>
- Active displays at baseline: <count>

## Observed behaviour
- BEFORE count: <n>
- AFTER (post-create) count: <n>
- ACTIVE (post-SLS) count: <n>
- Mirror cleanup triggered: <yes/no, which case(s)>
- 1x scale switch: <succeeded / fell back to retina 2x>
- READY count: <n>
- FINAL count: <n> (matches baseline: yes/no)
- Manual checks: <window drag — worked/didn't, cursor move — worked/didn't>

## Notes
<any unexpected stderr lines, error codes, quirks>

**Why:** Closes the spec's defined uncertainty by capturing the actual run on the developer's macOS version. Decides whether Phase 4 production port proceeds, defers extend to v1.5, or triggers a scope pivot.
**How to apply:** When planning Phase 4, read this file first. The macOS version + observed quirks dictate which Lumen workarounds need carrying over to the production port; the verdict dictates whether to proceed at all.
```

Then append to `/Users/jokot/.claude/projects/-Users-jokot-dev-vdisplay/memory/MEMORY.md`:

```markdown
- [vd-poc-mac outcome](vd_poc_outcome.md) — <PASS/PARTIAL/FAIL> on macOS <version>; baseline for Phase 4 decisions
```

- [ ] **Step 4: If PASS or PARTIAL, optionally remove the binary from the repo working tree**

The .gitignore from Task 1 already excludes the compiled binary; no action needed unless `.dSYM/` is present.

- [ ] **Step 5: No commit** — memory files are outside git.

---

## Self-Review

**Spec coverage:**

| Spec section | Plan task |
|---|---|
| Architecture (`experiments/vd-poc-mac/`, `build.sh`, `src/vd_poc.m`) | Task 1 |
| Components (load_private_symbols → destroy_virtual_display) | Tasks 2-10 (one helper per task) |
| Lifecycle 11-step run sequence | Tasks 3-10 incrementally |
| Error handling table (dlsym null, create NULL, SLS fails, etc.) | Task 2 (availability), Task 4 (create-fail), Task 6 (SLS), Task 10 (cleanup) |
| Verification (pre-run, run, manual, post-run, test matrix) | Task 11 (README), Task 12 (record outcome) |
| Build & toolchain (clang flags) | Task 1 |
| Signing (ad-hoc, Gatekeeper/TCC notes) | Task 11 README troubleshooting |
| Verdict criteria PASS/PARTIAL/FAIL | Task 11 README, Task 12 memory note |
| Decisions Locked (Q1-Q6, approach B) | Tasks reflect each decision; spec section unchanged |

**Type / name consistency:**

- `g_display` / `g_descriptor` introduced in Task 4, used in Task 10. ✓
- `kWidth` / `kHeight` / `kFPS` / `kExtendOriginX` introduced in Task 4, referenced consistently. ✓
- `g_should_exit` / `on_signal` introduced in Task 9. ✓
- `print_display_state` introduced in Task 3, called in Tasks 3, 4, 6, 7, 8, 10. ✓
- `force_extend_mode` (Task 7) name matches Lumen's `forceExtendMode` semantically; Lumen uses camelCase, plan uses snake_case for consistency with C-style POC code. Documented in commit message.
- `apply_settings` / `sls_activate` / `switch_to_native_1x` / `create_virtual_display` — all snake_case; introduced in their own tasks; called in `main`.

**Placeholder scan:** No "TBD", "TODO", "implement later", or "similar to Task N" patterns. The Task 12 memory file template uses `<PLACEHOLDER>` markers, but those are intentional fields the developer fills in with real run data — not instructions for an implementer to replace.

**Spec deviations noted in plan:** Spec architecture diagram lists a `headers/CGVirtualDisplay.h` file. Plan's File Structure section explains why it's omitted (private API declarations live inline in `vd_poc.m` matching Lumen's pattern; an external header adds duplication for no benefit in a single-file POC). This is the only deliberate deviation.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-03-mac-vdisplay-poc.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. Each task is self-contained (1-2 hours of work) and the run-and-observe step makes review crisp.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
