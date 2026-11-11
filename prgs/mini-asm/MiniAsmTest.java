import java.awt.event.KeyEvent;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BooleanSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/*
Drives the mini assembler in the KiT emulator: assembles every 65C02 opcode and compares
the bytes with Kick Assembler, checks errors and directives, runs an assembled program,
and saves it to the SSD and runs it with the monitor's f command.

Usage: java MiniAsmTest <mini-asm.prg> <video_mon.sym> <KickAss.jar>
(run from a directory holding video_mon.bin, ssd.bin, and character-set.png)
*/
public class MiniAsmTest {
    private final CPU cpu;
    private final Bus bus;
    private final VIA via1;
    private final VIA via2;
    private final SSD ssd;
    private final Map<String, Integer> monitor = new HashMap<>();
    private final Map<String, Integer> asm = new HashMap<>();
    private final Path kickAss;

    private static Object field(Object object, Class<?> type, String name) throws Exception {
        Field field = type.getDeclaredField(name);
        field.setAccessible(true);
        return field.get(object);
    }

    private static void readSymbols(String text, Map<String, Integer> into) {
        Matcher matcher = Pattern.compile("(?m)^\\s*\\.label (\\w+)=\\$([0-9a-f]+)").matcher(text);
        while (matcher.find()) into.put(matcher.group(1), Integer.parseInt(matcher.group(2), 16));
    }

    private MiniAsmTest(Path program, Path monitorSyms, Path kickAss) throws Exception {
        this.kickAss = kickAss;
        String monitorText = Files.readString(monitorSyms);
        readSymbols(monitorText.replaceAll("(?s)\\.namespace.*?\\n}", ""), monitor);

        String asmText = Files.readString(program.resolveSibling("mini-asm.sym"));
        int start = asmText.indexOf(".namespace mini_asm {");
        require(start >= 0, "mini_asm namespace in symbol file");
        int depth = 0, end = start;
        for (int i = asmText.indexOf('{', start); i < asmText.length(); i++) {
            if (asmText.charAt(i) == '{') depth++;
            if (asmText.charAt(i) == '}' && --depth == 0) { end = i; break; }
        }
        readSymbols(asmText.substring(start, end), asm);

        KiT kit = new KiT();
        cpu = (CPU) field(kit, KiT.class, "cpu");
        bus = (Bus) field(kit, KiT.class, "bus");
        via1 = (VIA) field(kit, KiT.class, "via1");
        via2 = (VIA) field(kit, KiT.class, "via2");
        ssd = (SSD) field(kit, KiT.class, "ssd");
        ((UART) field(kit, KiT.class, "uart")).loadPrg(program.toFile());
    }

    private static int lookup(Map<String, Integer> symbols, String name) {
        Integer value = symbols.get(name);
        if (value == null) throw new AssertionError("Missing symbol: " + name);
        return value;
    }

    private int mon(String name) { return lookup(monitor, name); }
    private int sym(String name) { return lookup(asm, name); }

    private int read(int address) { return bus.debugRead(address); }
    private int word(int address) { return read(address) | read(address + 1) << 8; }
    private int pc() { return word(sym("pc")); }

    private void step() {
        long before = cpu.getCycleCount();
        cpu.step();
        int cycles = (int) (cpu.getCycleCount() - before);
        via1.updateCycleCount(cycles);
        via2.updateCycleCount(cycles);
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

    private void scan(int code) {
        via1.kbByte(code);
        steps(500);
    }

    private void key(int keyCode, boolean shifted) {
        int code = PS2.getScanCode(keyCode);
        require(code != PS2.ERROR_CODE, "Missing emulator key mapping: " + KeyEvent.getKeyText(keyCode));
        int shift = PS2.getScanCode(KeyEvent.VK_SHIFT);
        if (shifted) scan(shift);
        scan(code);
        scan(0xf0);
        scan(code);
        if (shifted) {
            scan(0xf0);
            scan(shift);
        }
    }

    private void type(String text) {
        String letters = "abcdefghijklmnopqrstuvwxyz";
        String plain = "0123456789 \n\b,;./'-=[]\\`";
        String shifted = ")!@#$%^&*( \n\b<:>?\"_+{}|~";
        int[] punctuation = {
            KeyEvent.VK_0, KeyEvent.VK_1, KeyEvent.VK_2, KeyEvent.VK_3, KeyEvent.VK_4,
            KeyEvent.VK_5, KeyEvent.VK_6, KeyEvent.VK_7, KeyEvent.VK_8, KeyEvent.VK_9,
            KeyEvent.VK_SPACE, KeyEvent.VK_ENTER, KeyEvent.VK_BACK_SPACE,
            KeyEvent.VK_COMMA, KeyEvent.VK_SEMICOLON, KeyEvent.VK_PERIOD,
            KeyEvent.VK_SLASH, KeyEvent.VK_QUOTE, KeyEvent.VK_MINUS, KeyEvent.VK_EQUALS,
            KeyEvent.VK_OPEN_BRACKET, KeyEvent.VK_CLOSE_BRACKET,
            KeyEvent.VK_BACK_SLASH, KeyEvent.VK_BACK_QUOTE
        };
        for (char c : text.toCharArray()) {
            int index = letters.indexOf(Character.toLowerCase(c));
            if (index >= 0) {
                key(KeyEvent.VK_A + index, Character.isUpperCase(c));
            } else if ((index = plain.indexOf(c)) >= 0) {
                key(punctuation[index], false);
            } else if ((index = shifted.indexOf(c)) >= 0) {
                key(punctuation[index], true);
            } else {
                throw new AssertionError("Unsupported test character: " + c);
            }
        }
    }

    private void esc() {
        key(KeyEvent.VK_ESCAPE, false);
    }

    private String screen() {
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < 512; i++) {
            int value = read(0x6000 + i) & 127;
            text.append((char) (value >= 1 && value <= 26 ? 'a' + value - 1 : value));
            if (i % 32 == 31) text.append('\n');
        }
        return text.toString();
    }

    private String row(int row) {
        return screen().split("\n")[row];
    }

    private static void require(boolean condition, String description) {
        if (!condition) throw new AssertionError(description);
    }

    private void contains(String text, String expected) {
        require(text.contains(expected), "Expected \"" + expected + "\" in:\n" + text);
    }

    /* Wait until the assembler is waiting for a new line at the given address */
    private void prompt(int address) {
        until(() -> cpu.getPC() == sym("rl_wait") && read(sym("len")) == 0
            && read(sym("maxlen")) == 26 && pc() == address,
            "Assembler prompt at $" + Integer.toHexString(address));
        contains(row(15), String.format("%04x: ", address));
    }

    /* Type a line at the prompt; return the screen once the next prompt (at next) is up */
    private String line(String text, int next) {
        type(text + "\n");
        prompt(next);
        return screen();
    }

    private void monitorPrompt() {
        until(() -> cpu.getPC() == mon("mon_loop") && row(15).startsWith(">"), "Monitor prompt");
    }

    /* Enter an assembler line that must fail with the message, leaving memory and pc alone */
    private void error(String text, String message) {
        int address = pc();
        int[] before = new int[8];
        for (int i = 0; i < 8; i++) before[i] = read(address + i);
        String result = line(text, address);
        String[] rows = result.split("\n");
        require(rows[14].startsWith("? " + message), "\"" + text + "\" should fail with \"" + message
            + "\":\n" + result);
        for (int i = 0; i < 8; i++) require(read(address + i) == before[i], "\"" + text + "\" changed memory");
    }

    private void expectBytes(int address, int... bytes) {
        for (int i = 0; i < bytes.length; i++) {
            require(read(address + i) == bytes[i], String.format("Byte at $%04x: expected %02x, got %02x",
                address + i, bytes[i], read(address + i)));
        }
    }

    private void expectListing(String screen, int address, String bytes, String text) {
        String listed = screen.split("\n")[14];
        String head = String.format("%04x: %s", address, bytes);
        require(listed.startsWith(head), "Listing should start with \"" + head + "\":\n" + screen);
        if (text.isEmpty()) require(listed.trim().equals(head), "Listing should be \"" + head + "\":\n" + screen);
        else require(listed.substring(15).trim().equals(text), "Listing should show \"" + text + "\":\n" + screen);
    }

    /* One source line for each defined opcode */
    private record Op(int opcode, String source, String listing, int size) {}

    private List<Op> opcodeLines(int origin) throws Exception {
        CPU.Instruction[] instructions = (CPU.Instruction[]) field(cpu, CPU.class, "instructions");
        List<Op> ops = new ArrayList<>();
        int address = origin;
        boolean forward = true;
        for (int opcode = 0; opcode < 256; opcode++) {
            CPU.Instruction inst = instructions[opcode];
            String kind = inst.getClass().getSimpleName();
            if (kind.equals("UndefinedNOP") || kind.equals("Breakpoint")) continue;
            String mnemonic = inst.mnemonic;
            String mode = inst.addrMode.toString();
            if (opcode == 0x1a || opcode == 0x3a) mode = "ACCUMULATOR";

            String operand;
            String listing = null;
            int size;
            if (mnemonic.startsWith("bbr") || mnemonic.startsWith("bbs")) {
                operand = String.format("$12,$%04x", address + 3 + 5);
                size = 3;
            } else if (opcode == 0x7c) {
                operand = "($1234,x)";
                size = 3;
            } else {
                switch (mode) {
                    case "IMPLIED" -> { operand = ""; size = 1; }
                    case "ACCUMULATOR" -> { operand = ""; listing = mnemonic + " a"; size = 1; }
                    case "IMMEDIATE" -> { operand = "#$12"; size = 2; }
                    case "ZEROPAGE" -> { operand = "$12"; size = 2; }
                    case "ZEROPAGE_X" -> { operand = "$12,x"; size = 2; }
                    case "ZEROPAGE_Y" -> { operand = "$12,y"; size = 2; }
                    case "X_INDIRECT" -> { operand = "($12,x)"; size = 2; }
                    case "INDIRECT_Y" -> { operand = "($12),y"; size = 2; }
                    case "ZEROPAGE_INDIRECT" -> { operand = "($12)"; size = 2; }
                    case "ABSOLUTE" -> { operand = "$1234"; size = 3; }
                    case "ABSOLUTE_X" -> { operand = "$1234,x"; size = 3; }
                    case "ABSOLUTE_Y" -> { operand = "$1234,y"; size = 3; }
                    case "INDIRECT" -> { operand = "($1234)"; size = 3; }
                    case "RELATIVE" -> {
                        operand = String.format("$%04x", address + 2 + (forward ? 0x7f : -0x80));
                        forward = !forward;
                        size = 2;
                    }
                    default -> throw new AssertionError("Unknown mode " + mode);
                }
            }
            String source = operand.isEmpty() ? mnemonic : mnemonic + " " + operand;
            ops.add(new Op(opcode, source, listing == null ? source : listing, size));
            address += size;
        }
        return ops;
    }

    private byte[] kickAssemble(List<Op> ops, int origin) throws Exception {
        Path dir = Files.createTempDirectory("mini-asm-ka");
        StringBuilder source = new StringBuilder(".cpu _65c02\n*=$" + Integer.toHexString(origin) + "\n");
        for (Op op : ops) source.append("    ").append(op.source()).append('\n');
        Path file = dir.resolve("opcodes.asm");
        Files.writeString(file, source);
        Process process = new ProcessBuilder("java", "-jar", kickAss.toString(), "-binfile", file.toString())
            .directory(dir.toFile()).redirectErrorStream(true).start();
        String log = new String(process.getInputStream().readAllBytes());
        require(process.waitFor() == 0 && Files.exists(dir.resolve("opcodes.bin")), "Kick Assembler failed:\n" + log);
        byte[] bytes = Files.readAllBytes(dir.resolve("opcodes.bin"));
        try (var files = Files.list(dir)) {
            for (Path path : files.toList()) Files.delete(path);
        }
        Files.delete(dir);
        return bytes;
    }

    private void testAllOpcodes() throws Exception {
        int origin = 0x2000;
        List<Op> ops = opcodeLines(origin);
        require(ops.size() == 212, "Expected 212 65C02 opcodes, found " + ops.size());
        byte[] expected = kickAssemble(ops, origin);

        line("2000:", origin);
        int address = origin;
        for (Op op : ops) {
            require((expected[address - origin] & 255) == op.opcode(),
                String.format("Kick Assembler encodes \"%s\" as %02x", op.source(), expected[address - origin]));
            StringBuilder bytes = new StringBuilder();
            for (int i = 0; i < op.size(); i++) {
                bytes.append(i == 0 ? "" : " ").append(String.format("%02x", expected[address - origin + i] & 255));
            }
            String result = line(op.source(), address + op.size());
            expectListing(result, address, bytes.toString(), op.listing());
            address += op.size();
        }
        require(address - origin == expected.length, "Total size matches Kick Assembler");
        for (int i = 0; i < expected.length; i++) {
            require(read(origin + i) == (expected[i] & 255), String.format(
                "Mismatch at $%04x: expected %02x, got %02x", origin + i, expected[i] & 255, read(origin + i)));
        }
        System.out.println("assembled all " + ops.size() + " opcodes");
    }

    private void testSyntax() {
        line("3000:", 0x3000);
        expectListing(line("asl a", 0x3001), 0x3000, "0a", "asl a");
        expectListing(line("LDA #'A", 0x3003), 0x3001, "a9 41", "lda #$41");
        expectListing(line("lda #'a", 0x3005), 0x3003, "a9 61", "lda #$61");
        expectListing(line("lda #' ", 0x3007), 0x3005, "a9 20", "lda #$20");
        expectListing(line("  lda  ( 12 ) , y ", 0x3009), 0x3007, "b1 12", "lda ($12),y");
        expectListing(line("lda 0012", 0x300c), 0x3009, "ad 12 00", "lda $0012");
        expectListing(line("lda 12,y", 0x300f), 0x300c, "b9 12 00", "lda $0012,y");
        expectListing(line("jmp (12)", 0x3012), 0x300f, "6c 12 00", "jmp ($0012)");
        expectListing(line("jmp (12,x)", 0x3015), 0x3012, "7c 12 00", "jmp ($0012,x)");
        expectListing(line("ldx $ff,y", 0x3017), 0x3015, "b6 ff", "ldx $ff,y");
        expectListing(line("inc", 0x3018), 0x3017, "1a", "inc a");
        expectListing(line("BBS7 $80,3018", 0x301b), 0x3018, "ff 80 fd", "bbs7 $80,$3018");
        expectListing(line("bra 301b", 0x301d), 0x301b, "80 fe", "bra $301b");
        expectListing(line(".b 1,2 ff 'A", 0x3021), 0x301d, "01 02 ff 41", "");
        expectListing(line(".t Hi, KiT!", 0x3029), 0x3021, "48 69 2c 20 4b 69 54 21", "");
        expectListing(line(".b 0 1 2 3 4 5 6 7 8", 0x3032), 0x3029, "00 01 02 03 04 05 06 07+", "");
        expectListing(line("3100: nop", 0x3101), 0x3100, "ea", "nop");
        expectListing(line("$3200 : rts", 0x3201), 0x3200, "60", "rts");
        expectListing(line("lda #$13\b2", 0x3203), 0x3201, "a9 12", "lda #$12");
        line("", 0x3203);
        expectBytes(0x3000, 0x0a, 0xa9, 0x41, 0xa9, 0x61, 0xa9, 0x20, 0xb1, 0x12, 0xad, 0x12, 0x00);
        expectBytes(0x301d, 0x01, 0x02, 0xff, 0x41, 'H', 'i', ',', ' ', 'K', 'i', 'T', '!');

        error("foo", "bad mnemonic");
        error("ld", "bad mnemonic");
        error("ldaa", "bad mnemonic");
        error("rmb", "bad mnemonic");
        error("rmb8 $12", "bad mnemonic");
        error("lda3 $12", "bad mnemonic");
        error("lda #$123", "out of range");
        error("lda ($1234),y", "out of range");
        error("bbr0 $1234,$3203", "out of range");
        error("bne $3300", "out of range");
        error("bne $3184", "out of range");
        error("sta #$12", "bad address mode");
        error("jsr ($1234)", "bad address mode");
        error("lda", "bad address mode");
        error("lda $12,z", "bad operand");
        error("lda $12345", "bad operand");
        error("lda ($12", "bad operand");
        error("lda $", "bad operand");
        error("lda #", "bad operand");
        error(".x", "bad directive");
        error(".b", "bad operand");
        error(".b 100", "out of range");
        error("5000: nop", "overlaps mini-asm");
        require(pc() == 0x3203, "Errors keep the address");
        expectListing(line("bne $3282", 0x3205), 0x3203, "d0 7d", "bne $3282");
        expectListing(line("bne $3187", 0x3207), 0x3205, "d0 80", "bne $3187");
        System.out.println("syntax, directives, and errors ok");
    }

    private static final String[] PROGRAM = {
        "1000: ldx #5",
        "lda #0",
        "clc",
        "adc #3",
        "dex",
        "bne 1004",
        "sta 300",
        "brk",
    };

    private void testRunAndSave() throws Exception {
        line("1000:", 0x1000);
        int[] next = {0x1002, 0x1004, 0x1005, 0x1007, 0x1008, 0x100a, 0x100d, 0x100e};
        for (int i = 0; i < PROGRAM.length; i++) line(PROGRAM[i], next[i]);
        expectBytes(0x1000, 0xa2, 0x05, 0xa9, 0x00, 0x18, 0x69, 0x03, 0xca, 0xd0, 0xfa, 0x8d, 0x00, 0x03, 0x00);

        // esc to the monitor, x back to the assembler
        esc();
        monitorPrompt();
        type("x\n");
        prompt(0x100e);

        // run the program from the monitor, then g 5000 back to the assembler
        esc();
        monitorPrompt();
        bus.write(0x300, 0);
        type("g 1000\n");
        until(() -> read(0x300) == 0x0f, "Assembled program result");
        monitorPrompt();
        type("g 5000\n");
        prompt(0x100e);
        System.out.println("assembled program runs");

        // save to the SSD
        int sector = 0x3f;
        int[] data = (int[]) field(ssd, SSD.class, "data");
        int base = sector << 12;
        if (data[base] == 0) {
            type(".s 3f 1000\n");
            until(() -> row(15).startsWith("sector in use. overwrite? y/n"), "Overwrite prompt");
            type("y");
        } else {
            type(".s 3f 1000 100e\n");
        }
        until(() -> row(15).startsWith("name: ") && cpu.getPC() == sym("rl_wait"), "Name prompt");
        type("sum\n");
        prompt(0x100e);
        contains(row(14), "saved. run with f 3f");

        int sum1 = 0, sum2 = 0;
        for (int i = 0; i < 14; i++) {
            sum1 = (sum1 + read(0x1000 + i)) & 255;
            sum2 = (sum2 + sum1) & 255;
        }
        int[] header = {0x00, 0x00, 0x00, 0x10, 0x0e, 0x00, sum1, sum2, 0xff, 0xff};
        for (int i = 0; i < header.length; i++) {
            require(data[base + i] == header[i], String.format("SSD header byte %02x: expected %02x, got %02x",
                i, header[i], data[base + i]));
        }
        require(data[base + 0x10] == 's' && data[base + 0x11] == 'u' && data[base + 0x12] == 'm'
            && data[base + 0x13] == 0 && data[base + 0x20] == 0, "SSD file name");
        for (int i = 0; i < 14; i++) require(data[base + 0x100 + i] == read(0x1000 + i), "SSD file data");

        // saving over it asks first; n cancels
        type(".s 3f 1000\n");
        until(() -> row(15).startsWith("sector in use. overwrite? y/n"), "Overwrite prompt");
        type("n");
        prompt(0x100e);
        contains(row(14), "cancelled");
        error(".s 40 1000", "bad sector");
        error(".s 3f 1000 1000", "bad size");
        error(".s 3f 1000 0fff", "bad size");
        error(".s 3f 1000 1f00", "bad size");

        // run the saved file with the monitor's f command
        esc();
        monitorPrompt();
        for (int i = 0; i < 14; i++) bus.write(0x1000 + i, 0);
        bus.write(0x300, 0);
        type("f 3f\n");
        until(() -> read(0x300) == 0x0f, "Saved program result");
        monitorPrompt();
        System.out.println("saved program runs with f 3f");
    }

    private void run() throws Exception {
        until(() -> cpu.getPC() == mon("mon_loop"), "Monitor boot");
        type("l\n");
        until(() -> cpu.getPC() == mon("get_yn_loop"), "Serial PRG load");
        type("r");
        prompt(0x1000);
        contains(screen(), "mini-asm. esc: monitor");

        testAllOpcodes();
        testSyntax();
        testRunAndSave();
        System.out.println("All mini-asm emulator tests passed");
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 3) {
            System.err.println("usage: MiniAsmTest <mini-asm.prg> <video_mon.sym> <KickAss.jar>");
            System.exit(2);
        }
        new MiniAsmTest(Path.of(args[0]).toAbsolutePath(), Path.of(args[1]), Path.of(args[2]).toAbsolutePath()).run();
    }
}
