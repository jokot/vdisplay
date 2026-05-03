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
