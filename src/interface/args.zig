const std = @import("std");

pub const Option = struct {
    spelling: [:0]const u8,
    values: []const [:0]const u8,
};

pub const Invocation = struct {
    command: []const u8 = "",
    arguments: []const [:0]const u8 = &.{},
    options: []const Option = &.{},

    pub fn hasOption(self: Invocation, spelling: []const u8) bool {
        for (self.options) |option| {
            if (std.mem.eql(u8, option.spelling, spelling))
                return true;
        }

        return false;
    }

    pub fn optionWordsExcept(self: Invocation, allocator: std.mem.Allocator, excluded: []const []const u8) ![]const [:0]const u8 {
        var words: std.ArrayList([:0]const u8) = .empty;

        for (self.options) |option| {
            var skip = false;

            for (excluded) |spelling| {
                if (std.mem.eql(u8, option.spelling, spelling)) {
                    skip = true;
                    break;
                }
            }

            if (skip)
                continue;

            try words.append(allocator, option.spelling);
            try words.appendSlice(allocator, option.values);
        }
        return words.items;
    }
};

pub fn parse(allocator: std.mem.Allocator, process_args: std.process.Args) !Invocation {
    const argv = try process_args.toSlice(allocator);

    return try group(allocator, if (argv.len > 0) argv[1..] else argv);
}

pub fn is(word: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, word, expected);
}

pub fn isOption(word: []const u8) bool {
    return word.len > 1 and word[0] == '-' and !(word[1] >= '0' and word[1] <= '9') and
        !(word[1] == '.' and word.len > 2 and word[2] >= '0' and word[2] <= '9');
}

pub fn group(allocator: std.mem.Allocator, words: []const [:0]const u8) !Invocation {
    if (words.len == 0)
        return .{};

    var arguments: std.ArrayList([:0]const u8) = .empty;
    var options: std.ArrayList(Option) = .empty;
    errdefer arguments.deinit(allocator);
    errdefer options.deinit(allocator);

    var grouping = true;
    var i: usize = 1;

    while (i < words.len) {
        const word = words[i];

        if (grouping and is(word, "--")) {
            grouping = false;
            i += 1;
        } else if (grouping and isOption(word)) {
            const start = i + 1;

            i = start;

            while (i < words.len and !isOption(words[i])) : (i += 1) {}

            try options.append(allocator, .{ .spelling = word, .values = words[start..i] });
        } else {
            try arguments.append(allocator, word);
            i += 1;
        }
    }
    return .{ .command = words[0], .arguments = arguments.items, .options = options.items };
}

test "syntax grouping preserves unknown names duplicate options negative values and tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const words = [_][:0]const u8{ "unknown", "device", "--foo", "-2", "-.5", "--foo", "value", "-h" };
    const inv = try group(arena.allocator(), &words);

    try std.testing.expectEqualStrings("unknown", inv.command);
    try std.testing.expectEqualStrings("device", inv.arguments[0]);
    try std.testing.expectEqual(@as(usize, 3), inv.options.len);
    try std.testing.expectEqualStrings("-2", inv.options[0].values[0]);
    try std.testing.expectEqualStrings("-.5", inv.options[0].values[1]);
    try std.testing.expect(inv.options[1].values[0].ptr == words[6].ptr);
    try std.testing.expectEqual(@as(usize, 0), inv.options[2].values.len);
}

test "terminator is discarded and all following words are literal positionals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const inv = try group(arena.allocator(), &.{ "__complete", "--", "set", "--eff" });

    try std.testing.expectEqual(@as(usize, 0), inv.options.len);
    try std.testing.expectEqualStrings("set", inv.arguments[0]);
    try std.testing.expectEqualStrings("--eff", inv.arguments[1]);
    const set = try group(arena.allocator(), &.{ "set", "--effect", "static", "--", "--tone", "warm" });

    try std.testing.expectEqual(@as(usize, 1), set.options.len);
    try std.testing.expectEqualStrings("static", set.options[0].values[0]);
    try std.testing.expectEqualStrings("--tone", set.arguments[0]);
    try std.testing.expectEqualStrings("warm", set.arguments[1]);
}

test "option words preserve grouped values while excluding command options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const inv = try group(allocator, &.{ "set", "--effect", "static", "--tone", "warm", "--save", "--brightness", "20" });
    const words = try inv.optionWordsExcept(allocator, &.{"--save"});
    const expected = [_][]const u8{ "--effect", "static", "--tone", "warm", "--brightness", "20" };

    try std.testing.expectEqual(expected.len, words.len);

    for (expected, words) |want, got|
        try std.testing.expectEqualStrings(want, got);
}
