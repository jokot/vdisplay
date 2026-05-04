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

// Static storage so ARC keeps these objects alive for the lifetime of the
// process. Setting them to nil at exit triggers display destruction.
static CGVirtualDisplay *g_display = nil;
static CGVirtualDisplayDescriptor *g_descriptor = nil;

// Hardcoded POC parameters.
static const int kWidth  = 1920;
static const int kHeight = 1080;
static const int kFPS    = 60;
static const int32_t kExtendOriginX = 2000;

static volatile sig_atomic_t g_should_exit = 0;

static void on_signal(int sig) {
  g_should_exit = 1;
  // Wake the main thread's CFRunLoop so it can observe the flag.
  dispatch_async(dispatch_get_main_queue(), ^{
    CFRunLoopStop(CFRunLoopGetMain());
  });
  (void)sig;
}

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

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

int main(void) {
  @autoreleasepool {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    fprintf(stdout, "[vd-poc] pid=%d macOS=%ld.%ld.%ld\n",
            getpid(), (long)v.majorVersion, (long)v.minorVersion, (long)v.patchVersion);
    fflush(stdout);

    // Required for AppKit framework calls below; activation prohibited so we
    // don't appear in the Dock.
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];

    signal(SIGINT,  on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP,  on_signal);

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

    if (!apply_settings(g_display, kWidth, kHeight, kFPS)) {
      fprintf(stderr, "[vd-poc] WARN: applySettings returned NO — continuing\n");
    } else {
      fprintf(stdout, "[vd-poc] applied modes (native %dx%d@%d + half-res, hiDPI=1)\n",
              kWidth, kHeight, kFPS);
      fflush(stdout);
    }

    sls_activate(newID);
    print_display_state("ACTIVE:");

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

    switch_to_native_1x(newID, kWidth, kHeight);
    usleep(500000);
    print_display_state("READY:");

    fprintf(stdout, "[vd-poc] press Ctrl+C (SIGINT) or send SIGTERM to destroy and exit\n");
    fflush(stdout);

    while (!g_should_exit) {
      CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, false);
    }

    fprintf(stdout, "[vd-poc] received signal, shutting down...\n");
    fflush(stdout);

    uint32_t after = print_display_state("AFTER:");
    if (after <= before) {
      fprintf(stderr, "[vd-poc] WARN: display count did not increase (before=%u after=%u)\n",
              before, after);
    }
  }
  return 0;
}
