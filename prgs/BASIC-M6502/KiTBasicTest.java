import java.awt.event.KeyEvent;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
import java.util.function.BooleanSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class KiTBasicTest {
    private final CPU cpu;
    private final Bus bus;
    private final VIA via1;
    private final VIA via2;
    private final int[] ssd;
    private final Map<String, Integer> symbols = new HashMap<>();
    private final StringBuilder output = new StringBuilder();
    private final UART uart;
    private int[] big;

    private static Object field(KiT kit, String name) throws Exception {
        Field field = KiT.class.getDeclaredField(name);
        field.setAccessible(true);
        return field.get(kit);
    }

    private KiTBasicTest(Path program) throws Exception {
        Matcher matcher = Pattern.compile("\\.label ([\\w.]+)=\\$([0-9a-f]+)").matcher(
            Files.readString(program.resolveSibling("m6502.sym")));
        while (matcher.find()) {
            symbols.put(matcher.group(1), Integer.parseInt(matcher.group(2), 16));
        }
        KiT kit = new KiT();
        cpu = (CPU) field(kit, "cpu");
        bus = (Bus) field(kit, "bus");
        via1 = (VIA) field(kit, "via1");
        via2 = (VIA) field(kit, "via2");
        Object ssdDevice = field(kit, "ssd");
        Field data = ssdDevice.getClass().getDeclaredField("data");
        data.setAccessible(true);
        ssd = (int[]) data.get(ssdDevice);
        uart = (UART) field(kit, "uart");
        uart.loadPrg(program.toFile());
    }

    private int address(String name) {
        Integer value = symbols.get(name);
        if (value == null) throw new AssertionError("Missing symbol: " + name);
        return value;
    }

    private int word(String name) {
        int address = address(name);
        return bus.debugRead(address) | bus.debugRead(address + 1) << 8;
    }

    private void step() {
        if (cpu.getPC() == address("KIT_PUT_CHAR")) output.append((char) (cpu.getA() & 127));
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
            + "\n" + output);
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

    private void prompt() {
        until(() -> cpu.getPC() == address("KIT_GET_KEY")
            && bus.debugRead(address("input_length")) == 0, "BASIC prompt");
    }

    private String command(String text) {
        prompt();
        int start = output.length();
        type(text + "\n");
        prompt();
        String transcript = output.substring(start);
        int endOfEcho = transcript.indexOf('\r');
        require(endOfEcho >= 0, "Input line must finish with a carriage return");
        return transcript.substring(endOfEcho + 1).replace("\r", "");
    }

    private String screen() {
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < 512; i++) {
            int value = bus.debugRead(0x6000 + i) & 127;
            text.append((char) (value >= 1 && value <= 26 ? 'a' + value - 1 : value));
            if (i % 32 == 31) text.append('\n');
        }
        return text.toString();
    }

    private static void require(boolean condition, String description) {
        if (!condition) throw new AssertionError(description);
    }

    private void contains(String text, String expected) {
        require(text.contains(expected), "Expected " + expected + " in:\n" + text
            + "\nRecent console:\n" + output.substring(Math.max(0, output.length() - 300)));
    }

    private int ssdByte(int sector, int offset) {
        return ssd[sector * 4096 + offset];
    }

    private int ssdWord(int sector, int offset) {
        return ssdByte(sector, offset) | ssdByte(sector, offset + 1) << 8;
    }

    private String ssdName(int sector) {
        StringBuilder name = new StringBuilder();
        for (int i = 0x10; ssdByte(sector, i) != 0; i++) name.append((char) ssdByte(sector, i));
        return name.toString();
    }

    private int[] program() {
        int start = word("TXTTAB");
        int[] bytes = new int[word("VARTAB") - start];
        for (int i = 0; i < bytes.length; i++) bytes[i] = bus.debugRead(start + i);
        return bytes;
    }

    private void ok(String text) {
        String result = command(text);
        require(result.trim().equals("OK"), text + " failed:\n" + result);
    }

    private void saveLoad() {
        java.util.Arrays.fill(ssd, 0xff);

        command("new");
        command("10 print \"Saved\";:for i=1 to 3:print i;:next");
        int[] small = program();
        ok("save 5,\"Hello\"");
        require(ssdByte(5, 0) == 0 && ssdByte(5, 1) == 0x20, "Saved file must be KSF data");
        require(ssdWord(5, 2) == word("TXTTAB") && ssdWord(5, 4) == small.length, "Saved address and size");
        require(ssdByte(5, 8) == 0xff && ssdName(5).equals("Hello"), "Single-sector header");
        command("new");
        ok("load 5");
        require(java.util.Arrays.equals(program(), small), "LOAD by sector must restore the program");
        contains(command("list").replace("\n", ""), "10 PRINT \"Saved\";:FOR I=1 TO 3:PRINT I;:NEXT");
        contains(command("run"), "Saved 1  2  3");

        command("new");
        command("10 print \"Second\"");
        ok("save \"Second\"");
        require(ssdName(0).equals("Second"), "SAVE by name uses the first empty sector");
        command("new");
        command("10 load \"Hello\"");
        contains(command("run"), "OK");
        require(java.util.Arrays.equals(program(), small), "LOAD by name from a running program");
        ok("load \"Second\"");
        contains(command("run"), "Second");
        command("20 print \"Again\"");
        ok("save \"Second\"");
        require(ssdByte(1, 0) == 0xff, "SAVE by name must replace the existing file");
        command("new");
        ok("load \"Second\"");
        contains(command("run"), "Second\nAgain");

        command("new");
        for (int line = 1; line <= 40; line++) {
            command(line + " print \"" + String.valueOf((char) ('a' + line % 26)).repeat(100) + "\"");
        }
        big = program();
        require(big.length > 3840 && big.length < 7680, "Two-sector test program");
        ok("save 20,\"Big\"");
        require(ssdByte(20, 8) == 21 && ssdByte(21, 0) == 0 && ssdByte(21, 8) == 0xff, "Sector chain");
        require(ssdWord(21, 2) == word("TXTTAB") + 3840 && ssdWord(21, 4) == big.length - 3840,
            "Continuation header");
        require(ssdWord(21, 6) == ssdWord(20, 6) && ssdName(21).equals("Big"), "Continuation checksum and name");
        contains(command("save 21,\"Part\""), "?SECTOR IN USE ERROR");
        contains(command("save 63,\"Big\""), "?SSD FULL ERROR");
        command("new");
        ok("load \"Big\"");
        require(java.util.Arrays.equals(program(), big), "Multi-sector LOAD");
        contains(command("run"), "o".repeat(32));

        command("new");
        command("10 print 1");
        ok("save \"Big\"");
        require(ssdByte(20, 8) == 0xff && ssdByte(21, 0) == 0xff, "Shorter SAVE must erase leftover sectors");

        command("new");
        for (int line = 1; line <= 36; line++) {
            command(line + " print \"" + "e".repeat(line <= 34 ? 100 : 57) + "\"");
        }
        int[] even = program();
        require(even.length == 3840, "Exact-sector test program");
        ok("save \"Even\"");
        require(ssdWord(1, 4) == 3841 && ssdByte(1, 8) == 2 && ssdWord(2, 4) == 1,
            "Exact-sector files get a one-byte second sector");
        command("new");
        ok("load \"Even\"");
        require(java.util.Arrays.equals(program(), even), "Exact-sector LOAD");

        contains(command("load 9"), "?FILE NOT FOUND ERROR");
        contains(command("load \"Nope\""), "?FILE NOT FOUND ERROR");
        contains(command("load 64"), "?FC ERROR");
        contains(command("save 1,\"\""), "?FC ERROR");
        contains(command("save \"" + "n".repeat(17) + "\""), "?LS ERROR");
        contains(command("load 5 x"), "?SN ERROR");
        ssd[30 * 4096] = 0;
        ssd[30 * 4096 + 1] = 0;
        contains(command("save 30,\"Prg\""), "?SECTOR IN USE ERROR");
        contains(command("load 30"), "?BAD FILE ERROR");
        ssd[5 * 4096 + 0x105] ^= 1;
        contains(command("load 5"), "?BAD FILE ERROR");
        require(java.util.Arrays.equals(program(), even), "A bad file must not replace the program");
        contains(command("print 6*7"), " 42 ");
    }

    // Load an upload prg from the monitor, run it, and return its message.
    private String upload(String prg) {
        uart.loadPrg(Path.of(prg).toFile());
        type("l\n");
        until(() -> cpu.getPC() == address("get_yn_loop"), "Upload PRG load");
        type("r");
        until(() -> cpu.getPC() == address("mon_loop"), "Upload return to monitor");
        return screen().split("\n")[14].trim();
    }

    private void uploads(String[] args) throws Exception {
        java.util.Arrays.fill(ssd, 0xff);
        ssd[0] = 0;
        ssd[1] = 0;

        command("new");
        for (String line : Files.readAllLines(Path.of(args[1]))) {
            if (!line.isBlank()) command(line);
        }
        int[] typed = program();

        key(KeyEvent.VK_ESCAPE, false);
        until(() -> cpu.getPC() == address("mon_loop"), "Escape to monitor for uploads");
        String message = upload(args[2]);
        require(message.equals("saved to sector 1"), "Upload to the first free sector: " + message);
        require(ssdByte(1, 1) == 0x20 && ssdWord(1, 2) == word("TXTTAB") && ssdWord(1, 4) == typed.length
            && ssdName(1).equals("upload-test"), "Uploaded file header");
        message = upload(args[3]);
        require(message.equals("saved to sector 40"), "Upload to a chosen sector: " + message);
        require(ssdByte(40, 8) == 41 && ssdWord(41, 2) == word("TXTTAB") + 3840 && ssdName(41).equals("Big"),
            "Uploaded multi-sector file");
        message = upload(args[4]);
        require(message.equals("error: sector in use"), "Upload to an in-use sector: " + message);
        message = upload(args[2]);
        require(message.equals("saved to sector 1") && ssdByte(2, 0) == 0xff,
            "Upload replaces the file with the same name: " + message);

        type("g 1000\n");
        ok("load \"upload-test\"");
        require(java.util.Arrays.equals(program(), typed), "Uploaded program must match the typed one");
        contains(command("run"), "first\nHello, World from bas2prg\n 1  2  3 \nPRINTa:b\n"
            + "after data\nrem data to 11 \nSeventy\nreplaced\n");
        ok("load \"Big\"");
        require(java.util.Arrays.equals(program(), big), "Uploaded multi-sector program");
        contains(command("run"), "o".repeat(32));
    }

    // Run until the program polls for a key with GET, or BASIC prompts.
    private void waitForKey(String description) {
        int polls = 0;
        for (long i = 0; i < 1_000_000_000L; i++) {
            if (cpu.getPC() == address("KIT_GET_KEY") && ++polls > 2000) return;
            step();
        }
        throw new AssertionError(description + " timed out\n" + output);
    }

    private int countCells(java.util.function.IntPredicate test) {
        int count = 0;
        for (int i = 0; i < 512; i++) if (test.test(bus.debugRead(0x6000 + i))) count++;
        return count;
    }

    private void runExample(String name) {
        prompt();
        type("load \"" + name + "\"\nrun\n");
        waitForKey(name);
    }

    private void examples(String[] args) {
        key(KeyEvent.VK_ESCAPE, false);
        until(() -> cpu.getPC() == address("mon_loop"), "Escape to monitor for examples");
        for (int i = 5; i < 8; i++) contains(upload(args[i]), "saved to sector");
        type("g 1000\n");
        int start = output.length();

        runExample("mandel");
        require(bus.debugRead(0x6000 + 7 * 32 + 24) == 128, "Mandelbrot set is black");
        require(countCells(v -> v > 143) > 200, "Mandelbrot colours");
        type(" ");

        runExample("lissajous");
        for (int figure = 0; figure < 5; figure++) {
            require(countCells(v -> v > 128 && v < 256) > 40, "Lissajous figure " + figure);
            type(" ");
            waitForKey("lissajous");
        }

        runExample("music");
        contains(output.substring(start).replaceAll("\\s", ""), "runE4E4F4G4G4F4E4D4C4C4D4E4E4D4D4");
        require(countCells(v -> v > 128) > 20, "Music piano roll");
        require(!output.substring(start).contains("?"), "Examples must run without errors:\n"
            + output.substring(start));
    }

    private void run(String[] args) throws Exception {
        until(() -> cpu.getPC() == address("mon_loop"), "Monitor boot");
        type("l\n");
        until(() -> cpu.getPC() == address("get_yn_loop"), "Serial PRG load");
        type("r");
        prompt();
        contains(output.toString(), "KiT BASIC V1.1");
        require(word("MEMSIZ") == 0x6000, "BASIC memory must end below VRAM");
        require(word("TXTTAB") == address("RAMLOC") + 1, "Program start");
        require(address("basic_zp_start") == 0x80 && address("basic_zp_end") == 0xff,
            "Private zero-page bounds");
        require(bus.debugRead(0x1e) == (address("irq") & 255)
            && bus.debugRead(0x1f) == (address("irq") >> 8), "Monitor IRQ vector");

        contains(command("print 2+3*4"), " 14 ");
        contains(command("a=7:print a=7"), "-1 ");
        contains(command("print \"=+-[]\\`{}|~\""), "=+-[]\\`{}|~");
        contains(command("print int(exp(1)*1000)"), " 2718 ");
        contains(command("print int(log(10)*1000)"), " 2302 ");
        contains(command("print int(sin(1)*1000)"), " 841 ");
        contains(command("print int(atn(1)*1000)"), " 785 ");
        contains(command("print left$(\"Hello\",2)"), "He");
        contains(command("dim a(3):a(2)=17:print a(2)"), " 17 ");
        contains(command("dim b%(3):b%(1)=-123:print b%(1)"), "-123 ");
        command("5 def fnf(x)=x*x:print fnf(5)");
        command("10 for i=1 to 3:print i;:next i");
        command("20 gosub 100:end");
        command("100 print \"Sub\":return");
        contains(command("list"), "10 FOR I=1 TO 3:PRINT I;:NEXT I");
        String result = command("run");
        contains(result, " 25 ");
        contains(result, " 1  2  3 Sub");
        command("new");
        command("10 data 7,11,\"Ok\"");
        command("20 read a,b,a$:print a+b;a$");
        contains(command("run"), " 18 Ok");
        contains(command("print 1/0"), "?/0 ERROR");
        contains(screen(), "?/0 ERROR");
        contains(command("print 6*7"), " 42 ");
        contains(command("print 41\b2"), " 42 ");
        contains(command("print \"" + "x".repeat(64) + "\""), "x".repeat(32) + "\n" + "x".repeat(32));
        contains(screen(), "x".repeat(32) + "\n" + "x".repeat(32));
        contains(command("print \"" + "m".repeat(231) + "\"").replace("\n", ""), "m".repeat(231));
        contains(command("print \"" + "m".repeat(232) + "\""), "?LINE TOO LONG");
        contains(command("print 6*7"), " 42 ");

        command("new");
        command("10 input a:print a");
        prompt();
        type("run\n");
        until(() -> cpu.getPC() == address("KIT_GET_KEY")
            && bus.debugRead(address("input_in_program")) == 1, "INPUT prompt");
        int start = output.length();
        type("123\n");
        prompt();
        contains(output.substring(start), " 123 ");
        type("run\n");
        until(() -> cpu.getPC() == address("KIT_GET_KEY")
            && bus.debugRead(address("input_in_program")) == 1, "INPUT cancellation");
        start = output.length();
        key(KeyEvent.VK_ESCAPE, false);
        prompt();
        contains(output.substring(start), "BREAK IN  10");
        contains(command("print 6*7"), " 42 ");

        command("new");
        command("10 get a$:if a$=\"\" then 10");
        command("20 print a$");
        type("run\n");
        steps(10000);
        start = output.length();
        type("z");
        prompt();
        contains(output.substring(start), "z");

        command("new");
        command("10 a$=\"\":for i=1 to 200:a$=a$+\"x\":next");
        command("20 print len(a$)");
        contains(command("run"), " 200 ");
        require(word("FRETOP") > word("STREND"), "String garbage collection must preserve heap space");

        command("new");
        for (int i = 0x6200; i < 0x7800; i++) bus.write(i, 0x5a);
        contains(command("dim z(3000)"), "?OM ERROR");
        for (int i = 0x6200; i < 0x7800; i++) {
            require(bus.debugRead(i) == 0x5a, "Allocation must not write past RAM at $" + Integer.toHexString(i));
        }
        require(word("FRETOP") <= 0x6000 && word("STREND") < 0x6000, "Heap bounds after allocation failure");
        command("10 gosub 10");
        contains(command("run"), "?OM ERROR IN  10");
        contains(command("print 6*7"), " 42 ");

        command("new");
        command("10 goto 10");
        type("run\n");
        steps(10000);
        key(KeyEvent.VK_ESCAPE, false);
        prompt();
        contains(output.toString(), "BREAK IN  10");
        start = output.length();
        type("cont\n");
        steps(10000);
        type("a".repeat(33));
        require(bus.debugRead(address("key_overflow")) == 1, "Keyboard overflow must be reported");
        key(KeyEvent.VK_ESCAPE, false);
        prompt();
        contains(output.substring(start), "BREAK IN  10");
        contains(output.substring(start), "?KEY BUFFER FULL");
        contains(command("print 6*7"), " 42 ");

        saveLoad();
        uploads(args);
        examples(args);

        key(KeyEvent.VK_ESCAPE, false);
        until(() -> cpu.getPC() == address("mon_loop"), "Escape to monitor");
        type("g 1000\n");
        prompt();
        contains(command("print 6*7"), " 42 ");

        System.out.println("PASS: monitor serial load, startup, keyboard, video, arithmetic,");
        System.out.println("strings, arrays, functions, LIST/RUN, DATA/READ, INPUT/GET, editing,");
        System.out.println("line limits, scrolling, garbage collection, heap/stack exhaustion, Escape/CONT,");
        System.out.println("SSD SAVE/LOAD by sector and name, multi-sector files, SSD errors,");
        System.out.println("bas2prg uploads, example programs,");
        System.out.println("monitor return, and cold restart.");
        System.out.printf("BASIC RAM: $%04x-$5fff (%d bytes before program terminator).%n",
            address("RAMLOC"), 0x6000 - address("RAMLOC"));
    }

    public static void main(String[] args) throws Exception {
        new KiTBasicTest(Path.of(args[0])).run(args);
    }
}
