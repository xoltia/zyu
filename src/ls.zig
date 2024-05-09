const std = @import("std");
const builtin = @import("builtin");

const USAGE =
    \\Usage: {s} [OPTION]... [FILE]...
    \\List information about the FILEs (the current directory by default).
    \\  -a, --all                  do not ignore entries starting with .
    \\  -C                         list entries by columns
    \\  -R, --recursive            list subdirectories recursively
    \\      --help                 display this help and exit
    \\      --version              output version information and exit
;

fn MinHeap(comptime T: type) type {
    return struct {
        data: []T,
        size: usize = 0,
        less: LessFn,
        allocator: std.mem.Allocator,

        const Self = @This();
        const LessFn = *const fn (a: T, b: T) bool;

        fn initCapacity(allocator: std.mem.Allocator, less: LessFn, capacity: usize) !Self {
            return .{
                .data = try allocator.alloc(T, capacity),
                .less = less,
                .allocator = allocator,
            };
        }

        fn init(allocator: std.mem.Allocator, less: LessFn) !Self {
            return .{
                .data = try allocator.alloc(T, 16),
                .less = less,
                .allocator = allocator,
            };
        }

        fn deinit(self: *Self) void {
            self.allocator.free(self.data);
        }

        inline fn parent(i: usize) usize {
            return (i - 1) / 2;
        }

        inline fn left(i: usize) usize {
            return 2 * i + 1;
        }

        inline fn right(i: usize) usize {
            return 2 * i + 2;
        }

        fn insert(self: *Self, value: T) !void {
            if (self.size == self.data.len) {
                self.data = try self.allocator.realloc(self.data, self.data.len * 2);
            }

            var i = self.size;
            self.size += 1;
            self.data[i] = value;

            while (i != 0 and self.less(self.data[i], self.data[parent(i)])) {
                const tmp = self.data[parent(i)];
                self.data[parent(i)] = self.data[i];
                self.data[i] = tmp;
                i = parent(i);
            }
        }

        fn pop(self: *Self) ?T {
            if (self.size == 0) {
                return null;
            }

            const popped = self.data[0];
            self.size -= 1;
            self.data[0] = self.data[self.size];
            self.heapify(0);
            return popped;
        }

        fn heapify(self: *Self, i: usize) void {
            if (self.size <= 1) {
                return;
            }

            const l = left(i);
            const r = right(i);
            var smallest = i;

            if (l < self.size and self.less(self.data[l], self.data[i])) {
                smallest = l;
            }

            if (r < self.size and self.less(self.data[r], self.data[smallest])) {
                smallest = r;
            }

            if (smallest != i) {
                const tmp = self.data[i];
                self.data[i] = self.data[smallest];
                self.data[smallest] = tmp;
                self.heapify(smallest);
            }
        }
    };
}

const VERSION = "0.1.0";

const DirName = struct {
    name: []const u8,
    owned: bool = false,

    fn less(a: DirName, b: DirName) bool {
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

const DirHeap = MinHeap(DirName);

const ListFilesOptions = struct {
    recurse: bool = false,
    columns: bool = false,
    show_hidden: bool = false,
};

var console_size: ?usize = null;

fn consoleSize() usize {
    const default_size = 80;
    if (console_size != null)
        return console_size.?;

    if (builtin.os.tag != .linux) {
        console_size = default_size;
        return default_size;
    }

    var winsize = std.mem.zeroes(std.os.linux.winsize);
    if (std.os.linux.ioctl(0, 21523, @intFromPtr(&winsize)) != 0) {
        console_size = default_size;
        return default_size;
    }

    console_size = winsize.ws_col;
    return winsize.ws_col;
}

fn determineColumnSize(entries: []const []const u8) usize {
    var max_len: usize = 0;
    for (entries) |entry| {
        if (entry.len > max_len) {
            max_len = entry.len;
        }
    }

    return max_len;
}

fn printColumns(writer: std.io.AnyWriter, entries: []const []const u8) !void {
    const console_width = consoleSize();

    var fits_in_one_line = false;
    var total_len: usize = 0;
    for (entries) |entry| {
        total_len += entry.len + 2;
    }

    if (total_len <= console_width) {
        fits_in_one_line = true;
    }

    if (fits_in_one_line) {
        for (entries) |entry| {
            try writer.print("{s}  ", .{entry});
        }
        if (entries.len != 0) {
            try writer.print("\n", .{});
        }
        return;
    }

    const column_width = determineColumnSize(entries) + 2;
    const columns = console_width / column_width;

    var column_count: usize = 0;
    for (entries) |entry| {
        if (column_count == columns) {
            try writer.print("\n", .{});
            column_count = 0;
        }

        try writer.print("{s}", .{entry});
        try writer.writeByteNTimes(' ', column_width - entry.len + 1);
        column_count += 1;
    }

    if (column_count != 0) {
        try writer.print("\n", .{});
    }
}

fn fileNameCmp(_: @TypeOf(.{}), a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn listFiles(
    allocator: std.mem.Allocator,
    writer: std.io.AnyWriter,
    dir_name: []const u8,
    dirs: *DirHeap,
    options: ListFilesOptions,
) !void {
    var dir = try std.fs.cwd().openDir(dir_name, .{ .iterate = true });
    var dir_iter = dir.iterate();
    defer dir.close();

    var entries = std.ArrayListUnmanaged([]const u8){};
    defer {
        const allocated = if (options.show_hidden)
            entries.items[2..]
        else
            entries.items;

        for (allocated) |entry| {
            allocator.free(entry);
        }

        entries.deinit(allocator);
    }

    if (options.show_hidden) {
        try entries.append(allocator, ".");
        try entries.append(allocator, "..");
    }

    while (try dir_iter.next()) |entry| {
        if (!options.show_hidden and entry.name[0] == '.')
            continue;
        const name_copy = try allocator.alloc(u8, entry.name.len);

        std.mem.copyForwards(u8, name_copy, entry.name);
        try entries.append(allocator, name_copy);
        if (options.recurse and entry.kind == .directory) {
            //const full_path = try allocator.alloc(u8, dir_name.len + 1 + entry.name.len);
            // std.mem.copyForwards(u8, full_path, dir_name);
            // full_path[dir_name.len] = '/';
            // std.mem.copyForwards(u8, full_path[dir_name.len + 1 ..], entry.name);
            const full_path = try std.fs.path.join(allocator, &[2][]const u8{ dir_name, entry.name });
            try dirs.insert(.{ .name = full_path, .owned = true });
        }
    }

    //std.sort.heap([]const u8, entries.items, .{}, fileNameCmp);

    if (options.columns) {
        try printColumns(writer, entries.items);
    } else {
        for (entries.items) |entry| {
            try writer.print("{s}\n", .{entry});
        }
    }
}

pub fn printDirs(
    allocator: std.mem.Allocator,
    writer: std.io.AnyWriter,
    dirs: *DirHeap,
    options: ListFilesOptions,
) !void {
    // not recursive and only one directory, so
    // we can print the directory name
    if (!options.recurse and dirs.size == 1) {
        const dir = dirs.data[0];
        return listFiles(allocator, writer, dir.name, dirs, options);
    }

    while (dirs.pop()) |dir| {
        try writer.print("{s}:\n", .{dir.name});
        try listFiles(allocator, writer, dir.name, dirs, options);
        if (dirs.size != 0) {
            try writer.print("\n", .{});
        }
        // indicates the string was created within this function
        if (dir.owned) {
            allocator.free(dir.name);
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    //const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const stdout = std.io.getStdOut().writer().any();
    const stderr = std.io.getStdErr().writer().any();

    var options = ListFilesOptions{};

    if (std.io.getStdOut().isTty()) {
        options.columns = true;
    }

    var dirs = try DirHeap.init(allocator, DirName.less);
    defer dirs.deinit();

    var end_of_options = false;
    for (args[1..]) |arg| {
        if (end_of_options) {
            try dirs.insert(.{ .name = arg });
            continue;
        }

        if (std.mem.eql(u8, arg, "--help")) {
            try stderr.print(USAGE ++ "\n", .{args[0]});
            return;
        } else if (std.mem.eql(u8, "arg", "--version")) {
            try stderr.print("ls (zyu)" ++ VERSION ++ "\n", .{});
            return;
        } else if (arg[0] == '-' and arg.len > 1) {
            if (arg.len == 2 and arg[1] == '-') {
                end_of_options = true;
                continue;
            }
            for (arg[1..]) |c| {
                switch (c) {
                    'a' => options.show_hidden = true,
                    'C' => options.columns = true,
                    'R' => options.recurse = true,
                    '1' => options.columns = false,
                    else => {
                        try stderr.print("ls: invalid option -- '{c}'\n", .{c});
                        try stderr.print("Try 'ls --help' for more information.\n", .{});
                        return;
                    },
                }
            }
        } else {
            try dirs.insert(.{ .name = arg });
        }
    }

    try printDirs(allocator, stdout, &dirs, options);
}
