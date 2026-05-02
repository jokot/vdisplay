# vdisplay

Cross-platform virtual external display, low-latency, free and open source.

Mirror or extend your Windows / macOS desktop to another Windows / macOS device or Android phone over your local network. One unified app that works as both **host** and **client**.

> Status: pre-alpha. Forking [Sunshine](https://github.com/LizardByte/Sunshine) (host) and [Moonlight](https://github.com/moonlight-stream) (clients) as base. Phase 0 (validation) complete; Phase 1 (fork bring-up) in progress.

## Goals

- **Cross-platform**: Windows + macOS as host AND client. Android as client. iOS client phase 2 (optional).
- **Modes**: mirror + extend (virtual display extension) — both required.
- **Latency**: productivity-grade (<200ms glass-to-glass typical), competitive with spacedesk.
- **License**: GPL-3 (forced by upstream forks).

## v1 host → client matrix

| Host | Client | Status | G2G (typical) |
|------|--------|--------|---------------|
| macOS (M-series) | Windows | validated | ~100 ms |
| macOS (M-series) | Android | validated | ~150 ms |
| Windows | macOS | validated | ~60 ms |
| Windows | Android | validated | ~90 ms |

Same-OS pairs (Mac↔Mac, Win↔Win) deferred to v2 — already covered by Sidecar / AirPlay / Windows RDP.

## Repository layout

```
vdisplay/
├── upstream/
│   ├── host/              ← Sunshine fork (git subtree)
│   ├── client-desktop/    ← moonlight-qt fork (git subtree)
│   └── client-android/    ← moonlight-android fork (git subtree)
├── launcher/              ← unified Qt launcher (host + client UI in one app) — TBD
├── tools/
│   └── g2g-timer.html     ← glass-to-glass latency timer for slow-mo camera tests
├── LICENSE                ← GPL-3
└── README.md
```

Upstream code lives under `upstream/` as git subtrees. Pull upstream fixes via:

```bash
git subtree pull --prefix=upstream/host           sunshine-upstream         master --squash
git subtree pull --prefix=upstream/client-desktop moonlight-qt-upstream     master --squash
git subtree pull --prefix=upstream/client-android moonlight-android-upstream master --squash
```

(Remotes assumed: `sunshine-upstream`, `moonlight-qt-upstream`, `moonlight-android-upstream` pointing at the LizardByte / moonlight-stream repos.)

## Build (work in progress)

Each upstream still builds with its native toolchain. Submodules are not auto-populated by `subtree`; init them inside each subtree before building:

```bash
# Host (Sunshine)
cd upstream/host && git submodule update --init --recursive
cmake -B build && cmake --build build

# Desktop client (moonlight-qt)
cd upstream/client-desktop && git submodule update --init --recursive
qmake6 && make    # or open in Qt Creator

# Android client (moonlight-android)
cd upstream/client-android && git submodule update --init --recursive
./gradlew assembleDebug
```

The unified `launcher/` Qt app is not yet implemented.

## Architecture (planned)

- **Bundle approach**: single installer ships three binaries — `vdisplay-launcher` (Qt), forked `sunshine` (host engine), forked `moonlight-qt` (client engine).
- **Launcher**: tabbed UI — *Host this PC* embeds Sunshine config web UI via `QWebEngineView`; *Connect to PC* spawns the desktop client.
- **Android client**: standalone app, not part of the launcher.

## License

GPL-3.0 — see [`LICENSE`](./LICENSE). Inherited from Sunshine and Moonlight; all derivative work in this repository (including `launcher/`) is GPL-3 as a result.

## Acknowledgements

Built on top of:

- [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine)
- [moonlight-stream/moonlight-qt](https://github.com/moonlight-stream/moonlight-qt)
- [moonlight-stream/moonlight-android](https://github.com/moonlight-stream/moonlight-android)
