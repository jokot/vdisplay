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
