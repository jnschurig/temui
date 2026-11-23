# 20 · Packaging

> Seed prompt for `/spec-and-dev docs/roadmap/20-packaging.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **later**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
Install temui with Homebrew and Scoop, and remove macOS Gatekeeper friction with signing and notarization.

## Context
- D12 — package managers and macOS signing/notarization come after the release pipeline.

## In scope
- A Homebrew tap formula fed by item 16's release artifacts.
- A Scoop bucket manifest.
- macOS code signing and notarization in CI (needs an Apple Developer ID).
- Automated formula/manifest bumps on release.

## Out of scope
- Linux distribution packages (deb, rpm, AUR) unless cheap.
- Windows code signing.

## Acceptance sketch
- `brew install` and `scoop install` work from a clean machine.
- A downloaded macOS binary passes Gatekeeper without manual steps.

## Depends on
- [16](./16-release-pipeline.md) — release artifacts.

## Open questions for the cycle's interview
- Apple Developer account and secret management in CI?
- A tap in this repo or a separate `homebrew-temui` repo?
- Is Windows signing needed to avoid SmartScreen warnings?
