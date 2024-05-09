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

const VERSION = "0.1.0";

const DirName = struct {
    name: []const u8,
    owned: bool = false,
};

const ListFilesOptions = struct {
    recurse: bool = false,
    columns: bool = false,
    show_hidden: bool = false,
    // ..
};

var console_size: ?usize = null;

fn consoleSize() usize {
    if (console_size != null)
        return console_size.?;

    if (builtin.os.tag != .linux) {
        console_size = 80;
        return 80;
    }

    var winsize = std.mem.zeroes(std.os.linux.winsize);
    if (std.os.linux.ioctl(0, 21523, @intFromPtr(&winsize)) != 0) {
        console_size = 80;
        return 80;
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

fn listFiles(
    allocator: std.mem.Allocator,
    writer: std.io.AnyWriter,
    dir_name: []const u8,
    dirs: *std.ArrayListUnmanaged(DirName),
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
            try dirs.append(allocator, .{ .name = full_path, .owned = true });
        }
    }

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
    dirs: *std.ArrayListUnmanaged(DirName),
    options: ListFilesOptions,
) !void {
    while (dirs.popOrNull()) |dir| {
        try writer.print("{s}:\n", .{dir.name});
        try listFiles(allocator, writer, dir.name, dirs, options);
        if (dirs.items.len != 0) {
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

    var dirs = std.ArrayListUnmanaged(DirName){};
    defer dirs.deinit(allocator);

    var end_of_options = false;
    for (args[1..]) |arg| {
        if (end_of_options) {
            try dirs.append(allocator, .{ .name = arg });
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
                    else => {
                        try stderr.print("ls: invalid option -- '{c}'\n", .{c});
                        try stderr.print("Try 'ls --help' for more information.\n", .{});
                        return;
                    },
                }
            }
        } else {
            try dirs.append(allocator, .{ .name = arg });
        }
    }

    try printDirs(allocator, stdout, &dirs, options);
}
