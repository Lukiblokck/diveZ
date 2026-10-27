//! Text zoom steps (Ctrl and +, -, 0). Pure, so the limits can be tested.
const std = @import("std");

pub const min: f32 = 0.8;
pub const max: f32 = 2.0;
const step: f32 = 0.1;

fn clampRound(z: f32) f32 {
    return std.math.clamp(@round(z * 10) / 10, min, max);
}

pub fn larger(z: f32) f32 {
    return clampRound(z + step);
}

pub fn smaller(z: f32) f32 {
    return clampRound(z - step);
}

test "zoom steps stay inside the limits and do not drift" {
    try std.testing.expectEqual(@as(f32, 1.1), larger(1.0));
    try std.testing.expectEqual(@as(f32, 0.9), smaller(1.0));
    var z: f32 = 1.0;
    for (0..50) |_| z = larger(z);
    try std.testing.expectEqual(max, z);
    for (0..50) |_| z = smaller(z);
    try std.testing.expectEqual(min, z);
    z = 1.0;
    for (0..10) |_| z = larger(z);
    try std.testing.expectEqual(@as(f32, 2.0), z); // ten steps, no accumulated float error
}
