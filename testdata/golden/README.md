# Golden frames

Frame 60 of the test core (`testcore/main.zig`) running `testdata/testcore.rom`,
once per pixel format the host supports (D3, D14). Binary PPM (P6, 256×224,
maxval 255). The test `frame 60 matches the committed golden for each pixel
format` in `src/run.zig` runs `temui run --headless` in-process and compares
its output with these files byte for byte, on every CI runner.

| File | Core option |
|---|---|
| `testcore-xrgb8888-f60.ppm` | `temui_test_pixel_format=xrgb8888` (the core asks for XRGB8888) |
| `testcore-rgb565-f60.ppm` | `temui_test_pixel_format=rgb565` (the core asks for RGB565) |
| `testcore-0rgb1555-f60.ppm` | `temui_test_pixel_format=0rgb1555` (no request: the libretro default) |

What frame 60 shows: colour bars rotated by the ROM's CRC32, a one-pixel
inverted bar at x = 59, the CRC32 as a 32-cell bit strip, a grey gradient, and
16 unlit input boxes.

## Regenerating

Only regenerate when the test core's pattern, the fixture ROM, or the pixel
conversion changes on purpose. From the repo root, on macOS (use `.so` on
Linux, `zig-out/bin/temui_test_libretro.dll` on Windows):

```sh
zig build
for f in xrgb8888 rgb565 0rgb1555; do
  zig-out/bin/temui run --headless \
    --core zig-out/lib/temui_test_libretro.dylib --rom testdata/testcore.rom \
    --frames 60 --dump-every 60 --dump-ppm "zig-out/golden-$f" \
    --option temui_test_pixel_format=$f
  cp "zig-out/golden-$f/frame-000060.ppm" "testdata/golden/testcore-$f-f60.ppm"
done
```

**Inspect the diff before committing.** Convert old and new to PNG (e.g.
`sips -s format png <file>.ppm --out <file>.png` on macOS) and look at them: a
golden that is regenerated without looking will happily lock in a bug.

# Renderer goldens

`render-*` files are renderer output for the XRGB8888 frame above, drawn into
an 80×24 cell rect of 10×20 px cells (`src/render/golden.zig`). Cell backends
(half-block, ASCII) are compared byte for byte. They are binary (`.bin`, see
`.gitattributes`) because they hold raw escape sequences.

| File | Backend |
|---|---|
| `render-halfblock-80x24.bin` | half-block truecolor |

## Regenerating

```sh
zig build test -Dupdate-goldens
```

Every golden that is missing or differs is rewritten, and its test fails so an
update can't pass silently. Run `zig build test` again to confirm.

**Inspect before committing.** `cat` a cell golden in a truecolor terminal
(it draws in place at the top left; `clear` afterwards), and compare it with
the PPM.
