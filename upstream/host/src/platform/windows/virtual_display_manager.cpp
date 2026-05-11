/**
 * @file src/platform/windows/virtual_display_manager.cpp
 * @brief WinVirtualDisplayManager — detect and locate the MttVDD virtual display.
 */

// platform includes — must precede local includes to avoid WinSock ordering issues
#include <windows.h>
#include <cfgmgr32.h>

// standard includes
#include <algorithm>
#include <vector>

// local includes
#include "virtual_display_manager.h"
#include "utf_utils.h"
#include "src/logging.h"

using namespace std::literals;

namespace platf::win {

  WinVirtualDisplayManager &WinVirtualDisplayManager::instance() {
    static WinVirtualDisplayManager inst;
    return inst;
  }

  /**
   * Returns true when:
   *   1. HKLM\SOFTWARE\vdisplay\VddOemInf exists (written by the installer),
   *      confirming the driver package was staged into the Windows driver store.
   *   2. The ROOT\MTTVDD\0000 device node is present and has DN_STARTED set,
   *      confirming the UMDF function driver (WudfRd hosting MttVDD.dll) is
   *      loaded and the IDD adapter is active.
   */
  bool WinVirtualDisplayManager::probe_driver_installed() {
    std::lock_guard lock(mutex_);

    // --- 1. Registry sentinel written by the vdisplay installer ---
    HKEY hKey = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\vdisplay",
                      0, KEY_READ, &hKey) != ERROR_SUCCESS) {
      BOOST_LOG(debug) << "WinVDM: HKLM\\SOFTWARE\\vdisplay not found"sv;
      return false;
    }
    DWORD size = 0;
    bool hasOemInf = (RegQueryValueExW(hKey, L"VddOemInf",
                                       nullptr, nullptr,
                                       nullptr, &size) == ERROR_SUCCESS
                      && size > sizeof(wchar_t));
    RegCloseKey(hKey);
    if (!hasOemInf) {
      BOOST_LOG(debug) << "WinVDM: VddOemInf registry value missing or empty"sv;
      return false;
    }

    // --- 2. Device node must be present and started via CfgMgr32 ---
    DEVINST devInst = 0;
    // CM_LOCATE_DEVNODE_NORMAL returns CR_NO_SUCH_DEVNODE if absent
    CONFIGRET cr = CM_Locate_DevNodeW(
      &devInst,
      const_cast<DEVINSTID_W>(L"ROOT\\MTTVDD\\0000"),
      CM_LOCATE_DEVNODE_NORMAL);
    if (cr != CR_SUCCESS) {
      BOOST_LOG(debug) << "WinVDM: ROOT\\MTTVDD\\0000 not found (cr=0x"sv
                       << std::hex << cr << ")"sv;
      return false;
    }

    ULONG status = 0, problem = 0;
    cr = CM_Get_DevNode_Status(&status, &problem, devInst, 0);
    if (cr != CR_SUCCESS) {
      BOOST_LOG(debug) << "WinVDM: CM_Get_DevNode_Status failed (cr=0x"sv
                       << std::hex << cr << ")"sv;
      return false;
    }

    if (!(status & DN_STARTED)) {
      BOOST_LOG(debug) << "WinVDM: ROOT\\MTTVDD\\0000 present but not started"sv
                       << " (status=0x"sv << std::hex << status << ")"sv;
      return false;
    }

    BOOST_LOG(debug) << "WinVDM: MttVDD driver installed and running"sv;
    return true;
  }

  /**
   * Enumerates active display paths via QueryDisplayConfig.  For each path,
   * calls DisplayConfigGetDeviceInfo(GET_TARGET_NAME) and checks whether
   * monitorDevicePath contains "mttvdd" (the PnP hardware ID).  On a match,
   * calls DisplayConfigGetDeviceInfo(GET_SOURCE_NAME) to retrieve the GDI
   * device name (e.g. "\\.\DISPLAY3") that DXGI uses for output enumeration.
   *
   * Uses GetDisplayConfigBufferSizes + retry loop to handle display topology
   * changes between the size query and the actual query.
   */
  std::string WinVirtualDisplayManager::get_display_name() {
    std::lock_guard lock(mutex_);

    UINT32 numPaths = 0, numModes = 0;
    std::vector<DISPLAYCONFIG_PATH_INFO> paths;
    std::vector<DISPLAYCONFIG_MODE_INFO> modes;

    LONG ret;
    do {
      ret = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &numPaths, &numModes);
      if (ret != ERROR_SUCCESS) {
        BOOST_LOG(error) << "WinVDM: GetDisplayConfigBufferSizes failed: "sv << ret;
        return {};
      }
      paths.resize(numPaths);
      modes.resize(numModes);
      ret = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS,
                               &numPaths, paths.data(),
                               &numModes, modes.data(), nullptr);
    } while (ret == ERROR_INSUFFICIENT_BUFFER);

    if (ret != ERROR_SUCCESS) {
      BOOST_LOG(error) << "WinVDM: QueryDisplayConfig failed: "sv << ret;
      return {};
    }

    for (UINT32 i = 0; i < numPaths; ++i) {
      const auto &path = paths[i];

      // The monitorDevicePath contains the PnP instance path, e.g.
      // "\\?\DISPLAY#ROOT&MttVDD#...".  Matching on "mttvdd" is reliable
      // and survives display index changes across reboots.
      DISPLAYCONFIG_TARGET_DEVICE_NAME target {};
      target.header.type      = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
      target.header.size      = sizeof(target);
      target.header.adapterId = path.targetInfo.adapterId;
      target.header.id        = path.targetInfo.id;

      if (DisplayConfigGetDeviceInfo(&target.header) != ERROR_SUCCESS) {
        continue;
      }

      std::wstring devicePath(target.monitorDevicePath);
      std::transform(devicePath.begin(), devicePath.end(),
                     devicePath.begin(), ::towlower);
      if (devicePath.find(L"mttvdd") == std::wstring::npos) {
        continue;
      }

      // Matched — retrieve the GDI source device name used by DXGI.
      DISPLAYCONFIG_SOURCE_DEVICE_NAME source {};
      source.header.type      = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
      source.header.size      = sizeof(source);
      source.header.adapterId = path.sourceInfo.adapterId;
      source.header.id        = path.sourceInfo.id;

      if (DisplayConfigGetDeviceInfo(&source.header) != ERROR_SUCCESS) {
        BOOST_LOG(warning) << "WinVDM: GET_SOURCE_NAME failed for MttVDD path"sv;
        continue;
      }

      auto name = utf_utils::to_utf8(source.viewGdiDeviceName);
      BOOST_LOG(info) << "WinVDM: virtual display at "sv << name;
      return name;
    }

    BOOST_LOG(debug) << "WinVDM: MttVDD not found in active display paths"sv;
    return {};
  }

}  // namespace platf::win
