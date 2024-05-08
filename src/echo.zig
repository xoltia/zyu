const std = @import("std");

const USAGE =
    \\Usage: echo [SHORT-OPTION]... [STRING]...
    \\  or:  echo LONG-OPTION
    \\Echo the STRING(s) to standard output.
    \\
    \\  -n         do not output the trailing newline
    \\  -e         enable interpretation of backslash escapes
    \\  -E         disable interpretation of backslash escapes
    \\  --help     display this help and exit
    \\  --version  output version information and exit
    \\  --         end of options
    \\
    \\If -e is in effect, the following sequences are recognized:
    \\  \a     alert (bell)
    \\  \b     backspace
    \\  \c     produce no further output
    \\  \e     escape
    \\  \f     form feed
    \\  \n     new line
    \\  \r     carriage return
    \\  \t     horizontal tab
    \\  \v     vertical tab
    \\  \\     backslash
    \\  \NNN   byte with octal value NNN (1 to 3 digits)
    \\  \0NNN  byte with octal value NNN (0 to 3 digits)
    \\  \xHH   byte with hexadecimal value HH (1 to 2 digits)
;

const VERSION = "0.1.0";

const EscapeState = union(enum) {
    none,
    escape,
    octal: u2,
    hex: u1,
};

const UnescapedStringSlice = struct {
    str: []const u8,
    len: usize,
    last: bool,
};

fn unescape(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error!UnescapedStringSlice {
    const escaped = try allocator.alloc(u8, input.len);

    var state: EscapeState = .none;
    var i: usize = 0;
    var value: u8 = 0;

    loop: for (input) |c| {
        switch (state) {
            .none => {
                if (c == '\\') {
                    state = .escape;
                } else {
                    escaped[i] = c;
                    i += 1;
                }
            },
            .escape => {
                switch (c) {
                    'a' => escaped[i] = '\x07',
                    'b' => escaped[i] = '\x08',
                    'c' => return .{ .str = escaped, .len = i, .last = true },
                    'e' => escaped[i] = '\x1b',
                    'f' => escaped[i] = '\x0c',
                    'n' => escaped[i] = '\n',
                    'r' => escaped[i] = '\r',
                    't' => escaped[i] = '\t',
                    'v' => escaped[i] = '\x0b',
                    '\\' => escaped[i] = '\\',
                    '0' => {
                        state = .{ .octal = 0 };
                        continue :loop;
                    },
                    'x' => {
                        state = .{ .hex = 0 };
                        continue :loop;
                    },
                    '1', '2', '3', '4', '5', '6', '7' => {
                        state = .{ .octal = 1 };
                        value = c - '0';
                        continue :loop;
                    },
                    else => {
                        escaped[i] = '\\';
                        escaped[i + 1] = c;
                        i += 1;
                    },
                }

                i += 1;
                state = .none;
            },
            .octal => |nth_digit| {
                if (c >= '0' and c <= '7') {
                    value = value * 8 + (c - '0');
                    if (nth_digit == 2) {
                        escaped[i] = value;
                        value = 0;
                        i += 1;
                        state = .none;
                    } else {
                        state = .{ .octal = nth_digit + 1 };
                    }
                } else {
                    escaped[i] = value;
                    escaped[i + 1] = c;
                    value = 0;
                    i += 2;
                    state = .none;
                }
            },
            .hex => |nth_digit| {
                if (c >= '0' and c <= '9') {
                    value = value * 16 + (c - '0');
                } else if (c >= 'a' and c <= 'f') {
                    value = value * 16 + (c - 'a' + 10);
                } else if (c >= 'A' and c <= 'F') {
                    value = value * 16 + (c - 'A' + 10);
                } else {
                    escaped[i] = value;
                    escaped[i + 1] = c;
                    value = 0;
                    i += 2;
                    state = .none;
                }

                if (nth_digit == 1) {
                    escaped[i] = value;
                    value = 0;
                    i += 1;
                    state = .none;
                } else {
                    state = .{ .hex = 1 };
                }
            },
        }
    }

    switch (state) {
        .none => {},
        .escape => {
            escaped[i] = '\\';
            i += 1;
        },
        .octal, .hex => {
            escaped[i] = value;
            i += 1;
        },
    }

    return .{ .str = escaped, .len = i, .last = false };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    var buffered_writer = std.io.bufferedWriter(stdout);

    var output_newline = true;
    var enable_escapes = false;
    var first_arg = true;
    var end_of_options = false;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const args_without_program = args[1..];

    if (args_without_program.len == 1) {
        if (std.mem.eql(u8, args_without_program[0], "--help")) {
            _ = try stderr.writeAll(USAGE ++ "\n");
            return;
        } else if (std.mem.eql(u8, args_without_program[0], "--version")) {
            _ = try stderr.writeAll("echo (zyu) " ++ VERSION ++ "\n");
            return;
        }
    }

    for (args_without_program) |arg| {
        if (!end_of_options and arg[0] != '-' and arg.len >= 1) {
            end_of_options = true;
        }

        if (!end_of_options) {
            for (arg[1..]) |c| {
                switch (c) {
                    'n' => output_newline = false,
                    'e' => enable_escapes = true,
                    'E' => enable_escapes = false,
                    '-' => {
                        end_of_options = true;
                        break;
                    },
                    else => {
                        end_of_options = true;
                        break;
                    },
                }
            }
        }

        if (end_of_options) {
            if (!first_arg) {
                _ = try buffered_writer.write(" ");
            }

            if (enable_escapes) {
                const unescaped = try unescape(allocator, arg);
                defer allocator.free(unescaped.str);
                _ = try buffered_writer.write(unescaped.str[0..unescaped.len]);
                if (unescaped.last) {
                    output_newline = false;
                    break;
                }
            } else {
                _ = try buffered_writer.write(arg);
            }

            first_arg = false;
        }
    }

    if (output_newline) {
        _ = try buffered_writer.write("\n");
    }

    try buffered_writer.flush();
}
