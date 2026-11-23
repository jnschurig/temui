# temui — notes for Claude

- Read `docs/decisions.md` before starting a cycle. Decisions are referenced as D1–D15; change one by editing that file, not by working around it.
- Work comes from `docs/roadmap.md`. Run an item with `/spec-and-dev docs/roadmap/NN-slug.md`, and mark it ☑ in `roadmap.md` when the cycle finishes.
- The toolchain is managed by mise: `mise.toml` at the repo root pins Zig and is the single source of truth (CI uses `jdx/mise-action`). Don't install Zig any other way, and keep `minimum_zig_version` in `build.zig.zon` in sync with it.
- Work on a branch, not directly on `main`.
- Never link GPL code into the binary, and never commit or bundle libretro cores. Tests use the in-repo Zig test core (D14).
- Logs go to a file, never to stdout, because stdout carries the terminal graphics (D13).
