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

## Monitor name (`vdisplay-host`) — configuration

The `vdd_settings.xml` schema has no `<friendlyname>` field. The monitor
friendly name is set via a custom EDID binary:

- `options.xml` sets `<CustomEdid>true</CustomEdid>`
- `user_edid.bin` is a hand-crafted 128-byte EDID 1.4 block with:
  - Detailed Timing Descriptor for 1920×1080@60 (pixel clock 148.5 MHz)
  - Monitor Name Descriptor (tag `0xFC`) = `vdisplay-host` (13 chars)
  - Monitor Range Limits (24–75 Hz V, 15–83 kHz H, 150 MHz max clock)

`install.ps1` copies `options.xml` → `%ProgramData%\MttVDD\vdd_settings.xml`
and `user_edid.bin` → `%ProgramData%\MttVDD\user_edid.bin` at install time.

## Position (right of primary)

The driver creates the monitor; Windows assigns initial position arbitrarily.
`install.ps1` calls `Set-DisplayConfig` after install to place the virtual
monitor at `(primary_width, 0)` — i.e. immediately right of the primary.

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
