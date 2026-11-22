/*
65C02 opcode tables, shared by the assembler (mini_asm.asm) and the debugger (debugger.asm)

    op_mnem[opcode]     offset of the mnemonic in mnem_text (3 letters each)
    op_mode[opcode]     addressing mode, one of the OP_* modes below
    mode_len[mode]      instruction length in bytes

Undefined opcodes have the mnemonic "???" and a U1-U3 mode giving the length the
65C02 treats them as. rmb, smb, bbr, and bbs have all 8 opcodes; the bit number is
bits 4-6 of the opcode.
*/

// Addressing modes
.const OP_IMP = 0                                   // implied
.const OP_ACC = 1                                   // accumulator
.const OP_IMM = 2                                   // #$12
.const OP_ZP  = 3                                   // $12
.const OP_ZPX = 4                                   // $12,x
.const OP_ZPY = 5                                   // $12,y
.const OP_IZX = 6                                   // ($12,x)
.const OP_IZY = 7                                   // ($12),y
.const OP_IZP = 8                                   // ($12)
.const OP_ABS = 9                                   // $1234
.const OP_ABX = 10                                  // $1234,x
.const OP_ABY = 11                                  // $1234,y
.const OP_IND = 12                                  // ($1234)
.const OP_IAX = 13                                  // ($1234,x)
.const OP_REL = 14                                  // branch target
.const OP_ZPR = 15                                  // $12,target (bbr/bbs)
.const OP_U1 = 16                                   // undefined, 1 byte
.const OP_U2 = 17                                   // undefined, 2 bytes
.const OP_U3 = 18                                   // undefined, 3 bytes
.const OP_MODES = 19

.var opcodeTable = List().add(
    "brk imp","ora izx","??? u2","??? u1","tsb zp","ora zp","asl zp","rmb zp","php imp","ora imm","asl acc","??? u1","tsb abs","ora abs","asl abs","bbr zpr",
    "bpl rel","ora izy","ora izp","??? u1","trb zp","ora zpx","asl zpx","rmb zp","clc imp","ora aby","inc acc","??? u1","trb abs","ora abx","asl abx","bbr zpr",
    "jsr abs","and izx","??? u2","??? u1","bit zp","and zp","rol zp","rmb zp","plp imp","and imm","rol acc","??? u1","bit abs","and abs","rol abs","bbr zpr",
    "bmi rel","and izy","and izp","??? u1","bit zpx","and zpx","rol zpx","rmb zp","sec imp","and aby","dec acc","??? u1","bit abx","and abx","rol abx","bbr zpr",
    "rti imp","eor izx","??? u2","??? u1","??? u2","eor zp","lsr zp","rmb zp","pha imp","eor imm","lsr acc","??? u1","jmp abs","eor abs","lsr abs","bbr zpr",
    "bvc rel","eor izy","eor izp","??? u1","??? u2","eor zpx","lsr zpx","rmb zp","cli imp","eor aby","phy imp","??? u1","??? u3","eor abx","lsr abx","bbr zpr",
    "rts imp","adc izx","??? u2","??? u1","stz zp","adc zp","ror zp","rmb zp","pla imp","adc imm","ror acc","??? u1","jmp ind","adc abs","ror abs","bbr zpr",
    "bvs rel","adc izy","adc izp","??? u1","stz zpx","adc zpx","ror zpx","rmb zp","sei imp","adc aby","ply imp","??? u1","jmp iax","adc abx","ror abx","bbr zpr",
    "bra rel","sta izx","??? u2","??? u1","sty zp","sta zp","stx zp","smb zp","dey imp","bit imm","txa imp","??? u1","sty abs","sta abs","stx abs","bbs zpr",
    "bcc rel","sta izy","sta izp","??? u1","sty zpx","sta zpx","stx zpy","smb zp","tya imp","sta aby","txs imp","??? u1","stz abs","sta abx","stz abx","bbs zpr",
    "ldy imm","lda izx","ldx imm","??? u1","ldy zp","lda zp","ldx zp","smb zp","tay imp","lda imm","tax imp","??? u1","ldy abs","lda abs","ldx abs","bbs zpr",
    "bcs rel","lda izy","lda izp","??? u1","ldy zpx","lda zpx","ldx zpy","smb zp","clv imp","lda aby","tsx imp","??? u1","ldy abx","lda abx","ldx aby","bbs zpr",
    "cpy imm","cmp izx","??? u2","??? u1","cpy zp","cmp zp","dec zp","smb zp","iny imp","cmp imm","dex imp","wai imp","cpy abs","cmp abs","dec abs","bbs zpr",
    "bne rel","cmp izy","cmp izp","??? u1","??? u2","cmp zpx","dec zpx","smb zp","cld imp","cmp aby","phx imp","stp imp","??? u3","cmp abx","dec abx","bbs zpr",
    "cpx imm","sbc izx","??? u2","??? u1","cpx zp","sbc zp","inc zp","smb zp","inx imp","sbc imm","nop imp","??? u1","cpx abs","sbc abs","inc abs","bbs zpr",
    "beq rel","sbc izy","sbc izp","??? u1","??? u2","sbc zpx","inc zpx","smb zp","sed imp","sbc aby","plx imp","??? u1","??? u3","sbc abx","inc abx","bbs zpr"
)
.assert "256 opcodes", opcodeTable.size(), 256

.var opcodeModeIds = Hashtable().put(
    "imp",OP_IMP,"acc",OP_ACC,"imm",OP_IMM,"zp",OP_ZP,"zpx",OP_ZPX,"zpy",OP_ZPY,"izx",OP_IZX,
    "izy",OP_IZY,"izp",OP_IZP,"abs",OP_ABS,"abx",OP_ABX,"aby",OP_ABY,"ind",OP_IND,"iax",OP_IAX,
    "rel",OP_REL,"zpr",OP_ZPR,"u1",OP_U1,"u2",OP_U2,"u3",OP_U3)

// Mnemonics in order of first use, except that the bit instructions and then "???" come last
.var opcodeLast = List().add("rmb", "smb", "bbr", "bbs", "???")
.var opcodeMnems = List()
.for (var i = 0; i < 256; i++) {
    .var name = opcodeTable.get(i).substring(0, 3)
    .var seen = false
    .for (var j = 0; j < opcodeMnems.size(); j++) .if (opcodeMnems.get(j) == name) .eval seen = true
    .for (var j = 0; j < opcodeLast.size(); j++) .if (opcodeLast.get(j) == name) .eval seen = true
    .if (!seen) .eval opcodeMnems.add(name)
}
.for (var j = 0; j < opcodeLast.size(); j++) .eval opcodeMnems.add(opcodeLast.get(j))
.assert "mnemonic table fits in 256 bytes", opcodeMnems.size() * 3 <= 256, true

.function opcodeMnemOffset(name) {
    .for (var j = 0; j < opcodeMnems.size(); j++) .if (opcodeMnems.get(j) == name) .return j * 3
    .error "unknown mnemonic " + name
}

.const MNEM_FIRST_BIT = opcodeMnemOffset("rmb")    // rmb, smb, bbr, bbs: from here up to MNEM_UNKNOWN
.const MNEM_UNKNOWN = opcodeMnemOffset("???")      // the last mnemonic

op_mnem:
    .fill 256, opcodeMnemOffset(opcodeTable.get(i).substring(0, 3))
op_mode:
    .fill 256, opcodeModeIds.get(opcodeTable.get(i).substring(4, opcodeTable.get(i).size()))
mnem_text:
    .for (var i = 0; i < opcodeMnems.size(); i++) .text opcodeMnems.get(i)
mode_len:
    .byte 1, 1, 2, 2, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 2, 3, 1, 2, 3
.assert "mode_len has every mode", * - mode_len, OP_MODES
