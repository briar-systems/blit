# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- toolchain: Moved to Mach 5.0 and std 2.1. The manifest follows the mach 5 schema, `mach.lock` is replaced by the `dep/std` gitlink pinned to `tag/v2.1.0`, and `blit` is the default static artifact so a consumer's bare `use blit;` binds `blit.blit`.
- draw: `init`, `push_vert` and `push_quad` return `err[allocator.Error]` instead of `Option[str]`, and `free` returns `err[allocator.Error]` instead of nothing, leaving the buffer owned when the release is refused.
- font: `build_atlas` returns `err[allocator.Error]` instead of `Option[str]`.
- context: `init` returns `err[allocator.Error]` instead of `Option[str]`, and `free` returns `err[allocator.Error]` instead of nothing.

### Fixed
- version: `VERSION` reports 0.2.1, matching `mach.toml`.

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
