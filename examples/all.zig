//! Every example shown in README.md, compiled and run by `zig build
//! test`. tools/doc_examples.zig keeps the README's copy of each example
//! identical to its file here.

test {
    _ = @import("quick_start.zig");
    _ = @import("value.zig");
    _ = @import("stringify.zig");
    _ = @import("errors.zig");
    _ = @import("hook.zig");
    _ = @import("documents.zig");
    _ = @import("events.zig");
}
