//! Small compatibility helpers.
//!
//! Zig 0.17 turned `std.ArrayList` into an unmanaged type and reworked
//! `std.Io.Writer`. These wrappers keep call sites stable so that only
//! `util.zig` and `sys.zig` need touching on future toolchain bumps.

const std = @import("std");

pub fn List(comptime T: type) type {
    return struct {
        const Self = @This();

        inner: std.ArrayList(T) = .empty,
        gpa: std.mem.Allocator,

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn items(self: *const Self) []T {
            return self.inner.items;
        }

        pub fn deinit(self: *Self) void {
            self.inner.deinit(self.gpa);
            self.* = undefined;
        }

        pub fn append(self: *Self, item: T) !void {
            try self.inner.append(self.gpa, item);
        }

        pub fn appendSlice(self: *Self, slice: []const T) !void {
            try self.inner.appendSlice(self.gpa, slice);
        }

        pub fn appendFmt(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            if (T != u8) @compileError("appendFmt requires List(u8)");
            const tmp = try std.fmt.allocPrint(self.gpa, fmt, args);
            defer self.gpa.free(tmp);
            try self.inner.appendSlice(self.gpa, tmp);
        }

        pub fn toOwnedSlice(self: *Self) ![]T {
            return self.inner.toOwnedSlice(self.gpa);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.inner.clearRetainingCapacity();
        }
    };
}

/// Allocates a NUL-terminated copy of a formatted string.
pub fn allocPrintZ(gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![:0]u8 {
    return gpa.printSentinel(fmt, args, 0);
}

/// A small futex-backed mutex.
///
/// `std.Io.Mutex` requires an `Io` instance and `std.Thread.Mutex` no longer
/// exists in Zig 0.17; this keeps the socket-write lock out of the `std.Io`
/// migration path. Never spins on a blocked writer.
pub const Mutex = struct {
    state: std.atomic.Value(u32) = std.atomic.Value(u32).init(unlocked),

    const unlocked: u32 = 0;
    const locked_once: u32 = 1;
    const contended: u32 = 2;

    const linux = std.os.linux;
    const wait_op: linux.FUTEX_OP = .{ .cmd = .WAIT, .private = true };
    const wake_op: linux.FUTEX_OP = .{ .cmd = .WAKE, .private = true };

    pub fn lock(self: *Mutex) void {
        if (self.state.cmpxchgStrong(unlocked, locked_once, .acquire, .monotonic) == null) return;
        while (self.state.swap(contended, .acquire) != unlocked) {
            _ = linux.futex_4arg(@ptrCast(&self.state), wait_op, contended, null);
        }
    }

    pub fn unlock(self: *Mutex) void {
        if (self.state.swap(unlocked, .release) == contended) {
            _ = linux.futex_3arg(@ptrCast(&self.state), wake_op, 1);
        }
    }
};
