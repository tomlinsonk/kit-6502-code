import java.awt.event.KeyEvent;
import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.Deque;
import java.util.HashMap;
import java.util.Map;
import java.util.function.BooleanSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class DebuggerTest {
    private final CPU cpu;
    private final Bus bus;
    private final VIA via1;
    private final VIA via2;
    private final int[] ssd;
    private final Map<String, Integer> symbols = new HashMap<>();
    private final ByteArrayOutputStream console = new ByteArrayOutputStream();
    private int checks = 0;

    private static Object field(Object object, Class<?> type, String name) throws Exception {
        Field field = type.getDeclaredField(name);
        field.setAccessible(true);
        return field.get(object);
    }

    private void loadSymbols(Path file) throws Exception {
        Pattern namespace = Pattern.compile("^\\.namespace (\\w+) \\{");
        Pattern label = Pattern.compile("\\.label ([\\w.]+)=\\$([0-9a-f]+)");
        Deque<String> scopes = new ArrayDeque<>();      // namespace prefix of each open block
        for (String line : Files.readAllLines(file)) {
            String text = line.trim();
            String prefix = scopes.isEmpty() ? "" : scopes.peek();
            Matcher n = namespace.matcher(text);
            if (n.find()) {
                scopes.push(n.group(1) + ".");
                continue;
            }
            if (text.equals("}")) {
                scopes.pop();
                continue;
            }
            Matcher l = label.matcher(line);
            if (l.find()) symbols.put(prefix + l.group(1), Integer.parseInt(l.group(2), 16));
            if (text.endsWith("{")) scopes.push(prefix);
        }
    }

    private DebuggerTest(Path monitorSymbols) throws Exception {
        loadSymbols(monitorSymbols);
        PrintStream out = System.out;
        System.setOut(new PrintStream(new OutputStream() {
            public void write(int b) {
                console.write(b);
                out.write(b);
            }
        }, true));
        KiT kit = new KiT();
        cpu = (CPU) field(kit, KiT.class, "cpu");
        bus = (Bus) field(kit, KiT.class, "bus");
        via1 = (VIA) field(kit, KiT.class, "via1");
        via2 = (VIA) field(kit, KiT.class, "via2");
        ssd = (int[]) field(field(kit, KiT.class, "ssd"), SSD.class, "data");
    }

    // ---------------------------------------------------------------- emulator helpers

    private int sym(String name) {
        Integer value = symbols.get("debugger." + name);
        if (value == null) value = symbols.get(name);
        if (value == null) throw new AssertionError("Missing symbol: " + name);
        return value;
    }

    private int peek(int address) {
        return bus.debugRead(address);
    }

    private int var(String name) {
        return peek(sym(name));
    }

    private int word(String name) {
        int address = sym(name);
        return peek(address) | peek(address + 1) << 8;
    }

    private void poke(int address, int... values) {
        for (int value : values) bus.write(address++, value & 0xff);
    }

    private void step() {
        long before = cpu.getCycleCount();
        cpu.step();
        int cycles = (int) (cpu.getCycleCount() - before);
        via1.updateCycleCount(cycles);
        via2.updateCycleCount(cycles);
    }

    private void setS(int value) {
        try {
            Field field = CPU.class.getDeclaredField("S");
            field.setAccessible(true);
            field.setInt(cpu, value & 0xff);
        } catch (ReflectiveOperationException e) {
            throw new AssertionError(e);
        }
    }

    private void steps(int count) {
        for (int i = 0; i < count; i++) step();
    }

    private void until(BooleanSupplier condition, String description) {
        for (int i = 0; i < 5_000_000; i++) {
            if (condition.getAsBoolean()) return;
            step();
        }
        throw new AssertionError(description + " timed out at $" + Integer.toHexString(cpu.getPC())
            + "\n" + screen());
    }

    private boolean kbEmpty() {
        return peek(sym("zp.kb_read_ptr")) == peek(sym("zp.kb_write_ptr"));
    }

    // Run until the debugger has consumed every key and is waiting for another
    private void idle() {
        int[] waits = {sym("key_loop"), sym("rh_key"), sym("er_wait"), sym("vu_wait")};
        until(() -> {
            if (!kbEmpty()) return false;
            int pc = cpu.getPC();
            for (int w : waits) if (pc == w) return true;
            return false;
        }, "Debugger idle");
    }

    private void scan(int code) {
        via1.kbByte(code);
        steps(500);
    }

    private void press(int code) {
        scan(code);
        scan(0xf0);
        scan(code);
    }

    private boolean waitForDebugger = true;

    private void key(int keyCode) {
        int code = PS2.getScanCode(keyCode);
        require(code != PS2.ERROR_CODE, "Missing emulator key mapping: " + KeyEvent.getKeyText(keyCode));
        press(code);
        if (waitForDebugger) idle();
    }

    // Type at the monitor prompt
    private void monitor(String text) {
        waitForDebugger = false;
        type(text);
        waitForDebugger = true;
    }

    // Run a monitor command and wait for the prompt
    private void monitorCommand(String text) {
        monitor(text + "\n");
        until(() -> kbEmpty() && cpu.getPC() == sym("mon_loop"), "monitor command " + text);
    }

    // Start the debugger with d from the monitor prompt
    private void debug(String args) {
        monitor("d" + args + "\n");
        idle();
        require(cpu.getPC() == sym("key_loop"), "debugger started");
    }

    // Leave the debugger with esc
    private void leave() {
        press(PS2.getScanCode(KeyEvent.VK_ESCAPE));
        until(() -> kbEmpty() && cpu.getPC() == sym("mon_loop"), "monitor after esc");
    }

    private void arrow(int keyCode) {
        int code = PS2.getScanCode(keyCode);
        scan(0xe0);
        scan(code);
        scan(0xe0);
        scan(0xf0);
        scan(code);
        idle();
    }

    private void type(String text) {
        String plain = "0123456789.\t\b\n -";
        int[] codes = {
            KeyEvent.VK_0, KeyEvent.VK_1, KeyEvent.VK_2, KeyEvent.VK_3, KeyEvent.VK_4,
            KeyEvent.VK_5, KeyEvent.VK_6, KeyEvent.VK_7, KeyEvent.VK_8, KeyEvent.VK_9,
            KeyEvent.VK_PERIOD, KeyEvent.VK_TAB, KeyEvent.VK_BACK_SPACE, KeyEvent.VK_ENTER,
            KeyEvent.VK_SPACE, KeyEvent.VK_MINUS
        };
        for (char c : text.toCharArray()) {
            int index;
            if (c >= 'a' && c <= 'z') key(KeyEvent.VK_A + c - 'a');
            else if ((index = plain.indexOf(c)) >= 0) key(codes[index]);
            else throw new AssertionError("Unsupported test character: " + c);
        }
    }

    private void esc() {
        key(KeyEvent.VK_ESCAPE);
    }

    private static char decode(int value) {
        int base = value & 0x3f;
        if (base == 0) return '@';
        if (base < 0x20) return (char) ('a' + base - 1);
        return (char) base;
    }

    private String row(int row) {
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < 32; i++) text.append(decode(peek(0x6000 + row * 32 + i)));
        return text.toString();
    }

    private boolean inverse(int row, int col) {
        return (peek(0x6000 + row * 32 + col) & 0x40) != 0;
    }

    private String screen() {
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < 16; i++) text.append(row(i)).append('\n');
        return text.toString();
    }

    private void require(boolean condition, String description) {
        checks++;
        if (!condition) throw new AssertionError(description + "\nScreen:\n" + screen());
    }

    private void equal(int actual, int expected, String description) {
        require(actual == expected, String.format("%s: expected $%x, got $%x", description, expected, actual));
    }

    private void contains(String text, String expected) {
        require(text.contains(expected), "Expected \"" + expected + "\" in \"" + text + "\"");
    }

    private String status() {
        return row(15);
    }

    // ---------------------------------------------------------------- debugger commands

    private void jump(int address) {
        type("j" + String.format("%04x", address));
        equal(word("cur"), address, "cursor after j");
    }

    private void setPc(int address) {
        jump(address);
        type("p");
        equal(word("reg_pc"), address, "pc after p");
    }

    private void stepAndCheck(int pc) {
        type("s");
        equal(word("reg_pc"), pc, "pc after step");
    }

    // ---------------------------------------------------------------- disassembler

    // Disassemble the bytes at $1000 through the debugger's own formatter: call code_line
    // with a return address that points at a jmp-to-self in RAM
    private String disassemble(int... bytes) {
        require(cpu.getPC() == sym("key_loop"), "Debugger must be idle to call code_line");
        final int spin = 0x5ff0;
        poke(0x1000, bytes);
        poke(spin, 0x4c, spin & 0xff, spin >> 8);
        poke(sym("dpc"), 0x00, 0x10);
        int s = cpu.getS();
        poke(0x100 + s, (spin - 1) >> 8);
        poke(0x100 + ((s - 1) & 0xff), (spin - 1) & 0xff);
        setS(s - 2);
        cpu.setPC(sym("code_line"));
        until(() -> cpu.getPC() == spin, "code_line");
        StringBuilder text = new StringBuilder();
        int line = sym("line");
        for (int i = 0; i < 32; i++) text.append((char) (peek(line + i) & 0x7f));
        setS(s);
        cpu.setPC(sym("key_loop"));
        return text.toString().replaceAll(" +$", "");
    }

    // Expected disassembly, derived from the emulator's own instruction table
    private String expected(Object instruction, int opcode, int b1, int b2) throws Exception {
        Class<?> type = instruction.getClass().getSuperclass();
        while (!type.getName().equals("CPU$Instruction")) type = type.getSuperclass();
        String mnemonic = (String) field(instruction, type, "mnemonic");
        String mode = field(instruction, type, "addrMode").toString();
        int bytes = (int) field(instruction, type, "bytes");
        int length = opcode == 0x00 ? 1 : bytes;

        StringBuilder text = new StringBuilder(">  1000 ");
        int[] all = {opcode, b1, b2};
        for (int i = 0; i < length; i++) text.append(String.format("%02x ", all[i]));
        while (text.length() < 17) text.append(' ');

        if ((mnemonic.equals("nop") && opcode != 0xea) || mnemonic.equals("bpt")) {
            return text.append("???").toString();
        }
        text.append(mnemonic);
        int word = b1 | b2 << 8;
        String operand = switch (mode) {
            case "ACCUMULATOR", "IMPLIED" -> "";
            case "IMMEDIATE" -> String.format("#$%02x", b1);
            case "ZEROPAGE" -> mnemonic.startsWith("bb")
                ? String.format("$%02x,$%04x", b1, (0x1003 + (byte) b2) & 0xffff)
                : String.format("$%02x", b1);
            case "ZEROPAGE_X" -> String.format("$%02x,x", b1);
            case "ZEROPAGE_Y" -> String.format("$%02x,y", b1);
            case "X_INDIRECT" -> String.format("($%02x,x)", b1);
            case "INDIRECT_Y" -> String.format("($%02x),y", b1);
            case "ZEROPAGE_INDIRECT" -> String.format("($%02x)", b1);
            case "ABSOLUTE" -> String.format("$%04x", word);
            case "ABSOLUTE_X" -> mnemonic.equals("jmp")
                ? String.format("($%04x,x)", word)
                : String.format("$%04x,x", word);
            case "ABSOLUTE_Y" -> String.format("$%04x,y", word);
            case "INDIRECT" -> String.format("($%04x)", word);
            case "RELATIVE" -> String.format("$%04x", (0x1002 + (byte) b1) & 0xffff);
            default -> throw new AssertionError("Unknown mode " + mode);
        };
        if (!operand.isEmpty()) text.append(' ').append(operand);
        return text.toString();
    }

    private void testDisassembler() throws Exception {
        Object[] instructions = (Object[]) field(cpu, CPU.class, "instructions");
        int[][] operands = {{0x34, 0x12}, {0xf0, 0x80}, {0x00, 0xff}};
        for (int[] operand : operands) {
            for (int opcode = 0; opcode < 256; opcode++) {
                String want = expected(instructions[opcode], opcode, operand[0], operand[1]);
                String got = disassemble(opcode, operand[0], operand[1]);
                require(got.equals(want), String.format("opcode $%02x:%n  want \"%s\"%n  got  \"%s\"",
                    opcode, want, got));
            }
        }
        // spot checks against hand-written listings
        require(disassemble(0xa9, 0x42).endsWith("a9 42    lda #$42"), "lda #");
        require(disassemble(0x7c, 0x00, 0x20).endsWith("jmp ($2000,x)"), "jmp (abs,x)");
        require(disassemble(0x0a).endsWith("asl"), "asl a");
        require(disassemble(0xd0, 0xfe).endsWith("bne $1000"), "bne to self");
        require(disassemble(0xdf, 0x10, 0xfd).endsWith("bbs5 $10,$1000"), "bbs5 back");
        require(disassemble(0xb2, 0x80).endsWith("lda ($80)"), "lda (zp)");
        require(disassemble(0xdb).endsWith("stp"), "stp");
        require(disassemble(0x02, 0x00).endsWith("02 00    ???"), "undefined 2-byte nop");
        System.out.println("disassembler: 768 opcode/operand combinations OK");
    }

    // ---------------------------------------------------------------- single stepping

    private void testStepping() {
        poke(0x1000,
            0xa9, 0x42,             // 1000 lda #$42
            0xa2, 0x02,             // 1002 ldx #$02
            0xca,                   // 1004 dex
            0xd0, 0xfd,             // 1005 bne $1004
            0x20, 0x30, 0x10,       // 1007 jsr $1030
            0x0f, 0x50, 0x03,       // 100a bbr0 $50,$1010
            0xea, 0xea, 0xea,       // 100d
            0x8f, 0x50, 0x03,       // 1010 bbs0 $50,$1016
            0x6c, 0x40, 0x10);      // 1013 jmp ($1040)
        poke(0x1030,
            0x48,                   // 1030 pha
            0x08,                   // 1031 php
            0x68,                   // 1032 pla
            0x28,                   // 1033 plp
            0x60);                  // 1034 rts
        poke(0x1040, 0x50, 0x10);
        poke(0x1050,
            0x85, 0x05,             // 1050 sta $05
            0x8d, 0x21, 0x60,       // 1052 sta $6021
            0x00, 0xea);            // 1055 brk
        poke(0x50, 0x00);
        int liveZp5 = peek(0x05);
        int liveScreen = peek(0x6021);

        setPc(0x1000);
        type(".");
        contains(row(2), ">  1000 a9 42    lda #$42");
        require(inverse(2, 3) && !inverse(2, 8), "cursor address is highlighted");
        contains(row(3), "   1002 a2 02    ldx #$02");
        contains(row(4), "   1004 ca       dex");
        contains(row(5), "   1005 d0 fd    bne $1004");

        stepAndCheck(0x1002);
        equal(var("reg_a"), 0x42, "a after lda");
        contains(row(0), "pc 1002 a 42 x 00 y 00 s ff");
        stepAndCheck(0x1004);
        equal(var("reg_x"), 0x02, "x after ldx");
        stepAndCheck(0x1005);
        stepAndCheck(0x1004);                       // taken
        stepAndCheck(0x1005);
        stepAndCheck(0x1007);                       // not taken
        equal(var("reg_x"), 0, "x after loop");
        require((var("reg_p") & 0x02) != 0, "z set");
        contains(row(1), "p 22 nvdizc");
        require(inverse(1, 9), "z flag highlighted");

        stepAndCheck(0x1030);                       // jsr
        equal(var("reg_s"), 0xfd, "s after jsr");
        equal(peek(0x1ff), 0x10, "jsr pushed hi");
        equal(peek(0x1fe), 0x09, "jsr pushed lo");
        stepAndCheck(0x1031);                       // pha
        equal(peek(0x1fd), 0x42, "pha");
        equal(var("reg_s"), 0xfc, "s after pha");
        int p = var("reg_p");
        stepAndCheck(0x1032);                       // php
        stepAndCheck(0x1033);                       // pla
        equal(var("reg_a"), p | 0x30, "pla of pushed p");
        stepAndCheck(0x1034);                       // plp
        equal(var("reg_p"), 0x62, "plp pulls the $42 pushed by pha");
        stepAndCheck(0x100a);                       // rts
        equal(var("reg_s"), 0xff, "s after rts");
        stepAndCheck(0x1010);                       // bbr0 taken
        stepAndCheck(0x1013);                       // bbs0 not taken
        stepAndCheck(0x1050);                       // jmp ($1040)

        stepAndCheck(0x1052);                       // sta $05 goes to the user's zero page
        equal(peek(sym("zp_reg_stash") + 5), 0x32, "user zp write");
        equal(peek(0x05), liveZp5, "debugger zp untouched");
        stepAndCheck(0x1055);                       // sta $6021 goes to the user's screen
        equal(peek(sym("user_screen") + 0x21), 0x32, "user screen write");
        equal(peek(0x6021), liveScreen, "debugger screen untouched");

        int vector = peek(0xfffe) | peek(0xffff) << 8;
        stepAndCheck(vector);                       // brk
        equal(var("reg_s"), 0xfc, "s after brk");
        equal(peek(0x1ff), 0x10, "brk pushed hi");
        equal(peek(0x1fe), 0x57, "brk pushed lo");
        equal(peek(0x1fd) & 0x30, 0x30, "brk pushed b");
        require((var("reg_p") & 0x04) != 0, "brk sets i");

        poke(0x1060, 0x7c, 0x80, 0x10);              // jmp ($1080,x)
        poke(0x1082, 0x70, 0x10);
        poke(0x1070, 0xcb, 0x40);                    // wai; rti
        poke(0x1fd, 0xc3, 0x34, 0x12);
        type("rx02");
        type("rsfc");
        setPc(0x1060);
        stepAndCheck(0x1070);
        stepAndCheck(0x1071);
        stepAndCheck(0x1234);
        equal(var("reg_p"), 0xe3, "rti pulls p");
        equal(var("reg_s"), 0xff, "s after rti");
        type("rx00");
        type("rp20");

        poke(0x2000, 0xdb);
        setPc(0x2000);
        type("s");
        equal(word("reg_pc"), 0x2000, "stp is not stepped");
        contains(status(), "stp would halt the cpu");

        type("ra42");
        equal(var("reg_a"), 0x42, "r a");
        type("rs" + "ff");
        equal(var("reg_s"), 0xff, "r s");
        type("rpff");
        equal(var("reg_p"), 0xef, "r p ignores b");
        type("rp20");
        equal(var("reg_p"), 0x20, "r p");
        type("rx");
        esc();
        equal(var("reg_x"), 0, "esc cancels r");
        System.out.println("stepping OK");
    }

    // ---------------------------------------------------------------- code view navigation

    private void testNavigation() {
        poke(0x1000, 0xa9, 0x01, 0x8d, 0x00, 0x20, 0xea, 0xea);
        jump(0x1000);
        arrow(KeyEvent.VK_DOWN);
        equal(word("cur"), 0x1002, "down");
        arrow(KeyEvent.VK_DOWN);
        equal(word("cur"), 0x1005, "down over 3-byte op");
        arrow(KeyEvent.VK_UP);
        equal(word("cur"), 0x1002, "up");
        arrow(KeyEvent.VK_UP);
        equal(word("cur"), 0x1000, "up again");
        int after = word("after");
        arrow(KeyEvent.VK_RIGHT);
        equal(word("cur"), after, "page down");
        equal(word("top"), after, "page down top");
        System.out.println("navigation OK");
    }

    // ---------------------------------------------------------------- breakpoints and running

    private void testRunning() {
        poke(0x1100,
            0xe8,                   // 1100 inx
            0xe8,                   // 1101 inx
            0x20, 0x10, 0x11,       // 1102 jsr $1110
            0xc8,                   // 1105 iny
            0x80, 0xfe);            // 1106 bra $1106
        poke(0x1110,
            0xa9, 0x07,             // 1110 lda #$07
            0x60);                  // 1112 rts
        type("rx00");
        type("ry00");
        type("rsff");

        jump(0x1105);
        type("b");
        contains(row(2), " * 1105 c8       iny");
        type("b");
        require(row(2).startsWith("   1105"), "b toggles off");
        type("b");
        jump(0x0100);
        type("b");
        contains(status(), "bp must be in $0300-$5fff");
        jump(0x6000);
        type("b");
        contains(status(), "bp must be in $0300-$5fff");

        setPc(0x1100);
        type("g");
        equal(word("reg_pc"), 0x1105, "stopped at breakpoint");
        equal(var("reg_x"), 2, "x after run");
        equal(var("reg_a"), 7, "a after run");
        equal(var("reg_s"), 0xff, "s after run");
        equal(peek(0x1105), 0xc8, "breakpoint removed");
        contains(status(), "breakpoint");
        contains(row(5), ">* 1105 c8       iny");

        jump(0x1105);
        type("b");                                  // clear it
        setPc(0x1102);
        type("n");
        equal(word("reg_pc"), 0x1105, "step over jsr");
        equal(peek(0x1105), 0xc8, "temp breakpoint removed");
        equal(var("reg_s"), 0xff, "s after step over");
        setPc(0x1110);
        type("n");
        equal(word("reg_pc"), 0x1112, "n steps a non-jsr");

        setPc(0x1105);
        press(PS2.getScanCode(KeyEvent.VK_G));
        steps(20000);
        equal(cpu.getPC() & 0xfff0, 0x1100, "running the user loop");
        press(0x07);                                // F12
        idle();
        equal(word("reg_pc"), 0x1106, "f12 stopped the loop");
        equal(var("reg_y"), 1, "y after run");
        contains(status(), "stopped");

        poke(0x1200, 0xe8, 0x00, 0xea, 0xea);       // inx; brk
        setPc(0x1200);
        type("g");
        equal(word("reg_pc"), 0x1201, "stopped at brk");
        contains(status(), "brk");
        equal(peek(0x1e) | peek(0x1f) << 8, sym("irq"), "monitor irq handler restored");
        equal(peek(sym("irq_addr_stash")) | peek(sym("irq_addr_stash") + 1) << 8, sym("irq"),
            "user irq handler restored");
        System.out.println("running OK");
    }

    // ---------------------------------------------------------------- hex editor

    private void testHexEditor() {
        type("\t");
        equal(var("view"), 1, "tab to hex view");
        contains(row(1), " hex");

        jump(0x2000);
        type("a");
        contains(row(2), "2000 a.");
        type("\b");
        equal(var("pending"), 0, "backspace cancels digit");
        type("a5");
        equal(peek(0x2000), 0xa5, "ram edit");
        equal(word("cur"), 0x2001, "cursor advances");
        type("0f1e");
        equal(peek(0x2001), 0x0f, "ram edit 2");
        equal(peek(0x2002), 0x1e, "ram edit 3");
        contains(row(2), "2000 a5 0f 1e");
        arrow(KeyEvent.VK_LEFT);
        equal(word("cur"), 0x2002, "left");
        arrow(KeyEvent.VK_DOWN);
        equal(word("cur"), 0x200a, "down");
        arrow(KeyEvent.VK_UP);
        arrow(KeyEvent.VK_RIGHT);
        equal(word("cur"), 0x2003, "up, right");
        contains(status(), "2003  ");

        int live = peek(0x07);
        jump(0x0007);
        type("77");
        equal(peek(sym("zp_reg_stash") + 7), 0x77, "zero page edit goes to the user's copy");
        equal(peek(0x07), live, "debugger zero page untouched");

        jump(0x001e);
        int irq = sym("irq");
        contains(row(2), String.format("0018 %02x %02x %02x %02x %02x %02x %02x %02x",
            peek(0x18), peek(0x19), peek(0x1a), peek(0x1b), peek(0x1c), peek(0x1d), irq & 0xff, irq >> 8));

        jump(0x6010);
        type("01");
        equal(peek(sym("user_screen") + 0x10), 0x01, "screen edit goes to the user's copy");

        jump(0x7800);
        contains(row(2), "7800 -- --");
        System.out.println("hex editor OK");
    }

    private int[] sector(int number) {
        int[] data = new int[4096];
        System.arraycopy(ssd, number << 12, data, 0, 4096);
        return data;
    }

    private void testSsd() {
        int number = 0x3e;
        type("k3e");
        contains(row(1), "ssd 3e");
        equal(peek(sym("zp.ssd_sector")), number, "user sector");
        int[] before = sector(number);
        int[] neighbour = sector(number + 1);
        int offset = 0x123;
        while (before[offset] == 0) offset++;
        int old = before[offset];

        int cleared = old & (old - 1);              // clear the lowest set bit
        jump(0x8000 + offset);
        console.reset();
        type(String.format("%02x", cleared));
        int[] after = sector(number);
        equal(after[offset], cleared, "1->0 flash patch");
        require(!console.toString().contains("ERASE"), "1->0 patch must not erase");
        contains(row(2), String.format("%02x", cleared));

        jump(0x8000 + offset);                      // setting the bit again needs an erase
        console.reset();
        int[] userScreen = new int[512];
        for (int i = 0; i < 512; i++) userScreen[i] = peek(sym("user_screen") + i);
        type(String.format("%02x", old));
        for (int i = 0; i < 512; i++) equal(peek(sym("user_screen") + i), userScreen[i], "user screen kept");
        require(console.toString().contains("ERASE"), "0->1 patch erases the sector");
        after = sector(number);
        for (int i = 0; i < 4096; i++) {
            equal(after[i], before[i], String.format("sector byte $%03x after rewrite", i));
        }
        int[] neighbourAfter = sector(number + 1);
        for (int i = 0; i < 4096; i++) equal(neighbourAfter[i], neighbour[i], "next sector untouched");

        type("k40");
        contains(status(), "bad sector");
        System.out.println("ssd OK");
    }

    // ---------------------------------------------------------------- monitor and screens

    private void testMonitor() {
        type("v");
        require(cpu.getPC() == sym("vu_wait"), "v waits for a key");
        equal(peek(0x6021), 0x32, "v shows the user's screen");
        type("0");
        contains(row(0), "pc ");

        poke(0x3000,
            0xa5, 0x07,             // 3000 lda $07
            0x8d, 0x01, 0x31,       // 3002 sta $3101
            0xa9, 0x5a,             // 3005 lda #$5a
            0x8d, 0x00, 0x31,       // 3007 sta $3100
            0x00, 0xea);            // 300a brk
        poke(0x3100, 0, 0);
        setPc(0x3000);
        type("ra11");
        type("rx22");
        type("ry33");
        type("rp21");
        jump(0x3002);
        type("b");
        type("\t");
        jump(0x3010);

        leave();                                    // esc: the user's registers go on the monitor's stack
        require(row(0).isBlank(), "esc clears the screen");
        contains(row(15), ">");
        monitorCommand("s");
        contains(row(14), "pc3000 p21 a11 x22 y33 sf9");   // the monitor shows its own S: the user's S - 6
        System.out.println("monitor OK");
    }

    // ---------------------------------------------------------------- sessions

    private void testResume() {
        monitorCommand("u - - 44");                 // the monitor changes a register
        contains(row(14), "a44");
        debug("");
        equal(var("view"), 1, "view kept");
        equal(word("cur"), 0x3010, "cursor kept");
        contains(row(0), "pc 3000 a 44 x 22 y 33 s ff");
        contains(row(1), "p 21");
        type("\t");
        jump(0x3002);
        contains(row(2), " * 3002 8d 01 31");

        leave();                                    // x runs the program from the debugger's pc
        monitor("x\n");
        until(() -> kbEmpty() && cpu.getPC() == sym("mon_loop"), "brk back to the monitor");
        equal(peek(0x3101), 0x77, "the program sees the user's zero page");
        equal(peek(0x3100), 0x5a, "the program ran");
        debug("");                                  // d continues from the program's brk
        equal(word("reg_pc"), 0x300c, "pc after the program's brk");
        equal(var("reg_a"), 0x5a, "a from the program");
        equal(var("reg_s"), 0xff, "s after brk");
        equal(var("view"), 0, "code view after the pc moved");
        equal(word("cur"), 0x300c, "cursor at the new pc");
        contains(row(2), ">  300c");
        jump(0x3002);
        contains(row(2), " * 3002");
        System.out.println("resume OK");
    }

    private void testOverwrite() {
        int bpOn = sym("bp_on");
        poke(0x4000,
            0xa2, 0x00,             // 4000 ldx #0
            0xa9, 0xaa,             // 4002 lda #$aa
            0x9d, 0x00, 0x6e,       // 4004 sta $6e00,x: fill debugger_scratch like 6 KB graphics
            0x9d, 0x00, 0x6f,       // 4007 sta $6f00,x
            0x9d, 0x00, 0x70,       // 400a sta $7000,x
            0x9d, 0x00, 0x71,       // 400d sta $7100,x
            0xe8,                   // 4010 inx
            0xd0, 0xf1,             // 4011 bne $4004
            0xea,                   // 4013 nop
            0x8d, bpOn & 0xff, bpOn >> 8,   // 4014 sta bp_on
            0xea);                  // 4017 nop
        jump(0x4013);
        type("b");
        jump(0x4017);
        type("b");
        setPc(0x4000);
        type("g");
        equal(word("reg_pc"), 0x4013, "breakpoint after the program filled the debugger's memory");
        contains(status(), "breakpoint");
        equal(peek(0x4013), 0xea, "breakpoint removed");
        equal(peek(0x4017), 0xea, "other breakpoint removed");
        contains(row(2), ">* 4013 ea       nop");
        contains(row(4), " * 4017 ea       nop");

        stepAndCheck(0x4014);
        stepAndCheck(0x4017);                       // the step wrote into the breakpoint table
        contains(status(), "debugger memory overwritten");
        equal(word("cur"), 0x4017, "cursor at the pc");
        for (int i = 0; i <= 8; i++) equal(peek(bpOn + i), 0, "breakpoints cleared");
        stepAndCheck(0x4018);
        System.out.println("overwritten memory OK");
    }

    private void testUnfinishedRun() {
        int irq = sym("irq");
        poke(0x4100,
            0xa9, irq & 0xff,       // 4100 lda #<irq: the program takes back the irq vector
            0x85, 0x1e,             // 4102 sta $1e
            0xa9, irq >> 8,         // 4104 lda #>irq
            0x85, 0x1f,             // 4106 sta $1f
            0x00, 0xea,             // 4108 brk: goes to the monitor, not the debugger
            0xea);                  // 410a nop
        jump(0x410a);
        type("b");
        setPc(0x4100);
        press(PS2.getScanCode(KeyEvent.VK_G));
        until(() -> kbEmpty() && cpu.getPC() == sym("mon_loop"), "brk to the monitor during g");
        equal(peek(0x410a), 0x00, "breakpoint still in memory");
        debug("");
        equal(peek(0x410a), 0xea, "d removes the breakpoints of an unfinished run");
        equal(word("reg_pc"), 0x410a, "pc from the monitor");
        contains(row(2), ">* 410a ea       nop");
        System.out.println("unfinished run OK");
    }

    private void testNewSession() {
        leave();
        debug(" 2000");
        equal(word("reg_pc"), 0x2000, "d with an address");
        contains(row(0), "pc 2000 a 00 x 00 y 00 s ff");
        contains(row(1), "p 20 ");
        equal(var("view"), 0, "code view");
        equal(word("cur"), 0x2000, "cursor at the pc");
        for (int i = 0; i <= 8; i++) equal(peek(sym("bp_on") + i), 0, "no breakpoints");

        jump(0x2010);
        type("b");
        leave();
        poke(sym("user_screen") + 0x40, peek(sym("user_screen") + 0x40) ^ 0xff);
        debug("");
        equal(word("reg_pc"), 0x1000, "a lost session starts over at $1000");
        contains(row(0), "pc 1000 a 00 x 00 y 00 s ff");
        for (int i = 0; i <= 8; i++) equal(peek(sym("bp_on") + i), 0, "breakpoints of a lost session");
        System.out.println("new session OK");
    }

    private void run() throws Exception {
        until(() -> cpu.getPC() == sym("mon_loop"), "Monitor boot");
        monitor("d");
        scan(PS2.getScanCode(KeyEvent.VK_ENTER));  // the release arrives after the debugger starts
        until(() -> cpu.getPC() == sym("key_loop"), "Debugger start");
        scan(0xf0);
        scan(PS2.getScanCode(KeyEvent.VK_ENTER));
        scan(PS2.getScanCode(KeyEvent.VK_ENTER));  // a stray key must not break anything
        scan(0xf0);
        scan(PS2.getScanCode(KeyEvent.VK_ENTER));
        idle();
        equal(word("reg_pc"), 0x1000, "initial pc");
        contains(row(0), "pc 1000 a 00 x 00 y 00 s ff");
        contains(row(1), "p 20 nvdizc  ssd");
        contains(row(1), "code");
        contains(status(), "s n g b p r j k v . tab esc");

        testDisassembler();
        testStepping();
        testNavigation();
        testRunning();
        testHexEditor();
        testSsd();
        type("\t");
        testMonitor();
        testResume();
        testOverwrite();
        testUnfinishedRun();
        testNewSession();
        System.out.println("All debugger tests passed (" + checks + " checks)");
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: DebuggerTest kit_os.sym");
            System.exit(2);
        }
        new DebuggerTest(Path.of(args[0])).run();
    }
}
