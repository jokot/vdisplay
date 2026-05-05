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
// Helpers (ported from POC, comments trimmed for production)
// ---------------------------------------------------------------------------

static uint32_t create_virtual_display(int width, int height, int fps) {
  // fps is consumed in apply_settings(), not here; keep the parameter for the
  // caller's mental model (all three creation knobs travel together).
  (void)fps;
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
    // applySettings is best-effort per Lumen pattern: a NO result means the
    // display was created but mode application failed — Sunshine's encoder
    // will see whatever default mode the display is in. Logged for ops to
    // notice but not fatal; the spec's IPC contract has no exit code for this
    // failure mode (would be 5; deferred to v1.5 if it becomes an issue).
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
