import java.awt.event.KeyEvent;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.function.BooleanSupplier;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

// Runs kit-os with a fake Wi-Fi card in slot 3 that speaks the card's protocol (see lib/wifi.lib).
public class WifiTest {

    static class FakeCard implements BusListener {
        final Bus bus;
        int scratch, lcr, mcr, fcr, ier, dll = -1, dlm = -1;
        final ArrayDeque<Integer> toKit = new ArrayDeque<>();
        final List<Integer> fromKit = new ArrayList<>();
        final StringBuilder terminalInput = new StringBuilder();
        final List<Integer> result = new ArrayList<>();
        boolean terminal, waiting, badChecksum;
        int programAddress, truncate = -1, resultBytes, polls, gets;
        byte[] program;

        FakeCard(Bus bus) { this.bus = bus; }

        void upload(int address, int... bytes) {
            programAddress = address;
            program = new byte[bytes.length];
            for (int i = 0; i < bytes.length; i++) program[i] = (byte) bytes[i];
            waiting = true;
        }

        int[] checksum() {
            int sum1 = 0, sum2 = 0;
            for (byte b : program) {
                sum1 = (sum1 + (b & 0xff)) & 0xff;
                sum2 = (sum2 + sum1) & 0xff;
            }
            return new int[] {sum1, sum2};
        }

        public void activate() {
            int reg = bus.getAddr() & 7;
            boolean dlab = (lcr & 0x80) != 0;
            if (bus.readBitSet()) {
                int value;
                switch (reg) {
                    case 0: value = dlab ? dll : (toKit.isEmpty() ? 0 : toKit.poll()); break;
                    case 1: value = dlab ? dlm : ier; break;
                    case 2: value = 0xc1; break;
                    case 3: value = lcr; break;
                    case 4: value = mcr; break;
                    case 5: value = (toKit.isEmpty() ? 0 : 1) | 0x60; break;
                    case 7: value = scratch; break;
                    default: value = 0;
                }
                bus.setData(value);
                return;
            }
            int d = bus.getData();
            switch (reg) {
                case 0: if (dlab) dll = d; else received(d); break;
                case 1: if (dlab) dlm = d; else ier = d; break;
                case 2: fcr = d; if ((d & 2) != 0) toKit.clear(); break;
                case 3: lcr = d; break;
                case 4: mcr = d; break;
                case 7: scratch = d; break;
                default: break;
            }
        }

        void received(int d) {
            fromKit.add(d);
            if (resultBytes > 0) {
                result.add(d);
                resultBytes--;
                return;
            }
            if (d >= 0xf0) {
                switch (d) {
                    case 0xf0: polls++; toKit.add(waiting ? 0xf9 : 0xf8); break;
                    case 0xf1: gets++; sendProgram(); break;
                    case 0xf2: terminal = true; break;
                    case 0xf3: terminal = false; break;
                    case 0xf4: resultBytes = 2; result.clear(); break;
                    default: break;
                }
            } else if (terminal) {
                terminalInput.append((char) d);
            }
        }

        void sendProgram() {
            if (!waiting) {
                toKit.add(0xfb);
                return;
            }
            waiting = false;
            int[] sum = checksum();
            int n = program.length;
            int[] header = {0x00, 0xff, n & 0xff, n >> 8, sum[0] ^ (badChecksum ? 1 : 0), sum[1],
                programAddress & 0xff, programAddress >> 8, programAddress & 0xff, programAddress >> 8};
            toKit.add(0xfa);
            for (int h : header) toKit.add(h);
            int count = truncate >= 0 ? truncate : n;
            for (int i = 0; i < count; i++) toKit.add(program[i] & 0xff);
        }

        public int debugRead(int addr) { return scratch; }
    }

    private final CPU cpu;
    private final Bus bus;
    private final VIA via1, via2;
    private final FakeCard card;
    private final Map<String, Integer> symbols = new HashMap<>();
    private int checks = 0;

    private static Object field(Object object, Class<?> type, String name) throws Exception {
        Field f = type.getDeclaredField(name);
        f.setAccessible(true);
        return f.get(object);
    }

    private void loadSymbols(Path file) throws Exception {
        Pattern namespace = Pattern.compile("^\\.namespace (\\w+) \\{");
        Pattern label = Pattern.compile("^\\.label ([\\w.]+)=\\$([0-9a-f]+)( \\{)?");
        ArrayDeque<String> scopes = new ArrayDeque<>();
        for (String line : Files.readAllLines(file)) {
            String t = line.trim();
            Matcher n = namespace.matcher(t);
            if (n.find()) { scopes.push("ns:" + n.group(1)); continue; }
            Matcher l = label.matcher(t);
            if (l.find()) {
                String ns = scopes.stream().filter(s -> s.startsWith("ns:")).findFirst().map(s -> s.substring(3) + ".").orElse("");
                if (scopes.stream().noneMatch(s -> s.startsWith("label:"))) symbols.putIfAbsent(ns + l.group(1), Integer.parseInt(l.group(2), 16));
                if (l.group(3) != null) scopes.push("label:" + l.group(1));
                continue;
            }
            if (t.equals("}") && !scopes.isEmpty()) scopes.pop();
        }
    }

    private int sym(String name) {
        Integer value = symbols.get(name);
        if (value == null) throw new AssertionError("Missing symbol: " + name);
        return value;
    }

    private WifiTest(Path monitorSymbols, boolean withCard) throws Exception {
        loadSymbols(monitorSymbols);
        KiT kit = new KiT();
        cpu = (CPU) field(kit, KiT.class, "cpu");
        bus = (Bus) field(kit, KiT.class, "bus");
        via1 = (VIA) field(kit, KiT.class, "via1");
        via2 = (VIA) field(kit, KiT.class, "via2");
        card = new FakeCard(bus);
        if (withCard) {
            AddressDecoder decoder = (AddressDecoder) field(bus, Bus.class, "addrDecoder");
            BusListener[] map = (BusListener[]) field(decoder, AddressDecoder.class, "addressMap");
            for (int addr = 0x7c00; addr <= 0x7cff; addr++) map[addr] = card;
        }
    }

    private int peek(int address) { return bus.debugRead(address); }

    private void step() {
        long before = cpu.getCycleCount();
        cpu.step();
        int cycles = (int) (cpu.getCycleCount() - before);
        via1.updateCycleCount(cycles);
        via2.updateCycleCount(cycles);
    }

    private void steps(int count) { for (int i = 0; i < count; i++) step(); }

    private void until(BooleanSupplier condition, String description) {
        for (int i = 0; i < 20_000_000; i++) {
            if (condition.getAsBoolean()) return;
            step();
        }
        throw new AssertionError(description + " timed out at $" + Integer.toHexString(cpu.getPC()) + "\n" + screen());
    }

    // Run for about the given number of CPU cycles
    private void run(long cycles) {
        long end = cpu.getCycleCount() + cycles;
        while (cpu.getCycleCount() < end) step();
    }

    private void scan(int code) { via1.kbByte(code); steps(500); }

    private void key(int keyCode) {
        int code = PS2.getScanCode(keyCode);
        scan(code);
        scan(0xf0);
        scan(code);
    }

    private void type(String text) {
        for (char c : text.toCharArray()) {
            if (c >= 'a' && c <= 'z') key(KeyEvent.VK_A + c - 'a');
            else if (c == '\n') key(KeyEvent.VK_ENTER);
            else if (c == '\b') key(KeyEvent.VK_BACK_SPACE);
            else if (c == 27) key(KeyEvent.VK_ESCAPE);
            else throw new AssertionError("Unsupported test character: " + c);
        }
    }

    private static char decode(int value) {
        int base = value & 0x3f;
        if (base == 0) return '@';
        if (base < 0x20) return (char) ('a' + base - 1);
        return (char) base;
    }

    private String row(int r) {
        StringBuilder text = new StringBuilder();
        for (int i = 0; i < 32; i++) text.append(decode(peek(0x6000 + r * 32 + i)));
        return text.toString();
    }

    private String screen() {
        StringBuilder s = new StringBuilder();
        for (int r = 0; r < 16; r++) s.append(row(r)).append('\n');
        return s.toString();
    }

    private void require(boolean condition, String description) {
        checks++;
        if (!condition) throw new AssertionError(description + "\nScreen:\n" + screen());
    }

    private void contains(String text, String expected) {
        require(text.contains(expected), "Expected \"" + expected + "\" in \"" + text + "\"");
    }

    private boolean atPrompt() {
        return cpu.getPC() == sym("mon_loop") && peek(sym("zp.kb_read_ptr")) == peek(sym("zp.kb_write_ptr"));
    }

    private void boot() {
        until(() -> cpu.getPC() == sym("mon_loop"), "monitor boot");
    }

    // Waits for the monitor to pick up an upload and ask what to do with it
    private void awaitLoadPrompt() {
        until(() -> row(15).startsWith("done! run, save, or cancel?"), "load prompt");
        until(() -> cpu.getPC() == sym("get_yn_loop"), "waiting for r/s/c");
    }

    private void testNoCard() {
        boot();
        require(peek(0x0232) == 0, "no card detected");
        type("t\n");
        until(this::atPrompt, "prompt after t");
        contains(row(14), "no wifi card in slot 3");
        System.out.println("no card OK");
    }

    private void testSetup() {
        boot();
        require(peek(0x0232) == 0xff, "card detected");
        require(card.dll == 3 && card.dlm == 0, "38400 baud divisor");
        require(card.lcr == 0x03, "8n1");
        require(card.mcr == 0x22, "auto flow control");
        require(card.fromKit.contains(0xf3), "terminal off at start");
        System.out.println("setup OK");
    }

    private void testUploadAndRun() {
        int before = card.polls;
        run(3_000_000);
        require(card.polls > before, "polls while idle");
        require(card.gets == 0, "nothing to get");

        // lda #$42 / sta $3100 / brk / nop
        card.upload(0x3000, 0xa9, 0x42, 0x8d, 0x00, 0x31, 0x00, 0xea);
        awaitLoadPrompt();
        require(card.gets == 1, "one get");
        contains(row(14), "a3000 b0007 c");
        int[] sum = card.checksum();
        require(card.result.equals(List.of(sum[0], sum[1])), "result sent: " + card.result);
        for (int i = 0; i < card.program.length; i++) require(peek(0x3000 + i) == (card.program[i] & 0xff), "byte " + i);

        type("r");
        until(() -> peek(0x3100) == 0x42, "program ran");
        until(this::atPrompt, "back at prompt after brk");
        System.out.println("upload and run OK");
    }

    private void testNoPollWhileTyping() {
        type("r");
        int polls = card.polls, gets = card.gets;
        card.upload(0x3000, 0xea, 0x00, 0xea);
        run(3_000_000);
        require(card.polls == polls && card.gets == gets, "no polling with text at the prompt");
        type("\b");                                 // the prompt now holds a space: still empty
        awaitLoadPrompt();
        type("c");
        until(this::atPrompt, "prompt after cancel");
        System.out.println("no polling while typing OK");
    }

    private void testChecksumError() {
        card.badChecksum = true;
        card.upload(0x3000, 0x01, 0x02, 0x03);
        until(() -> row(14).startsWith("checksum error"), "checksum error");
        until(this::atPrompt, "prompt after checksum error");
        card.badChecksum = false;
        System.out.println("checksum error OK");
    }

    private void testTimeout() {
        card.truncate = 2;
        card.upload(0x3000, 0x01, 0x02, 0x03, 0x04);
        until(() -> row(14).startsWith("wifi load failed"), "load timeout");
        until(this::atPrompt, "prompt after timeout");
        card.truncate = -1;
        System.out.println("timeout OK");
    }

    private void testTerminal() {
        type("t\n");
        until(() -> card.terminal, "terminal on");
        contains(row(0), "wifi terminal. esc to exit");
        for (char c : "hello\r\nworld".toCharArray()) card.toKit.add((int) c);
        until(() -> card.toKit.isEmpty(), "terminal output shown");
        steps(20000);
        contains(row(1), "hello");
        contains(row(2), "world");

        type("w");
        until(() -> card.terminalInput.toString().equals("w"), "key sent");
        require(row(2).startsWith("world") && !row(2).contains("worldw"), "no local echo");

        type("\u001b");
        until(() -> !card.terminal, "terminal off");
        until(this::atPrompt, "prompt after terminal");
        System.out.println("terminal OK");
    }

    private void runWithCard() {
        testSetup();
        testUploadAndRun();
        testNoPollWhileTyping();
        testChecksumError();
        testTimeout();
        testTerminal();
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            System.err.println("usage: WifiTest kit_os.sym");
            System.exit(2);
        }
        WifiTest noCard = new WifiTest(Path.of(args[0]), false);
        noCard.testNoCard();
        WifiTest test = new WifiTest(Path.of(args[0]), true);
        test.runWithCard();
        System.out.println("All Wi-Fi tests passed (" + (noCard.checks + test.checks) + " checks)");
    }
}
