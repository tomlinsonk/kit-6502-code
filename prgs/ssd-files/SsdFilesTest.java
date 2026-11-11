import java.awt.event.KeyEvent;
import java.io.File;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.function.BooleanSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/*
Drives ssd_files.prg in the KiT emulator. Run from a directory holding
video_mon.bin, ssd.bin (a copy of kit-emu's), and character-set.png.
*/
public class SsdFilesTest {
    private static final int SECTOR = 4096;
    private static final int KB_READ_PTR = 0x10;
    private static final int KB_WRITE_PTR = 0x11;

    private final CPU cpu;
    private final Bus bus;
    private final VIA via1;
    private final VIA via2;
    private final UART uart;
    private final int[] flash;
    private final int[] original;
    private final File program;
    private final Map<String, Integer> symbols = new HashMap<>();

    private static Object field(Object object, String name) throws Exception {
        Field field = object.getClass().getDeclaredField(name);
        field.setAccessible(true);
        return field.get(object);
    }

    private SsdFilesTest(Path program) throws Exception {
        this.program = program.toFile();
        Matcher matcher = Pattern.compile("\\.label ([\\w.]+)=\\$([0-9a-f]+)").matcher(
            Files.readString(program.resolveSibling("ssd_files.sym")));
        while (matcher.find()) {
            symbols.putIfAbsent(matcher.group(1), Integer.parseInt(matcher.group(2), 16));
        }
        KiT kit = new KiT();
        kit.setSaveSsd(false);
        cpu = (CPU) field(kit, "cpu");
        bus = (Bus) field(kit, "bus");
        via1 = (VIA) field(kit, "via1");
        via2 = (VIA) field(kit, "via2");
        uart = (UART) field(kit, "uart");
        flash = (int[]) field(field(kit, "ssd"), "data");
        original = flash.clone();
    }

    private int address(String name) {
        Integer value = symbols.get(name);
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

    private String name(int sector) {
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < 16; i++) {
            int c = flash[sector * SECTOR + 0x10 + i];
            if (c == 0) break;
            text.append((char) c);
        }
        return text.toString();
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

    private void startProgram() {
        until(() -> cpu.getPC() == address("mon_loop"), "Monitor");
        uart.loadPrg(program);
        key(KeyEvent.VK_L);
        scan(PS2.getScanCode(KeyEvent.VK_ENTER));
        until(() -> cpu.getPC() == address("get_yn_loop"), "Serial PRG load");
        scan(PS2.RELEASE_CODE);                         // release enter once the load has finished,
        scan(PS2.getScanCode(KeyEvent.VK_ENTER));       // so no scancode is dropped during it
        type("r", null);
        idle("main_loop");
    }

    private void run() {
        startProgram();

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
        contains(row(15), "ret:run r:ren d:del c:copy esc");

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

        // Images show until a key is pressed
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
        selected("08");

        // Rename: cancel, unchanged, then every sector of a multi-sector file
        press(KeyEvent.VK_DOWN, "main_loop");
        selected("0a");
        press(KeyEvent.VK_R, "edit_key");
        contains(row(15), "name: basic");
        type("xyz", "edit_key");
        contains(row(15), "name: basicxyz");
        press(KeyEvent.VK_ESCAPE, "main_loop");
        contains(row(15), "ret:run");
        press(KeyEvent.VK_R, "edit_key");
        press(KeyEvent.VK_ENTER, "main_loop");
        unchanged(0x0a, 0x0b, 0x0c);
        press(KeyEvent.VK_R, "edit_key");
        for (int i = 0; i < 5; i++) press(KeyEvent.VK_BACK_SPACE, "edit_key");
        contains(row(15), "name:  ");
        press(KeyEvent.VK_ENTER, "edit_key");          // empty names aren't accepted
        type("kit-basic.prg", "edit_key");
        press(KeyEvent.VK_ENTER, "main_loop");
        contains(row(15), "renamed");
        sameContents(0x0a, 0x0a, "kit-basic.prg", 0x0b);
        sameContents(0x0b, 0x0b, "kit-basic.prg", 0x0c);
        sameContents(0x0c, 0x0c, "kit-basic.prg", 0xff);
        contains(listRow("0a"), entry("0a", 'p', "kit-basic.prg", 8619, 3));
        selected("0a");
        contains(row(0), "14 files  43 free");

        // Long names stop at 16 characters
        press(KeyEvent.VK_R, "edit_key");
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
        key(KeyEvent.VK_ENTER);
        until(() -> cpu.getPC() == 0x1000, "Running the copy");
        for (int i = 0; i < 8619; i++) {
            int sector = i < 3840 ? 0x0a : i < 7680 ? 0x0b : 0x0c;
            require(bus.debugRead(0x1000 + i) == original[sector * SECTOR + 0x100 + i % 3840],
                "Loaded program byte " + i);
        }
        steps(3_000_000);
        contains(screen().toLowerCase(), "basic");
        key(KeyEvent.VK_ESCAPE);
        until(() -> cpu.getPC() == address("mon_loop"), "BASIC escape to monitor");

        // Esc quits to the monitor
        startProgram();
        contains(row(0), "15 files  40 free");
        press(KeyEvent.VK_ESCAPE, "mon_loop");

        unchanged(0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x08, 0x09, 0x0e, 0x0f,
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x3e, 0x3f);
        for (int sector = 0x16; sector < 0x3e; sector++) unchanged(sector);

        // Links to a sector of another file, and loops of links, are flagged
        flash[0x00 * SECTOR + 8] = 0x06;
        flash[0x3e * SECTOR + 8] = 0x3f;
        flash[0x3f * SECTOR + 8] = 0x3e;
        startProgram();
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

        System.out.println("PASS: listing, sector map, paging, data/image open, rename, copy,");
        System.out.println("delete, running a copied multi-sector program, broken chains, and quitting.");
    }

    public static void main(String[] args) throws Exception {
        new SsdFilesTest(Path.of(args[0])).run();
    }
}
