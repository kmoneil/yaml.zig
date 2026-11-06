//! yaml: a YAML 1.2.2 library for Zig, built to pass the whole
//! yaml/yaml-test-suite.
//!
//! The pipeline follows the spec's stages: a scanner turns text into
//! tokens, a parser turns tokens into events, a composer turns events
//! into a node graph, and construction turns nodes into typed Zig
//! values. An emitter goes the other way. The scanner is begun; the
//! rest is not written yet.

const std = @import("std");

/// The YAML version this library implements.
pub const spec_version = "1.2.2";

/// YAML text to tokens: the first stage, which the parser pulls from.
pub const Scanner = @import("Scanner.zig");

/// Tokens to events: a stream's documents and the nodes in them.
pub const Parser = @import("Parser.zig");

/// Events to a graph of nodes, a document at a time.
pub const Composer = @import("Composer.zig");

/// How nodes with no specific tag get one: the failsafe, JSON and core
/// schemas, and the values their scalars hold.
pub const schema = @import("schema.zig");

test "the module builds and its tests run" {
    try std.testing.expectEqualStrings("1.2.2", spec_version);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("Scanner_test.zig");
    _ = @import("Parser_test.zig");
    _ = @import("Composer_test.zig");
    _ = @import("schema_test.zig");
}
