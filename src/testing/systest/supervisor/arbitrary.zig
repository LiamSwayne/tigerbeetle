const std = @import("std");

const assert = std.debug.assert;

/// Draw an enum value from `E` based on the relative `weights`. Fields in the weights struct must
/// match the enum.
///
/// The `E` type parameter should be inferred, but seemingly to due to
/// https://github.com/ziglang/zig/issues/19985, it can't be.
pub fn weighted(
    random: std.rand.Random,
    comptime E: type,
    weights: EnumWeights(E),
) ?E {
    const s = @typeInfo(@TypeOf(weights)).Struct;
    var total: u64 = 0;
    var enum_weights: [s.fields.len]std.meta.Tuple(&.{ E, u32 }) = undefined;
    var possible_values_count: usize = 0;

    inline for (s.fields) |field| {
        const weight = @field(weights, field.name);
        if (weight > 0) {
            total += weight;
            const value = std.meta.stringToEnum(E, field.name).?;
            enum_weights[possible_values_count] = .{ value, weight };
            possible_values_count += 1;
        }
    }

    // In case of no weights, or all weights being zero, we can't pick any value.
    if (enum_weights.len == 0) {
        return null;
    }

    assert(total > 0);
    assert(possible_values_count > 0);

    const pick = random.uintLessThan(u64, total) + 1;
    var current: u64 = 0;
    for (enum_weights[0..possible_values_count]) |w| {
        current += w[1];
        if (pick <= current) {
            return w[0];
        }
    }

    unreachable;
}

/// Given an enum type, returns a struct type where each field is an enum value mapped to an u32
/// weight. Used together with `weighted`.
pub fn EnumWeights(comptime E: type) type {
    return std.enums.EnumFieldStruct(E, u32, null);
}
