#Requires -RunAsAdministrator
param(
    [string]$DriverDir  = "$PSScriptRoot\vendored",
    [string]$OptionsSrc = "$PSScriptRoot\options.xml",
    [string]$EdidSrc    = "$PSScriptRoot\user_edid.bin"
)

$ErrorActionPreference = "Stop"

# --- 1. Locate INF ---
$inf = Get-ChildItem -Path $DriverDir -Recurse -Filter "MttVDD.inf" -ErrorAction Stop |
       Select-Object -First 1
if (-not $inf) {
    Write-Error "MttVDD.inf not found under $DriverDir"
    exit 1
}

# --- 2. Install driver via pnputil ---
# Resolve full path: Sysnative alias lets a 32-bit host reach real System32.
$pnputil = "$env:SystemRoot\System32\pnputil.exe"
if (-not (Test-Path $pnputil)) {
    $pnputil = "$env:SystemRoot\Sysnative\pnputil.exe"
}
Write-Host "Installing VDD driver: $($inf.FullName)"
$pnpOut = & $pnputil /add-driver $inf.FullName /install 2>&1
$pnpOut | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Error "pnputil exited $LASTEXITCODE"
    exit $LASTEXITCODE
}

# Persist published OEM inf name for the uninstaller
$oemMatch = $pnpOut | Where-Object { $_ -match "Published Name\s*:\s*(oem\d+\.inf)" } |
            Select-Object -First 1
if ($oemMatch -match "(oem\d+\.inf)") {
    $oemName = $Matches[1]
    $regPath = "HKLM:\SOFTWARE\vdisplay"
    if (-not (Test-Path $regPath)) { New-Item $regPath -Force | Out-Null }
    Set-ItemProperty -Path $regPath -Name "VddOemInf" -Value $oemName -Force
    Write-Host "OEM inf saved for uninstall: $oemName"
}

# --- 2b. Instantiate root-enumerated device via SetupAPI ---
# pnputil /add-driver only installs onto existing matching devices.
# pnputil /add-device is not available on all Windows versions.
# Use SetupAPI DIF_REGISTERDEVICE to create the Root\MttVDD node; PnP then
# auto-matches and installs the driver already in the store.
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class DevNodeCreator {
    private const uint DICD_GENERATE_ID       = 0x00000001u;
    private const uint DIF_INSTALLDEVICE      = 0x00000002u;
    private const uint DIF_SELECTBESTCOMPATDRV = 0x00000017u;
    private const uint DIF_REGISTERDEVICE     = 0x00000019u;
    private const uint SPDRP_HARDWAREID       = 0x00000001u;
    private const uint SPDIT_COMPATDRIVER     = 0x00000002u;

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA {
        public uint   cbSize;
        public Guid   ClassGuid;
        public uint   DevInst;
        public IntPtr Reserved;
    }

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiCreateDeviceInfoList(
        ref Guid ClassGuid, IntPtr hwnd);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiCreateDeviceInfoW(
        IntPtr DevInfoSet, string DeviceName, ref Guid ClassGuid,
        string Description, IntPtr hwnd, uint Flags,
        ref SP_DEVINFO_DATA DevInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiOpenDeviceInfoW(
        IntPtr DevInfoSet, string DeviceInstanceId, IntPtr hwnd,
        uint OpenFlags, ref SP_DEVINFO_DATA DevInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiSetDeviceRegistryPropertyW(
        IntPtr DevInfoSet, ref SP_DEVINFO_DATA DevInfoData,
        uint Property, byte[] Buffer, uint BufferSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiBuildDriverInfoList(
        IntPtr DevInfoSet, ref SP_DEVINFO_DATA DevInfoData, uint DriverType);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiSelectBestCompatDrv(
        IntPtr DevInfoSet, ref SP_DEVINFO_DATA DevInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiCallClassInstaller(
        uint DifCode, IntPtr DevInfoSet, ref SP_DEVINFO_DATA DevInfoData);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr DevInfoSet);

    private static readonly Guid DisplayGuid =
        new Guid("{4D36E968-E325-11CE-BFC1-08002BE10318}");

    private static void InstallDriver(IntPtr set, ref SP_DEVINFO_DATA dd) {
        // Build compatible driver list from the driver store, select best, install.
        if (!SetupDiBuildDriverInfoList(set, ref dd, SPDIT_COMPATDRIVER)) {
            int e = Marshal.GetLastWin32Error();
            throw new Exception("SetupDiBuildDriverInfoList Win32=" + e +
                " (0x" + e.ToString("X8") + "): " + new Win32Exception(e).Message);
        }
        if (!SetupDiSelectBestCompatDrv(set, ref dd)) {
            int e = Marshal.GetLastWin32Error();
            throw new Exception("SetupDiSelectBestCompatDrv Win32=" + e +
                " (0x" + e.ToString("X8") + "): " + new Win32Exception(e).Message);
        }
        if (!SetupDiCallClassInstaller(DIF_INSTALLDEVICE, set, ref dd)) {
            int e = Marshal.GetLastWin32Error();
            if ((uint)e != 0xE0000230u)
                throw new Exception("SetupDiCallClassInstaller(INSTALLDEVICE) Win32=" + e +
                    " (0x" + e.ToString("X8") + "): " + new Win32Exception(e).Message);
        }
    }

    // Returns true = created new node, false = already existed.
    // In both cases, attempts to install the driver from the store.
    // DeviceName for DICD_GENERATE_ID on local machine must omit "Root\";
    // Windows generates the instance ID as ROOT\<name>\0000.
    public static bool EnsureRootDevice() {
        Guid g = DisplayGuid;
        IntPtr set = SetupDiCreateDeviceInfoList(ref g, IntPtr.Zero);
        if (set == new IntPtr(-1)) {
            int e = Marshal.GetLastWin32Error();
            throw new Exception("SetupDiCreateDeviceInfoList Win32=" + e +
                " (0x" + e.ToString("X8") + "): " + new Win32Exception(e).Message);
        }
        try {
            var dd = new SP_DEVINFO_DATA();
            dd.cbSize = (uint)Marshal.SizeOf(dd);
            bool created;

            if (!SetupDiCreateDeviceInfoW(set, "MttVDD", ref g,
                    "Virtual Display Driver", IntPtr.Zero,
                    DICD_GENERATE_ID, ref dd)) {
                int e = Marshal.GetLastWin32Error();
                if (e != 0xB7) // not ERROR_ALREADY_EXISTS
                    throw new Exception("SetupDiCreateDeviceInfo Win32=" + e +
                        " (0x" + e.ToString("X8") + "): " + new Win32Exception(e).Message);
                // Device already exists -- open it so we can install the driver.
                created = false;
                dd = new SP_DEVINFO_DATA();
                dd.cbSize = (uint)Marshal.SizeOf(dd);
                if (!SetupDiOpenDeviceInfoW(set, "ROOT\\MTTVDD\\0000",
                        IntPtr.Zero, 0, ref dd)) {
                    int e2 = Marshal.GetLastWin32Error();
                    throw new Exception("SetupDiOpenDeviceInfo Win32=" + e2 +
                        " (0x" + e2.ToString("X8") + "): " + new Win32Exception(e2).Message);
                }
            } else {
                created = true;
                // Hardware ID stored as REG_MULTI_SZ (double-null-terminated Unicode)
                byte[] hwId = Encoding.Unicode.GetBytes("Root\\MttVDD\0\0");
                if (!SetupDiSetDeviceRegistryPropertyW(set, ref dd,
                        SPDRP_HARDWAREID, hwId, (uint)hwId.Length)) {
                    int e = Marshal.GetLastWin32Error();
                    throw new Exception("SetupDiSetDeviceRegistryProperty Win32=" + e +
                        " (0x" + e.ToString("X8") + "): " + new Win32Exception(e).Message);
                }
                if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, ref dd)) {
                    int e = Marshal.GetLastWin32Error();
                    if ((uint)e != 0xE0000230u)
                        throw new Exception("SetupDiCallClassInstaller(REGISTERDEVICE) Win32=" + e +
                            " (0x" + e.ToString("X8") + "): " + new Win32Exception(e).Message);
                }
            }

            // Install driver from store onto the device (new or existing).
            InstallDriver(set, ref dd);
            return created;
        }
        finally {
            SetupDiDestroyDeviceInfoList(set);
        }
    }
}
'@

Write-Host "Ensuring Root\MttVDD device node exists..."
try {
    if ([DevNodeCreator]::EnsureRootDevice()) {
        Write-Host "Device node Root\MttVDD created - triggering PnP scan..."
        & $pnputil /scan-devices 2>&1 | Out-Null
    }
    else {
        Write-Host "Device node Root\MttVDD already exists."
    }
}
catch {
    Write-Warning "Device node creation failed: $_"
}

# --- 3. Deploy config files ---
$configDir = Join-Path $env:ProgramData "MttVDD"
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
Copy-Item -Force $OptionsSrc (Join-Path $configDir "vdd_settings.xml")
Copy-Item -Force $EdidSrc    (Join-Path $configDir "user_edid.bin")
Write-Host "Config deployed to $configDir"

# --- 4. Position virtual monitor right of primary (best-effort) ---
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WinDisplayUtil {
    public const int  ENUM_CURRENT_SETTINGS  = -1;
    public const uint DM_POSITION            = 0x00000020u;
    public const uint CDS_UPDATEREGISTRY     = 0x00000001u;
    public const uint CDS_NORESET            = 0x10000000u;
    public const uint DISPLAY_DEVICE_ACTIVE  = 0x00000001u;
    public const uint DISPLAY_DEVICE_PRIMARY = 0x00000004u;

    // DEVMODE for display - sequential layout matches DEVMODEA field order.
    // LayoutKind.Explicit cannot be used with managed string fields (CLR restriction),
    // so we use Sequential with fields declared in the exact DEVMODEA order.
    // With CharSet.Ansi, ByValTStr fields are 1-byte-aligned char arrays; the
    // resulting offsets are identical to the C struct layout.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;      // offset   0 (32 bytes)
        public ushort SpecVersion;     // offset  32
        public ushort DriverVersion;   // offset  34
        public ushort Size;            // offset  36
        public ushort DriverExtra;     // offset  38
        public uint   Fields;          // offset  40
        public int    PosX;            // offset  44  dmPosition.x
        public int    PosY;            // offset  48  dmPosition.y
        public uint   DisplayOrientation;  // offset 52
        public uint   DisplayFixedOutput;  // offset 56
        public short  Color;           // offset  60
        public short  Duplex;          // offset  62
        public short  YResolution;     // offset  64
        public short  TTOption;        // offset  66
        public short  Collate;         // offset  68
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FormName;        // offset  70 (32 bytes)
        public ushort LogPixels;       // offset 102
        public uint   BitsPerPel;      // offset 104
        public uint   PelsWidth;       // offset 108
        public uint   PelsHeight;      // offset 112
        public uint   DisplayFlags;    // offset 116
        public uint   DisplayFrequency; // offset 120
        public uint   ICMMethod;       // offset 124
        public uint   ICMIntent;       // offset 128
        public uint   MediaType;       // offset 132
        public uint   DitherType;      // offset 136
        public uint   Reserved1;       // offset 140
        public uint   Reserved2;       // offset 144
        public uint   PanningWidth;    // offset 148
        public uint   PanningHeight;   // offset 152
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Ansi)]
    public struct DISPLAY_DEVICE {
        public uint cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplayDevicesA(
        string lpDevice, uint iDevNum,
        ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern bool EnumDisplaySettingsA(
        string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode);

    [DllImport("user32.dll", CharSet = CharSet.Ansi)]
    public static extern int ChangeDisplaySettingsExA(
        string lpszDeviceName, ref DEVMODE lpDevMode,
        IntPtr hwnd, uint dwflags, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "ChangeDisplaySettingsExA")]
    public static extern int ChangeDisplaySettingsExApply(
        IntPtr device, IntPtr mode, IntPtr hwnd, uint flags, IntPtr param);
}
'@

function New-DisplayDevice {
    $d = New-Object WinDisplayUtil+DISPLAY_DEVICE
    $d.cb = [uint32][Runtime.InteropServices.Marshal]::SizeOf($d)
    $d
}

function New-Devmode {
    $dm = New-Object WinDisplayUtil+DEVMODE
    $dm.Size = [ushort][Runtime.InteropServices.Marshal]::SizeOf($dm)
    $dm
}

function Wait-VirtualAdapter([int]$TimeoutSec = 30) {
    $deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
    while ([DateTime]::Now -lt $deadline) {
        $dev = New-DisplayDevice
        $i = [uint32]0
        while ([WinDisplayUtil]::EnumDisplayDevicesA($null, $i, [ref]$dev, 0)) {
            if ($dev.DeviceString -match "MttVDD|Virtual Display") {
                return $dev.DeviceName
            }
            $dev = New-DisplayDevice
            $i++
        }
        Start-Sleep -Seconds 2
    }
    return $null
}

try {
    Write-Host "Waiting for virtual display adapter (up to 30 s)..."
    $vAdapter = Wait-VirtualAdapter -TimeoutSec 30

    if (-not $vAdapter) {
        Write-Warning "Virtual adapter not detected - skipping position step. Set it manually in Display Settings."
    }
    else {
        Write-Host "Virtual adapter: $vAdapter"

        # Find primary display width
        $primaryWidth = 0
        $dev = New-DisplayDevice
        $i = [uint32]0
        while ([WinDisplayUtil]::EnumDisplayDevicesA($null, $i, [ref]$dev, 0)) {
            if ($dev.StateFlags -band [WinDisplayUtil]::DISPLAY_DEVICE_PRIMARY) {
                $dm = New-Devmode
                if ([WinDisplayUtil]::EnumDisplaySettingsA(
                        $dev.DeviceName,
                        [WinDisplayUtil]::ENUM_CURRENT_SETTINGS,
                        [ref]$dm)) {
                    $primaryWidth = [int]$dm.PelsWidth
                }
                break
            }
            $dev = New-DisplayDevice
            $i++
        }

        # Position virtual adapter at (primaryWidth, 0)
        $vdm = New-Devmode
        [WinDisplayUtil]::EnumDisplaySettingsA(
            $vAdapter,
            [WinDisplayUtil]::ENUM_CURRENT_SETTINGS,
            [ref]$vdm) | Out-Null
        $vdm.PosX   = $primaryWidth
        $vdm.PosY   = 0
        $vdm.Fields = [WinDisplayUtil]::DM_POSITION
        $vdm.Size   = [ushort][Runtime.InteropServices.Marshal]::SizeOf($vdm)

        $r = [WinDisplayUtil]::ChangeDisplaySettingsExA(
                $vAdapter, [ref]$vdm, [IntPtr]::Zero,
                ([WinDisplayUtil]::CDS_UPDATEREGISTRY -bor [WinDisplayUtil]::CDS_NORESET),
                [IntPtr]::Zero)
        if ($r -ne 0) {
            Write-Warning "ChangeDisplaySettingsEx returned $r - position not applied."
        }
        else {
            [WinDisplayUtil]::ChangeDisplaySettingsExApply(
                [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero) | Out-Null
            Write-Host "Virtual monitor positioned at ($primaryWidth, 0)."
        }
    }
}
catch {
    Write-Warning "Position step skipped: $_"
}

Write-Host "vdisplay driver setup complete."
