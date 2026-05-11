/**
 * @file src/platform/windows/virtual_display_manager.h
 * @brief Detection and integration of the MttVDD virtual display driver
 *        (itsmikethetech Virtual Display Driver) on Windows.
 *
 * Unlike the macOS implementation there is no subprocess to spawn; the VDD
 * is a persistent UMDF kernel driver that appears as a regular display
 * adapter once installed.  This class locates it and exposes its DXGI device
 * name so the rest of Sunshine can capture it like any other monitor.
 */
#pragma once

#include <mutex>
#include <string>

namespace platf::win {

  class WinVirtualDisplayManager {
  public:
    static WinVirtualDisplayManager &instance();

    /**
     * Returns true if the MttVDD driver package is installed in the Windows
     * driver store and the ROOT\MTTVDD\0000 device node is present and in
     * the running (DN_STARTED) state.
     *
     * Implementation (Task 8): reads HKLM\SOFTWARE\vdisplay\VddOemInf to
     * confirm the installer ran, then uses CfgMgr32 to verify the device
     * node status.
     */
    bool probe_driver_installed();

    /**
     * Returns the DXGI GDI device name (e.g. "\\\\.\\DISPLAY3") of the
     * active virtual display, or an empty string if it is not found or not
     * attached to the desktop.
     *
     * Implementation (Task 7): enumerates display paths via
     * QueryDisplayConfig / DisplayConfigGetDeviceInfo, matches the adapter
     * device path that contains the MttVDD hardware ID, and returns the
     * corresponding GDI device name that DXGI uses for output enumeration.
     */
    std::string get_display_name();

  private:
    WinVirtualDisplayManager() = default;
    WinVirtualDisplayManager(const WinVirtualDisplayManager &) = delete;
    WinVirtualDisplayManager &operator=(const WinVirtualDisplayManager &) = delete;

    mutable std::mutex mutex_;
  };

}  // namespace platf::win
