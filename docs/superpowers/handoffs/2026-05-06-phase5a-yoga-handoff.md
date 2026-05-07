# Phase 5A Yoga Handoff Prompt

Paste the block below verbatim into Claude Code on the Yoga laptop to start Phase 5A execution. Includes inlined memos so Yoga-Claude has all carry-over context (its memory dir is separate from the Mac one).

---

I'm starting Phase 5A — Windows virtual display port. Plan is committed at:

  docs/superpowers/plans/2026-05-06-phase5a-win-vdisplay-port.md

Spec is at:

  docs/superpowers/specs/2026-05-06-phase5a-win-vdisplay-port-design.md

Repo: https://github.com/jokot/vdisplay
Target branch: feat/phase5a-win-vdisplay (create at Task 1)

Context — Phase 4 (macOS side) shipped 2026-05-05 in commit 468486aa0
on main. Phase 5A mirrors that work for Windows. I'm running on Yoga
laptop with Win 11 24H2.

Use superpowers:subagent-driven-development to execute the plan
task-by-task. Start at Task 1 (Yoga env bootstrap + smoke-build
current Sunshine — closes long-pending Phase 1 #14 task too).

Stop after each task and ask me to verify Yoga-side outcomes before
moving to the next.

---

# Carry-over context from Mac session (memories I have on Mac, not Yoga)

## Memo 1: User dev hardware

Primary dev machine: MacBook Pro M3 (Apple Silicon), Built-in Retina
Display id 1. Acts as Mac host AND Mac client.

Primary Win device (v1 host + client target): **Yoga Slim 7 14IMH9
with Intel Arc Graphics** (Lunar/Meteor Lake gen, has QuickSync
HEVC/H264/AV1 HW encode + decode). Productivity-realistic test target
— Intel iGPU ≈ 80% of Win laptop fleet in real world.

Secondary Win device (v2 / gaming test): Desktop PC with NVIDIA RTX
4060 (NVENC). Deferred for v1.

Android client: **Oppo Reno 14** (MediaTek SoC, c2.mtk.avc / c2.mtk.hevc
decoders, low-latency variants available).

Network: typically cafe WiFi (variable, may have client isolation),
phone hotspot 2.4 GHz / 5 GHz fallback.

When explaining Win code paths, default to DXGI Desktop Duplication +
QuickSync (the Intel Arc media engine).

## Memo 2: Phase 4 Path A outcome (Mac side, for reference)

Phase 4 macOS shipped in **Path A** form (manual standalone helper):

  # Terminal 1
  ./Sunshine.app/Contents/MacOS/vd_helper 1920 1080 60
  # Terminal 2
  ./Sunshine.app/Contents/MacOS/Sunshine

Sunshine `MacVirtualDisplayManager::get_display_id()` does live
`NSScreen` scan for `localizedName == "vdisplay-host"`. No config edit
— `output_name` stays empty. `display.mm` capability-probes
`CGDisplayCopyDisplayMode` before adopting; falls back to main display
if probe fails.

**Why Path A on Mac:** Sunshine-spawned vd_helper produces virtual
displays where `AVCaptureScreenInput` never delivers frames (encoder
probe creates h264_videotoolbox then hangs forever). Terminal-spawned
helper works. Tried setsid() in fork-child + 5s spawn delay — neither
fixed it. Mechanism: parent-process context affects AVCapture frame
delivery for private CGVirtualDisplay; root cause unknown.

**Discovery contract reused on Win:** match by friendly name
`"vdisplay-host"`. The Phase 5A spec preserves this contract — Win
uses DisplayConfig API (`DisplayConfigGetDeviceInfo` with
`DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME`) to look up the same
friendly name. Same fallback semantics.

Verified working 2026-05-05: macOS 26.4.1, Sunshine → Moonlight
Android, virtual display extends right of main, dragged windows render
on phone.

## Memo 3: Bootstrap submodule SHA-pinning gap

`scripts/bootstrap.sh` clones each submodule listed in `.gitmodules`
at HEAD of the declared branch (default `master`), **NOT at the SHA
pinned by the upstream tree at the time of subtree merge.** Subtree
squashes drop submodule SHA pinning, so HEAD is the only reference
left in `.gitmodules`.

When the submodule's HEAD has diverged from the SHA the parent
expects (e.g., directory renames, API breaks), the build fails despite
`bootstrap.sh` reporting success.

**Concrete instance, 2026-05-06 (Mac, moonlight-android subtree):**
moonlight-android subtree merge expected
`moonlight-common-c/reedsolomon/rs.c`. moonlight-common-c master had
since renamed `reedsolomon/` → `nanors/`. `ndk-build` failed with "no
rule to make target rs.c". Manual fix:

  cd <subtree-path>
  git fetch origin <pinned-sha>
  git checkout <pinned-sha>
  git submodule update --init --recursive

To rediscover the SHA after a future subtree pull:

  TREE=$(git ls-tree <upstream-remote>/<branch> <path-of-submodule-parent> \
          | awk '{print $3}')
  git ls-tree $TREE | grep <submodule-name>

**Why:** Subtree merges flatten history; submodule SHA pinning lives
in the parent's tree object, not in `.gitmodules`. Bootstrap script
reads only `.gitmodules`.

**Apply on Yoga:** if Sunshine's host subtree shows similar drift
during Task 1, use the manual recipe above against
`sunshine-upstream/master`. Do NOT fix bootstrap.sh in Phase 5A — log
the gap and defer.

---

End of carry-over context. Ready to start Task 1.
