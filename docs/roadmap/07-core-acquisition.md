# 07 · Core acquisition

> Seed prompt for `/spec-and-dev docs/roadmap/07-core-acquisition.md`. temui is a single-binary, dependency-free, terminal-based libretro frontend written in Zig. Read [decisions.md](../decisions.md) first; this seed refers to decisions by number (D1–D15) and only summarizes the parts it needs. If a summary here disagrees with `decisions.md`, `decisions.md` wins. Tier: **MVP**. Roadmap: [roadmap.md](../roadmap.md).

## Goal
`temui core install <system>` downloads, verifies, and caches a working core, so users don't have to find cores themselves.

## Context
- D4 — nightly buildbot per-core zips; pinned on first download; `core update` is the only way to move a pinned core; local-path override; system→core map.
- D2 — windows-aarch64 has no buildbot cores: download must fail with a message pointing to the local-path option.
- Verified on 2026-11-23: nightly URLs are `https://buildbot.libretro.com/nightly/{platform}/latest/{core}_libretro.{so,dylib,dll}.zip` with platform dirs `linux/x86_64`, `linux/aarch64`, `apple/osx/x86_64`, `apple/osx/arm64`, `windows/x86_64`; zips are deflate; `std.http.Client.fetch` works against the buildbot on macOS; each dir has `.index-extended` (date, CRC32, filename) and per-core `.sig` files (magic `RACSIG01`).

## In scope
- Download over HTTPS with Zig std; extract with `std.zip`; store in a per-user cache.
- Pin record: core name, source URL, download date, SHA-256 of the extracted library.
- `temui core install|list|update|remove`; `--core <path>` override everywhere a core is used.
- Built-in system→core map: SNES → snes9x; NES → fceumm (alt nestopia); GB/GBC → gambatte (alt sameboy, not available on linux-aarch64).
- Spike: find RetroArch's core-signature format and public key, and decide whether to verify `.sig` files.
- Spike: confirm std TLS loads system certificates on Linux and Windows (CI runners).

## Out of scope
- The stable channel (7z bundles only; rejected in D4).
- Mirrors other than a configurable base URL.
- Core options UI.

## Acceptance sketch
- `temui core install snes` works on macOS, Linux and Windows x86_64, and on the aarch64 runners that exist.
- A second `install` is a no-op; after the upstream file changes, the pinned core is still used until `core update`.
- A tampered cached file is detected (hash mismatch) and reported.
- On windows-aarch64, `install` explains that cores must be given by path.
- The `.sig` outcome is written into `docs/decisions.md` (D4).

## Depends on
- [01](./01-scaffold.md) — build and CI.
- [03](./03-libretro-host-and-test-core.md) — to load the downloaded core as a post-install check.

## Open questions for the cycle's interview
- Cache location per OS, and should cores live in the cache or data directory?
- Verify `.sig` (if the key is published) instead of, or in addition to, pinning?
- Proxy support (`HTTPS_PROXY`)? Download progress display?
- What does `core update` show the user (dates, hashes) before replacing a pinned core?
