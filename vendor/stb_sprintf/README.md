# stb_sprintf.h (vendored)

A freestanding `vsnprintf` used to format the messages libretro cores send
through their variadic log callback (`retro_log_printf_t`). Zig 0.17.1 cannot
define C variadic functions on every target (`@cVaStart` is disabled on
aarch64-linux and x86_64-windows), and temui links no libc on Windows, so
`src/libretro/core_log.c` formats with this header instead of libc. It needs only
compiler-provided headers (`<stdarg.h>`, `<stddef.h>`).

Dual-licensed MIT / public domain (see [LICENSE](LICENSE)).

| | |
|---|---|
| Upstream | https://github.com/nothings/stb_sprintf (moved out of `nothings/stb` in 2026-10) |
| Path | `stb_sprintf.h` (v1.10) |
| Commit | `d9d1bb37d2ea313eb8a734452b178b2c27bbb951` (2026-11-01) |
| Fetched | 2026-11-23 |
| SHA-256 | `f8e15fddaf4c88c3b39e3d5e979bada250acdd2c18aa3f7de9c873a52d8045ca` |

The file is unmodified. Format strings come from the loaded core, which already
runs as native code in the process, so a malformed format string is not a new
trust boundary.

## Updating

```sh
SHA=$(gh api repos/nothings/stb_sprintf/commits/main --jq .sha)
curl -fsSL "https://raw.githubusercontent.com/nothings/stb_sprintf/$SHA/stb_sprintf.h" \
  -o vendor/stb_sprintf/stb_sprintf.h
```

Then update the commit, SHA-256 (`shasum -a 256 vendor/stb_sprintf/stb_sprintf.h`)
and dates above, check the license is unchanged, and run `zig build test` and
`zig build cross`.
