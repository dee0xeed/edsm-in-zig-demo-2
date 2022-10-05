
const NeedMoreData = *const fn(buf: []u8) bool;

pub const IoContext = struct {
    fd: i32,
    buf: []u8,
    cnt: usize,
    needMore: NeedMoreData,
    timeout: u32,
};
