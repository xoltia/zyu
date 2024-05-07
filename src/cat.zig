const std = @import("std");

const USAGE =
    \\Usage: {s} [OPTION]... [FILE]...
    \\Concatenate FILE(s) to standard output.
    \\
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -A, --show-all           equivalent to -vET
    \\  -b, --number-nonblank    number nonempty output lines, overrides -n
    \\  -e                       equivalent to -vE
    \\  -E, --show-ends          display $ at end of each line
    \\  -n, --number             number all output lines
    \\  -s, --squeeze-blank      suppress repeated empty output lines
    \\  -t                       equivalent to -vT
    \\  -T, --show-tabs          display TAB characters as ^I
    \\  -v, --show-nonprinting   use ^ and M- notation, except for LFD and TAB
    \\      --help               display this help and exit
    \\      --version            output version information and exit
;

const VERSION = "0.1.0";

const BUFF_SIZE = 4096;

const CatOptions = struct {
    number_nonblank: bool = false,
    number: bool = false,
    show_ends: bool = false,
    squeeze_blank: bool = false,
    show_tabs: bool = false,
    show_nonprinting: bool = false,

    fn simple(self: @This()) bool {
        return !(self.number_nonblank or self.show_ends or self.number or self.show_tabs or self.show_nonprinting);
    }
};

inline fn fread(file: std.fs.File, buffer: []u8) !?usize {
    if (file.read(buffer)) |n| {
        return if (n > 0) n else null;
    } else |err| {
        return err;
    }
}

fn simpleCat(file: std.fs.File, writer: std.io.AnyWriter, buffer: []u8) !void {
    while (try fread(file, buffer)) |n| {
        if (n == 0) break;
        try writer.writeAll(buffer[0..n]);
    }
}

fn complexCat(file: std.fs.File, writer: std.io.AnyWriter, buffer: []u8, line_number: *usize, opts: CatOptions) !void {
    var newline = true;

    while (try fread(file, buffer)) |n| {
        if (n == 0) break;

        for (buffer[0..n]) |c| switch (c) {
            '\n' => {
                if (opts.squeeze_blank and newline)
                    continue;

                if (opts.number_nonblank and !newline) {
                    line_number.* += 1;
                } else if (opts.number) {
                    if (newline) {
                        try writer.print("{d: >6}\t", .{line_number.*});
                    }
                    line_number.* += 1;
                }

                if (opts.show_ends) {
                    try writer.writeAll("$\n");
                } else {
                    try writer.writeByte('\n');
                }

                newline = true;
            },
            '\t' => {
                if (opts.number_nonblank and newline) {
                    try writer.print("{d: >6}\t", .{line_number.*});
                } else if (opts.number and newline) {
                    try writer.print("{d: >6}\t", .{line_number.*});
                }

                if (opts.show_tabs) {
                    try writer.writeAll("^I");
                } else {
                    try writer.writeByte(c);
                }

                newline = false;
            },
            else => {
                if (opts.number_nonblank and newline) {
                    try writer.print("{d: >6}\t", .{line_number.*});
                } else if (opts.number and newline) {
                    try writer.print("{d: >6}\t", .{line_number.*});
                }

                newline = false;

                if (!opts.show_nonprinting) {
                    try writer.writeByte(c);
                } else if (c >= 32) {
                    if (c < 127) {
                        try writer.writeByte(c);
                    } else if (c == 127) {
                        try writer.writeAll("^?");
                    } else {
                        try writer.writeAll("M-");
                        if (c >= 128 + 32) {
                            if (c < 128 + 127) {
                                try writer.writeByte(c - 128);
                            } else {
                                try writer.writeAll("^?");
                            }
                        } else {
                            try writer.writeAll("^");
                            try writer.writeByte(c - 128 + 64);
                        }
                    }
                } else {
                    try writer.writeAll("^");
                    try writer.writeByte(c + 64);
                }
            },
        };
    }
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer().any();
    const stderr = std.io.getStdErr().writer().any();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const args_without_program = args[1..];

    var file_names = try std.ArrayListUnmanaged([]const u8)
        .initCapacity(allocator, args_without_program.len);
    defer file_names.deinit(allocator);

    var options = CatOptions{};

    for (args_without_program) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            try stderr.print(USAGE, .{args[0]});
            try stderr.print("\n", .{});
            return 0;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try stderr.print("cat (zyu) {s}\n", .{VERSION});
            return 0;
        } else if (std.mem.eql(u8, arg, "--")) {
            break;
        } else if (arg[0] == '-' and arg.len > 1) {
            for (arg[1..]) |c| switch (c) {
                'n' => options.number = true,
                'b' => options.number_nonblank = true,
                'E' => options.show_ends = true,
                's' => options.squeeze_blank = true,
                'T' => options.show_tabs = true,
                'v' => options.show_nonprinting = true,
                'A' => {
                    options.show_ends = true;
                    options.show_tabs = true;
                    options.show_nonprinting = true;
                },
                't' => {
                    options.show_tabs = true;
                    options.show_nonprinting = true;
                },
                'e' => {
                    options.show_ends = true;
                    options.show_nonprinting = true;
                },
                else => {
                    try stderr.print("cat: invalid option -- '{c}'\n", .{c});
                    try stderr.print("Try 'cat --help' for more information.\n", .{});
                    return 1;
                },
            };
        } else {
            try file_names.append(allocator, arg);
        }
    }

    var buffer: [BUFF_SIZE]u8 = undefined;

    var line_number: usize = 1;
    if (file_names.items.len == 0) {
        const file = std.io.getStdIn();
        if (options.simple()) {
            try simpleCat(file, stdout, &buffer);
        } else {
            try complexCat(file, stdout, &buffer, &line_number, options);
        }
        return 0;
    }

    for (file_names.items) |file_name| {
        const file = if (file_name[0] == '-' and file_name.len == 1)
            std.io.getStdIn()
        else
            try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });

        defer file.close();
        if (options.simple()) {
            try simpleCat(file, stdout, &buffer);
        } else {
            try complexCat(file, stdout, &buffer, &line_number, options);
        }
    }

    return 0;
}
