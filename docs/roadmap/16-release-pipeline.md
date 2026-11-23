# 16 · Release pipeline

> Seed prompt for `/spec-and-dev docs/roadmap/16-release-pipeline.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **next**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Pushing a version tag publishes a GitHub Release that users can download and verify.

## Context
- D12 — GitHub Releases from the CI cross-compile matrix, with checksums; package managers and signing come later.
- D2 — six targets; windows-aarch64 is tier-2 (local cores only), which the release notes must say.

## In scope
- A tag-triggered workflow that reuses item 01's matrix and uploads six archives (`.tar.gz` for Linux and macOS, `.zip` for Windows).
- `SHA256SUMS` file attached to the release.
- Version embedded in the binary from the tag.
- Install docs in the README; a note on removing macOS quarantine (`xattr -d com.apple.quarantine`).
- Release-notes template.

## Out of scope
- Homebrew, Scoop, signing and notarization (item 20).
- Auto-update.

## Acceptance sketch
- Pushing `v0.1.0` produces a release with six archives and `SHA256SUMS`.
- Checksums verify, and the downloaded binary runs on macOS and Linux.
- `temui --version` reports the tag.

## Depends on
- [01](./01-scaffold.md) — the CI matrix.

## Open questions for the cycle's interview
- Archive naming scheme?
- Changelog: hand-written, or generated from commits?
- Should the release include build provenance (GitHub artifact attestations)?
