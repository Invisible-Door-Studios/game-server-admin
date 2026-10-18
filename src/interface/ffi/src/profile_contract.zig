// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (c) 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
//
// Draft, fixture-only validator for the versioned JSON game-profile boundary.
// It is deliberately not wired to the legacy A2ML registry, a C ABI, or a
// network/deployment path. See schemas/game-profile-draft-0.1.schema.json.

const std = @import("std");
const Allocator = std.mem.Allocator;
const JsonValue = std.json.Value;

pub const PROFILE_CONTRACT_NAME = "gsa.game-profile";
pub const PROFILE_CONTRACT_VERSION = "0.1.0-draft";

pub const Audience = enum { player, operator };
pub const Visibility = enum { player, operator, secret };
pub const FieldKind = enum { string, integer, number, boolean, enumeration, secret_ref };

pub const VisibleValue = union(enum) {
    string: []const u8,
    integer: i64,
    number: f64,
    boolean: bool,
};

pub const StatusField = struct {
    key: []const u8,
    value: VisibleValue,
};

/// A deliberately small safe projection. It owns only fields explicitly
/// classified for the requested audience; the source JSON (including secrets)
/// is not retained. All returned strings and fields are owned by this view.
pub const StatusView = struct {
    arena: std.heap.ArenaAllocator,
    source: []const u8,
    connected: bool,
    profile_id: []const u8,
    capability_id: []const u8,
    capability_version: []const u8,
    fields: []const StatusField,

    pub fn deinit(self: *StatusView) void {
        self.arena.deinit();
    }
};

pub const ProfileDocument = struct {
    parsed: std.json.Parsed(JsonValue),

    pub fn deinit(self: *ProfileDocument) void {
        self.parsed.deinit();
    }
};

/// Parse and check the draft descriptor's structural contract. Unknown
/// capability IDs are intentionally accepted, but their generic field
/// declarations must still use the supported, typed field subset.
pub fn parseProfile(allocator: Allocator, input: []const u8) !ProfileDocument {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, input, .{});
    errdefer parsed.deinit();
    try validateProfileDescriptor(parsed.value);
    return .{ .parsed = parsed };
}

/// Validate a configuration JSON object against a profile's declared fields.
/// Errors are static and never include submitted values (which may be secrets).
pub fn validateConfiguration(
    allocator: Allocator,
    profile: *const ProfileDocument,
    input: []const u8,
) !void {
    const configuration = requiredMember(profile.parsed.value, "configuration") catch return error.InvalidProfileDescriptor;
    const fields = requiredMember(configuration, "fields") catch return error.InvalidProfileDescriptor;
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, input, .{});
    defer parsed.deinit();
    try validateObjectAgainstFields(fields, parsed.value);
}

/// Validate a fixture envelope without pretending it is deployment input.
pub fn validateFixtureConfiguration(
    allocator: Allocator,
    profile: *const ProfileDocument,
    input: []const u8,
) !void {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, input, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFixtureConfiguration;
    try requireOnlyKeys(parsed.value, &.{ "$comment", "source", "connected", "data" });
    if (member(parsed.value, "$comment")) |comment| if (comment != .string) return error.InvalidFixtureConfiguration;
    const source = stringMember(parsed.value, "source") orelse return error.InvalidFixtureConfiguration;
    if (!std.mem.eql(u8, source, "fixture")) return error.NotFixtureConfiguration;
    const connected = member(parsed.value, "connected") orelse return error.InvalidFixtureConfiguration;
    if (connected != .bool or connected.bool) return error.NotFixtureConfiguration;
    const configuration = requiredMember(profile.parsed.value, "configuration") catch return error.InvalidProfileDescriptor;
    const fields = requiredMember(configuration, "fields") catch return error.InvalidProfileDescriptor;
    const data = member(parsed.value, "data") orelse return error.InvalidFixtureConfiguration;
    try validateObjectAgainstFields(fields, data);
}

/// Convert an explicitly supplied fixture envelope to a safe status view.
/// This API refuses non-fixture or connected payloads: it is not a live-server
/// adapter. Player views contain only player-visible fields; operator views
/// may additionally contain operator-visible fields. Secret fields are never
/// copied to either audience.
pub fn projectFixtureStatus(
    allocator: Allocator,
    profile: *const ProfileDocument,
    input: []const u8,
    audience: Audience,
) !StatusView {
    var parsed = try std.json.parseFromSlice(JsonValue, allocator, input, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidFixtureStatus;
    try requireOnlyKeys(parsed.value, &.{ "$comment", "source", "connected", "capability_id", "capability_version", "data" });
    if (member(parsed.value, "$comment")) |comment| if (comment != .string) return error.InvalidFixtureStatus;

    const source = stringMember(parsed.value, "source") orelse return error.InvalidFixtureStatus;
    if (!std.mem.eql(u8, source, "fixture")) return error.NotFixtureStatus;
    const connected = member(parsed.value, "connected") orelse return error.InvalidFixtureStatus;
    if (connected != .bool or connected.bool) return error.NotFixtureStatus;

    const capability_id = stringMember(parsed.value, "capability_id") orelse return error.InvalidFixtureStatus;
    const capability_version = stringMember(parsed.value, "capability_version") orelse return error.InvalidFixtureStatus;
    const capability = findCapability(profile.parsed.value, capability_id) orelse return error.CapabilityNotAdvertised;
    const declared_version = stringMember(capability, "version") orelse return error.InvalidProfileDescriptor;
    if (!std.mem.eql(u8, declared_version, capability_version)) return error.CapabilityVersionMismatch;
    const fields = requiredMember(capability, "fields") catch return error.InvalidProfileDescriptor;
    const data = member(parsed.value, "data") orelse return error.InvalidFixtureStatus;
    try validateObjectAgainstFields(fields, data);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    var projected: std.ArrayList(StatusField) = .empty;
    for (fields.array.items) |field| {
        const key = stringMember(field, "key") orelse return error.InvalidProfileDescriptor;
        const raw_value = member(data, key) orelse continue;
        const visibility_text = stringMember(field, "visibility") orelse return error.InvalidProfileDescriptor;
        const visibility = parseVisibility(visibility_text) orelse return error.InvalidProfileDescriptor;
        if (!isVisible(visibility, audience)) continue;
        const kind_text = stringMember(field, "type") orelse return error.InvalidProfileDescriptor;
        const kind = parseFieldKind(kind_text) orelse return error.InvalidProfileDescriptor;
        try projected.append(owned, .{
            .key = try owned.dupe(u8, key),
            .value = try copyVisibleValue(owned, kind, raw_value),
        });
    }

    return .{
        .arena = arena,
        .source = "fixture",
        .connected = false,
        .profile_id = try owned.dupe(u8, profileId(profile.parsed.value) orelse return error.InvalidProfileDescriptor),
        .capability_id = try owned.dupe(u8, capability_id),
        .capability_version = try owned.dupe(u8, capability_version),
        .fields = try projected.toOwnedSlice(owned),
    };
}

fn validateProfileDescriptor(root: JsonValue) !void {
    if (root != .object) return error.InvalidProfileDescriptor;
    try requireOnlyKeys(root, &.{ "$comment", "contract", "metadata", "profile", "configuration", "capabilities" });
    if (member(root, "$comment")) |comment| if (comment != .string) return error.InvalidProfileDescriptor;

    const contract = requiredMember(root, "contract") catch return error.InvalidProfileDescriptor;
    if (contract != .object) return error.InvalidProfileDescriptor;
    try requireOnlyKeys(contract, &.{ "name", "version" });
    const contract_name = stringMember(contract, "name") orelse return error.InvalidProfileDescriptor;
    const contract_version = stringMember(contract, "version") orelse return error.InvalidProfileDescriptor;
    if (!std.mem.eql(u8, contract_name, PROFILE_CONTRACT_NAME) or
        !std.mem.eql(u8, contract_version, PROFILE_CONTRACT_VERSION)) return error.UnsupportedProfileContract;

    if (member(root, "metadata")) |metadata| {
        if (metadata != .object) return error.InvalidProfileDescriptor;
        try requireOnlyKeys(metadata, &.{ "status", "source" });
        if (member(metadata, "status")) |status| if (status != .string) return error.InvalidProfileDescriptor;
        if (member(metadata, "source")) |source| if (source != .string) return error.InvalidProfileDescriptor;
    }

    const profile = requiredMember(root, "profile") catch return error.InvalidProfileDescriptor;
    if (profile != .object) return error.InvalidProfileDescriptor;
    try requireOnlyKeys(profile, &.{ "id", "name", "kind" });
    const id = stringMember(profile, "id") orelse return error.InvalidProfileDescriptor;
    const name = stringMember(profile, "name") orelse return error.InvalidProfileDescriptor;
    const kind = stringMember(profile, "kind") orelse return error.InvalidProfileDescriptor;
    if (!isProfileId(id) or name.len == 0 or kind.len == 0) return error.InvalidProfileDescriptor;

    const configuration = requiredMember(root, "configuration") catch return error.InvalidProfileDescriptor;
    if (configuration != .object) return error.InvalidProfileDescriptor;
    try requireOnlyKeys(configuration, &.{ "version", "fields" });
    const config_version = stringMember(configuration, "version") orelse return error.InvalidProfileDescriptor;
    if (config_version.len == 0) return error.InvalidProfileDescriptor;
    const config_fields = requiredMember(configuration, "fields") catch return error.InvalidProfileDescriptor;
    try validateFieldArray(config_fields);

    if (member(root, "capabilities")) |capabilities| {
        if (capabilities != .array) return error.InvalidProfileDescriptor;
        for (capabilities.array.items, 0..) |capability, index| {
            if (capability != .object) return error.InvalidProfileDescriptor;
            try requireOnlyKeys(capability, &.{ "id", "version", "fields" });
            const capability_id = stringMember(capability, "id") orelse return error.InvalidProfileDescriptor;
            const capability_version = stringMember(capability, "version") orelse return error.InvalidProfileDescriptor;
            if (capability_id.len == 0 or capability_version.len == 0) return error.InvalidProfileDescriptor;
            for (capabilities.array.items[0..index]) |prior| {
                const prior_id = stringMember(prior, "id") orelse return error.InvalidProfileDescriptor;
                if (std.mem.eql(u8, prior_id, capability_id)) return error.DuplicateCapability;
            }
            const fields = requiredMember(capability, "fields") catch return error.InvalidProfileDescriptor;
            try validateFieldArray(fields);
        }
    }
}

fn validateFieldArray(fields: JsonValue) !void {
    if (fields != .array) return error.InvalidProfileDescriptor;
    for (fields.array.items, 0..) |field, index| {
        if (field != .object) return error.InvalidFieldDefinition;
        try requireOnlyKeys(field, &.{
            "key", "type", "required", "visibility", "values", "minimum", "maximum", "minLength", "maxLength", "description",
        });
        const key = stringMember(field, "key") orelse return error.InvalidFieldDefinition;
        const kind_text = stringMember(field, "type") orelse return error.InvalidFieldDefinition;
        const kind = parseFieldKind(kind_text) orelse return error.InvalidFieldDefinition;
        const required = member(field, "required") orelse return error.InvalidFieldDefinition;
        if (required != .bool) return error.InvalidFieldDefinition;
        const visibility_text = stringMember(field, "visibility") orelse return error.InvalidFieldDefinition;
        const visibility = parseVisibility(visibility_text) orelse return error.InvalidFieldDefinition;
        if (!isFieldKey(key)) return error.InvalidFieldDefinition;

        for (fields.array.items[0..index]) |prior| {
            const prior_key = stringMember(prior, "key") orelse return error.InvalidFieldDefinition;
            if (std.mem.eql(u8, prior_key, key)) return error.DuplicateField;
        }

        if (member(field, "description")) |description| if (description != .string) return error.InvalidFieldDefinition;
        if (member(field, "values")) |values| {
            if (kind != .enumeration or values != .array or values.array.items.len == 0) return error.InvalidFieldDefinition;
            for (values.array.items, 0..) |value, value_index| {
                if (value != .string) return error.InvalidFieldDefinition;
                for (values.array.items[0..value_index]) |prior| {
                    if (std.mem.eql(u8, value.string, prior.string)) return error.InvalidFieldDefinition;
                }
            }
        } else if (kind == .enumeration) {
            return error.InvalidFieldDefinition;
        }

        const minimum = member(field, "minimum");
        const maximum = member(field, "maximum");
        if (minimum != null or maximum != null) {
            if (kind != .integer and kind != .number) return error.InvalidFieldDefinition;
            if (kind == .integer) {
                if (minimum) |value| if (integerValue(value) == null) return error.InvalidFieldDefinition;
                if (maximum) |value| if (integerValue(value) == null) return error.InvalidFieldDefinition;
            } else {
                if (minimum) |value| if (numberValue(value) == null) return error.InvalidFieldDefinition;
                if (maximum) |value| if (numberValue(value) == null) return error.InvalidFieldDefinition;
            }
            if (minimum) |low| if (maximum) |high| {
                if (numberValue(low).? > numberValue(high).?) return error.InvalidFieldDefinition;
            };
        }

        const min_length = member(field, "minLength");
        const max_length = member(field, "maxLength");
        if (min_length != null or max_length != null) {
            if (kind != .string) return error.InvalidFieldDefinition;
            if (min_length) |value| if (integerValue(value) == null or integerValue(value).? < 0) return error.InvalidFieldDefinition;
            if (max_length) |value| if (integerValue(value) == null or integerValue(value).? < 0) return error.InvalidFieldDefinition;
            if (min_length) |low| if (max_length) |high| {
                if (integerValue(low).? > integerValue(high).?) return error.InvalidFieldDefinition;
            };
        }

        if (kind == .secret_ref and visibility != .secret) return error.InvalidFieldDefinition;
    }
}

fn validateObjectAgainstFields(fields: JsonValue, value: JsonValue) !void {
    if (fields != .array or value != .object) return error.InvalidConfiguration;

    var value_iterator = value.object.iterator();
    while (value_iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const field = findField(fields, key) orelse return error.UnknownConfigurationField;
        try validateFieldValue(field, entry.value_ptr.*);
    }

    for (fields.array.items) |field| {
        const key = stringMember(field, "key") orelse return error.InvalidFieldDefinition;
        const required = member(field, "required") orelse return error.InvalidFieldDefinition;
        if (required.bool and member(value, key) == null) return error.MissingRequiredField;
    }
}

fn validateFieldValue(field: JsonValue, value: JsonValue) !void {
    const kind_text = stringMember(field, "type") orelse return error.InvalidFieldDefinition;
    const kind = parseFieldKind(kind_text) orelse return error.InvalidFieldDefinition;
    switch (kind) {
        .string => {
            if (value != .string) return error.TypeMismatch;
            try validateStringLength(field, value.string);
        },
        .enumeration => {
            if (value != .string) return error.TypeMismatch;
            const values = member(field, "values") orelse return error.InvalidFieldDefinition;
            var found = false;
            for (values.array.items) |allowed| {
                if (std.mem.eql(u8, value.string, allowed.string)) found = true;
            }
            if (!found) return error.InvalidValue;
        },
        .integer => {
            const actual = integerValue(value) orelse return error.TypeMismatch;
            if (member(field, "minimum")) |minimum| if (actual < integerValue(minimum).?) return error.ValueOutOfRange;
            if (member(field, "maximum")) |maximum| if (actual > integerValue(maximum).?) return error.ValueOutOfRange;
        },
        .number => {
            const actual = numberValue(value) orelse return error.TypeMismatch;
            if (member(field, "minimum")) |minimum| if (actual < numberValue(minimum).?) return error.ValueOutOfRange;
            if (member(field, "maximum")) |maximum| if (actual > numberValue(maximum).?) return error.ValueOutOfRange;
        },
        .boolean => if (value != .bool) return error.TypeMismatch,
        .secret_ref => try validateSecretReference(value),
    }
}

fn validateSecretReference(value: JsonValue) !void {
    if (value != .object or value.object.count() != 2) return error.InvalidValue;
    const provider = stringMember(value, "provider") orelse return error.InvalidValue;
    const identifier = stringMember(value, "id") orelse return error.InvalidValue;
    if (provider.len == 0 or identifier.len == 0) return error.InvalidValue;
    try requireOnlyKeys(value, &.{ "provider", "id" });
}

fn validateStringLength(field: JsonValue, value: []const u8) !void {
    const length = std.unicode.utf8CountCodepoints(value) catch return error.InvalidValue;
    if (member(field, "minLength")) |minimum| {
        if (length < @as(usize, @intCast(integerValue(minimum).?))) return error.ValueOutOfRange;
    }
    if (member(field, "maxLength")) |maximum| {
        if (length > @as(usize, @intCast(integerValue(maximum).?))) return error.ValueOutOfRange;
    }
}

fn findField(fields: JsonValue, key: []const u8) ?JsonValue {
    if (fields != .array) return null;
    for (fields.array.items) |field| {
        const field_key = stringMember(field, "key") orelse continue;
        if (std.mem.eql(u8, field_key, key)) return field;
    }
    return null;
}

fn findCapability(root: JsonValue, capability_id: []const u8) ?JsonValue {
    const capabilities = member(root, "capabilities") orelse return null;
    if (capabilities != .array) return null;
    for (capabilities.array.items) |capability| {
        const id = stringMember(capability, "id") orelse continue;
        if (std.mem.eql(u8, id, capability_id)) return capability;
    }
    return null;
}

fn profileId(root: JsonValue) ?[]const u8 {
    const profile = member(root, "profile") orelse return null;
    return stringMember(profile, "id");
}

fn member(value: JsonValue, key: []const u8) ?JsonValue {
    if (value != .object) return null;
    return value.object.get(key);
}

fn requiredMember(value: JsonValue, key: []const u8) !JsonValue {
    return member(value, key) orelse error.MissingMember;
}

fn stringMember(value: JsonValue, key: []const u8) ?[]const u8 {
    const found = member(value, key) orelse return null;
    if (found != .string) return null;
    return found.string;
}

fn requireOnlyKeys(value: JsonValue, allowed: []const []const u8) !void {
    if (value != .object) return error.InvalidProfileDescriptor;
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        var found = false;
        for (allowed) |key| {
            if (std.mem.eql(u8, entry.key_ptr.*, key)) found = true;
        }
        if (!found) return error.UnknownDescriptorField;
    }
}

fn parseFieldKind(value: []const u8) ?FieldKind {
    if (std.mem.eql(u8, value, "string")) return .string;
    if (std.mem.eql(u8, value, "integer")) return .integer;
    if (std.mem.eql(u8, value, "number")) return .number;
    if (std.mem.eql(u8, value, "boolean")) return .boolean;
    if (std.mem.eql(u8, value, "enum")) return .enumeration;
    if (std.mem.eql(u8, value, "secret-ref")) return .secret_ref;
    return null;
}

fn parseVisibility(value: []const u8) ?Visibility {
    if (std.mem.eql(u8, value, "player")) return .player;
    if (std.mem.eql(u8, value, "operator")) return .operator;
    if (std.mem.eql(u8, value, "secret")) return .secret;
    return null;
}

fn isVisible(visibility: Visibility, audience: Audience) bool {
    return switch (audience) {
        .player => visibility == .player,
        .operator => visibility == .player or visibility == .operator,
    };
}

fn integerValue(value: JsonValue) ?i64 {
    return switch (value) {
        .integer => |integer| integer,
        .float => |number| blk: {
            if (!std.math.isFinite(number) or @trunc(number) != number or
                number < -9223372036854775808.0 or number >= 9223372036854775808.0) break :blk null;
            break :blk @intFromFloat(number);
        },
        else => null,
    };
}

fn numberValue(value: JsonValue) ?f64 {
    const number = switch (value) {
        .integer => |integer| @as(f64, @floatFromInt(integer)),
        .float => |number| number,
        else => return null,
    };
    if (!std.math.isFinite(number)) return null;
    return number;
}

fn copyVisibleValue(allocator: Allocator, kind: FieldKind, value: JsonValue) !VisibleValue {
    return switch (kind) {
        .integer => .{ .integer = integerValue(value) orelse return error.UnsupportedVisibleValue },
        .number => .{ .number = numberValue(value) orelse return error.UnsupportedVisibleValue },
        .string, .enumeration => .{ .string = try allocator.dupe(u8, value.string) },
        .boolean => .{ .boolean = value.bool },
        .secret_ref => error.UnsupportedVisibleValue,
    };
}

fn isProfileId(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphanumeric(value[0])) return false;
    for (value[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') return false;
    }
    return true;
}

fn isFieldKey(value: []const u8) bool {
    if (value.len == 0 or value.len > 128 or !std.ascii.isAlphabetic(value[0])) return false;
    for (value[1..]) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '.' and char != '-') return false;
    }
    return true;
}

const SOP_PROFILE = @embedFile("../../../../fixtures/standard-operating-psychopathy/profile.v0.1.json");
const SOP_CONFIG = @embedFile("../../../../fixtures/standard-operating-psychopathy/config.sample.fixture.json");
const SOP_STATUS = @embedFile("../../../../fixtures/standard-operating-psychopathy/session-summary.fixture.json");

fn testConfig(
    allocator: Allocator,
    mode: []const u8,
    capacity: i64,
    pacing: []const u8,
    world_policy_id: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"mode\":\"{s}\",\"player_capacity\":{d},\"pacing\":\"{s}\",\"signal_binding\":\"non-binding\",\"commitment_mode\":\"simultaneous-hidden\",\"deadline_policy_id\":\"fixture.deadline.unresolved\",\"world_advance_policy_id\":\"{s}\",\"no_response_fallback_id\":\"fixture.no-response.unresolved\",\"disconnect_fallback_id\":\"fixture.disconnect.unresolved\"}}",
        .{ mode, capacity, pacing, world_policy_id },
    );
}

test "SOP profile and sample configuration validate as a fixture" {
    const allocator = std.testing.allocator;
    var profile = try parseProfile(allocator, SOP_PROFILE);
    defer profile.deinit();
    try validateFixtureConfiguration(allocator, &profile, SOP_CONFIG);
}

test "configuration validation covers supplied combinations, opaque policies, and optional UMS references" {
    const allocator = std.testing.allocator;
    var profile = try parseProfile(allocator, SOP_PROFILE);
    defer profile.deinit();

    const combinations = [_]struct { mode: []const u8, capacity: i64, pacing: []const u8, world_policy_id: []const u8 }{
        .{ .mode = "co-op", .capacity = 4, .pacing = "continuous", .world_policy_id = "fixture.world-advance.policy-a" },
        .{ .mode = "competitive", .capacity = 5, .pacing = "hybrid", .world_policy_id = "fixture.world-advance.policy-b" },
        .{ .mode = "co-opetitive", .capacity = 6, .pacing = "hybrid", .world_policy_id = "fixture.world-advance.policy-c" },
        .{ .mode = "co-op", .capacity = 4, .pacing = "continuous", .world_policy_id = "fixture.world-advance.policy-d" },
    };
    for (combinations) |combination| {
        const config = try testConfig(allocator, combination.mode, combination.capacity, combination.pacing, combination.world_policy_id);
        defer allocator.free(config);
        try validateConfiguration(allocator, &profile, config);
    }
}

test "configuration validator rejects out-of-range, unknown, missing, and mistyped values" {
    const allocator = std.testing.allocator;
    var profile = try parseProfile(allocator, SOP_PROFILE);
    defer profile.deinit();

    const too_few = try testConfig(allocator, "co-op", 3, "continuous", "fixture.world-advance.test");
    defer allocator.free(too_few);
    try std.testing.expectError(error.ValueOutOfRange, validateConfiguration(allocator, &profile, too_few));

    const too_many = try testConfig(allocator, "co-op", 7, "continuous", "fixture.world-advance.test");
    defer allocator.free(too_many);
    try std.testing.expectError(error.ValueOutOfRange, validateConfiguration(allocator, &profile, too_many));

    const bad_mode = try testConfig(allocator, "unknown-mode", 4, "continuous", "fixture.world-advance.test");
    defer allocator.free(bad_mode);
    try std.testing.expectError(error.InvalidValue, validateConfiguration(allocator, &profile, bad_mode));

    try std.testing.expectError(error.UnknownConfigurationField, validateConfiguration(allocator, &profile, "{\"unexpected\":true}"));
    try std.testing.expectError(error.MissingRequiredField, validateConfiguration(allocator, &profile, "{\"mode\":\"co-op\"}"));
    try std.testing.expectError(error.TypeMismatch, validateConfiguration(allocator, &profile, "{\"mode\":\"co-op\",\"player_capacity\":\"4\"}"));
}

test "fixture status projection is audience-filtered and explicitly disconnected" {
    const allocator = std.testing.allocator;
    var profile = try parseProfile(allocator, SOP_PROFILE);
    defer profile.deinit();

    var operator_view = try projectFixtureStatus(allocator, &profile, SOP_STATUS, .operator);
    defer operator_view.deinit();
    try std.testing.expectEqualStrings("fixture", operator_view.source);
    try std.testing.expect(!operator_view.connected);
    try std.testing.expectEqualStrings("standard-operating-psychopathy", operator_view.profile_id);
    try std.testing.expectEqual(@as(usize, 6), operator_view.fields.len);

    var player_view = try projectFixtureStatus(allocator, &profile, SOP_STATUS, .player);
    defer player_view.deinit();
    try std.testing.expectEqual(@as(usize, 1), player_view.fields.len);
    try std.testing.expectEqualStrings("package_version", player_view.fields[0].key);

    const phase_absent =
        "{\"source\":\"fixture\",\"connected\":false,\"capability_id\":\"gsa.session-summary\",\"capability_version\":\"0.1.0-draft\",\"data\":{\"player_count\":4}}";
    var no_phase_view = try projectFixtureStatus(allocator, &profile, phase_absent, .operator);
    defer no_phase_view.deinit();
    try std.testing.expectEqual(@as(usize, 1), no_phase_view.fields.len);
    try std.testing.expectEqualStrings("player_count", no_phase_view.fields[0].key);

    const wrong_version =
        "{\"source\":\"fixture\",\"connected\":false,\"capability_id\":\"gsa.session-summary\",\"capability_version\":\"9.9.9\",\"data\":{}}";
    try std.testing.expectError(error.CapabilityVersionMismatch, projectFixtureStatus(allocator, &profile, wrong_version, .operator));
}

test "secret session values are not copied into either status audience" {
    const allocator = std.testing.allocator;
    const secret_profile_json =
        "{\"contract\":{\"name\":\"gsa.game-profile\",\"version\":\"0.1.0-draft\"}," ++
        "\"profile\":{\"id\":\"privacy-test\",\"name\":\"Privacy test\",\"kind\":\"test-fixture\"}," ++
        "\"configuration\":{\"version\":\"0.1.0-draft\",\"fields\":[]}," ++
        "\"capabilities\":[{\"id\":\"gsa.session-summary\",\"version\":\"0.1.0-draft\",\"fields\":[" ++
        "{\"key\":\"player_count\",\"type\":\"integer\",\"required\":false,\"visibility\":\"operator\",\"minimum\":0}," ++
        "{\"key\":\"hidden_order_payload\",\"type\":\"string\",\"required\":false,\"visibility\":\"secret\"}]}]}";
    const secret_status =
        "{\"source\":\"fixture\",\"connected\":false,\"capability_id\":\"gsa.session-summary\",\"capability_version\":\"0.1.0-draft\"," ++
        "\"data\":{\"player_count\":4,\"hidden_order_payload\":\"redaction-canary-not-for-output\"}}";

    var profile = try parseProfile(allocator, secret_profile_json);
    defer profile.deinit();
    var view = try projectFixtureStatus(allocator, &profile, secret_status, .operator);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 1), view.fields.len);
    try std.testing.expectEqualStrings("player_count", view.fields[0].key);
    try std.testing.expect(view.fields[0].value == .integer);
    try std.testing.expectEqual(@as(i64, 4), view.fields[0].value.integer);

    var player_view = try projectFixtureStatus(allocator, &profile, secret_status, .player);
    defer player_view.deinit();
    try std.testing.expectEqual(@as(usize, 0), player_view.fields.len);
}

test "unknown versioned capabilities remain optional and generically validated" {
    const allocator = std.testing.allocator;
    const descriptor =
        "{\"contract\":{\"name\":\"gsa.game-profile\",\"version\":\"0.1.0-draft\"}," ++
        "\"profile\":{\"id\":\"extension-test\",\"name\":\"Extension test\",\"kind\":\"test-fixture\"}," ++
        "\"configuration\":{\"version\":\"0.1.0-draft\",\"fields\":[]}," ++
        "\"capabilities\":[{\"id\":\"vendor.example.future-capability\",\"version\":\"9.7.3\",\"fields\":[" ++
        "{\"key\":\"opaque_count\",\"type\":\"integer\",\"required\":false,\"visibility\":\"operator\",\"minimum\":0}]}]}";
    const fixture =
        "{\"source\":\"fixture\",\"connected\":false,\"capability_id\":\"vendor.example.future-capability\",\"capability_version\":\"9.7.3\",\"data\":{\"opaque_count\":2}}";

    var profile = try parseProfile(allocator, descriptor);
    defer profile.deinit();
    try validateConfiguration(allocator, &profile, "{}");
    var view = try projectFixtureStatus(allocator, &profile, fixture, .operator);
    defer view.deinit();
    try std.testing.expectEqualStrings("vendor.example.future-capability", view.capability_id);
    try std.testing.expectEqual(@as(usize, 1), view.fields.len);

    const no_capabilities =
        "{\"contract\":{\"name\":\"gsa.game-profile\",\"version\":\"0.1.0-draft\"}," ++
        "\"profile\":{\"id\":\"no-capability\",\"name\":\"No capability\",\"kind\":\"test-fixture\"}," ++
        "\"configuration\":{\"version\":\"0.1.0-draft\",\"fields\":[]}}";
    var basic_profile = try parseProfile(allocator, no_capabilities);
    defer basic_profile.deinit();
    try std.testing.expectError(error.CapabilityNotAdvertised, projectFixtureStatus(allocator, &basic_profile, fixture, .operator));
}

test "secret references are opaque and never accept raw values" {
    const allocator = std.testing.allocator;
    const descriptor =
        "{\"contract\":{\"name\":\"gsa.game-profile\",\"version\":\"0.1.0-draft\"}," ++
        "\"profile\":{\"id\":\"secret-ref-test\",\"name\":\"Secret ref test\",\"kind\":\"test-fixture\"}," ++
        "\"configuration\":{\"version\":\"0.1.0-draft\",\"fields\":[" ++
        "{\"key\":\"admin_secret_ref\",\"type\":\"secret-ref\",\"required\":true,\"visibility\":\"secret\"}]}}";
    var profile = try parseProfile(allocator, descriptor);
    defer profile.deinit();

    try validateConfiguration(allocator, &profile, "{\"admin_secret_ref\":{\"provider\":\"fixture-vault\",\"id\":\"sop/admin\"}}");
    try std.testing.expectError(error.InvalidValue, validateConfiguration(allocator, &profile, "{\"admin_secret_ref\":\"not-a-secret-reference\"}"));
    try std.testing.expectError(error.InvalidValue, validateConfiguration(allocator, &profile, "{\"admin_secret_ref\":{\"provider\":\"fixture-vault\",\"id\":\"sop/admin\",\"value\":\"must-not-be-inline\"}}"));
}

test "integer fields accept integral JSON numbers and reject fractional values" {
    const allocator = std.testing.allocator;
    const descriptor =
        "{\"contract\":{\"name\":\"gsa.game-profile\",\"version\":\"0.1.0-draft\"}," ++
        "\"profile\":{\"id\":\"integer-test\",\"name\":\"Integer test\",\"kind\":\"test-fixture\"}," ++
        "\"configuration\":{\"version\":\"0.1.0-draft\",\"fields\":[" ++
        "{\"key\":\"capacity\",\"type\":\"integer\",\"required\":true,\"visibility\":\"operator\",\"minimum\":4,\"maximum\":6}]}}";
    var profile = try parseProfile(allocator, descriptor);
    defer profile.deinit();

    try validateConfiguration(allocator, &profile, "{\"capacity\":4.0}");
    try std.testing.expectError(error.TypeMismatch, validateConfiguration(allocator, &profile, "{\"capacity\":4.5}"));
}

test "fixture projector rejects connected or non-fixture status payloads" {
    const allocator = std.testing.allocator;
    var profile = try parseProfile(allocator, SOP_PROFILE);
    defer profile.deinit();

    const live_payload =
        "{\"source\":\"adapter\",\"connected\":true,\"capability_id\":\"gsa.session-summary\",\"capability_version\":\"0.1.0-draft\",\"data\":{}}";
    try std.testing.expectError(error.NotFixtureStatus, projectFixtureStatus(allocator, &profile, live_payload, .operator));
}
