; vdisplay-driver-setup.nsi
; Produces vdisplay-driver-setup.exe — standalone admin installer for the
; itsmikethetech Virtual Display Driver pre-configured for vdisplay-host.

!define APP_NAME    "vdisplay Virtual Display Driver"
!define APP_VER     "1.0.0"
!define VDD_VER     "25.7.23"
!define INST_KEY    "Software\Microsoft\Windows\CurrentVersion\Uninstall\vdisplay-driver"
Name            "${APP_NAME} ${APP_VER}"
OutFile         "vdisplay-driver-setup.exe"
InstallDir      "$PROGRAMFILES64\vdisplay\driver"
RequestExecutionLevel admin
SetCompressor   lzma

; ── Pages ─────────────────────────────────────────────────────────────────────
Page directory
Page instfiles

UninstPage uninstConfirm
UninstPage instfiles

; ── Install ───────────────────────────────────────────────────────────────────
Section "Install" SEC_INSTALL
    SetOutPath "$INSTDIR"

    ; Driver binaries (vendored release)
    SetOutPath "$INSTDIR\vendored\${VDD_VER}\VirtualDisplayDriver"
    File "vendored\${VDD_VER}\VirtualDisplayDriver\MttVDD.dll"
    File "vendored\${VDD_VER}\VirtualDisplayDriver\MttVDD.inf"
    File "vendored\${VDD_VER}\VirtualDisplayDriver\mttvdd.cat"

    ; vdisplay configuration
    SetOutPath "$INSTDIR"
    File "options.xml"
    File "user_edid.bin"
    File "install.ps1"
    File "LICENSE.MIT.txt"

    ; Run install.ps1 (already admin — NSIS RequestExecutionLevel admin)
    DetailPrint "Running install.ps1 ..."
    ; Use Sysnative to reach 64-bit PowerShell from 32-bit NSIS process.
    ; Without this, WOW64 redirects powershell.exe to SysWOW64 (32-bit),
    ; which cannot find pnputil.exe (64-bit only in real System32).
    nsExec::ExecToLog \
        '$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe \
         -NoProfile -ExecutionPolicy Bypass \
         -File "$INSTDIR\install.ps1" \
         -DriverDir "$INSTDIR\vendored" \
         -OptionsSrc "$INSTDIR\options.xml" \
         -EdidSrc "$INSTDIR\user_edid.bin"'
    Pop $0
    IntCmp $0 0 +3
        MessageBox MB_ICONSTOP "Driver install failed (exit code $0). Check the Details log."
        Abort

    ; Register uninstaller
    WriteUninstaller "$INSTDIR\uninstall.exe"
    WriteRegStr   HKLM "${INST_KEY}" "DisplayName"      "${APP_NAME}"
    WriteRegStr   HKLM "${INST_KEY}" "DisplayVersion"   "${APP_VER}"
    WriteRegStr   HKLM "${INST_KEY}" "Publisher"        "vdisplay"
    WriteRegStr   HKLM "${INST_KEY}" "UninstallString"  '"$INSTDIR\uninstall.exe"'
    WriteRegStr   HKLM "${INST_KEY}" "InstallLocation"  "$INSTDIR"
    WriteRegDWORD HKLM "${INST_KEY}" "NoModify"         1
    WriteRegDWORD HKLM "${INST_KEY}" "NoRepair"         1

    DetailPrint "Installation complete."
SectionEnd

; ── Uninstall ─────────────────────────────────────────────────────────────────
Section "Uninstall"
    ; Remove driver — read published OEM inf name saved during install
    DetailPrint "Removing VDD driver via pnputil ..."
    nsExec::ExecToLog \
        'powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
         "$$n = (Get-ItemProperty HKLM:\SOFTWARE\vdisplay -ErrorAction SilentlyContinue).VddOemInf; \
          if ($$n) { pnputil /delete-driver $$n /uninstall /force } \
          else { Write-Warning ''VddOemInf registry value not found -- driver may need manual removal.'' }"'
    Pop $0

    ; Clean up config directory — read ProgramData path from registry
    ReadRegStr $1 HKLM \
        "SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" \
        "Common AppData"
    RMDir /r "$1\MttVDD"

    ; Remove install tree
    RMDir /r "$INSTDIR"

    ; Remove registry entries
    DeleteRegKey HKLM "${INST_KEY}"
    DeleteRegKey /ifempty HKLM "SOFTWARE\vdisplay"

    DetailPrint "Uninstall complete."
SectionEnd
