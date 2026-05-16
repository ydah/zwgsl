const std = @import("std");
const zwgsl = @import("zwgsl");

test "lexer fuzz smoke handles generated ASCII inputs" {
    var prng = std.Random.DefaultPrng.init(0x7a7767736c);
    const random = prng.random();
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_():,.\n +-*/=#\"";

    var buffer: [256]u8 = undefined;
    for (0..128) |_| {
        const len = random.intRangeLessThan(usize, 0, buffer.len);
        for (buffer[0..len]) |*byte| {
            byte.* = alphabet[random.intRangeLessThan(usize, 0, alphabet.len)];
        }

        const tokens = try zwgsl.lexer.Lexer.tokenize(std.testing.allocator, buffer[0..len]);
        defer std.testing.allocator.free(tokens);

        try std.testing.expect(tokens.len > 0);
        try std.testing.expectEqual(zwgsl.token.TokenTag.eof, tokens[tokens.len - 1].tag);
    }
}
