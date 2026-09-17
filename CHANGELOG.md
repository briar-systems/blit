# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-09-17

### Added
- context: layers. `push_layer`/`pop_layer` open a screen-space overlay, `end()` composes the draw list by layer, and `Run` carries its `layer`.
- context: claim-based input routing. `claim`, `reserve_claim` and `fill_claim` record interactive rects, and `hover` holds the topmost claimant under the cursor. Frame N's input is routed by frame N-1's claims at frame N's cursor, so a widget is interactive from the frame after it first appears. `blit.hit` holds the claim list and resolver.
- widget: `begin_popup`/`end_popup` open an overlay column. A press outside an open popup dismisses it and is consumed.
- draw: `reserve` grows a draw list to a known vertex count.

### Changed
- context: **a press in the first frame a widget exists does nothing.** Input in frame N is routed by the rects widgets claimed in frame N-1, so a widget becomes clickable one frame after it first appears. A widget that appears in response to a click (a popup, a newly revealed button) cannot be pressed in the frame it appears. This is a deliberate property of topmost-at-point routing, not a bug.
- widget: **the dropdown's option list is now an overlay popup.** It no longer pushes the widgets after it down, so the layout continues directly under the header whether the dropdown is open or not. A layout that relied on the open dropdown's extra height needs its own spacing. A press outside the open list closes it without reaching what lies beneath.
- widget: `begin_panel` and `begin_window` return a `Block`, and `end_panel`/`end_window` take it, instead of a `usize` vertex handle.
- widget: panels, windows and popups claim their whole rect, so a click on their empty area no longer reaches the widget they cover.
- widget: each dropdown takes one more id (its popup), so ids after a dropdown shift by one.
- manifest: `[project]` declares the compiler range `mach = "^5.3"`, so mach 5.3 and later no longer warn about a missing range.
- license: copyright is attributed to Briar Systems LLC.
- ci: releases are published by the family release workflow (`briar-systems/.github` `mach-release.yml`). Pushing a `v*` tag runs verify, the full CI tier and publish, and `workflow_dispatch` rehearses the same path. `ci.yml` accepts `heavy` as a `workflow_call` input, and pull requests run as before.

### Fixed
- widget: an open dropdown no longer loses its click to a window called after it (#1). Input goes to whatever is painted on top.
- context: a frame that closes more than `RUN_DEPTH` spans no longer leaves the extra vertices outside every span. The last span absorbs them, as documented.
- widget: a panel or window background that could not be emitted no longer lets its end call rewrite some other quad.

## [0.3.1] - 2026-09-16

### Changed
- deps: std moves to `tag/v4.0.0` (90b2f11), which requires mach 5.2.0 or later. blit uses none of the names that 4.0.0 removed or moved, and the std types in its API (`allocator.Error`, `err`, `res`) are unchanged, so no source changes were needed.

## [0.3.0] - 2026-09-16

### Added
- manifest: `linux-arm64` and `darwin-aarch64` targets, so the native aarch64 hosts build and test for themselves instead of falling back to linux-x86_64.
### Changed
- ci: CI runs the family pipeline (`briar-systems/.github` `mach-lib.yml`) on the pinned, checksum-verified mach seed: debug and release build and test, `mach fmt --check` and an all-targets release build on x86_64-linux for pull requests into dev, plus native aarch64-linux, windows and darwin legs for pull requests into main. A `gate` job is the one required check.
- deps: std moves to `tag/v3.2.0` (62bd03f). blit uses none of the io surfaces that changed in 3.x, so no source changes were needed.
- toolchain: Moved to Mach 5.0 and std 2.1. The manifest follows the mach 5 schema, `mach.lock` is replaced by the `dep/std` gitlink pinned to `tag/v2.1.0`, and `blit` is the default static artifact so a consumer's bare `use blit;` binds `blit.blit`.
- draw: `init`, `push_vert` and `push_quad` return `err[allocator.Error]` instead of `Option[str]`, and `free` returns `err[allocator.Error]` instead of nothing, leaving the buffer owned when the release is refused.
- font: `build_atlas` returns `err[allocator.Error]` instead of `Option[str]`.
- context: `init` returns `err[allocator.Error]` instead of `Option[str]`, and `free` returns `err[allocator.Error]` instead of nothing.

### Fixed
- version: `VERSION` matches `mach.toml` again. v0.2.1 shipped reporting 0.2.0.

## [0.2.1] - 2026-08-09

### Changed
- manifest: Re-touched to RFC-exact totality per mach#1964/mach#1979.

## [0.2.0] - 2026-07-07

Overhauls the build manifest to comply with the v2 build system schema.

### Changed
- manifest: Migrated manifest to v2 schema (`[artifact.blit]`, `[artifact.harness]`).
- deps: Updated `mach-std` dependency to the git URL.

## [0.1.2] - 2026-06-19

### Fixed
- version: Aligned VERSION constant with mach.toml.

## [0.1.1] - 2026-06-19

### Added
- Initial releases of blit.
