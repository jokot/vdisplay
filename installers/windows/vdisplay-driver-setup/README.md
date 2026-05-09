# vdisplay Windows Driver Setup

This directory ships a pre-configured release of
[itsmikethetech/Virtual-Display-Driver](https://github.com/itsmikethetech/Virtual-Display-Driver)
under MIT license. We do NOT modify the driver source. We add only:

- `options.xml` — vdisplay-specific monitor config (1 monitor, 1920×1080@60,
  friendly name set via custom EDID to `vdisplay-host`).
- `install.ps1` — wraps `pnputil /add-driver` for unattended install.
- `vdisplay-driver-setup.nsi` — NSIS script producing the standalone installer artifact.

## Pinned version

- Upstream tag: **25.7.23**
- Upstream release: "Beta: Virtual Driver Control (25.7.23)" (`prerelease=false`)
- Asset vendored: `VirtualDisplayDriver-x86.Driver.Only.zip` (AMD64)
- Vendored on: **2026-05-09**

## Driver files (vendored/25.7.23/VirtualDisplayDriver/)

| File | Purpose |
|------|---------|
| `MttVDD.dll` | UMDF IDDCX user-mode display driver binary |
| `MttVDD.inf` | Driver installation manifest |
| `mttvdd.cat` | Signed security catalog (Microsoft WHQL) |
| `vdd_settings.xml` | Driver configuration — monitor count, resolutions, refresh rates |

## Monitor name (`vdisplay-host`) — configuration notes

The `vdd_settings.xml` schema does not expose a `<friendlyname>` field.
The monitor friendly name shown in Windows Display Settings is determined by
the EDID descriptor embedded in the driver. Options:

1. **Custom EDID binary** — set `<CustomEdid>true</CustomEdid>` in
   `vdd_settings.xml` and provide `user_edid.bin` with Monitor Name
   Descriptor (tag `0xFC`) set to `vdisplay-host`. Investigated in Task 3.
2. **Sunshine discovery fallback** — if custom EDID cannot be made to work,
   `WinVirtualDisplayManager::get_display_id()` can also match by device
   instance path prefix (`Root\MttVDD`) as a secondary strategy, with a
   warning that the user should not rename the driver device.

## Upgrade procedure

1. Pick a newer upstream release tag from
   https://github.com/itsmikethetech/Virtual-Display-Driver/releases
2. Download `VirtualDisplayDriver-x86.Driver.Only.zip` for the new tag.
3. Extract into `vendored/<new-tag>/VirtualDisplayDriver/`.
4. Diff `vdd_settings.xml` schema against the new release — field names change.
5. Smoke test on Yoga via Task 5.
6. Bump the pinned version in this README and ship a new vdisplay release.

## Attribution

The IDDCX driver is © Virtual Display contributors, MIT license —
see `LICENSE.MIT.txt`. vdisplay distributes it unmodified per MIT terms;
the configuration and installer wrapper are vdisplay's own under GPL-3.
