/**
 * @file tests/unit/platform/macos/test_virtual_display_manager.cpp
 * @brief Integration test for platf::macos::MacVirtualDisplayManager.
 *
 * Skipped on macOS < 14 (CGVirtualDisplay was added in Sonoma).
 * Verifies a round-trip: spawn helper, assert displayID is visible to
 * CGGetActiveDisplayList, teardown, assert state reset.
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
      return (long) v.majorVersion;
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
