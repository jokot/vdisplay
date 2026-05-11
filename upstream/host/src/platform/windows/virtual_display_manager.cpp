/**
 * @file src/platform/windows/virtual_display_manager.cpp
 * @brief WinVirtualDisplayManager — stub implementations.
 *
 * probe_driver_installed() is filled in by Task 8.
 * get_display_name()       is filled in by Task 7.
 */
#include "virtual_display_manager.h"

#include "src/logging.h"

using namespace std::literals;

namespace platf::win {

  WinVirtualDisplayManager &WinVirtualDisplayManager::instance() {
    static WinVirtualDisplayManager inst;
    return inst;
  }

  bool WinVirtualDisplayManager::probe_driver_installed() {
    // TODO(Task 8): check HKLM\SOFTWARE\vdisplay\VddOemInf in the registry,
    // then use CM_Locate_DevNodeW / CM_Get_DevNode_Status (cfgmgr32) to
    // confirm ROOT\MTTVDD\0000 is present and DN_STARTED.
    BOOST_LOG(debug) << "WinVirtualDisplayManager::probe_driver_installed() -- stub"sv;
    return false;
  }

  std::string WinVirtualDisplayManager::get_display_name() {
    // TODO(Task 7): call QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS) to get the
    // full path/mode tables, then DisplayConfigGetDeviceInfo with
    // DISPLAYCONFIG_DEVICE_INFO_GET_ADAPTER_NAME to find the adapter whose
    // device path contains "MttVDD".  Return the GDI device name from the
    // matching DISPLAYCONFIG_SOURCE_DEVICE_NAME query.
    BOOST_LOG(debug) << "WinVirtualDisplayManager::get_display_name() -- stub"sv;
    return {};
  }

}  // namespace platf::win
