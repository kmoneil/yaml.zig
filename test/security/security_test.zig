//! The security suite (karte t44): a test per known attack on a YAML
//! library, each a row of CATALOG.md, through the public API only, as an
//! attacker reaches it. tools/security_catalog.zig, run by `zig build
//! test`, fails a row whose test is gone and a test no row names.

test {
    _ = @import("resources_test.zig");
    _ = @import("types_test.zig");
    _ = @import("encoding_test.zig");
    _ = @import("output_test.zig");
    _ = @import("api_test.zig");
}
