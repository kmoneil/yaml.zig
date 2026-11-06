//! yaml: a YAML 1.2.2 library for Zig, built to pass the whole
//! yaml/yaml-test-suite.
//!
//! The pipeline follows the spec's stages: a scanner turns text into
//! tokens, a parser turns tokens into events, a composer turns events
//! into a node graph, and construction turns nodes into typed Zig
//! values. An emitter goes the other way, and `stringify` writes Zig
//! values through it. Each stage can be used alone.

const std = @import("std");

/// The YAML version this library implements.
pub const spec_version = "1.2.2";

/// YAML text to tokens: the first stage, which the parser pulls from.
pub const Scanner = @import("Scanner.zig");

/// Tokens to events: a stream's documents and the nodes in them.
pub const Parser = @import("Parser.zig");

/// Events to a graph of nodes, a document at a time.
pub const Composer = @import("Composer.zig");

/// Events to YAML text.
pub const Emitter = @import("Emitter.zig");

/// How nodes with no specific tag get one: the failsafe, JSON and core
/// schemas, and the values their scalars hold.
pub const schema = @import("schema.zig");

/// A stream's encoding, and decoding UTF-16 and UTF-32 to the UTF-8 the
/// scanner reads.
pub const encoding = @import("encoding.zig");

const construct = @import("construct.zig");
/// Reads the one document in a slice into a `T`; see `ParseOptions`.
pub const parseFromSlice = construct.parseFromSlice;
/// `parseFromSlice` into an allocator freed as a whole, as an arena is.
pub const parseFromSliceLeaky = construct.parseFromSliceLeaky;
/// A value `parseFromSlice` read, and the arena it lives in.
pub const Parsed = construct.Parsed;
/// How `parseFromSlice` reads: schema, duplicate keys, limits, diagnostic.
pub const ParseOptions = construct.ParseOptions;
/// What reading can fail with.
pub const ParseError = construct.ParseError;
/// A document of any shape.
pub const Value = construct.Value;

/// A map from strings to values, for a mapping whose keys are not known
/// at compile time; `parseFromSlice` and `stringify` take it as a field.
pub const ArrayHashMap = @import("map.zig").ArrayHashMap;

const stringify_mod = @import("stringify.zig");
/// Writes a Zig value as a YAML document; `parseFromSlice` reads it back.
pub const stringify = stringify_mod.stringify;
/// `stringify` into a new slice the caller frees.
pub const stringifyAlloc = stringify_mod.stringifyAlloc;
/// How `stringify` writes: style, indentation, width, null fields.
pub const StringifyOptions = stringify_mod.StringifyOptions;
/// What writing can fail with.
pub const StringifyError = stringify_mod.StringifyError;
/// Where and why parsing failed: a mark (offset, line and column, from
/// 0) and a message.
pub const Diagnostic = Scanner.Diagnostic;

test "the module builds and its tests run" {
    try std.testing.expectEqualStrings("1.2.2", spec_version);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("Scanner_test.zig");
    _ = @import("Parser_test.zig");
    _ = @import("Composer_test.zig");
    _ = @import("schema_test.zig");
    _ = @import("construct_test.zig");
    _ = @import("encoding_test.zig");
    _ = @import("Emitter_test.zig");
    _ = @import("stringify_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("map_test.zig");
}
