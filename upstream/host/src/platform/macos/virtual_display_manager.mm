/**
 * @file src/platform/macos/virtual_display_manager.mm
 * @brief Implementation of MacVirtualDisplayManager.
 */
#include "virtual_display_manager.h"

#include "src/logging.h"

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
    @autoreleasepool {
      NSString *self_path = [[NSString stringWithUTF8String:buf] stringByResolvingSymlinksInPath];
      NSString *self_dir  = [self_path stringByDeletingLastPathComponent];
      NSString *helper    = [self_dir stringByAppendingPathComponent:@"vd_helper"];
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
