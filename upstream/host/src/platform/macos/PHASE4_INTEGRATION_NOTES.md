# Phase 4 integration points (research output for plan Task 1)

These are the exact file:line locations the implementation tasks below modify.
If any have shifted relative to those captured here at branch creation time,
re-verify before editing.

- `upstream/host/src/platform/macos/display.mm:196`
  `display_names()` — return a `std::vector<std::string>`. We will inject the
  virtual display name here in Task 8.

- `upstream/host/src/stream.cpp:1996`
  `stream::session::start()` calls `platf::streaming_will_start()` — `session.config.monitor`
  (type `video::config_t`) is available here, with fields `width`, `height`, `framerate`.
  Spawn the helper here, Apple-only, in Task 9.

- `upstream/host/src/stream.cpp:1957`
  `stream::session::stop()` calls `platf::streaming_will_stop()`. We add
  `MacVirtualDisplayManager::teardown()` next to it (Apple-only) in Task 9.

- `upstream/host/src/video.h:24-26`
  `video::config_t` struct — fields used by spawn(): `int width;`, `int height;`,
  `int framerate;` (verified 2026-05-04 in worktree).

This file is for our own bookkeeping during Phase 4 implementation.
Delete after Phase 4 lands.
