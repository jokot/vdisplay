# Phase 5A — Windows Virtual Display Port — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port Phase 4 macOS virtual extended display capability to Windows. After install, host owns a persistent virtual monitor (1920×1080@60, right of primary) named `vdisplay-host`. Sunshine streams it to Moonlight clients by default; falls back to primary when driver missing.

**Architecture:** Vendor `itsmikethetech/Virtual-Display-Driver` (MIT, signed IDDCX kernel driver) inside a separate `vdisplay-driver-setup.exe` bundled with Sunshine. Sunshine prompts user to install driver on first launch. Discovery via Win DisplayConfig API matching friendly name `vdisplay-host`, mirroring Phase 4's `NSScreen.localizedName` pattern on Mac.

**Tech Stack:** Sunshine fork (C++17 / CMake / DXGI / Desktop Duplication API), itsmikethetech/Virtual-Display-Driver (vendored release binaries), NSIS packaging, gtest unit tests, Win 11 24H2 target on Yoga laptop.

**Spec:** [`docs/superpowers/specs/2026-05-06-phase5a-win-vdisplay-port-design.md`](../specs/2026-05-06-phase5a-win-vdisplay-port-design.md)

**Worktree:** Create at task 1: `/Users/jokot/dev/vdisplay-phase5a` (Mac side) + `C:\dev\vdisplay-phase5a` (Yoga side).

**Branch:** `feat/phase5a-win-vdisplay`

---

## File Structure (locked at planning time)

**New files (created during this plan):**

- `installers/windows/vdisplay-driver-setup/vendored/` — pinned release artifacts of itsmikethetech VDD (`.sys`, `.inf`, `.cat`, signed cert, README, LICENSE)
- `installers/windows/vdisplay-driver-setup/options.txt` — VDD config: monitor count = 1, EDID name `vdisplay-host`, 1920×1080@60, position right-of-primary
- `installers/windows/vdisplay-driver-setup/install.ps1` — wraps `pnputil /add-driver` + service registration; called by NSIS at install time
- `installers/windows/vdisplay-driver-setup/vdisplay-driver-setup.nsi` — NSIS script producing `vdisplay-driver-setup.exe`
- `installers/windows/vdisplay-driver-setup/README.md` — vendoring policy, attribution, upgrade procedure
- `upstream/host/src/platform/windows/virtual_display_manager.h` — singleton interface
- `upstream/host/src/platform/windows/virtual_display_manager.cpp` — DisplayConfig-API discovery
- `upstream/host/tests/unit/platform/windows/test_virtual_display_manager.cpp` — gtest mocks for DisplayConfig
- `upstream/host/src/platform/windows/vd_install_prompt.h/.cpp` — first-launch modal + spawn of installer

**Modified files:**

- `upstream/host/src/platform/windows/display_base.cpp` — patched `init()` to consult `WinVirtualDisplayManager` before defaulting to primary DXGI output
- `upstream/host/src/platform/windows/display.cpp` (or wherever Win display enumeration lives — confirm at Task 6) — `display_names()` analog injects virtual display ID when present
- `upstream/host/cmake/targets/windows.cmake` — link new sources, copy `vdisplay-driver-setup.exe` to install output
- `upstream/host/src/main.cpp` — wire `vd_install_prompt::maybe_show()` into Win-only boot path
- `upstream/host/src/config.h/.cpp` — add `prompt_vdisplay_install_done` boolean config field
- `installers/windows/<existing Sunshine NSIS or WiX file>` — bundle `vdisplay-driver-setup.exe` into Sunshine's main installer

**Reference:** Phase 4 implementation in `upstream/host/src/platform/macos/{virtual_display_manager.h,virtual_display_manager.mm,display.mm,av_video.m}` (commit `468486aa0`). Mirror its conventions where Win-applicable.

---

## Task 1: Bootstrap Yoga dev environment + smoke-build current Sunshine

**Goal:** Verify Yoga can build the post-Phase-4 Sunshine fork before adding any Phase 5A code. Closes pending task #14 (Phase 1 Win smoke build).

**Files:**
- Modify: `scripts/bootstrap.sh` (only if Yoga exposes a different submodule SHA gap; document, do not fix in this task)

- [ ] **Step 1: Clone monorepo on Yoga**

```powershell
cd C:\dev
git clone https://github.com/jokot/vdisplay.git vdisplay-phase5a
cd vdisplay-phase5a
git checkout -b feat/phase5a-win-vdisplay
```

- [ ] **Step 2: Install prerequisites on Yoga**

Required (verify each):
- Visual Studio 2022 with "Desktop development with C++" + Windows 11 SDK (10.0.22621.0 or later)
- CMake 3.25+
- Ninja (`choco install ninja` or via VS installer)
- Git for Windows
- Python 3.11+ (Sunshine's web UI build)
- Node.js 20+ + npm (web UI build)
- 7-Zip (NSIS prerequisite)
- NSIS 3.10+ (`choco install nsis`)

Document any version that differs from spec at task end so the impl plan can be updated.

- [ ] **Step 3: Run bootstrap script**

```powershell
bash scripts/bootstrap.sh
```

Expected: clones submodules of `upstream/host`. If a submodule SHA-gap appears (per memory `bootstrap_submodule_sha_gap.md`), apply the manual recipe — do NOT fix bootstrap.sh in this task.

- [ ] **Step 4: Configure CMake**

```powershell
cd upstream\host
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
```

Expected: configure succeeds, no missing dependency errors. If FFmpeg/Boost FetchContent fails: re-run with `-DSUNSHINE_BUILD_TESTS=OFF` first to isolate.

- [ ] **Step 5: Build Sunshine**

```powershell
cmake --build build --target sunshine
```

Expected: `build\sunshine.exe` produced (or whatever Win binary path Sunshine uses).

- [ ] **Step 6: Smoke-test Sunshine launch**

```powershell
build\sunshine.exe
```

Expected: Sunshine starts, web UI on `https://localhost:47990`, no crash. Ctrl+C to stop. Note: do NOT pair Moonlight yet — bare smoke only.

- [ ] **Step 7: Commit (no code change yet — just confirms env)**

If `scripts/bootstrap.sh` was tweaked or any platform-config tweak was needed, commit those. Otherwise no commit; record findings in TaskUpdate description so Task 14 has them.

```powershell
git add <any-tweaked-files>
git commit -m "chore(phase5a): Yoga build environment validated"
```

---

## Task 2: Vendor itsmikethetech/Virtual-Display-Driver release

**Goal:** Pull a pinned signed release of the upstream VDD into `installers/windows/vdisplay-driver-setup/vendored/` so we can ship it.

**Files:**
- Create: `installers/windows/vdisplay-driver-setup/vendored/` (directory)
- Create: `installers/windows/vdisplay-driver-setup/vendored/<version>/<artifacts>` — exact filenames depend on release; expect `IddSampleDriver.sys`, `.inf`, `.cat`, `IddSampleDriver.cer`
- Create: `installers/windows/vdisplay-driver-setup/README.md` — attribution + upgrade procedure
- Create: `installers/windows/vdisplay-driver-setup/LICENSE.MIT.txt` — copy of upstream LICENSE

- [ ] **Step 1: Pick a release tag**

Visit https://github.com/itsmikethetech/Virtual-Display-Driver/releases. Pick the most recent release marked "Stable" with Win 11 24H2 in tested platforms list (verify the project README first; tag names change). Record the tag (e.g., `v25.x.y`) in `installers/windows/vdisplay-driver-setup/README.md` for upgrade traceability.

- [ ] **Step 2: Download the release ZIP**

```powershell
$tag = "v<picked-tag>"
$url = "https://github.com/itsmikethetech/Virtual-Display-Driver/releases/download/$tag/Virtual.Display.Driver.zip"
mkdir -Force installers\windows\vdisplay-driver-setup\vendored\$tag
Invoke-WebRequest -Uri $url -OutFile installers\windows\vdisplay-driver-setup\vendored\$tag.zip
Expand-Archive installers\windows\vdisplay-driver-setup\vendored\$tag.zip `
  -DestinationPath installers\windows\vdisplay-driver-setup\vendored\$tag
```

Verify the archive layout matches the project's README. If `IddSampleDriver.sys` is the kernel driver, that is the binary that gets installed.

- [ ] **Step 3: Copy LICENSE**

```powershell
Copy-Item installers\windows\vdisplay-driver-setup\vendored\$tag\LICENSE `
  installers\windows\vdisplay-driver-setup\LICENSE.MIT.txt
```

- [ ] **Step 4: Write attribution README**

Create `installers/windows/vdisplay-driver-setup/README.md`:

```markdown
# vdisplay Windows Driver Setup

This directory ships a pre-configured release of
[itsmikethetech/Virtual-Display-Driver](https://github.com/itsmikethetech/Virtual-Display-Driver)
under MIT license. We do NOT modify the driver source. We add only:

- `options.txt` — vdisplay-specific monitor config (1 monitor,
  `vdisplay-host` EDID name, 1920×1080@60).
- `install.ps1` — wraps `pnputil /add-driver` for unattended install.
- `vdisplay-driver-setup.nsi` — NSIS script producing the standalone
  installer artifact.

## Pinned version

- Upstream tag: **<paste tag here>**
- Upstream commit (resolve via GitHub releases UI): **<paste sha here>**
- Vendored on: **<YYYY-MM-DD>**

## Upgrade procedure

1. Pick a newer upstream release tag.
2. Re-run `Invoke-WebRequest` from Task 2 Step 2 with the new tag.
3. Diff `options.txt` schema against the new release — config format
   may have changed.
4. Smoke test on Yoga via Task 5.
5. Bump the pin in this README and ship a new vdisplay release.

## Attribution

The IDDCX driver is © itsmikethetech and contributors, MIT license
— see `LICENSE.MIT.txt`. vdisplay distributes it unmodified per MIT
terms; modifications (config + installer wrapper) are vdisplay's own
under GPL-3.
```

- [ ] **Step 5: Commit**

```powershell
git add installers\windows\vdisplay-driver-setup
git commit -m "vendor(phase5a): itsmikethetech VDD <tag> with MIT attribution"
```

---

## Task 3: Configure vendored VDD with vdisplay-host EDID

**Goal:** Override upstream VDD's default monitor config so the installed driver presents itself as `vdisplay-host` at 1920×1080@60, positioned right of primary.

**Files:**
- Create: `installers/windows/vdisplay-driver-setup/options.txt`
- Modify: `installers/windows/vdisplay-driver-setup/README.md` (note the config format)

- [ ] **Step 1: Read upstream's `options.txt` schema**

Open `installers/windows/vdisplay-driver-setup/vendored/<tag>/options.txt` (or `option.txt` / `IddSampleDriver.txt` — name varies by release). Find the schema for: monitor count, resolution list, refresh rate, EDID monitor name. Record syntax in plan-task notes.

- [ ] **Step 2: Write our `options.txt`**

Place at `installers/windows/vdisplay-driver-setup/options.txt` (one level above `vendored/`, so it overrides at install time). Example structure (verify exact syntax against what step 1 found):

```
# vdisplay Phase 5A monitor config
# Single virtual monitor named "vdisplay-host", 1920x1080@60
1
1920 1080 60
```

If the release uses a JSON or registry-key config instead, write the equivalent. The user-visible EDID name (`vdisplay-host`) may live in a separate `.inf` overlay or registry hive depending on release — discover at Step 1, document in plan-task notes.

- [ ] **Step 3: Add a position hint**

Most VDD releases do NOT directly support "position right of primary" — that's a Win Display Settings concern, set after the monitor materializes. If the vendored VDD has no position config, document this in `README.md`:

```markdown
## Position
The driver creates the monitor; Windows assigns initial position
arbitrarily. After install, vdisplay's `install.ps1` calls
`Set-DisplayConfig` (Win 11 native) or PowerShell+CCD APIs to move
the virtual monitor to (primary_width, 0). See `install.ps1`.
```

- [ ] **Step 4: Commit**

```powershell
git add installers\windows\vdisplay-driver-setup\options.txt installers\windows\vdisplay-driver-setup\README.md
git commit -m "config(phase5a): VDD pre-config — vdisplay-host EDID, 1920x1080@60"
```

---

## Task 4: Build vdisplay-driver-setup.exe (NSIS)

**Goal:** Produce a standalone signed installer EXE that, when run with admin rights, registers the vendored VDD via `pnputil` and applies our `options.txt`.

**Files:**
- Create: `installers/windows/vdisplay-driver-setup/install.ps1`
- Create: `installers/windows/vdisplay-driver-setup/vdisplay-driver-setup.nsi`

- [ ] **Step 1: Write `install.ps1`**

```powershell
# install.ps1 — runs as admin via NSIS
# Installs the vendored IDDCX driver and applies vdisplay options.

param(
    [string]$DriverDir = "$PSScriptRoot\vendored",
    [string]$OptionsSrc = "$PSScriptRoot\options.txt"
)

$ErrorActionPreference = "Stop"

# Locate the .inf inside the vendored release directory
$Inf = Get-ChildItem -Path $DriverDir -Recurse -Filter "*.inf" | Select-Object -First 1
if (-not $Inf) {
    Write-Error "No .inf found under $DriverDir"
    exit 1
}

# Install via pnputil (Win 10+ ships this in System32)
pnputil /add-driver $Inf.FullName /install
if ($LASTEXITCODE -ne 0) {
    Write-Error "pnputil exited $LASTEXITCODE"
    exit $LASTEXITCODE
}

# Copy options.txt to the location the driver reads from
# (path depends on the upstream release — discover at Task 3 Step 1)
$DriverConfigDir = "$env:ProgramData\IddSampleDriver"
New-Item -ItemType Directory -Force -Path $DriverConfigDir | Out-Null
Copy-Item -Force $OptionsSrc "$DriverConfigDir\options.txt"

# Restart the driver so options.txt takes effect
# (driver vendor's install scripts usually do this — copy their pattern)
# pnputil /restart-device  ... etc
Write-Host "vdisplay driver installed."
```

- [ ] **Step 2: Write `vdisplay-driver-setup.nsi`**

```nsis
; vdisplay-driver-setup.nsi
; Produces vdisplay-driver-setup.exe — admin-required installer.

!define APP_NAME "vdisplay Virtual Display Driver"
!define VERSION "1.0.0"
!define INSTALL_DIR "$PROGRAMFILES64\vdisplay\driver"

OutFile "vdisplay-driver-setup.exe"
InstallDir "${INSTALL_DIR}"
RequestExecutionLevel admin

Page directory
Page instfiles

Section "Install"
  SetOutPath "$INSTDIR"
  File /r "vendored\*"
  File "options.txt"
  File "install.ps1"
  File "LICENSE.MIT.txt"

  ; Run install.ps1 elevated (NSIS is already admin per RequestExecutionLevel)
  ExecWait 'powershell.exe -ExecutionPolicy Bypass -NoProfile -File "$INSTDIR\install.ps1"' $0
  IntCmp $0 0 +3
    MessageBox MB_ICONSTOP "Driver install failed (exit $0). See log."
    Abort

  WriteUninstaller "$INSTDIR\uninstall.exe"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\vdisplay-driver" \
    "DisplayName" "${APP_NAME}"
  WriteRegStr HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\vdisplay-driver" \
    "UninstallString" "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
  ; Remove driver via pnputil
  ExecWait 'pnputil /delete-driver "$INSTDIR\vendored\<inf-name>" /uninstall /force' $0
  RMDir /r "$INSTDIR"
  DeleteRegKey HKLM "Software\Microsoft\Windows\CurrentVersion\Uninstall\vdisplay-driver"
SectionEnd
```

(Resolve `<inf-name>` to the actual `.inf` filename discovered in Task 2 Step 2 before committing.)

- [ ] **Step 3: Build the installer**

```powershell
cd installers\windows\vdisplay-driver-setup
makensis vdisplay-driver-setup.nsi
```

Expected: produces `vdisplay-driver-setup.exe` (~5–15 MB depending on driver size).

- [ ] **Step 4: Commit**

```powershell
git add installers\windows\vdisplay-driver-setup\install.ps1 `
        installers\windows\vdisplay-driver-setup\vdisplay-driver-setup.nsi
git commit -m "build(phase5a): NSIS installer for vendored VDD"
```

---

## Task 5: Manual driver install + verification on Yoga

**Goal:** Validate the artifact from Task 4 actually installs and produces a `vdisplay-host` monitor.

**No automated tests** — kernel-mode driver install requires UAC.

- [ ] **Step 1: Run installer**

```powershell
.\installers\windows\vdisplay-driver-setup\vdisplay-driver-setup.exe
```

Accept UAC. Click through. Wait for "Driver installed" message.

- [ ] **Step 2: Verify driver in Device Manager**

Open Device Manager → expand "Display adapters". Expect entry like `vdisplay-host` or `Virtual Display Driver (vdisplay-host)`. Status: Working properly.

- [ ] **Step 3: Verify monitor in Display Settings**

Win+I → System → Display. Expect a 2nd monitor in the topology view. Click it; "Display name" or details panel should show `vdisplay-host`.

- [ ] **Step 4: Verify resolution**

In Display Settings, with the virtual monitor selected, "Display resolution" should be `1920 × 1080`. "Refresh rate" should be `60 Hz`.

- [ ] **Step 5: Drag a window onto the virtual monitor**

Drag any window past the right edge of the primary display. Expect the window to land on the virtual monitor (you won't see it visually since the monitor is virtual — but Win+Tab will show it as occupying virtual-monitor space).

- [ ] **Step 6: Uninstall test**

Control Panel → Programs → uninstall `vdisplay Virtual Display Driver` → reboot if Win prompts. Verify Device Manager no longer shows the entry.

- [ ] **Step 7: Reinstall**

Re-run the installer (you'll need it for subsequent tasks).

- [ ] **Step 8: Commit**

(No code change. Record outcomes in PR description / task notes.)

---

## Task 6: WinVirtualDisplayManager skeleton

**Goal:** Create the singleton class header + stub implementation + CMake hookup. No real logic yet.

**Files:**
- Create: `upstream/host/src/platform/windows/virtual_display_manager.h`
- Create: `upstream/host/src/platform/windows/virtual_display_manager.cpp`
- Modify: `upstream/host/cmake/targets/windows.cmake`

- [ ] **Step 1: Write `virtual_display_manager.h`**

```cpp
/**
 * @file src/platform/windows/virtual_display_manager.h
 * @brief Singleton that discovers a vendored vdisplay-host virtual
 *        monitor on Windows and reports it to Sunshine's display
 *        selection.
 *
 * Mirrors the macOS MacVirtualDisplayManager contract from Phase 4:
 *   - get_display_id() returns the virtual display when available,
 *     std::nullopt otherwise. Live discovery, not cached.
 *   - probe_driver_installed(timeout) is used by the first-launch
 *     prompt to wait for IDDCX device materialization after install.
 *
 * Unlike Phase 4, the driver is OS-managed; there is no spawn or
 * teardown. The class is stateless beyond a configuration knob.
 */
#pragma once

#include <chrono>
#include <cstdint>
#include <optional>
#include <string>

#include <windows.h>

namespace platf::windows {

  struct VirtualDisplayInfo {
    LUID adapter;
    uint32_t target_id;
    std::wstring device_name;  // DXGI DeviceName, e.g., L"\\\\.\\DISPLAY3"
  };

  class WinVirtualDisplayManager {
   public:
    static WinVirtualDisplayManager &instance();

    /**
     * Live DisplayConfig scan for an IDDCX target whose friendly
     * name matches "vdisplay-host". Returns std::nullopt on absent,
     * disabled, or DisplayConfig API failure.
     */
    std::optional<VirtualDisplayInfo> get_display_id() const;

    /**
     * Polls get_display_id() at 500 ms intervals until it returns
     * a value or the deadline elapses. Used during the first-launch
     * install flow.
     */
    bool probe_driver_installed(std::chrono::milliseconds timeout) const;

   private:
    WinVirtualDisplayManager() = default;
    WinVirtualDisplayManager(const WinVirtualDisplayManager &) = delete;
    WinVirtualDisplayManager &operator=(const WinVirtualDisplayManager &) = delete;
  };

}  // namespace platf::windows
```

- [ ] **Step 2: Write `virtual_display_manager.cpp` stub**

```cpp
/**
 * @file src/platform/windows/virtual_display_manager.cpp
 * @brief Implementation of WinVirtualDisplayManager.
 *        Stub bodies in this commit; real DisplayConfig calls
 *        land in Task 7.
 */
#include "virtual_display_manager.h"

#include "src/logging.h"

namespace platf::windows {

  WinVirtualDisplayManager &WinVirtualDisplayManager::instance() {
    static WinVirtualDisplayManager s;
    return s;
  }

  std::optional<VirtualDisplayInfo>
  WinVirtualDisplayManager::get_display_id() const {
    // Filled in Task 7.
    return std::nullopt;
  }

  bool WinVirtualDisplayManager::probe_driver_installed(
      std::chrono::milliseconds timeout) const {
    // Filled in Task 8.
    (void)timeout;
    return false;
  }

}  // namespace platf::windows
```

- [ ] **Step 3: Hook up CMake**

Open `upstream/host/cmake/targets/windows.cmake`. Append:

```cmake
list(APPEND PLATFORM_TARGET_FILES
     ${CMAKE_SOURCE_DIR}/src/platform/windows/virtual_display_manager.h
     ${CMAKE_SOURCE_DIR}/src/platform/windows/virtual_display_manager.cpp)
```

(Verify the actual list variable name by grepping the file — match Sunshine's existing convention.)

- [ ] **Step 4: Build to verify hookup**

```powershell
cmake --build build --target sunshine
```

Expected: clean build, no warnings on the new files.

- [ ] **Step 5: Commit**

```powershell
git add upstream\host\src\platform\windows\virtual_display_manager.h `
        upstream\host\src\platform\windows\virtual_display_manager.cpp `
        upstream\host\cmake\targets\windows.cmake
git commit -m "host(win): WinVirtualDisplayManager skeleton"
```

---

## Task 7: get_display_id() — DisplayConfig API + unit tests

**Goal:** Implement live discovery via Win DisplayConfig API. Match friendly name `"vdisplay-host"` → return `VirtualDisplayInfo`.

**Files:**
- Modify: `upstream/host/src/platform/windows/virtual_display_manager.cpp`
- Create: `upstream/host/tests/unit/platform/windows/test_virtual_display_manager.cpp`
- Modify: `upstream/host/tests/CMakeLists.txt` — wire new test

- [ ] **Step 1: Write the failing test**

```cpp
// tests/unit/platform/windows/test_virtual_display_manager.cpp
#include <gtest/gtest.h>
#include "src/platform/windows/virtual_display_manager.h"

using platf::windows::WinVirtualDisplayManager;

// Sanity: the singleton is constructible.
TEST(WinVirtualDisplayManager, SingletonIsAccessible) {
  auto &mgr = WinVirtualDisplayManager::instance();
  ASSERT_NE(&mgr, nullptr);
}

// Returns nullopt when no matching IDDCX target is present.
// On a CI runner without the driver installed, this is the
// production case.
TEST(WinVirtualDisplayManager, NoDriverReturnsNullopt) {
  auto result = WinVirtualDisplayManager::instance().get_display_id();
  ASSERT_FALSE(result.has_value());
}
```

(Mocking `DisplayConfigGetDeviceInfo` cleanly requires a function-pointer indirection. For Phase 5A v1, we keep the test surface minimal — null-on-absent, real-API-on-present — and rely on manual e2e for positive cases. Defer full mock to Task 13 review if missing coverage hurts.)

- [ ] **Step 2: Run test, expect FAIL or trivially pass on the second case**

```powershell
cmake --build build --target test_virtual_display_manager
build\tests\test_virtual_display_manager.exe
```

Expected: SingletonIsAccessible passes; `NoDriverReturnsNullopt` may pass too with stub returning `std::nullopt`. That's actually fine — proves the stub. Move on.

- [ ] **Step 3: Implement `get_display_id()` in `virtual_display_manager.cpp`**

```cpp
#include "virtual_display_manager.h"

#include "src/logging.h"

#include <chrono>
#include <thread>
#include <vector>

#include <wingdi.h>

namespace platf::windows {

  WinVirtualDisplayManager &WinVirtualDisplayManager::instance() {
    static WinVirtualDisplayManager s;
    return s;
  }

  static constexpr wchar_t kVdisplayHostName[] = L"vdisplay-host";

  std::optional<VirtualDisplayInfo>
  WinVirtualDisplayManager::get_display_id() const {
    UINT32 path_count = 0, mode_count = 0;
    LONG rc = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS,
                                          &path_count, &mode_count);
    if (rc != ERROR_SUCCESS) {
      BOOST_LOG(warning) << "GetDisplayConfigBufferSizes failed: " << rc;
      return std::nullopt;
    }

    std::vector<DISPLAYCONFIG_PATH_INFO> paths(path_count);
    std::vector<DISPLAYCONFIG_MODE_INFO> modes(mode_count);
    rc = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &path_count, paths.data(),
                            &mode_count, modes.data(), nullptr);
    if (rc != ERROR_SUCCESS) {
      BOOST_LOG(warning) << "QueryDisplayConfig failed: " << rc;
      return std::nullopt;
    }

    for (UINT32 i = 0; i < path_count; ++i) {
      DISPLAYCONFIG_TARGET_DEVICE_NAME tgt = {};
      tgt.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
      tgt.header.size = sizeof(tgt);
      tgt.header.adapterId = paths[i].targetInfo.adapterId;
      tgt.header.id = paths[i].targetInfo.id;

      rc = DisplayConfigGetDeviceInfo(&tgt.header);
      if (rc != ERROR_SUCCESS) {
        continue;  // skip this target, try next
      }

      if (wcscmp(tgt.monitorFriendlyDeviceName, kVdisplayHostName) != 0) {
        continue;
      }

      // Match. Resolve the GDI device name via the source path.
      DISPLAYCONFIG_SOURCE_DEVICE_NAME src = {};
      src.header.type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
      src.header.size = sizeof(src);
      src.header.adapterId = paths[i].sourceInfo.adapterId;
      src.header.id = paths[i].sourceInfo.id;
      rc = DisplayConfigGetDeviceInfo(&src.header);
      if (rc != ERROR_SUCCESS) {
        BOOST_LOG(warning)
            << "Source-name lookup failed for vdisplay-host: " << rc;
        return std::nullopt;
      }

      VirtualDisplayInfo info;
      info.adapter = paths[i].targetInfo.adapterId;
      info.target_id = paths[i].targetInfo.id;
      info.device_name = src.viewGdiDeviceName;
      BOOST_LOG(info)
          << "vdisplay-host found: target_id=" << info.target_id
          << " gdi=" << std::wstring(info.device_name);
      return info;
    }

    return std::nullopt;
  }

  bool WinVirtualDisplayManager::probe_driver_installed(
      std::chrono::milliseconds timeout) const {
    // Filled in Task 8.
    (void)timeout;
    return false;
  }

}  // namespace platf::windows
```

- [ ] **Step 4: Re-run tests**

```powershell
cmake --build build --target test_virtual_display_manager
build\tests\test_virtual_display_manager.exe
```

Expected: PASS (no driver in CI → nullopt; trivially correct).

- [ ] **Step 5: Manual sanity test on Yoga**

Driver was installed in Task 5. With it present:

```powershell
build\sunshine.exe
```

Expected: a log line like `vdisplay-host found: target_id=XX gdi=\\.\DISPLAYY` appears at boot. (We have not yet wired this into capture-side code — Task 9. But the discovery line should fire if `WinVirtualDisplayManager::instance().get_display_id()` is exercised somewhere.)

If no log line: add a temporary `BOOST_LOG(info) << "phase5a probe: " << (id.has_value() ? "found" : "missing");` in `main.cpp` after config load, just for this manual check, then revert.

- [ ] **Step 6: Commit**

```powershell
git add upstream\host\src\platform\windows\virtual_display_manager.cpp `
        upstream\host\tests\unit\platform\windows\test_virtual_display_manager.cpp `
        upstream\host\tests\CMakeLists.txt
git commit -m "host(win): WinVirtualDisplayManager::get_display_id via DisplayConfig"
```

---

## Task 8: probe_driver_installed() + tests

**Goal:** Polling wrapper around `get_display_id()` with deadline.

**Files:**
- Modify: `upstream/host/src/platform/windows/virtual_display_manager.cpp`
- Modify: `upstream/host/tests/unit/platform/windows/test_virtual_display_manager.cpp`

- [ ] **Step 1: Write the failing test**

```cpp
TEST(WinVirtualDisplayManager, ProbeRespectsTimeout) {
  using namespace std::chrono;
  auto t0 = steady_clock::now();
  bool found = WinVirtualDisplayManager::instance()
                   .probe_driver_installed(milliseconds(200));
  auto elapsed = duration_cast<milliseconds>(steady_clock::now() - t0);
  // CI: no driver, must time out around 200 ms.
  ASSERT_FALSE(found);
  ASSERT_GE(elapsed.count(), 180);
  ASSERT_LE(elapsed.count(), 600);  // allow polling slack
}
```

- [ ] **Step 2: Run test, expect FAIL**

Stub returns `false` immediately, so elapsed will be ~0 ms. The lower bound assertion (`>= 180`) fails.

```powershell
build\tests\test_virtual_display_manager.exe --gtest_filter=*ProbeRespectsTimeout*
```

Expected: FAIL.

- [ ] **Step 3: Implement `probe_driver_installed()`**

Replace stub in `virtual_display_manager.cpp`:

```cpp
bool WinVirtualDisplayManager::probe_driver_installed(
    std::chrono::milliseconds timeout) const {
  using clock = std::chrono::steady_clock;
  const auto deadline = clock::now() + timeout;
  do {
    if (get_display_id().has_value()) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
  } while (clock::now() < deadline);
  return false;
}
```

- [ ] **Step 4: Re-run test**

```powershell
build\tests\test_virtual_display_manager.exe --gtest_filter=*ProbeRespectsTimeout*
```

Expected: PASS.

- [ ] **Step 5: Commit**

```powershell
git add upstream\host\src\platform\windows\virtual_display_manager.cpp `
        upstream\host\tests\unit\platform\windows\test_virtual_display_manager.cpp
git commit -m "host(win): WinVirtualDisplayManager::probe_driver_installed"
```

---

## Task 9: display_base.cpp probe-and-adopt patch

**Goal:** When Sunshine initializes display capture, prefer the virtual display if available, fall back to primary otherwise.

**Files:**
- Modify: `upstream/host/src/platform/windows/display_base.cpp`

- [ ] **Step 1: Locate `display_base.cpp::init()`**

```powershell
grep -n "init\|EnumAdapters\|EnumOutputs" upstream\host\src\platform\windows\display_base.cpp | Select-Object -First 30
```

Find where the primary DXGI output is selected (likely `IDXGIFactory::EnumAdapters[0]::EnumOutputs[0]` or similar). Note exact line numbers in plan-task notes.

- [ ] **Step 2: Add the include**

```cpp
#include "src/platform/windows/virtual_display_manager.h"
```

- [ ] **Step 3: Insert probe-and-adopt before primary fallback**

Where `display_base_t::init()` enumerates DXGI outputs, replace the "always pick primary" logic with:

```cpp
// Phase 5A: if the vdisplay-host virtual monitor is present and
// capturable, prefer it over the primary display. Fall back to
// primary on any failure path (mirror mode).
{
  auto vd = platf::windows::WinVirtualDisplayManager::instance().get_display_id();
  if (vd.has_value()) {
    Microsoft::WRL::ComPtr<IDXGIOutput> match;
    for (UINT a = 0; ; ++a) {
      Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
      if (factory->EnumAdapters(a, &adapter) == DXGI_ERROR_NOT_FOUND) break;
      for (UINT o = 0; ; ++o) {
        Microsoft::WRL::ComPtr<IDXGIOutput> output;
        if (adapter->EnumOutputs(o, &output) == DXGI_ERROR_NOT_FOUND) break;
        DXGI_OUTPUT_DESC desc{};
        if (FAILED(output->GetDesc(&desc))) continue;
        if (vd->device_name == desc.DeviceName) {
          match = output;
          break;
        }
      }
      if (match) break;
    }
    if (match) {
      BOOST_LOG(info) << "Phase 5A: streaming virtual display vdisplay-host";
      // Adopt 'match' as the chosen output. The exact assignment
      // depends on Sunshine's existing init body — typically saved
      // to a member like `output_` or returned to the caller. Mirror
      // exactly what the existing primary-pick code does, but with
      // `match` substituted for the primary output. Resolve at impl
      // time by reading the existing init() body.
    } else {
      BOOST_LOG(warning)
          << "Phase 5A: vdisplay-host registered but no matching DXGI "
             "output; falling back to primary";
    }
  }
  // No virtual display OR no DXGI match → existing primary-pick code.
}
```

(Resolve the "Adopt 'match'" comment to the actual Sunshine assignment by reading the existing `init()` body — it varies by Sunshine version. Mirror exactly what the existing fallback does, but with `match` substituted for the primary output.)

- [ ] **Step 4: Build**

```powershell
cmake --build build --target sunshine
```

Expected: clean build.

- [ ] **Step 5: Manual e2e smoke (Yoga)**

Driver installed (Task 5). Run Sunshine. Connect Moonlight Android. Expect: phone shows the **virtual** display, not main. Drag a window past primary's right edge → window appears on phone.

- [ ] **Step 6: Mirror-fallback smoke**

Disable VDD via Device Manager → Display adapters → right-click → Disable. Reconnect Moonlight. Expect: phone shows main display. Sunshine log: `Phase 5A: vdisplay-host registered but no matching DXGI output; falling back to primary` OR no Phase 5A log line at all (depending on whether DisplayConfig still surfaces the disabled device — verify which case applies).

Re-enable VDD before next task.

- [ ] **Step 7: Commit**

```powershell
git add upstream\host\src\platform\windows\display_base.cpp
git commit -m "host(win): display_base — adopt vdisplay-host when present, fallback to primary"
```

---

## Task 10: display_names() injection

**Goal:** Sunshine's web UI display picker should list `vdisplay-host` as an option (and as the default) when present.

**Files:**
- Modify: `upstream/host/src/platform/windows/display.cpp` (or wherever Win `display_names()` lives — find at Step 1)

- [ ] **Step 1: Find the Win analog of macOS `display_names()`**

```powershell
grep -rn "display_names" upstream\host\src\platform\windows\ | Select-Object -First 5
```

Phase 4 macOS lives in `display.mm:219`. The Win equivalent is wherever `std::vector<std::string> display_names(mem_type_e)` is defined for Win.

- [ ] **Step 2: Inject vdisplay-host id at the front of the list**

Mirror the Phase 4 pattern (`display.mm:233-240`):

```cpp
// Phase 5A: prepend the virtual display when available + capturable.
auto vd = platf::windows::WinVirtualDisplayManager::instance().get_display_id();
if (vd.has_value()) {
  std::wstring w = vd->device_name;
  std::string utf8(w.begin(), w.end());  // fine for ASCII-only DeviceName
  // If we got here from get_display_id() we already matched a
  // DisplayConfig active path; that's the capturability proof for
  // listing purposes. (display_base.cpp handles the harder probe.)
  display_names.insert(display_names.begin(), utf8);
}
```

(Verify the `display_names` collection name and the existing function structure before pasting; adjust to match Sunshine's coding style.)

- [ ] **Step 3: Build + smoke test**

```powershell
cmake --build build --target sunshine
build\sunshine.exe
```

Open https://localhost:47990 → Configuration → Display. Expected: dropdown lists `\\.\DISPLAYn` (or whatever GDI name) for the virtual display as the top entry.

- [ ] **Step 4: Commit**

```powershell
git add upstream\host\src\platform\windows\display.cpp
git commit -m "host(win): display_names injects vdisplay-host when present"
```

---

## Task 11: First-launch install prompt + config flag

**Goal:** When Sunshine boots and the driver isn't installed, prompt the user once. Persist the answer in config.

**Files:**
- Create: `upstream/host/src/platform/windows/vd_install_prompt.h`
- Create: `upstream/host/src/platform/windows/vd_install_prompt.cpp`
- Modify: `upstream/host/src/main.cpp`
- Modify: `upstream/host/src/config.h`
- Modify: `upstream/host/src/config.cpp`

- [ ] **Step 1: Add config flag**

Edit `upstream/host/src/config.h`. Add to the appropriate config struct (find by grep — `bool` fields with `config::sunshine.<name>` access):

```cpp
bool prompt_vdisplay_install_done = false;
```

Edit `upstream/host/src/config.cpp` — add to the parser/serializer alongside other booleans:

```cpp
{"prompt_vdisplay_install_done", &config::sunshine.prompt_vdisplay_install_done},
```

(Pattern depends on Sunshine's config plumbing — match the existing convention.)

- [ ] **Step 2: Write `vd_install_prompt.h`**

```cpp
/**
 * @file src/platform/windows/vd_install_prompt.h
 * @brief First-launch UAC-elevated install prompt for the vendored
 *        vdisplay IDDCX driver.
 */
#pragma once

namespace platf::windows::vd_install_prompt {

  /**
   * Called once per Sunshine boot. If the driver is not detected
   * AND the user has not already declined, shows a modal asking
   * to install. Updates config flags accordingly.
   *
   * Spawns vdisplay-driver-setup.exe (UAC) on Install. Polls for
   * device materialization up to 30 seconds afterwards.
   */
  void maybe_show();

}  // namespace platf::windows::vd_install_prompt
```

- [ ] **Step 3: Write `vd_install_prompt.cpp`**

```cpp
/**
 * @file src/platform/windows/vd_install_prompt.cpp
 */
#include "vd_install_prompt.h"

#include "virtual_display_manager.h"
#include "src/config.h"
#include "src/logging.h"

#include <chrono>
#include <filesystem>

#include <windows.h>
#include <shellapi.h>

namespace fs = std::filesystem;

namespace platf::windows::vd_install_prompt {

  static fs::path installer_path() {
    // Installer is shipped alongside Sunshine at
    // <Sunshine install dir>\driver\vdisplay-driver-setup.exe
    wchar_t buf[MAX_PATH];
    GetModuleFileNameW(nullptr, buf, MAX_PATH);
    fs::path exe(buf);
    return exe.parent_path() / "driver" / "vdisplay-driver-setup.exe";
  }

  void maybe_show() {
    if (config::sunshine.prompt_vdisplay_install_done) {
      return;
    }
    if (WinVirtualDisplayManager::instance().get_display_id().has_value()) {
      return;
    }

    int btn = MessageBoxW(
        nullptr,
        L"vdisplay's virtual extended display driver is not installed.\n\n"
        L"Install it now? (Recommended — required for streaming a "
        L"separate virtual desktop instead of mirroring your main "
        L"screen.)\n\n"
        L"You can also skip and install it later from "
        L"Program Files\\vdisplay\\driver.",
        L"vdisplay — Install Virtual Display Driver",
        MB_YESNOCANCEL | MB_ICONQUESTION);

    auto installer = installer_path();
    switch (btn) {
      case IDYES: {
        if (!fs::exists(installer)) {
          BOOST_LOG(warning)
              << "vdisplay installer not found at " << installer;
          return;
        }
        SHELLEXECUTEINFOW sei = {sizeof(sei)};
        sei.lpVerb = L"runas";
        sei.lpFile = installer.c_str();
        sei.nShow = SW_SHOW;
        sei.fMask = SEE_MASK_NOCLOSEPROCESS;
        if (!ShellExecuteExW(&sei) || !sei.hProcess) {
          BOOST_LOG(warning) << "vdisplay installer launch failed";
          return;
        }
        WaitForSingleObject(sei.hProcess, INFINITE);
        DWORD code = 0;
        GetExitCodeProcess(sei.hProcess, &code);
        CloseHandle(sei.hProcess);
        if (code != 0) {
          BOOST_LOG(warning)
              << "vdisplay installer exited with code " << code;
          return;
        }
        bool ok = WinVirtualDisplayManager::instance()
                      .probe_driver_installed(std::chrono::seconds(30));
        if (ok) {
          config::sunshine.prompt_vdisplay_install_done = true;
          // Persist config — call Sunshine's existing config-save fn.
          // Resolve at impl time by grepping for an existing config
          // save call (e.g., config::save(), config::write_to_file()).
        } else {
          BOOST_LOG(warning)
              << "vdisplay driver installed but device did not "
                 "materialize within 30 s; reboot may be required";
        }
        break;
      }
      case IDNO:
        config::sunshine.prompt_vdisplay_install_done = true;
        // Persist config (same call as above).
        break;
      case IDCANCEL:
        // "Remind me later" — leave flag false, re-prompt next launch.
        break;
    }
  }

}  // namespace platf::windows::vd_install_prompt
```

- [ ] **Step 4: Wire into `main.cpp`**

```cpp
#ifdef _WIN32
  #include "platform/windows/vd_install_prompt.h"
#endif

// ...inside main(), after config load, before main loop:
#ifdef _WIN32
  platf::windows::vd_install_prompt::maybe_show();
#endif
```

- [ ] **Step 5: Build**

```powershell
cmake --build build --target sunshine
```

- [ ] **Step 6: Manual e2e — prompt happy path**

Uninstall driver (Task 5 step 6). Reset config: edit `%APPDATA%\Sunshine\sunshine.conf` and remove `prompt_vdisplay_install_done` line if present. Run Sunshine. Expect: modal appears. Click Yes → UAC fires → installer runs → after ~30s the modal closes silently. Restart Sunshine. Expect: NO modal (flag persisted).

- [ ] **Step 7: Manual e2e — Skip path**

Reset config flag again. Uninstall driver again. Run Sunshine. Click No on modal. Expect: Sunshine continues, logs say mirror mode. Restart Sunshine. Expect: NO modal (flag persisted).

- [ ] **Step 8: Manual e2e — Cancel/Remind path**

Reset flag. Uninstall driver. Run Sunshine. Click Cancel. Restart Sunshine. Expect: modal re-appears.

- [ ] **Step 9: Commit**

```powershell
git add upstream\host\src\platform\windows\vd_install_prompt.h `
        upstream\host\src\platform\windows\vd_install_prompt.cpp `
        upstream\host\src\main.cpp `
        upstream\host\src\config.h upstream\host\src\config.cpp
git commit -m "host(win): first-launch install prompt for vdisplay driver"
```

---

## Task 12: Bundle vdisplay-driver-setup.exe in Sunshine packaging

**Goal:** Sunshine's existing Win installer (NSIS or WiX — confirm at Task 1) ships `vdisplay-driver-setup.exe` alongside the Sunshine binary so `vd_install_prompt::installer_path()` resolves.

**Files:**
- Modify: `upstream/host/cmake/targets/windows.cmake` (post-build copy)
- Modify: `upstream/host/<existing Win packaging file>` (include the file in the MSI/NSIS payload)

- [ ] **Step 1: Locate Sunshine's Win packaging file**

```powershell
ls upstream\host\src_assets\windows\
ls upstream\host\packaging\windows\
grep -rln "OutFile\|MSIComponent\|wix" upstream\host\src_assets upstream\host\packaging | Select-Object -First 5
```

Find the NSIS / WiX / inno script. Record path.

- [ ] **Step 2: Add `File` directive (NSIS) or component (WiX) for the driver setup**

Example NSIS line:

```nsis
File "/oname=driver\vdisplay-driver-setup.exe" "${CMAKE_BINARY_DIR}\..\..\installers\windows\vdisplay-driver-setup\vdisplay-driver-setup.exe"
```

- [ ] **Step 3: Add CMake post-build copy (defense in depth — supports running from build tree)**

In `upstream/host/cmake/targets/windows.cmake` after the sunshine target:

```cmake
add_custom_command(TARGET sunshine POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    ${CMAKE_SOURCE_DIR}/../installers/windows/vdisplay-driver-setup/vdisplay-driver-setup.exe
    $<TARGET_FILE_DIR:sunshine>/driver/vdisplay-driver-setup.exe
  COMMENT "Copying vdisplay-driver-setup.exe alongside sunshine"
)
```

(Match the path-resolution convention used by Phase 4's macOS POST_BUILD copy of `vd_helper`.)

- [ ] **Step 4: Build the full Sunshine installer**

```powershell
cmake --build build --target package
```

(Or whatever target Sunshine uses — `cpack`, `nsis`, etc.)

- [ ] **Step 5: Verify payload**

7-Zip → open the produced `Sunshine-*.exe` or `.msi` → confirm `driver\vdisplay-driver-setup.exe` is inside.

- [ ] **Step 6: Commit**

```powershell
git add upstream\host\cmake\targets\windows.cmake `
        upstream\host\<packaging-file>
git commit -m "build(win): bundle vdisplay-driver-setup.exe in Sunshine installer"
```

---

## Task 13: Manual e2e on Yoga — full spec test plan

**Goal:** Run the 7-step manual e2e from `phase5a-win-vdisplay-port-design.md` Testing § exactly, on Yoga, with the bundled installer.

**No code changes** — capture results.

- [ ] **Step 1: Fresh install dry-run**

Uninstall any prior vdisplay driver via Control Panel. Uninstall any prior Sunshine. Run the freshly-built Sunshine installer from Task 12. Verify:
  - Sunshine binary at expected install path
  - `vdisplay-driver-setup.exe` at `<install path>\driver\`

- [ ] **Step 2: First-launch prompt → Install**

Run Sunshine. Expect modal. Click Install → UAC → installer runs → modal closes. Verify Device Manager shows `vdisplay-host`.

- [ ] **Step 3: Stream extend mode**

Pair Moonlight Android with Sunshine. Connect. Expect: phone shows VIRTUAL display (extended desktop), not the laptop's main screen. Drag a window past the laptop's right screen edge → it appears on phone.

- [ ] **Step 4: Mirror fallback (driver disabled)**

Open Device Manager → Display adapters → right-click `vdisplay-host` → Disable. Disconnect + reconnect Moonlight. Expect: phone shows MAIN display. Sunshine log shows fallback. No retry storm.

- [ ] **Step 5: Mid-session loss**

Re-enable vdisplay-host driver. Reconnect (now back to virtual). With stream live: Disable driver via Device Manager. Expect: stream continues, switches to main, no Moonlight disconnect. Confirm stream stays alive 5+ s after switch.

- [ ] **Step 6: Reinstall path**

Uninstall driver via Control Panel. Restart Sunshine. Expect: prompt re-appears (because flag was set true on prior install but driver is now genuinely gone — verify the spec's "do not re-prompt on user-uninstall" decision; if behavior diverges, file an Open Question for v1.5).

- [ ] **Step 7: Skip-then-restart**

Uninstall driver. Reset config flag (edit `sunshine.conf`). Run Sunshine. Click Skip on modal. Restart Sunshine. Expect: NO modal (flag persisted true).

- [ ] **Step 8: Document outcomes**

For each step, record PASS / FAIL / NOTE in plan-task TaskUpdate description. Any FAIL → file follow-up task.

- [ ] **Step 9: Commit (test artifacts only)**

If you took screenshots, store under `docs/superpowers/artifacts/2026-05-06-phase5a-e2e/`. Commit:

```powershell
git add docs\superpowers\artifacts\2026-05-06-phase5a-e2e\
git commit -m "test(phase5a): manual e2e results — Yoga Win 11 24H2"
```

---

## Task 14: PR + cleanup

**Goal:** Open Phase 5A PR against jokot/vdisplay main. Sync memory.

- [ ] **Step 1: Push the branch**

```powershell
git push -u origin feat/phase5a-win-vdisplay
```

- [ ] **Step 2: Open PR**

```powershell
gh pr create --base main --head feat/phase5a-win-vdisplay `
  --title "Phase 5A: Windows virtual display port" `
  --body-file <PR body file>
```

PR body template:

```markdown
## Summary

Phase 5A ports Phase 4's macOS virtual extended display capability
to Windows. Bundles a vendored release of itsmikethetech/Virtual-
Display-Driver (MIT, signed) inside `vdisplay-driver-setup.exe`.
Sunshine prompts the user to install on first launch. Discovery via
Win DisplayConfig API matching friendly name `vdisplay-host`,
mirroring Phase 4's NSScreen pattern.

## What's in this PR

- `installers/windows/vdisplay-driver-setup/` — vendored VDD release
  + NSIS installer + pre-configured options.txt
- `WinVirtualDisplayManager` — singleton (DisplayConfig-API discovery,
  no spawn/teardown — driver is OS-managed)
- `display_base.cpp` — probe-and-adopt patch with mirror fallback
- `display_names()` — injection of virtual display in Sunshine's
  display list
- First-launch install prompt with persistent `prompt_vdisplay_install_done`
  config flag
- Sunshine Win packaging — bundles `vdisplay-driver-setup.exe`

## Test plan

- [x] Yoga: install → prompt → driver materializes → stream extend
- [x] Mirror fallback when driver disabled
- [x] Mid-session driver disable → fallback without disconnect
- [x] Skip path persists, Cancel re-prompts
- [ ] CI: Win runner builds Sunshine + installer artifact

## Known limitations (deferred to v1.5)

- 1920×1080@60 hardcoded; not driven by Moonlight's negotiated res
- Position right-of-primary hardcoded
- No tray UI for one-click virtual-display toggle
- HDR / multiple virtual displays out of scope
```

- [ ] **Step 3: Update memory after merge**

Once merged: add `phase5a_outcome.md` summarizing what shipped + open Win-side limitations, paralleling `phase4_path_a_outcome.md`.

- [ ] **Step 4: Worktree cleanup**

After merge:

```powershell
git checkout main
git pull origin main
git branch -d feat/phase5a-win-vdisplay
git push origin --delete feat/phase5a-win-vdisplay
```

---

## Self-Review

**Spec coverage:**
- Architecture three-layer split → Tasks 2-4 (installer), Task 6 (Sunshine manager), Task 9 (display_base patch). ✓
- Discovery contract `vdisplay-host` → Task 7 (`get_display_id()` matches `kVdisplayHostName = L"vdisplay-host"`). ✓
- First-launch prompt + Install/Skip/Remind buttons → Task 11. ✓
- Persistent install model (no spawn/teardown) → Task 6 explicitly omits spawn methods. ✓
- Mirror fallback → Tasks 9, 13 step 4. ✓
- Probe-before-adopt → Tasks 9, 10. ✓
- Open Question "re-prompt-after-uninstall" → flagged again in Task 13 step 6. ✓
- Compat matrix Win 11 24H2 primary → Task 1, Task 5, Task 13 all run on Yoga = 24H2. ✓
- Out-of-scope items (HDR, multiple displays) → not implemented; PR body lists them. ✓

**Placeholder scan:**
- Task 4 step 2 has `<inf-name>` — flagged as "resolve before committing", acceptable.
- Task 9 step 3 has "Adopt 'match'" comment for the Sunshine assignment — flagged as "resolve by reading existing init() body", acceptable; cannot pin without seeing Sunshine's actual variable name on Yoga.
- Task 11 step 3 has comment `Persist config — call Sunshine's existing config-save fn` — acceptable; Sunshine's config-save API name varies by version.
- Task 12 step 1 has `<existing-packaging-file>` — flagged for discovery at Step 1.

These are explicitly impl-time discovery items, NOT vague-handwave placeholders. Acceptable.

**Type consistency:**
- `WinVirtualDisplayManager` consistent across Tasks 6, 7, 8, 11. ✓
- `VirtualDisplayInfo` struct fields (`adapter`, `target_id`, `device_name`) consistent across declaration (Task 6) + use sites (Tasks 7, 9, 10). ✓
- `kVdisplayHostName` constant used in Task 7 lookup; matches the EDID name set in Task 3 config. ✓
- `prompt_vdisplay_install_done` config flag spelled identically in Tasks 11 step 1, step 3, step 6. ✓

No issues found.
