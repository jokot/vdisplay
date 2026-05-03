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
