#Requires -RunAsAdministrator
param(
    [string]$DriverDir  = "$PSScriptRoot\vendored",
    [string]$OptionsSrc = "$PSScriptRoot\options.xml",
    [string]$EdidSrc    = "$PSScriptRoot\user_edid.bin"
)

$ErrorActionPreference = "Stop"

# ── 1. Locate INF ─────────────────────────────────────────────────────────────
$inf = Get-ChildItem -Path $DriverDir -Recurse -Filter "MttVDD.inf" -ErrorAction Stop |
       Select-Object -First 1
if (-not $inf) {
    Write-Error "MttVDD.inf not found under $DriverDir"
    exit 1
}

# ── 2. Install driver via pnputil ─────────────────────────────────────────────
Write-Host "Installing VDD driver: $($inf.FullName)"
$pnpOut = & pnputil.exe /add-driver $inf.FullName /install 2>&1
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

# ── 3. Deploy config files ─────────────────────────────────────────────────────
$configDir = Join-Path $env:ProgramData "MttVDD"
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
Copy-Item -Force $OptionsSrc (Join-Path $configDir "vdd_settings.xml")
Copy-Item -Force $EdidSrc    (Join-Path $configDir "user_edid.bin")
Write-Host "Config deployed → $configDir"

# ── 4. Position virtual monitor right of primary (best-effort) ────────────────
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

    // DEVMODE for display — explicit field offsets match DEVMODEA layout
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Ansi)]
    public struct DEVMODE {
        [FieldOffset(0),   MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        [FieldOffset(32)]  public ushort SpecVersion;
        [FieldOffset(34)]  public ushort DriverVersion;
        [FieldOffset(36)]  public ushort Size;
        [FieldOffset(38)]  public ushort DriverExtra;
        [FieldOffset(40)]  public uint   Fields;
        [FieldOffset(44)]  public int    PosX;        // dmPosition.x
        [FieldOffset(48)]  public int    PosY;        // dmPosition.y
        [FieldOffset(52)]  public uint   DisplayOrientation;
        [FieldOffset(56)]  public uint   DisplayFixedOutput;
        [FieldOffset(60)]  public short  Color;
        [FieldOffset(62)]  public short  Duplex;
        [FieldOffset(64)]  public short  YResolution;
        [FieldOffset(66)]  public short  TTOption;
        [FieldOffset(68)]  public short  Collate;
        [FieldOffset(70),  MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string FormName;
        [FieldOffset(102)] public ushort LogPixels;
        [FieldOffset(104)] public uint   BitsPerPel;
        [FieldOffset(108)] public uint   PelsWidth;
        [FieldOffset(112)] public uint   PelsHeight;
        [FieldOffset(116)] public uint   DisplayFlags;
        [FieldOffset(120)] public uint   DisplayFrequency;
        [FieldOffset(124)] public uint   ICMMethod;
        [FieldOffset(128)] public uint   ICMIntent;
        [FieldOffset(132)] public uint   MediaType;
        [FieldOffset(136)] public uint   DitherType;
        [FieldOffset(140)] public uint   Reserved1;
        [FieldOffset(144)] public uint   Reserved2;
        [FieldOffset(148)] public uint   PanningWidth;
        [FieldOffset(152)] public uint   PanningHeight;
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

    // Overload for the final "apply all" call (both pointer args null)
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
        $dev = New-DisplayDevice; $i = [uint32]0
        while ([WinDisplayUtil]::EnumDisplayDevicesA($null, $i, [ref]$dev, 0)) {
            if ($dev.DeviceString -match "MttVDD|Virtual Display") {
                return $dev.DeviceName
            }
            $dev = New-DisplayDevice; $i++
        }
        Start-Sleep -Seconds 2
    }
    return $null
}

try {
    Write-Host "Waiting for virtual display adapter (up to 30 s)..."
    $vAdapter = Wait-VirtualAdapter -TimeoutSec 30

    if (-not $vAdapter) {
        Write-Warning "Virtual adapter not detected — skipping position step. Set it manually in Display Settings."
    } else {
        Write-Host "Virtual adapter: $vAdapter"

        # Find primary display width
        $primaryWidth = 0
        $dev = New-DisplayDevice; $i = [uint32]0
        while ([WinDisplayUtil]::EnumDisplayDevicesA($null, $i, [ref]$dev, 0)) {
            if ($dev.StateFlags -band [WinDisplayUtil]::DISPLAY_DEVICE_PRIMARY) {
                $dm = New-Devmode
                if ([WinDisplayUtil]::EnumDisplaySettingsA($dev.DeviceName,
                        [WinDisplayUtil]::ENUM_CURRENT_SETTINGS, [ref]$dm)) {
                    $primaryWidth = [int]$dm.PelsWidth
                }
                break
            }
            $dev = New-DisplayDevice; $i++
        }

        # Position virtual adapter at (primaryWidth, 0)
        $vdm = New-Devmode
        [WinDisplayUtil]::EnumDisplaySettingsA($vAdapter,
            [WinDisplayUtil]::ENUM_CURRENT_SETTINGS, [ref]$vdm) | Out-Null
        $vdm.PosX   = $primaryWidth
        $vdm.PosY   = 0
        $vdm.Fields = [WinDisplayUtil]::DM_POSITION
        $vdm.Size   = [ushort][Runtime.InteropServices.Marshal]::SizeOf($vdm)

        $r = [WinDisplayUtil]::ChangeDisplaySettingsExA(
                $vAdapter, [ref]$vdm, [IntPtr]::Zero,
                ([WinDisplayUtil]::CDS_UPDATEREGISTRY -bor [WinDisplayUtil]::CDS_NORESET),
                [IntPtr]::Zero)
        if ($r -ne 0) {
            Write-Warning "ChangeDisplaySettingsEx returned $r — position not applied."
        } else {
            [WinDisplayUtil]::ChangeDisplaySettingsExApply(
                [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero) | Out-Null
            Write-Host "Virtual monitor positioned at ($primaryWidth, 0)."
        }
    }
} catch {
    Write-Warning "Position step skipped: $_"
}

Write-Host "vdisplay driver setup complete."
