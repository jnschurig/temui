//! temui's internals as a library, for tools built beside the main binary
//! (`temui-bench`). The `temui` executable itself is rooted at `main.zig`;
//! this file only re-exports.

pub const render = struct {
    pub const Renderer = @import("render/Renderer.zig");
    pub const layout = @import("render/layout.zig");
    pub const kitty = @import("render/kitty.zig");
};

pub const term = struct {
    pub const caps = @import("term/caps.zig");
    pub const detect = @import("term/detect.zig");
    pub const session = @import("term/session.zig");
    pub const replies = @import("term/replies.zig");
};

pub const host = @import("libretro/host.zig");
pub const log = @import("log.zig");
pub const paths = @import("paths.zig");
