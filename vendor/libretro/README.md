# libretro.h (vendored)

The libretro API header, used by temui to load and drive cores at runtime (D3).
It is header-only and MIT-licensed (see [LICENSE](LICENSE), copied verbatim from
the header's own comment block). No libretro core code is vendored.

| | |
|---|---|
| Upstream | https://github.com/libretro/libretro-common |
| Path | `include/libretro.h` |
| Commit | `ae22debd425c33fe355ac2e51d9a140d7e8b3fa6` (2026-11-21) |
| Fetched | 2026-11-23 |
| SHA-256 | `469b0fbe2919ca9f5372b48a94ff8af51f70ee00c364798ec70670ecf6b7f9da` |

The file is unmodified. `build.zig` translates it with `b.addTranslateC` and
exposes it to Zig code as the `libretro` module.

## Updating

```sh
SHA=$(gh api repos/libretro/libretro-common/commits/master --jq .sha)
curl -fsSL "https://raw.githubusercontent.com/libretro/libretro-common/$SHA/include/libretro.h" \
  -o vendor/libretro/libretro.h
```

Then update the commit, SHA-256 (`shasum -a 256 vendor/libretro/libretro.h`) and dates above, check that the license block is unchanged,
and run `zig build test` and `zig build cross`.
