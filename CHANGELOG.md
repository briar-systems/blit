# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
