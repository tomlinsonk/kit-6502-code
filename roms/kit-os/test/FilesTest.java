import java.awt.event.KeyEvent;
import java.io.File;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.Deque;
import java.util.HashMap;
import java.util.Map;
import java.util.function.BooleanSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/*
Drives the kit-os file manager (f) and saving after a load (l, then s) in the KiT
emulator. Run from a directory holding kit_os.bin, ssd.bin (a copy of kit-emu's),
and character-set.png. Takes the path to kit_os.sym.
*/
public class FilesTest {
    private static final int SECTOR = 4096;
    private static final int KB_READ_PTR = 0x10;
    private static final int KB_WRITE_PTR = 0x11;
    private static final int USER_RAM_START = 0x0300;
    private static final int USER_RAM_END = 0x6000;
    private static final String STOCK_SECTORS =
        "00 01 02 03 04 05 08 09 0a 0b 0c 0e 0f 10 11 12 13 14 15 3e 3f";

    private final CPU cpu;
    private final Bus bus;
    private final VIA via1;
    private final VIA via2;
    private final UART uart;
    private final int[] flash;
    private final int[] original;
    private final Map<String, Integer> symbols;

    private static Object field(Object object, String name) throws Exception {
        Field field = object.getClass().getDeclaredField(name);
        field.setAccessible(true);
        return field.get(object);
    }

    // Read KickAssembler's symbol file, naming labels by their namespaces (e.g. files.main_loop)
    private static Map<String, Integer> loadSymbols(Path file) throws Exception {
        Pattern namespace = Pattern.compile("^\\.namespace (\\w+) \\{");
        Pattern label = Pattern.compile("^\\.label ([\\w.]+)=\\$([0-9a-f]+)( \\{)?");
        Map<String, Integer> symbols = new HashMap<>();
        Deque<String> scopes = new ArrayDeque<>();
        for (String line : Files.readAllLines(file)) {
            String text = line.trim();
            StringBuilder prefix = new StringBuilder();
            scopes.descendingIterator().forEachRemaining(scope -> prefix.append(scope).append('.'));
            Matcher n = namespace.matcher(text);
            Matcher l = label.matcher(text);
            if (n.find()) {
                scopes.push(n.group(1));
            } else if (l.find()) {
                symbols.putIfAbsent(prefix + l.group(1), Integer.parseInt(l.group(2), 16));
                if (l.group(3) != null) scopes.push(l.group(1));
            } else if (text.equals("}")) {
                scopes.pop();
            }
        }
        return symbols;
    }

    private FilesTest(Map<String, Integer> symbols) throws Exception {
        this.symbols = symbols;
        KiT kit = new KiT();
        kit.setSaveSsd(false);
        cpu = (CPU) field(kit, "cpu");
        bus = (Bus) field(kit, "bus");
        via1 = (VIA) field(kit, "via1");
        via2 = (VIA) field(kit, "via2");
        uart = (UART) field(kit, "uart");
        flash = (int[]) field(field(kit, "ssd"), "data");
        // Start from kit-emu's stock files; anything saved since goes
        for (int sector = 0; sector < 64; sector++) {
            if (!STOCK_SECTORS.contains(String.format("%02x", sector))) {
                Arrays.fill(flash, sector * SECTOR, (sector + 1) * SECTOR, 0xff);
            }
        }
        original = flash.clone();
    }

    private int address(String name) {
        Integer value = symbols.get("files." + name);
        if (value == null) value = symbols.get(name);
        if (value == null) throw new AssertionError("Missing symbol: " + name);
        return value;
    }

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
        for (int i = 0; i < 20_000_000; i++) {
            if (condition.getAsBoolean()) return;
            step();
        }
        throw new AssertionError(description + " timed out at $" + Integer.toHexString(cpu.getPC())
            + "\n" + screen());
    }

    // Wait until the program sits in the key loop at label with no keys left to read
    private void idle(String label) {
        int pc = address(label);
        until(() -> cpu.getPC() == pc
            && bus.debugRead(KB_READ_PTR) == bus.debugRead(KB_WRITE_PTR), "Waiting at " + label);
    }

    private void scan(int code) {
        via1.kbByte(code);
        steps(500);
    }

    private void raw(int code, boolean extended) {
        if (extended) scan(PS2.EXTENDED_CODE);
        scan(code);
        if (extended) scan(PS2.EXTENDED_CODE);
        scan(PS2.RELEASE_CODE);
        scan(code);
    }

    private void key(int keyCode) {
        int code = PS2.getScanCode(keyCode);
        require(code != PS2.ERROR_CODE, "Missing emulator key mapping: " + KeyEvent.getKeyText(keyCode));
        raw(code, PS2.isExtended(keyCode));
    }

    private void press(int keyCode, String waitLabel) {
        key(keyCode);
        idle(waitLabel);
    }

    private void type(String text, String waitLabel) {
        for (char c : text.toCharArray()) {
            int keyCode;
            if (c >= 'a' && c <= 'z') keyCode = KeyEvent.VK_A + c - 'a';
            else if (c >= '0' && c <= '9') keyCode = KeyEvent.VK_0 + c - '0';
            else if (c == '-') keyCode = KeyEvent.VK_MINUS;
            else if (c == '.') keyCode = KeyEvent.VK_PERIOD;
            else if (c == ' ') keyCode = KeyEvent.VK_SPACE;
            else if (c == '\n') keyCode = KeyEvent.VK_ENTER;
            else throw new AssertionError("Unsupported test character: " + c);
            key(keyCode);
            if (waitLabel != null) idle(waitLabel);
        }
    }

    private static char decode(int value) {
        int code = value & 0x3f;
        return code < 0x20 ? (char) ('`' + code) : (char) code;
    }

    private String row(int row) {
        StringBuilder text = new StringBuilder();
        for (int col = 0; col < 32; col++) text.append(decode(bus.debugRead(0x6000 + row * 32 + col)));
        return text.toString();
    }

    private String screen() {
        StringBuilder text = new StringBuilder();
        for (int row = 0; row < 16; row++) text.append(row(row)).append('\n');
        return text.toString();
    }

    private boolean inverse(int row, int col) {
        return (bus.debugRead(0x6000 + row * 32 + col) & 0x40) != 0;
    }

    private String listRow(String sector) {
        for (int row = 2; row < 12; row++) {
            if (row(row).startsWith(sector + " ")) return row(row);
        }
        throw new AssertionError("Sector " + sector + " not listed:\n" + screen());
    }

    private static String entry(String sector, char type, String name, int size, int sectors) {
        return String.format("%s %c %-16s %5d  %2d", sector, type, name, size, sectors);
    }

    private int listRowIndex(String sector) {
        for (int row = 2; row < 12; row++) {
            if (row(row).startsWith(sector + " ")) return row;
        }
        return -1;
    }

    private void selected(String sector) {
        int row = listRowIndex(sector);
        require(row >= 0 && inverse(row, 0) && inverse(row, 31),
            "Sector " + sector + " should be selected:\n" + screen());
    }

    private static void require(boolean condition, String description) {
        if (!condition) throw new AssertionError(description);
    }

    private void contains(String text, String expected) {
        require(text.contains(expected), "Expected \"" + expected + "\" in:\n" + text);
    }

    private void notContains(String text, String unexpected) {
        require(!text.contains(unexpected), "Did not expect \"" + unexpected + "\" in:\n" + text);
    }

    private boolean erased(int sector) {
        for (int i = 0; i < SECTOR; i++) {
            if (flash[sector * SECTOR + i] != 0xff) return false;
        }
        return true;
    }

    // Compare flash sector to a sector of the original image, apart from the name and next link
    private void sameContents(int sector, int originalSector, String name, int next) {
        for (int i = 0; i < SECTOR; i++) {
            int expected = original[originalSector * SECTOR + i];
            if (i >= 0x10 && i < 0x20) {
                int index = i - 0x10;
                expected = index < name.length() ? name.charAt(index) : 0;
            } else if (i == 8) {
                expected = next;
            }
            int actual = flash[sector * SECTOR + i];
            require(actual == expected, String.format("Sector %02x byte %03x: expected %02x, got %02x",
                sector, i, expected, actual));
        }
    }

    private void unchanged(int... sectors) {
        for (int sector : sectors) {
            require(Arrays.equals(flash, sector * SECTOR, (sector + 1) * SECTOR,
                original, sector * SECTOR, (sector + 1) * SECTOR),
                String.format("Sector %02x changed", sector));
        }
    }

    private static int userPattern(int addr) {
        return (addr * 31 + (addr >> 8) + 7) & 0xff;
    }

    private void fillUserRam() {
        for (int addr = USER_RAM_START; addr < USER_RAM_END; addr++) bus.write(addr, userPattern(addr));
    }

    private void userRamUnchanged() {
        for (int addr = USER_RAM_START; addr < USER_RAM_END; addr++) {
            require(bus.debugRead(addr) == userPattern(addr),
                String.format("User RAM changed at $%04x", addr));
        }
    }

    // Open the file manager from the monitor prompt
    private void openFiles() {
        idle("mon_loop");
        type("f", "mon_loop");
        press(KeyEvent.VK_ENTER, "main_loop");
    }

    private void fileManager() {
        idle("mon_loop");
        int stack = cpu.getS();
        fillUserRam();
        openFiles();

        // Each file is listed once, at its first sector
        contains(row(0), "ssd files   14 files  43 free");
        contains(row(1), "sc t name             bytes sec");
        contains(listRow("00"), entry("00", 'p', "snake", 542, 1));
        contains(listRow("08"), entry("08", 'i', "neil", 6144, 2));
        contains(listRow("0a"), entry("0a", 'p', "basic", 8619, 3));
        contains(listRow("0e"), entry("0e", 'i', "neil-bw", 6144, 2));
        notContains(screen(), "\n09 ");
        notContains(screen(), "\n0b ");
        notContains(screen(), "\n0c ");
        selected("00");
        contains(row(12), "program at $1000");
        require(row(13).equals("pppppp..iippp.iipppppp.........."), "Map row 1:\n" + screen());
        require(row(14).equals(".".repeat(30) + "dd"), "Map row 2:\n" + screen());
        require(inverse(13, 0) && !inverse(13, 1), "Selected file in map");
        contains(row(15), "ent:run n:name d:del c:cpy esc");
        require(inverse(15, 8) && inverse(15, 15) && inverse(15, 21) && !inverse(15, 9),
            "Key letters in inverse video:\n" + screen());

        // Paging and scrolling
        raw(0x7a, true);                                // page down
        idle("main_loop");
        selected("11");
        contains(listRow("10"), "sid-play");
        contains(listRow("11"), entry("11", 'p', "wizball.sid", 8375, 3));
        notContains(screen(), "\n00 ");
        key(KeyEvent.VK_RIGHT);
        idle("main_loop");
        selected("3f");
        contains(row(12), "data at $adde");
        contains(listRow("14"), entry("14", 'p', "monty.sid", 6066, 2));
        press(KeyEvent.VK_DOWN, "main_loop");
        selected("3f");
        raw(0x7d, true);                                // page up
        idle("main_loop");
        selected("03");
        key(KeyEvent.VK_LEFT);
        idle("main_loop");
        selected("00");
        press(KeyEvent.VK_UP, "main_loop");
        selected("00");
        for (int i = 0; i < 7; i++) press(KeyEvent.VK_DOWN, "main_loop");
        selected("0a");
        require(inverse(13, 10) && inverse(13, 11) && inverse(13, 12) && !inverse(13, 0),
            "Every sector of the selected file in the map:\n" + screen());

        // Data files don't open
        for (int i = 0; i < 5; i++) press(KeyEvent.VK_DOWN, "main_loop");
        selected("3e");
        press(KeyEvent.VK_ENTER, "main_loop");
        contains(row(15), "only programs and images open");

        // Images show until a key is pressed, over the file manager's tables
        for (int i = 0; i < 6; i++) press(KeyEvent.VK_UP, "main_loop");
        selected("08");
        key(KeyEvent.VK_ENTER);
        idle("wait_key");
        for (int i = 0; i < 6144; i++) {
            require(bus.debugRead(0x6000 + i) == original[(i < 3840 ? 8 * SECTOR + 0x100 + i
                : 9 * SECTOR + 0x100 + i - 3840)], "Image byte " + i);
        }
        require(via2.getPortB() == 8, "SSD sector after image load");
        press(KeyEvent.VK_SPACE, "main_loop");
        contains(row(0), "ssd files   14 files  43 free");
        contains(listRow("0a"), entry("0a", 'p', "basic", 8619, 3));
        require(row(13).equals("pppppp..iippp.iipppppp.........."), "Map after image:\n" + screen());
        selected("08");

        // Rename: cancel, unchanged, then every sector of a multi-sector file
        press(KeyEvent.VK_DOWN, "main_loop");
        selected("0a");
        press(KeyEvent.VK_N, "edit_key");
        contains(row(15), "name: basic");
        type("xyz", "edit_key");
        contains(row(15), "name: basicxyz");
        press(KeyEvent.VK_ESCAPE, "main_loop");
        contains(row(15), "ent:run");
        press(KeyEvent.VK_N, "edit_key");
        press(KeyEvent.VK_ENTER, "main_loop");
        unchanged(0x0a, 0x0b, 0x0c);
        press(KeyEvent.VK_N, "edit_key");
        for (int i = 0; i < 5; i++) press(KeyEvent.VK_BACK_SPACE, "edit_key");
        contains(row(15), "name:  ");
        press(KeyEvent.VK_ENTER, "edit_key");          // empty names aren't accepted
        type("kit-basic.prg", "edit_key");
        press(KeyEvent.VK_ENTER, "main_loop");
        contains(row(15), "renamed");
        sameContents(0x0a, 0x0a, "kit-basic.prg", 0x0b);
        sameContents(0x0b, 0x0b, "kit-basic.prg", 0x0c);
        sameContents(0x0c, 0x0c, "kit-basic.prg", 0xff);
        require(erased(0x06), "Rename's spare sector erased afterwards");
        contains(listRow("0a"), entry("0a", 'p', "kit-basic.prg", 8619, 3));
        selected("0a");
        contains(row(0), "14 files  43 free");

        // Long names stop at 16 characters
        press(KeyEvent.VK_N, "edit_key");
        type("abcdef", "edit_key");
        contains(row(15), "name: kit-basic.prgabc");
        press(KeyEvent.VK_ESCAPE, "main_loop");

        // Copy into the lowest free sectors, which aren't contiguous
        press(KeyEvent.VK_C, "edit_key");
        contains(row(15), "name: kit-basic.prg");
        for (int i = 0; i < 13; i++) press(KeyEvent.VK_BACK_SPACE, "edit_key");
        type("basic2", "edit_key");
        press(KeyEvent.VK_ENTER, "main_loop");
        contains(row(15), "copied to sector 06");
        sameContents(0x06, 0x0a, "basic2", 0x07);
        sameContents(0x07, 0x0b, "basic2", 0x0d);
        sameContents(0x0d, 0x0c, "basic2", 0xff);
        sameContents(0x0a, 0x0a, "kit-basic.prg", 0x0b);
        contains(row(0), "15 files  40 free");
        contains(listRow("06"), entry("06", 'p', "basic2", 8619, 3));
        selected("06");
        require(row(13).equals("ppppppppiippppiipppppp.........."), "Map after copy:\n" + screen());
        require(inverse(13, 6) && inverse(13, 7) && inverse(13, 13) && !inverse(13, 10),
            "Copied sectors in the map:\n" + screen());

        // Delete: cancel, then erase every sector
        press(KeyEvent.VK_D, "confirm");
        contains(row(15), "delete basic2? y/n");
        press(KeyEvent.VK_N, "main_loop");
        contains(row(0), "15 files  40 free");
        press(KeyEvent.VK_D, "confirm");
        press(KeyEvent.VK_Y, "main_loop");
        contains(row(15), "deleted");
        require(erased(0x06) && erased(0x07) && erased(0x0d), "Deleted sectors erased");
        contains(row(0), "14 files  43 free");
        notContains(screen(), "basic2");
        selected("08");

        // Copy again and run the copy: it loads across its three scattered sectors
        press(KeyEvent.VK_DOWN, "main_loop");
        selected("0a");
        press(KeyEvent.VK_C, "edit_key");
        press(KeyEvent.VK_ENTER, "main_loop");
        contains(row(15), "copied to sector 06");
        contains(listRow("06"), "06 p kit-basic.prg");
        contains(listRow("0a"), "0a p kit-basic.prg");
        selected("06");
        userRamUnchanged();                             // rename and copy need no RAM buffer
        key(KeyEvent.VK_ENTER);
        until(() -> cpu.getPC() == 0x1000, "Running the copy");
        require(cpu.getS() == stack, "Program runs with the monitor's stack");
        for (int i = 0; i < 8619; i++) {
            int sector = i < 3840 ? 0x0a : i < 7680 ? 0x0b : 0x0c;
            require(bus.debugRead(0x1000 + i) == original[sector * SECTOR + 0x100 + i % 3840],
                "Loaded program byte " + i);
        }
        steps(3_000_000);
        contains(screen().toLowerCase(), "basic");
        key(KeyEvent.VK_ESCAPE);
        until(() -> cpu.getPC() == address("mon_loop"), "BASIC escape to monitor");

        // Esc goes back to the monitor, leaving the stack as it was
        idle("mon_loop");
        stack = cpu.getS();
        openFiles();
        contains(row(0), "15 files  40 free");
        press(KeyEvent.VK_ESCAPE, "mon_loop");
        require(cpu.getS() == stack, "Stack after esc");
        require(row(15).startsWith(">"), "Prompt after esc:\n" + screen());

        unchanged(0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x08, 0x09, 0x0e, 0x0f,
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x3e, 0x3f);
        for (int sector = 0x16; sector < 0x3e; sector++) unchanged(sector);

        // Links to a sector of another file, and loops of links, are flagged
        flash[0x00 * SECTOR + 8] = 0x06;
        flash[0x3e * SECTOR + 8] = 0x3f;
        flash[0x3f * SECTOR + 8] = 0x3e;
        openFiles();
        contains(row(0), "14 files  40 free");
        contains(listRow("00"), "00 p!snake              542   1");
        contains(listRow("06"), entry("06", 'p', "kit-basic.prg", 8619, 3));
        contains(row(12), "program at $1000  ! chain broken");
        press(KeyEvent.VK_RIGHT, "main_loop");
        press(KeyEvent.VK_RIGHT, "main_loop");
        selected("3e");
        contains(listRow("3e"), "3e d!high scores         19   2");
        require(inverse(14, 30) && inverse(14, 31), "Looped sectors in the map:\n" + screen());
        press(KeyEvent.VK_ESCAPE, "mon_loop");

        // Images that would load over I/O or ROM aren't shown
        flash[0x3e * SECTOR + 1] = 0x10;
        openFiles();
        press(KeyEvent.VK_RIGHT, "main_loop");
        press(KeyEvent.VK_RIGHT, "main_loop");
        selected("3e");
        press(KeyEvent.VK_ENTER, "main_loop");
        contains(row(15), "image would load outside ram");
        press(KeyEvent.VK_ESCAPE, "mon_loop");

        System.out.println("PASS file manager: listing, sector map, paging, data/image open, rename,");
        System.out.println("copy, delete, running a copied multi-sector program, broken chains, esc.");
    }


    /* ---------------------------------------------------------------------
    Saving after a load
    */

    // Bytes of a program at $1000 that stores $42 at $0300 and returns to the monitor
    private static int[] program(int size) {
        int[] data = new int[size];
        int[] code = {0xa9, 0x42, 0x8d, 0x00, 0x03, 0x00, 0xea};   // lda #$42, sta $0300, brk, nop
        for (int i = 0; i < size; i++) data[i] = i < code.length ? code[i] : (i * 7 + (i >> 8)) & 0xff;
        return data;
    }

    private static Path writePrg(String name, int address, int[] data) throws Exception {
        byte[] bytes = new byte[data.length + 2];
        bytes[0] = (byte) address;
        bytes[1] = (byte) (address >> 8);
        for (int i = 0; i < data.length; i++) bytes[i + 2] = (byte) data[i];
        Path path = Path.of(name).toAbsolutePath();
        Files.write(path, bytes);
        return path;
    }

    // l: load a PRG over the serial port, leaving the monitor asking run, save, or cancel
    private void load(Path prg) {
        idle("mon_loop");
        uart.loadPrg(prg.toFile());
        key(KeyEvent.VK_L);
        scan(PS2.getScanCode(KeyEvent.VK_ENTER));
        until(() -> cpu.getPC() == address("get_yn_loop"), "Serial PRG load");
        scan(PS2.RELEASE_CODE);                         // release enter once the load has finished,
        scan(PS2.getScanCode(KeyEvent.VK_ENTER));       // so no scancode is dropped during it
        idle("get_yn_loop");
    }

    private static int[] checksum(int[] data) {
        int sum1 = 0;
        int sum2 = 0;
        for (int value : data) {
            sum1 = (sum1 + value) & 0xff;
            sum2 = (sum2 + sum1) & 0xff;
        }
        return new int[] {sum1, sum2};
    }

    /*
    Check that sectors hold the file as ssd_save_file writes it: each sector's header has
    the address and size of the rest of the file, and links to the next sector. tail holds
    the bytes saved past the end in an extra sector, for sizes that are a multiple of 3840.
    */
    private void saved(int[] sectors, int address, int[] data, String name, int[] tail) {
        int[] sum = checksum(data);
        for (int k = 0; k < sectors.length; k++) {
            int base = sectors[k] * SECTOR;
            int offset = k * 3840;
            int rest = data.length - offset;
            int[] header = new int[256];
            Arrays.fill(header, 0);
            header[0] = 0x00;
            header[1] = 0x00;                           // program
            header[2] = (address + offset) & 0xff;
            header[3] = (address + offset) >> 8;
            header[4] = rest & 0xff;
            header[5] = rest >> 8;
            header[6] = sum[0];
            header[7] = sum[1];
            header[8] = k + 1 < sectors.length ? sectors[k + 1] : 0xff;
            header[9] = 0xff;                           // video mode
            for (int i = 0x0a; i < 0x10; i++) header[i] = 0xff;
            for (int i = 0; i < name.length(); i++) header[0x10 + i] = name.charAt(i);
            for (int i = 0; i < 256; i++) {
                require(flash[base + i] == header[i], String.format(
                    "Sector %02x header byte %02x: expected %02x, got %02x",
                    sectors[k], i, header[i], flash[base + i]));
            }
            for (int i = 0; i < 3840; i++) {
                int expected = 0xff;
                if (offset + i < data.length && i < 3840) expected = data[offset + i];
                else if (rest == 0 && i < 256) expected = tail[i];
                require(flash[base + 0x100 + i] == expected, String.format(
                    "Sector %02x data byte %03x: expected %02x, got %02x",
                    sectors[k], i, expected, flash[base + 0x100 + i]));
            }
        }
    }

    // Mark free sectors as holding a one-sector data file, except those listed
    private void fillFreeSectors(int... keep) {
        outer:
        for (int sector = 0; sector < 64; sector++) {
            for (int k : keep) if (k == sector) continue outer;
            int base = sector * SECTOR;
            if (flash[base] == 0) continue;
            Arrays.fill(flash, base, base + SECTOR, 0xff);
            flash[base] = 0x00;
            flash[base + 1] = 0x20;
            flash[base + 4] = 0x01;
            flash[base + 5] = 0x00;
            flash[base + 8] = 0xff;
            String name = String.format("fill%02x", sector);
            for (int i = 0; i < 16; i++) flash[base + 0x10 + i] = i < name.length() ? name.charAt(i) : 0;
            flash[base + 0x100] = 0x00;
        }
    }

    // Run sector's program with f XX; it stores $42 at $0300 and breaks back to the monitor
    private void runSaved(String sector, int address, int[] data) {
        for (int i = 0; i < data.length; i++) bus.write(address + i, 0);
        bus.write(0x0300, 0);
        idle("mon_loop");
        type("f " + sector, "mon_loop");
        key(KeyEvent.VK_ENTER);
        until(() -> cpu.getPC() == address, "Running sector " + sector);
        for (int i = 0; i < data.length; i++) {
            require(bus.debugRead(address + i) == data[i], "Loaded byte " + i + " from sector " + sector);
        }
        until(() -> cpu.getPC() == address("mon_loop"), "Program breaks back to the monitor");
        require(bus.debugRead(0x0300) == 0x42, "Program from sector " + sector + " ran");
    }

    private void save() throws Exception {
        // A three-sector program goes to the lowest free sectors: 06, 07, 0d
        int[] big = program(8000);
        Path bigPrg = writePrg("big.prg", 0x1000, big);
        load(bigPrg);
        int stack = cpu.getS();
        key(KeyEvent.VK_S);
        idle("save_wait_key");
        contains(row(14), "done! run, save, or cancel?");
        require(row(15).startsWith("name: "), "Name prompt:\n" + screen());
        require(inverse(15, 6), "Cursor after the prompt:\n" + screen());
        press(KeyEvent.VK_ENTER, "save_wait_key");     // empty names aren't accepted
        type("bigx", "save_wait_key");
        press(KeyEvent.VK_BACK_SPACE, "save_wait_key");
        require(row(15).startsWith("name: big "), "Name after backspace:\n" + screen());
        require(inverse(15, 9), "Cursor after backspace:\n" + screen());
        press(KeyEvent.VK_ENTER, "mon_loop");
        require(row(13).startsWith("name: big "), "Name stays on screen:\n" + screen());
        require(row(14).startsWith("saved to 06 "), "Save result:\n" + screen());
        require(row(15).startsWith(">"), "Prompt after save:\n" + screen());
        require(cpu.getS() == stack, "files.save returns to the monitor with rts");
        saved(new int[] {0x06, 0x07, 0x0d}, 0x1000, big, "big", null);
        unchanged(0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0e);
        runSaved("06", 0x1000, big);

        // The file manager lists it
        openFiles();
        contains(listRow("06"), entry("06", 'p', "big", 8000, 3));
        contains(row(0), "15 files  40 free");
        press(KeyEvent.VK_ESCAPE, "mon_loop");

        // A file loaded over the text screen isn't scrolled before it's saved
        int[] screenData = new int[512];
        for (int i = 0; i < 512; i++) screenData[i] = (i * 13 + 5) & 0xff;
        load(writePrg("screen.prg", 0x6000, screenData));
        int[] loaded = new int[512];
        for (int i = 0; i < 512; i++) loaded[i] = bus.debugRead(0x6000 + i);
        for (int i = 0; i < 14 * 32; i++) require(loaded[i] == screenData[i], "Loaded screen byte " + i);
        key(KeyEvent.VK_S);
        idle("save_wait_key");
        type("scr", "save_wait_key");
        press(KeyEvent.VK_ENTER, "mon_loop");
        require(row(14).startsWith("saved to 16 "), "Screen file result:\n" + screen());
        for (int i = 0; i < 15 * 32; i++) {
            require(flash[0x16 * SECTOR + 0x100 + i] == loaded[i], "Saved screen byte " + i);
        }
        require(flash[0x16 * SECTOR + 0x100 + 0x200] == 0xff, "Screen file ends after 512 bytes");

        // Sizes that are a multiple of 3840 get an extra sector, as ssd_save_file writes
        int[] exact = program(3840);
        load(writePrg("exact.prg", 0x1000, exact));
        int[] tail = new int[256];
        for (int i = 0; i < 256; i++) tail[i] = bus.debugRead(0x1000 + 3840 + i);
        key(KeyEvent.VK_S);
        idle("save_wait_key");
        type("exact", "save_wait_key");
        press(KeyEvent.VK_ENTER, "mon_loop");
        require(row(14).startsWith("saved to 17 "), "Exact file result:\n" + screen());
        saved(new int[] {0x17, 0x18}, 0x1000, exact, "exact", tail);
        runSaved("17", 0x1000, exact);

        // Esc doesn't save
        int[] before = flash.clone();
        load(bigPrg);
        key(KeyEvent.VK_S);
        idle("save_wait_key");
        type("nope", "save_wait_key");
        press(KeyEvent.VK_ESCAPE, "mon_loop");
        require(row(14).startsWith("not saved "), "Esc result:\n" + screen());
        require(Arrays.equals(flash, before), "Esc leaves the SSD alone");

        // Not enough room: two free sectors for a three-sector file
        fillFreeSectors(0x3c, 0x3d);
        before = flash.clone();
        load(bigPrg);
        stack = cpu.getS();
        key(KeyEvent.VK_S);
        idle("save_wait_key");
        type("big2", "save_wait_key");
        press(KeyEvent.VK_ENTER, "mon_loop");
        require(row(14).startsWith("not enough free sectors "), "Full SSD result:\n" + screen());
        require(cpu.getS() == stack, "Stack after a failed save");
        require(Arrays.equals(flash, before), "A failed save leaves the SSD alone");

        // With no free sector at all, rename and copy refuse and change nothing
        fillFreeSectors();
        before = flash.clone();
        fillUserRam();
        openFiles();
        contains(row(0), " 0 free");
        selected("00");
        press(KeyEvent.VK_N, "edit_key");
        type("x", "edit_key");
        press(KeyEvent.VK_ENTER, "main_loop");
        contains(row(15), "rename needs a free sector");
        press(KeyEvent.VK_C, "main_loop");
        contains(row(15), "not enough free sectors");
        press(KeyEvent.VK_ESCAPE, "mon_loop");
        require(Arrays.equals(flash, before), "Refused rename and copy leave the SSD alone");
        userRamUnchanged();

        System.out.println("PASS save: name prompt, lowest free sectors, chained headers, f XX runs it,");
        System.out.println("files over the screen, exact multiples, esc, full SSD, rename/copy with no space.");
    }

    public static void main(String[] args) throws Exception {
        Map<String, Integer> symbols = loadSymbols(Path.of(args[0]));
        new FilesTest(symbols).fileManager();
        new FilesTest(symbols).save();
    }
}
