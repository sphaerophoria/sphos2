const std = @import("std");
const console = @import("console.zig");

const MB_HEADER_MAGIC = 0x1BADB002;
const MB_FLAG_ALIGN = 1 << 0;
const MB_FLAG_MEMINFO = 1 << 1;
const FLAGS = MB_FLAG_ALIGN | MB_FLAG_MEMINFO;

const PDE4M = packed struct (u32) {
    p: u1,
    rw: u1,
    us: u1,
    pwt: u1,
    pcd: u1,
    a: u1,
    d: u1,
    ps: u1,
    g: u1,
    avl: u3,
    pat: u1,
    addr_high: u8,
    rsvd: u1,
    addr_low: u10,
};

const PDE4K = packed struct (u32) {
    p: u1,
    rw: u1,
    us: u1,
    pwt: u1,
    pcd: u1,
    a: u1,
    avl2: u1,
    ps: u1,
    avl1: u4,
    addr: u20,
};

const PDE = packed union(u32) {
    large: PDE4M,
    small: PDE4K,
};

var page_directory: [1024]PDE align(4096) = undefined;

/// https://www.gnu.org/software/grub/manual/multiboot/multiboot.html#Header-layout
const MultibootHeader = extern struct {
    magic: u32 = MB_HEADER_MAGIC,
    flags: u32 = FLAGS,
    checksum: u32,
    padding: u32 = 0,
};

export var multiboot: MultibootHeader align(4) linksection(".multiboot") = .{
    // Here we are adding magic and flags and ~ to get 1's complement and by adding 1 we get 2's complement
    .checksum = ~@as(u32, (MB_HEADER_MAGIC + FLAGS)) + 1,
};

var stack_bytes: [16 * 1024]u8 align(16) linksection(".bss") = undefined;

fn outb(port: u16, val: u8) void {
    // FIXME: Might want to force immediate port if port <= 255
    asm volatile (
        "outb %[val], %[port]"
        :
        : [port] "{dx}" (port),
        [val] "{al}" (val)
        : .{ .memory = true}
    );
}

fn inb(port: u16) u8 {
    // FIXME: Might want to force immediate port if port <= 255
    return asm volatile (
        "inb %[port], %[val]"
        : [val] "={al}" (-> u8)
        : [port] "{dx}" (port),
        : .{ .memory = true}
    );
}

// We specify that this function is "naked" to let the compiler know
// not to generate a standard function prologue and epilogue, since
// we don't have a stack yet.
export fn _start() linksection(".early_text") callconv(.naked) noreturn {
    const stack_ptr: u32 = @intFromPtr(stack_bytes[stack_bytes.len..].ptr);
    const phys_stack_ptr = stack_ptr - (1 << 31);
    @setRuntimeSafety(false);
    // We use inline assembly to set up the stack before jumping to
    // our kernel entry point.
    asm volatile (
        \\ movl %[stack_top:P], %%esp
        \\ movl %%esp, %%ebp
        \\ call %[kmain:P]
        :
        // The stack grows downwards on x86, so we need to point ESP register
        // to one element past the end of `stack_bytes`.
        //
        // Finally, we pass the whole expression as an input operand with the
        // "immediate" constraint to force the compiler to encode this as an
        // absolute address. This prevents the compiler from doing unnecessary
        // extra steps to compute the address at runtime (especially in Debug mode),
        // which could possibly clobber registers that are specified by multiboot
        // to hold special values (e.g. EAX).
        : [stack_top] "X" (@as([*]u8, @ptrFromInt(phys_stack_ptr))),
          // We let the compiler handle the reference to kmain by passing it as an input operand as well.
          [kmain] "X" (&early_kmain),
    );
}

const serial_port = 0x3F8;
fn initSerial() void {
    outb(serial_port + 1, 0x00);    // Disable all interrupts
   outb(serial_port + 0, 0x03);    // Set divisor to 3 (lo byte) 38400 baud
   outb(serial_port + 1, 0x00);    //                  (hi byte)
   outb(serial_port + 3, 0x03);    // 8 bits, no parity, one stop bit
   outb(serial_port + 2, 0xC7);    // Enable FIFO, clear them, with 14-byte threshold
   outb(serial_port + 4, 0x0B);    // IRQs enabled, RTS/DSR set
   outb(serial_port + 4, 0x1E);    // Set in loopback mode, test the serial chip
   outb(serial_port + 0, 0xAE);    // Test serial chip (send byte 0xAE and check if serial returns same byte)

   // Check if serial is faulty (i.e: not same byte as sent)
   if(inb(serial_port + 0) != 0xAE) {
        asm volatile ("hlt");
   }

   // If serial is not faulty set it in normal operation mode
   // (not-loopback with IRQs enabled and OUT#1 and OUT#2 bits enabled)
   outb(serial_port + 4, 0x0F);

}

fn isTransmitEmpty() bool {
   return (inb(serial_port + 5) & 0x20) == 0x20;
}

fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const to_write = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    for (to_write) |c| {
        writeSerial(c);
    }
}

fn writeSerial(c: u8) void {
   while (!isTransmitEmpty()) {}

   outb(serial_port,c);
}

const GdtEntry = packed struct(u64) {
    limit: u16,
    base: u24,
    access_byte: u8,
    limit2: u4,
    flags: u4,
    base2: u8,

    const Init = struct {
        limit: u20,
        base: u32,
        access: u8,
        flags: u4,
    };

    fn init( args: Init) GdtEntry {
        return .{
            .limit = @truncate(args.limit),
            .limit2 = @truncate(args.limit >> 16),
            .base = @truncate(args.base),
            .base2 = @truncate(args.base >> 24),
            .access_byte = args.access,
            .flags = args.flags,
        };
    }
};

// FIXME: Snure this ends up at addr < uint32_max
var gdt: [4]GdtEntry = undefined;

// FIXME: This needs to be put at an address < uint32_max by the linker script
var tss: [0x70]u8 = undefined;


fn loadGdt(table: []GdtEntry) void {
    const gdtr: packed struct (u64) {
        size: u16,
        ptr: u32,
        pad: u16,
    } = .{
        .ptr = @intFromPtr(table.ptr),
        .size = @intCast(table.len * @sizeOf(GdtEntry) - 1),
        .pad = 0x00,
    };

    asm volatile (
        // I dont' know how to just get the address straight in. Pass as
        // register and indirect. Ggs
        \\lgdt (%[gdtr])
        \\ljmp  $0x08, $.reload_CS
        \\.reload_CS:
        \\mov   $0x10, %ax
        \\mov   %ax, %ds
        \\mov   %ax, %es
        \\mov   %ax, %fs
        \\mov   %ax, %gs
        \\mov   %ax, %ss
        :
        : [gdtr] "r" (&gdtr),
        : .{ .memory = true, .ax = true }
    );
}


fn enablePaging(addr: u32) linksection(".early_text") void {
    asm volatile(
        \\mov %cr4, %ecx
        \\or $0x00000010, %ecx
        \\mov %ecx, %cr4
        \\mov %[val], %cr3
        \\movl %cr0, %ecx
	\\orl $0x80010000, %ecx
	\\movl %ecx, %cr0
        :
        : [val] "r" (addr),
        : .{ .ecx = true }
    );
}

//0x0000    Null Descriptor     Base = 0
//Limit = 0x00000000
//Access Byte = 0x00
//Flags = 0x0
//0x0008     Kernel Mode Code Segment     Base = 0
//Limit = 0xFFFFF
//Access Byte = 0x9A
//Flags = 0xC
//0x0010     Kernel Mode Data Segment     Base = 0
//Limit = 0xFFFFF
//Access Byte = 0x92
//Flags = 0xC
//0x0028     Task State Segment     Base = &TSS
//Limit = sizeof(TSS)-1
//Access Byte = 0x89
//Flags = 0x0


noinline fn early_kmain() linksection(".early_text") callconv(.c) noreturn {
    // FIXME: This should only be done for the kernel and should map high ->
    // low, but that's for later
    const alternate_ptr: [*]PDE = @ptrFromInt(@as(u32, @intFromPtr(&page_directory)) - (1 << 31));
    for (alternate_ptr[0..1024], 0..) |*entry, i| {
        entry.* = .{
            .large = .{
                .rsvd = 0,
                .avl = 0,
                .p = 1,
                .rw = 1,
                .us = 1,
                .pwt = 0,
                .pcd = 0,
                .a = 0,
                .d = 0,
                .ps = 1,
                .g = 0,
                .pat = 0,
                .addr_low = @intCast(i % 512),
                .addr_high = 0,
            },
        };
    }

    enablePaging(@intFromPtr(alternate_ptr));

    kmain();
}

// We use noinline to make sure it don't get inlined by compiler
noinline fn kmain() callconv(.c) noreturn {
    // Initialize our VGA driver
    //console.init();
    //// Printing string
    //console.print("Hello {s} kernel!", .{"zig"});

    // FIXME: This should only be done for the kernel and should map high ->
    // low, but that's for later
    //for (&page_directory, 0..) |*entry, i| {
    //    entry.* = .{
    //        .large = .{
    //            .rsvd = 0,
    //            .avl = 0,
    //            .p = 1,
    //            .rw = 1,
    //            .us = 1,
    //            .pwt = 0,
    //            .pcd = 0,
    //            .a = 0,
    //            .d = 0,
    //            .ps = 1,
    //            .g = 0,
    //            .pat = 0,
    //            .addr_low = @intCast(i % 512),
    //            .addr_high = 0,
    //        },
    //    };
    //}

    // FIXME: We might need some form of GDT enabled before paging in early kmain, unsure
    gdt = .{
        .init(.{ .base = 0, .limit = 0, .access = 0, .flags = 0}),
        .init(.{ .base = 0, .limit = 0xfffff, .access = 0x9a, .flags = 0xc}),
        .init(.{ .base = 0, .limit = 0xfffff, .access = 0x92, .flags = 0xc}),
        .init(.{ .base = @intFromPtr(&tss), .limit = 0x69, .access = 0x89, .flags = 0x0}),
    };
    loadGdt(&gdt);

    initSerial();

    print("hello\n", .{});
    //for (&page_directory) |entry| {
    //    print("0x{x} -> {any}\n", .{@as(u32, @bitCast(entry)), entry.large});
    //}

    //enablePaging(@intFromPtr(&page_directory));

    //const alternate_ptr: [*]PDE = @ptrFromInt(@as(u32, @intFromPtr(&page_directory)) + (1 << 31));
    //print("{*} / {*}\n", .{&page_directory, alternate_ptr});

    //for (&page_directory, alternate_ptr[0..1024]) |entry, entry2| {
    //    const entry_bits: u32 = @bitCast(entry);
    //    const entry2_bits: u32 = @bitCast(entry2);
    //    if (entry_bits != entry2_bits)  {
    //        print("fuck ggs its over\n", .{});
    //        asm volatile ("hlt");
    //    }
    //}

    print("hello2\n", .{});

    while (true) {
        asm volatile ("hlt");
    }
}
