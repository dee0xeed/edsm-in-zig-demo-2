
pub fn opaqPtrTo(ptr: ?*anyopaque, comptime T: type) T {
    return @ptrCast(@alignCast(ptr));
}
