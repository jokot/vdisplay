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

#include <cerrno>
#include <chrono>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cstring>
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
        // Child: redirect stdout and stderr to pipes, then exec helper.
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
        std::fprintf(stdout, "0\n");
        std::fflush(stdout);
        ::_exit(127);
      }

      // Parent.
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

}  // namespace platf::macos
