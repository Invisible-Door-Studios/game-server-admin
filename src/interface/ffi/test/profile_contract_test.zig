// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Isolated unit tests of the draft contract's public Zig API, included by
// integration_test.zig so the existing `zig build test-integration` runs them.
// No C ABI, registry, network, deployment, or persistent state is involved.

const std = @import("std");
const testing = std.testing;
const contract = @import("gsa").profile_contract;
const allocator = testing.allocator;

const BASE_DESCRIPTOR =
    \\{"$comment":"synthetic unit fixture",
    \\"contract":{"name":"gsa.game-profile","version":"0.1.0-draft"},
    \\"metadata":{"status":"test","source":"synthetic"},
    \\"profile":{"id":"Unit_1-test","name":"Unit test","kind":"test-fixture"},
    \\"configuration":{"version":"config.v7","fields":[]},
    \\"capabilities":[]}
;

// Keep generated descriptor bytes alive: ProfileDocument can borrow strings
// from its input. Tests also use this owner to check StatusView independence.
const Descriptor = struct {
    input: []u8,
    document: contract.ProfileDocument,

    fn init(fields: []const u8, capabilities: []const u8) !Descriptor {
        const input = try descriptorJson(fields, capabilities);
        errdefer allocator.free(input);
        return .{ .input = input, .document = try contract.parseProfile(allocator, input) };
    }

    fn deinit(self: *Descriptor) void {
        self.document.deinit();
        allocator.free(self.input);
    }
};

fn descriptorJson(fields: []const u8, capabilities: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"contract":{{"name":"gsa.game-profile","version":"0.1.0-draft"}},
        \\"profile":{{"id":"unit-test","name":"Unit test","kind":"test-fixture"}},
        \\"configuration":{{"version":"config.v7","fields":[{s}]}},"capabilities":[{s}]}}
    , .{ fields, capabilities });
}

fn statusJson(data: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"source":"fixture","connected":false,"capability_id":"vendor.summary",
        \\"capability_version":"summary.v2","data":{s}}}
    , .{data});
}

fn replace(input: []const u8, before: []const u8, after: []const u8) ![]u8 {
    // A stale mutation must fail loudly instead of silently testing the base.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, input, before));
    return std.mem.replaceOwned(u8, allocator, input, before, after);
}

test "profile contract: descriptor structure and contract identity are strict" {
    const cases = [_]struct { before: []const u8, after: []const u8, err: anyerror }{
        .{ .before = "gsa.game-profile", .after = "vendor.other", .err = error.UnsupportedProfileContract },
        .{ .before = "0.1.0-draft", .after = "0.2.0", .err = error.UnsupportedProfileContract },
        .{ .before = "\"name\":\"gsa.game-profile\"", .after = "\"name\":null", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"contract\":{\"name\":\"gsa.game-profile\",\"version\":\"0.1.0-draft\"},", .after = "", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"contract\":{", .after = "\"contract\":{\"extra\":true,", .err = error.UnknownDescriptorField },
        .{ .before = "\"$comment\":\"synthetic unit fixture\"", .after = "\"$comment\":false", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"metadata\":{\"status\":\"test\",\"source\":\"synthetic\"}", .after = "\"metadata\":[]", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"status\":\"test\"", .after = "\"status\":false", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"source\":\"synthetic\"", .after = "\"source\":0", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"metadata\":{", .after = "\"metadata\":{\"extra\":true,", .err = error.UnknownDescriptorField },
        .{ .before = "\"profile\":{\"id\":\"Unit_1-test\",\"name\":\"Unit test\",\"kind\":\"test-fixture\"}", .after = "\"profile\":null", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"name\":\"Unit test\"", .after = "\"name\":\"\"", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"kind\":\"test-fixture\"", .after = "\"kind\":\"\"", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"profile\":{", .after = "\"profile\":{\"extra\":true,", .err = error.UnknownDescriptorField },
        .{ .before = "\"configuration\":{\"version\":\"config.v7\",\"fields\":[]}", .after = "\"configuration\":false", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"version\":\"config.v7\"", .after = "\"version\":\"\"", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"fields\":[]", .after = "\"fields\":{}", .err = error.InvalidProfileDescriptor },
        .{ .before = ",\"fields\":[]", .after = "", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"configuration\":{", .after = "\"configuration\":{\"extra\":true,", .err = error.UnknownDescriptorField },
        .{ .before = "\"capabilities\":[]", .after = "\"capabilities\":{}", .err = error.InvalidProfileDescriptor },
        .{ .before = "\"capabilities\":[]", .after = "\"capabilities\":[],\"execute\":\"anything\"", .err = error.UnknownDescriptorField },
    };
    for (cases) |case| {
        errdefer std.debug.print("descriptor mutation: {s}\n", .{case.after});
        const input = try replace(BASE_DESCRIPTOR, case.before, case.after);
        defer allocator.free(input);
        try testing.expectError(case.err, contract.parseProfile(allocator, input));
    }

    for ([_][]const u8{ "null", "[]", "false", "{}" }) |input| {
        try testing.expectError(error.InvalidProfileDescriptor, contract.parseProfile(allocator, input));
    }
}

test "profile contract: profile IDs enforce grammar and the 128 character boundary" {
    const accepted = [_][]const u8{ "A", "0", "Game_2-test", "a" ** 128 };
    for (accepted) |id| {
        const input = try replace(BASE_DESCRIPTOR, "Unit_1-test", id);
        defer allocator.free(input);
        var profile = try contract.parseProfile(allocator, input);
        defer profile.deinit();
        // Configuration versions are independent of the profile contract.
        try contract.validateConfiguration(allocator, &profile, "{}");
    }
    for ([_][]const u8{ "", "_game", "-game", "game.name", "game name", "é", "a" ** 129 }) |id| {
        const input = try replace(BASE_DESCRIPTOR, "Unit_1-test", id);
        defer allocator.free(input);
        try testing.expectError(error.InvalidProfileDescriptor, contract.parseProfile(allocator, input));
    }
}

const STRING_FIELD =
    \\{"key":"setting","type":"string","required":false,"visibility":"operator"}
;

test "profile contract: field keys enforce grammar and the 128 character boundary" {
    for ([_][]const u8{ "A", "a.b-c_9", "a" ** 128 }) |key| {
        const field = try replace(STRING_FIELD, "setting", key);
        defer allocator.free(field);
        var descriptor = try Descriptor.init(field, "");
        defer descriptor.deinit();
    }
    for ([_][]const u8{ "", "1field", "_field", ".field", "a/b", "a b", "é", "a" ** 129 }) |key| {
        const field = try replace(STRING_FIELD, "setting", key);
        defer allocator.free(field);
        const input = try descriptorJson(field, "");
        defer allocator.free(input);
        try testing.expectError(error.InvalidFieldDefinition, contract.parseProfile(allocator, input));
    }
}

test "profile contract: malformed and contradictory field declarations are rejected" {
    // Each fragment is the interior of an otherwise valid field declaration.
    const invalid = [_][]const u8{
        \\"type":"string","required":false,"visibility":"operator"
        ,
        \\"key":"x","required":false,"visibility":"operator"
        ,
        \\"key":"x","type":"string","visibility":"operator"
        ,
        \\"key":"x","type":"string","required":false
        ,
        \\"key":"x","type":"object","required":false,"visibility":"operator"
        ,
        \\"key":"x","type":"string","required":"false","visibility":"operator"
        ,
        \\"key":"x","type":"string","required":false,"visibility":"public"
        ,
        \\"key":"x","type":"string","required":false,"visibility":"operator","description":4
        ,
        \\"key":"x","type":"enum","required":false,"visibility":"player"
        ,
        \\"key":"x","type":"enum","required":false,"visibility":"player","values":[]
        ,
        \\"key":"x","type":"enum","required":false,"visibility":"player","values":"one"
        ,
        \\"key":"x","type":"enum","required":false,"visibility":"player","values":[1]
        ,
        \\"key":"x","type":"enum","required":false,"visibility":"player","values":["one","one"]
        ,
        \\"key":"x","type":"string","required":false,"visibility":"player","values":["one"]
        ,
        \\"key":"x","type":"integer","required":false,"visibility":"operator","minimum":1.5
        ,
        \\"key":"x","type":"integer","required":false,"visibility":"operator","maximum":1.5
        ,
        \\"key":"x","type":"number","required":false,"visibility":"operator","minimum":"0"
        ,
        \\"key":"x","type":"number","required":false,"visibility":"operator","maximum":null
        ,
        \\"key":"x","type":"number","required":false,"visibility":"operator","minimum":2,"maximum":1
        ,
        \\"key":"x","type":"string","required":false,"visibility":"operator","minimum":0
        ,
        \\"key":"x","type":"string","required":false,"visibility":"operator","minLength":-1
        ,
        \\"key":"x","type":"string","required":false,"visibility":"operator","maxLength":-1
        ,
        \\"key":"x","type":"string","required":false,"visibility":"operator","minLength":0.5
        ,
        \\"key":"x","type":"string","required":false,"visibility":"operator","minLength":3,"maxLength":2
        ,
        \\"key":"x","type":"boolean","required":false,"visibility":"operator","maxLength":2
        ,
        \\"key":"x","type":"secret-ref","required":false,"visibility":"operator"
        ,
        \\"key":"x","type":"secret-ref","required":false,"visibility":"player"
        ,
    };
    for (invalid) |fragment| {
        errdefer std.debug.print("invalid field: {s}\n", .{fragment});
        const field = try std.fmt.allocPrint(allocator, "{{{s}}}", .{fragment});
        defer allocator.free(field);
        const input = try descriptorJson(field, "");
        defer allocator.free(input);
        try testing.expectError(error.InvalidFieldDefinition, contract.parseProfile(allocator, input));
    }
    for ([_][]const u8{ "null", "false", "[]", "42" }) |field| {
        const input = try descriptorJson(field, "");
        defer allocator.free(input);
        try testing.expectError(error.InvalidFieldDefinition, contract.parseProfile(allocator, input));
    }
    const unknown_field = try replace(STRING_FIELD, "\"key\":", "\"command\":\"ignored\",\"key\":");
    defer allocator.free(unknown_field);
    const input = try descriptorJson(unknown_field, "");
    defer allocator.free(input);
    try testing.expectError(error.UnknownDescriptorField, contract.parseProfile(allocator, input));
}

const CAPABILITY =
    \\{"id":"vendor.summary","version":"summary.v2","fields":[]}
;

test "profile contract: duplicate fields and capabilities fail within their scopes" {
    const duplicate_fields = try std.fmt.allocPrint(allocator, "{s},{s}", .{ STRING_FIELD, STRING_FIELD });
    defer allocator.free(duplicate_fields);
    const input = try descriptorJson(duplicate_fields, "");
    defer allocator.free(input);
    try testing.expectError(error.DuplicateField, contract.parseProfile(allocator, input));

    const capability = try replace(CAPABILITY, "\"fields\":[]", "\"fields\":[" ++ STRING_FIELD ++ "," ++ STRING_FIELD ++ "]");
    defer allocator.free(capability);
    const bad_capability = try descriptorJson("", capability);
    defer allocator.free(bad_capability);
    try testing.expectError(error.DuplicateField, contract.parseProfile(allocator, bad_capability));

    const duplicate_capabilities = try descriptorJson("", CAPABILITY ++ "," ++ CAPABILITY);
    defer allocator.free(duplicate_capabilities);
    try testing.expectError(error.DuplicateCapability, contract.parseProfile(allocator, duplicate_capabilities));

    // Identical keys in configuration and a capability are separate namespaces.
    var scoped = try Descriptor.init(STRING_FIELD,
        \\{"id":"vendor.summary","version":"summary.v2","fields":[
    ++ STRING_FIELD ++ "]}");
    defer scoped.deinit();
    try contract.validateConfiguration(allocator, &scoped.document, "{}");
}

test "profile contract: unknown capabilities still require valid generic declarations" {
    const invalid = [_][]const u8{
        "null",
        "[]",
        \\{"id":"","version":"v1","fields":[]}
        ,
        \\{"id":"vendor.summary","version":"","fields":[]}
        ,
        \\{"id":"vendor.summary","version":1,"fields":[]}
        ,
        \\{"id":"vendor.summary","fields":[]}
        ,
        \\{"id":"vendor.summary","version":"v1"}
        ,
        \\{"id":"vendor.summary","version":"v1","fields":{}}
        ,
    };
    for (invalid) |capability| {
        const input = try descriptorJson("", capability);
        defer allocator.free(input);
        try testing.expectError(error.InvalidProfileDescriptor, contract.parseProfile(allocator, input));
    }
    const unknown = try replace(CAPABILITY, "\"fields\":[]", "\"fields\":[],\"endpoint\":\"ignored\"");
    defer allocator.free(unknown);
    const input = try descriptorJson("", unknown);
    defer allocator.free(input);
    try testing.expectError(error.UnknownDescriptorField, contract.parseProfile(allocator, input));
}

test "profile contract: string lengths count Unicode codepoints with inclusive limits" {
    var descriptor = try Descriptor.init(
        \\{"key":"name","type":"string","required":true,"visibility":"player","minLength":2,"maxLength":3}
    , "");
    defer descriptor.deinit();
    for ([_][]const u8{
        \\{"name":"ab"}
        ,
        \\{"name":"abc"}
        ,
        \\{"name":"é🙂"}
        ,
        \\{"name":"\u00e9\ud83d\ude42!"}
        ,
    }) |input| try contract.validateConfiguration(allocator, &descriptor.document, input);

    for ([_][]const u8{
        \\{"name":""}
        ,
        \\{"name":"🙂"}
        ,
        \\{"name":"é🙂ab"}
        ,
    }) |input| try testing.expectError(error.ValueOutOfRange, contract.validateConfiguration(allocator, &descriptor.document, input));

    var empty_only = try Descriptor.init(
        \\{"key":"name","type":"string","required":true,"visibility":"player","minLength":0,"maxLength":0}
    , "");
    defer empty_only.deinit();
    try contract.validateConfiguration(allocator, &empty_only.document, "{\"name\":\"\"}");
    try testing.expectError(error.ValueOutOfRange, contract.validateConfiguration(allocator, &empty_only.document, "{\"name\":\"a\"}"));
}

test "profile contract: integer conversion handles signed 64 bit limits without overflow" {
    var descriptor = try Descriptor.init(
        \\{"key":"count","type":"integer","required":true,"visibility":"operator"}
    , "");
    defer descriptor.deinit();
    for ([_][]const u8{
        \\{"count":-9223372036854775808}
        ,
        \\{"count":9223372036854775807}
        ,
        \\{"count":-9223372036854775808.0}
        ,
        \\{"count":9.223372036854775e18}
        ,
        \\{"count":4e0}
        ,
    }) |input| try contract.validateConfiguration(allocator, &descriptor.document, input);
    for ([_][]const u8{
        \\{"count":9223372036854775808.0}
        ,
        \\{"count":-9.223372036854778e18}
        ,
        \\{"count":0.5}
        ,
        \\{"count":true}
        ,
        \\{"count":"4"}
        ,
    }) |input| try testing.expectError(error.TypeMismatch, contract.validateConfiguration(allocator, &descriptor.document, input));
}

test "profile contract: number bounds accept integers and fractions and include both endpoints" {
    var descriptor = try Descriptor.init(
        \\{"key":"ratio","type":"number","required":true,"visibility":"operator","minimum":-1.5,"maximum":2.5}
    , "");
    defer descriptor.deinit();
    for ([_][]const u8{ "{\"ratio\":-1.5}", "{\"ratio\":0}", "{\"ratio\":2.5}" }) |input| {
        try contract.validateConfiguration(allocator, &descriptor.document, input);
    }
    for ([_][]const u8{ "{\"ratio\":-1.5001}", "{\"ratio\":2.5001}" }) |input| {
        try testing.expectError(error.ValueOutOfRange, contract.validateConfiguration(allocator, &descriptor.document, input));
    }
    for ([_][]const u8{ "{\"ratio\":\"1.5\"}", "{\"ratio\":null}", "{\"ratio\":false}" }) |input| {
        try testing.expectError(error.TypeMismatch, contract.validateConfiguration(allocator, &descriptor.document, input));
    }
}

test "profile contract: optional omission differs from null and enum matching is exact" {
    var descriptor = try Descriptor.init(
        \\{"key":"enabled","type":"boolean","required":false,"visibility":"player"},
        \\{"key":"mode","type":"enum","required":false,"visibility":"player","values":["Co-op","competitive"]}
    , "");
    defer descriptor.deinit();
    for ([_][]const u8{ "{}", "{\"enabled\":false}", "{\"enabled\":true}", "{\"mode\":\"Co-op\"}", "{\"mode\":\"competitive\"}" }) |input| {
        try contract.validateConfiguration(allocator, &descriptor.document, input);
    }
    for ([_][]const u8{ "{\"enabled\":0}", "{\"enabled\":\"false\"}", "{\"enabled\":null}", "{\"mode\":null}", "{\"mode\":1}" }) |input| {
        try testing.expectError(error.TypeMismatch, contract.validateConfiguration(allocator, &descriptor.document, input));
    }
    for ([_][]const u8{ "{\"mode\":\"co-op\"}", "{\"mode\":\"Co-op \"}" }) |input| {
        try testing.expectError(error.InvalidValue, contract.validateConfiguration(allocator, &descriptor.document, input));
    }
    try testing.expectError(error.UnknownConfigurationField, contract.validateConfiguration(allocator, &descriptor.document, "{\"Enabled\":true}"));
    for ([_][]const u8{ "null", "[]", "true", "0", "\"text\"" }) |input| {
        try testing.expectError(error.InvalidConfiguration, contract.validateConfiguration(allocator, &descriptor.document, input));
    }
}

const SECRET_FIELD =
    \\{"key":"token","type":"secret-ref","required":true,"visibility":"secret"}
;

test "profile contract: secret references require exactly two nonempty string identifiers" {
    var descriptor = try Descriptor.init(SECRET_FIELD, "");
    defer descriptor.deinit();
    try contract.validateConfiguration(allocator, &descriptor.document,
        \\{"token":{"provider":"unknown-local-provider","id":"opaque://not-resolved"}}
    );
    for ([_][]const u8{
        \\{"token":null}
        ,
        \\{"token":[]}
        ,
        \\{"token":{}}
        ,
        \\{"token":{"provider":"vault"}}
        ,
        \\{"token":{"provider":"","id":"key"}}
        ,
        \\{"token":{"provider":"vault","id":""}}
        ,
        \\{"token":{"provider":1,"id":"key"}}
        ,
        \\{"token":{"provider":"vault","id":false}}
        ,
        \\{"token":{"provider":"vault","value":"inline-secret-canary"}}
        ,
        \\{"token":{"provider":"vault","id":"key","value":"inline-secret-canary"}}
        ,
    }) |input| try testing.expectError(error.InvalidValue, contract.validateConfiguration(allocator, &descriptor.document, input));
}

test "profile contract: fixture configuration validates its envelope before declared data" {
    var descriptor = try Descriptor.init(
        \\{"key":"enabled","type":"boolean","required":true,"visibility":"player"}
    , "");
    defer descriptor.deinit();
    const valid =
        \\{"$comment":"synthetic","source":"fixture","connected":false,"data":{"enabled":false}}
    ;
    try contract.validateFixtureConfiguration(allocator, &descriptor.document, valid);
    const cases = [_]struct { before: []const u8, after: []const u8, err: anyerror }{
        .{ .before = "\"source\":\"fixture\"", .after = "\"source\":\"adapter\"", .err = error.NotFixtureConfiguration },
        .{ .before = "\"connected\":false", .after = "\"connected\":true", .err = error.NotFixtureConfiguration },
        .{ .before = "\"connected\":false", .after = "\"connected\":\"false\"", .err = error.NotFixtureConfiguration },
        .{ .before = "\"connected\":false,", .after = "", .err = error.InvalidFixtureConfiguration },
        .{ .before = "\"source\":\"fixture\",", .after = "", .err = error.InvalidFixtureConfiguration },
        .{ .before = "\"source\":\"fixture\"", .after = "\"source\":null", .err = error.InvalidFixtureConfiguration },
        .{ .before = "\"$comment\":\"synthetic\"", .after = "\"$comment\":0", .err = error.InvalidFixtureConfiguration },
        .{ .before = "\"data\":{\"enabled\":false}", .after = "\"data\":[]", .err = error.InvalidConfiguration },
        .{ .before = "\"data\":{\"enabled\":false}", .after = "\"data\":{}", .err = error.MissingRequiredField },
        .{ .before = "\"enabled\":false", .after = "\"enabled\":null", .err = error.TypeMismatch },
        .{ .before = "\"enabled\":false", .after = "\"unexpected\":false", .err = error.UnknownConfigurationField },
        .{ .before = ",\"data\":{\"enabled\":false}", .after = "", .err = error.InvalidFixtureConfiguration },
        .{ .before = "\"data\":", .after = "\"extra\":true,\"data\":", .err = error.UnknownDescriptorField },
    };
    for (cases) |case| {
        const input = try replace(valid, case.before, case.after);
        defer allocator.free(input);
        try testing.expectError(case.err, contract.validateFixtureConfiguration(allocator, &descriptor.document, input));
    }
    try testing.expectError(error.InvalidFixtureConfiguration, contract.validateFixtureConfiguration(allocator, &descriptor.document, "[]"));
}

test "profile contract: status rejects each envelope defect independently" {
    var descriptor = try Descriptor.init("", CAPABILITY);
    defer descriptor.deinit();
    const valid = try statusJson("{}");
    defer allocator.free(valid);
    const cases = [_]struct { before: []const u8, after: []const u8, err: anyerror }{
        .{ .before = "\"source\":\"fixture\"", .after = "\"source\":\"adapter\"", .err = error.NotFixtureStatus },
        .{ .before = "\"source\":\"fixture\",", .after = "", .err = error.InvalidFixtureStatus },
        .{ .before = "\"source\":\"fixture\"", .after = "\"source\":false", .err = error.InvalidFixtureStatus },
        .{ .before = "\"connected\":false", .after = "\"connected\":true", .err = error.NotFixtureStatus },
        .{ .before = "\"connected\":false", .after = "\"connected\":\"false\"", .err = error.NotFixtureStatus },
        .{ .before = "\"connected\":false,", .after = "", .err = error.InvalidFixtureStatus },
        .{ .before = "\"capability_id\":\"vendor.summary\"", .after = "\"capability_id\":null", .err = error.InvalidFixtureStatus },
        .{ .before = "vendor.summary", .after = "unadvertised.summary", .err = error.CapabilityNotAdvertised },
        .{ .before = "summary.v2", .after = "summary.v3", .err = error.CapabilityVersionMismatch },
        .{ .before = "\"capability_version\":\"summary.v2\"", .after = "\"capability_version\":2", .err = error.InvalidFixtureStatus },
        .{ .before = "\"data\":{}", .after = "\"data\":null", .err = error.InvalidConfiguration },
        .{ .before = ",\"data\":{}", .after = "", .err = error.InvalidFixtureStatus },
        .{ .before = "\"data\":{}", .after = "\"data\":{},\"$comment\":false", .err = error.InvalidFixtureStatus },
        .{ .before = "\"data\":{}", .after = "\"data\":{},\"debug\":true", .err = error.UnknownDescriptorField },
    };
    for (cases) |case| {
        const input = try replace(valid, case.before, case.after);
        defer allocator.free(input);
        try testing.expectError(case.err, contract.projectFixtureStatus(allocator, &descriptor.document, input, .operator));
    }
    for ([_][]const u8{ "null", "[]", "false" }) |input| {
        try testing.expectError(error.InvalidFixtureStatus, contract.projectFixtureStatus(allocator, &descriptor.document, input, .player));
    }
}

test "profile contract: an empty status projection releases all owned allocations" {
    var descriptor = try Descriptor.init("", CAPABILITY);
    defer descriptor.deinit();
    const input = try statusJson("{}");
    defer allocator.free(input);
    // The testing allocator also verifies that deinit releases metadata copied
    // into the view when no visible fields have allocated an arena block yet.
    var empty = try contract.projectFixtureStatus(allocator, &descriptor.document, input, .player);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.fields.len);
    try testing.expectEqualStrings("unit-test", empty.profile_id);
    try testing.expectEqualStrings("vendor.summary", empty.capability_id);
    try testing.expectEqualStrings("summary.v2", empty.capability_version);
}

const SUMMARY_FIELDS =
    \\{"key":"label","type":"string","required":true,"visibility":"player"},
    \\{"key":"count","type":"integer","required":true,"visibility":"operator","minimum":0},
    \\{"key":"ratio","type":"number","required":true,"visibility":"player"},
    \\{"key":"ready","type":"boolean","required":true,"visibility":"player"},
    \\{"key":"mode","type":"enum","required":true,"visibility":"player","values":["opaque"]},
    \\{"key":"private_order","type":"string","required":false,"visibility":"secret"},
    \\{"key":"token","type":"secret-ref","required":false,"visibility":"secret"}
;
const SUMMARY_CAPABILITY =
    \\{"id":"vendor.summary","version":"summary.v2","fields":[
++ SUMMARY_FIELDS ++ "]}";
const SUMMARY_DATA =
    \\{"token":{"provider":"vault","id":"local-only"},"private_order":"secret-canary",
    \\"mode":"opaque","ready":false,"ratio":1.25,"count":4.0,"label":"safe\nlabel"}
;

test "profile contract: projection preserves scalar types, values and declared order for each audience" {
    var descriptor = try Descriptor.init("", SUMMARY_CAPABILITY);
    defer descriptor.deinit();
    const input = try statusJson(SUMMARY_DATA);
    defer allocator.free(input);

    var operator_view = try contract.projectFixtureStatus(allocator, &descriptor.document, input, .operator);
    defer operator_view.deinit();
    try testing.expectEqualStrings("fixture", operator_view.source);
    try testing.expect(!operator_view.connected);
    try testing.expectEqualStrings("unit-test", operator_view.profile_id);
    try testing.expectEqualStrings("vendor.summary", operator_view.capability_id);
    try testing.expectEqualStrings("summary.v2", operator_view.capability_version);
    try testing.expectEqual(@as(usize, 5), operator_view.fields.len);
    for ([_][]const u8{ "label", "count", "ratio", "ready", "mode" }, operator_view.fields) |key, field| {
        try testing.expectEqualStrings(key, field.key);
    }
    try testing.expect(operator_view.fields[0].value == .string);
    try testing.expectEqualStrings("safe\nlabel", operator_view.fields[0].value.string);
    try testing.expect(operator_view.fields[1].value == .integer);
    try testing.expectEqual(@as(i64, 4), operator_view.fields[1].value.integer);
    try testing.expect(operator_view.fields[2].value == .number);
    try testing.expectEqual(@as(f64, 1.25), operator_view.fields[2].value.number);
    try testing.expect(operator_view.fields[3].value == .boolean);
    try testing.expect(!operator_view.fields[3].value.boolean);
    try testing.expectEqualStrings("opaque", operator_view.fields[4].value.string);

    var player_view = try contract.projectFixtureStatus(allocator, &descriptor.document, input, .player);
    defer player_view.deinit();
    try testing.expectEqual(@as(usize, 4), player_view.fields.len);
    for ([_][]const u8{ "label", "ratio", "ready", "mode" }, player_view.fields) |key, field| {
        try testing.expectEqualStrings(key, field.key);
    }
}

test "profile contract: status validates hidden and unknown data before projecting either audience" {
    var descriptor = try Descriptor.init("", SUMMARY_CAPABILITY);
    defer descriptor.deinit();
    const cases = [_]struct { before: []const u8, after: []const u8, err: anyerror }{
        .{ .before = "\"count\":4.0", .after = "\"count\":-1", .err = error.ValueOutOfRange },
        .{ .before = "\"private_order\":\"secret-canary\"", .after = "\"private_order\":false", .err = error.TypeMismatch },
        .{ .before = "\"token\":{\"provider\":\"vault\",\"id\":\"local-only\"}", .after = "\"token\":\"inline-secret\"", .err = error.InvalidValue },
        .{ .before = "\"count\":4.0,", .after = "", .err = error.MissingRequiredField },
        .{ .before = "\"label\":", .after = "\"undeclared_private_data\":\"canary\",\"label\":", .err = error.UnknownConfigurationField },
    };
    for (cases) |case| {
        const data = try replace(SUMMARY_DATA, case.before, case.after);
        defer allocator.free(data);
        const input = try statusJson(data);
        defer allocator.free(input);
        for ([_]contract.Audience{ .player, .operator }) |audience| {
            try testing.expectError(case.err, contract.projectFixtureStatus(allocator, &descriptor.document, input, audience));
        }
    }
}

fn detachedStatusView() !contract.StatusView {
    var descriptor = try Descriptor.init("", SUMMARY_CAPABILITY);
    defer descriptor.deinit();
    const input = try statusJson(SUMMARY_DATA);
    defer allocator.free(input);
    const view = try contract.projectFixtureStatus(allocator, &descriptor.document, input, .operator);
    // Poison the source buffers before freeing them to expose borrowed strings.
    @memset(input, 'x');
    @memset(descriptor.input, 'x');
    return view;
}

test "profile contract: status owns all projected strings after both input documents are destroyed" {
    var view = try detachedStatusView();
    defer view.deinit();
    try testing.expectEqualStrings("unit-test", view.profile_id);
    try testing.expectEqualStrings("vendor.summary", view.capability_id);
    try testing.expectEqualStrings("summary.v2", view.capability_version);
    try testing.expectEqualStrings("label", view.fields[0].key);
    try testing.expectEqualStrings("safe\nlabel", view.fields[0].value.string);
    try testing.expectEqualStrings("mode", view.fields[4].key);
    try testing.expectEqualStrings("opaque", view.fields[4].value.string);
}

test "profile contract: malformed and duplicate JSON keys fail at all public input boundaries" {
    var descriptor = try Descriptor.init("", CAPABILITY);
    defer descriptor.deinit();
    try testing.expectError(error.UnexpectedEndOfInput, contract.parseProfile(allocator, "{"));
    try testing.expectError(error.UnexpectedEndOfInput, contract.validateConfiguration(allocator, &descriptor.document, "{"));
    try testing.expectError(error.UnexpectedEndOfInput, contract.validateFixtureConfiguration(allocator, &descriptor.document, "{"));
    try testing.expectError(error.UnexpectedEndOfInput, contract.projectFixtureStatus(allocator, &descriptor.document, "{", .operator));
    for ([_][]const u8{ "{\"x\":}", "{} trailing" }) |input| {
        try testing.expectError(error.SyntaxError, contract.parseProfile(allocator, input));
        try testing.expectError(error.SyntaxError, contract.validateConfiguration(allocator, &descriptor.document, input));
        try testing.expectError(error.SyntaxError, contract.validateFixtureConfiguration(allocator, &descriptor.document, input));
        try testing.expectError(error.SyntaxError, contract.projectFixtureStatus(allocator, &descriptor.document, input, .operator));
    }
    const duplicate = "{\"connected\":false,\"connected\":true}";
    try testing.expectError(error.DuplicateField, contract.parseProfile(allocator, duplicate));
    try testing.expectError(error.DuplicateField, contract.validateConfiguration(allocator, &descriptor.document, duplicate));
    try testing.expectError(error.DuplicateField, contract.validateFixtureConfiguration(allocator, &descriptor.document, duplicate));
    try testing.expectError(error.DuplicateField, contract.projectFixtureStatus(allocator, &descriptor.document, duplicate, .player));
}
