/* =========================================================================
   TINY GPT
   A 4-bit transformer language model for the KiT.

   Type a prompt (or nothing) and press enter. The model continues it one
   token at a time. Esc stops it; esc at the prompt returns to the monitor.

   Weights stream straight from the SSD: each model is a KSF data file
   named "<model>-weights" (see export.py). This program carries only code
   and model-independent tables, plus constants from build/<model>/model.inc
   and settings from models/<model>/settings.inc, so it must be assembled
   for the weights it runs with:

     ka -libdir ../../roms/kit-os -libdir build/titles -libdir models/titles \
        -odir build/titles tinygpt.asm
   ========================================================================= */

.cpu _65c02
.encoding "ascii"
.filenamespace tinygpt

#define PCB
#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/kb.lib"
#import "kit_os.sym"
#import "model.inc"
#import "settings.inc"

// ---------------------------------------------------------------- settings
.const PROMPT_MAX = 60
.const XMAX = 8191              // residual saturation
.const ATT_C0 = mod(16384 * HD, 65536)

#if TEST
.var TEST_TOKENS = cmdLineVars.containsKey("TOKENS") ? cmdLineVars.get("TOKENS").asNumber() : 24
.var TEST_PROMPT = cmdLineVars.containsKey("PROMPT") ? cmdLineVars.get("PROMPT") : ""
#endif
// Debugging: assemble with :DUMP=n to copy 512 bytes of state to the screen and stop at stage n
.var DUMP = cmdLineVars.containsKey("DUMP") ? cmdLineVars.get("DUMP").asNumber() : 0
.var DUMP_FROM = cmdLineVars.containsKey("DUMPFROM") ? cmdLineVars.get("DUMPFROM").asNumber() : $0d00
.var DUMPSTEP = cmdLineVars.containsKey("DUMPSTEP") ? cmdLineVars.get("DUMPSTEP").asNumber() : 0
.macro stage(n) {
#if TEST
    .if (DUMP == n) {
        lda fwd_count
        cmp #DUMPSTEP
        bne !+
        jsr dump_state
    !:
    }
#endif
}

// ---------------------------------------------------------------- hardware
.label SECREG = $7900           // VIA2 port B: SSD sector
.label SECDDR = $7902
.label VRAM = $6000

// ---------------------------------------------------------------- zero page
.label ACCL = $80               // 64 accumulators, low bytes
.label ACCH = $c0               // and high bytes
.label OACC = 32                // attention output accumulators at ACCL+32, ACCH+32

.label ne = $40                 // next_column: end of column (2)
.label wp = $46                 // weight column pointer
.label p1 = $48                 // quarter-square table pointers
.label p2 = $4a
.label p3 = $4c
.label p4 = $4e
.label wsec = $50               // weight stream: index into seclist
.label waddr = $51              // and address in the $8100-$8fff window
.label mvx = $53                // matvec input vector
.label mvrows = $55
.label mvcols = $56
.label mvcol = $57
.label colbytes = $58
.label xl = $59                 // P-table multiplier
.label ma = $5a                 // mulshift operands: ma (signed) * mb (unsigned) >> mk
.label mb = $5c
.label mk = $5e
.label mr = $5f                 // 32-bit result
.label msign = $63
.label umlo = $64
.label t0 = $65
.label t1 = $66
.label t2 = $67
.label t3 = $68
.label t4 = $69
.label t5 = $6a
.label rq_m = $6b               // requant: multiplier pointer
.label rq_d = $6d               // destination pointer
.label rq_src = $6f
.label rq_n = $70
.label rq_k = $71
.label rq_mode = $72
.label rq_i = $73
.label layer = $74
.label head = $75
.label slot = $76               // KV slot of the current token
.label count = $77              // valid KV slots
.label npos = $78               // tokens processed (saturates at NW)
.label rng = $79                // 2
.label crow = $7b               // text cursor
.label ccol = $7c
.label ptr = $7d                // 2
.label curtok = $7f

// ---------------------------------------------------------------- RAM
.label SQ1L = $0300             // floor(n^2/4), n = 0..511
.label SQ1H = $0500
.label SQ2L = $0700             // floor((n-255)^2/4), n = 0..511
.label SQ2H = $0900
.label PL = $0b00               // P table: entry n and 16n hold (n-8)*x
.label PH = $0c00
.label XL = $0d00               // residual stream, int16
.label XH = $0d40
.label HV = $0d80               // normalized vector, int8
.label QV = $0dc0               // queries
.label KVV = $0e00              // key (HD) then value (HD)
.label OV = $0e40               // attention output
.label UV = $0e80               // FFN hidden (FF <= 128)
.label ZL = $0f00               // attention logits
.label ZH = $0f20
.label EV = $0f40               // attention weights
.label SECLIST = $0f60          // SSD sectors of the weight file
.label WBUF = $0f70             // word-wrap buffer (32)
.label ntok = $0f90             // prompt tokens
.label ngen = $0f91             // generated tokens
.label nm_i = $0f92
.label nm_f = $0f93             // 2
.label ntot = $0f95             // tokens generated in a test run
.label TOKBUF = $3000           // prompt tokens
.label PROMPT = $3080           // prompt text
.label PARAMS = $3100           // parameter blob
.label KC = $3a00               // keys: [layer][c][slot], offset binary
.label VC = $3e00               // values: [layer][slot][c], offset binary
.label KSL = $4200              // 128 * sum of key bytes: [layer][slot]
.label KSH = $4240
.label LOGL = $4300             // logits
.label LOGH = $4400
.label ET = $4500               // sampling weights

.assert "blob fits", PARAMS + BLOB_SIZE <= KC, true
.assert "keys fit", KC + NL * HD * NW <= VC, true
.assert "values fit", VC + NL * NW * HD <= KSL, true
.assert "dims", DM <= 64 && FF <= 128 && 2 * HD <= 32 && NH * HD == DM && NW == 32, true


#if TEST
.segment Code [outPrg=NAME + "-test.prg", start=$1000]
#else
.segment Code [outPrg=NAME + ".prg", start=$1000]
#endif

start:
    lda #$ff
    sta SECDDR
    jsr kb.init                     // the monitor's go leaves kb_read_ptr clobbered
    jsr vid.blank_screen
    stz crow
    stz ccol
    lda #1
    sta rng
    stz rng+1
    ldx #0
!:  lda intro_text,x
    beq !+
    jsr putc
    inx
    bra !-
!:
    jsr gen_squares
    lda #>SQ1L                      // pointer high bytes never change
    sta p1+1
    lda #>SQ2L
    sta p2+1
    lda #>SQ1H
    sta p3+1
    lda #>SQ2H
    sta p4+1

    jsr find_weights
    bcs no_weights
    jsr load_blob
    bcc main_loop
no_weights:
    ldx #0
!:  lda missing,x
    beq !+
    jsr putc
    inx
    bra !-
!:
#if TEST
    .byte $bb
#endif
    jsr wait_key
    jmp exit

main_loop:
#if TEST
    ldy #0
!:  lda test_prompt,y
    sta PROMPT,y
    beq !+
    jsr putc
    iny
    bra !-
!:  lda #$34
    sta rng
    lda #$12
    sta rng+1
#else
    jsr read_prompt
#endif
    jsr tokenize
    stz npos
    stz slot
    jsr show_busy
    lda #0                          // start of story
    jsr forward
    stz ngen
!:  lda ngen
    cmp ntok
    beq !+
    tax
    lda TOKBUF,x
    jsr forward
    inc ngen
    bra !-
!:  jsr clear_busy
#if TEST
    stz ntot
#endif
gen_item:
    stz ngen                        // tokens in this item
gen_loop:
#if !TEST
    jsr kb.get_press
    cmp #kb.ASCII_ESC
    beq story_done
#endif
    jsr sample
#if TEST
    ldx ntot
    sta TOKBUF,x
    inc ntot
#endif
    cmp #0
    beq item_done
    pha
    jsr print_token
    jsr show_busy
    pla
    jsr forward
    jsr clear_busy
#if TEST
    lda ntot
    cmp #TEST_TOKENS
    beq story_done
#endif
    inc ngen
    lda ngen
    cmp #MAX_TOKENS
    bne gen_loop
item_done:
#if TEST
    lda ntot
    cmp #TEST_TOKENS
    beq story_done
#endif
.if (STREAM != 0) {
    lda ntok                        // with no prompt, start another one
    bne story_done
    jsr newline
    jsr newline
    jsr show_busy
    lda #0
    jsr forward
    jsr clear_busy
    jmp gen_item
}
story_done:
#if TEST
    .if (DUMP == 99) jsr dump_state
    .byte $bb
#endif
    jsr newline
    jsr newline
    jmp main_loop

exit:
    jsr vid.blank_screen
    brk
    nop

#if TEST
fwd_count:
    .byte $ff
dump_state:
    ldx #0
!:  lda DUMP_FROM,x
    sta VRAM,x
    lda DUMP_FROM + 256,x
    sta VRAM + 256,x
    inx
    bne !-
    .byte $bb
#endif


intro_text:
    intro()
    .byte 0
missing:
    .text "no " + NAME + " weights on the ssd (or they don't match)."
    .byte 10, 0

#if TEST
test_prompt:
    .text TEST_PROMPT
    .byte 0

#endif


// =========================================================================
// Forward pass: A = input token. Leaves logits in LOGL/LOGH.
// =========================================================================

.macro set_stream(name) {
    .var m = MAT.get(name)
    ldx #m.get(0)
    stx wsec
    lda SECLIST,x
    sta SECREG
    lda #<m.get(1)
    sta waddr
    lda #>m.get(1)
    sta waddr+1
}

.macro matvec(name, input) {
    .var m = MAT.get(name)
    set_stream(name)
    lda #m.get(2)
    sta mvrows
    lda #m.get(3)
    sta mvcols
    lda #<input
    sta mvx
    lda #>input
    sta mvx+1
    jsr matvec
}

// Requantize n accumulators starting at row `first` of an R-row matvec
.macro requant(rows, first, n, mults, k, dest, mode) {
    lda #64 - rows + first
    sta rq_src
    lda #n
    sta rq_n
    lda #<mults
    sta rq_m
    lda #>mults
    sta rq_m+1
    lda #k
    sta rq_k
    lda #<dest
    sta rq_d
    lda #>dest
    sta rq_d+1
    lda #mode
    sta rq_mode
    jsr requant
}
.const RQ_INT8 = 0
.const RQ_RELU = 1
.const RQ_RESID = 2
.const RQ_LOGIT = 3                 // int16 into LOGL/LOGH at index dest + i

.macro norm(cname, dest, final) {
    lda #<MC.get(cname + "_C")
    sta t0
    lda #>MC.get(cname + "_C")
    sta t1
    lda #MC.get(cname + "_S")
    sta t2
    lda #final
    sta t3
    lda #<dest
    sta rq_d
    lda #>dest
    sta rq_d+1
    jsr norm
}

forward:
    sta curtok
#if TEST
    inc fwd_count
#endif
    jsr embed
    stage(1)
.for (var l = 0; l < NL; l++) {
    .var p = "L" + l + "_"
    lda #l
    sta layer
    norm(p + "N1", HV, 0)
    stage(2 + 10 * l)
    matvec(p + "Q", HV)
    requant(DM, 0, DM, PARAMS + PO.get(p + "QM"), MC.get(p + "QK"), QV, RQ_INT8)
    matvec(p + "KV", HV)
    requant(2 * HD, 0, HD, PARAMS + PO.get(p + "KM"), MC.get(p + "KK"), KVV, RQ_INT8)
    requant(2 * HD, HD, HD, PARAMS + PO.get(p + "VM"), MC.get(p + "VK"), KVV + HD, RQ_INT8)
    stage(3 + 10 * l)
    lda #MC.get(p + "ATT_A")
    sta att_a
    lda #MC.get(p + "ATT_KA")
    sta att_ka
    lda #<(PARAMS + PO.get(p + "BIASL"))
    sta att_bl+1
    lda #>(PARAMS + PO.get(p + "BIASL"))
    sta att_bl+2
    lda #<(PARAMS + PO.get(p + "BIASH"))
    sta att_bh+1
    lda #>(PARAMS + PO.get(p + "BIASH"))
    sta att_bh+2
    jsr attention
    stage(4 + 10 * l)
    matvec(p + "O", OV)
    requant(DM, 0, DM, PARAMS + PO.get(p + "OM"), MC.get(p + "OK"), 0, RQ_RESID)
    norm(p + "N2", HV, 0)
    stage(5 + 10 * l)
    .for (var ch = 0; ch * 64 < FF; ch++) {
        .var rows = min(64, FF - ch * 64)
        matvec(p + "UP" + ch, HV)
        requant(rows, 0, rows, PARAMS + PO.get(p + "UPM") + ch * 64, MC.get(p + "UPK"), UV + ch * 64, RQ_RELU)
    }
    stage(6 + 10 * l)
    matvec(p + "DOWN", UV)
    requant(DM, 0, DM, PARAMS + PO.get(p + "DOWNM"), MC.get(p + "DOWNK"), 0, RQ_RESID)
    stage(7 + 10 * l)
}
    norm("NF", HV, 1)
    stage(30)
    // logits for each 64-token chunk of the vocabulary
.for (var ch = 0; ch < VCHUNKS; ch++) {
    matvec("EMB" + ch, HV)
    requant(64, 0, 64, PARAMS + PO.get("EMB_M") + ch * 64, MC.get("EMB_K"), ch * 64, RQ_LOGIT)
}
    stage(31)
    // advance the KV ring
    lda slot
    inc
    and #NW - 1
    sta slot
    lda npos
    cmp #NW
    beq !+
    inc npos
!:  rts

// Embedding lookup: XL/XH = lv[curtok] * m_in[curtok] >> EMB_KIN
embed:
    lda curtok
    lsr
    lsr
    lsr
    lsr
    lsr
    lsr
    tax                             // vocabulary chunk
    lda emb_sec,x
    sta wsec
    tay
    lda SECLIST,y
    sta SECREG
    lda emb_lo,x
    sta waddr
    lda emb_hi,x
    sta waddr+1
    lda #32
    sta colbytes
    lda curtok
    and #63
    lsr
    sta t4                          // byte within column
    ldx curtok
    lda PARAMS + PO.get("EMB_MIN"),x
    sta mb
    stz mb+1
    stz layer                       // column index
emb_loop:
    jsr next_column
    ldy t4
    lda (wp),y
    sta t5
    lda curtok                      // odd rows are in the high nibble
    lsr
    lda t5
    bcc !+
    lsr
    lsr
    lsr
    lsr
!:  and #$0f
    sec
    sbc #8
    sta ma
    lda #0
    sbc #0                          // sign extend (borrow propagates)
    sta ma+1
    lda #MC.get("EMB_KIN")
    sta mk
    jsr mulshift
    ldx layer
    stz XL,x
    stz XH,x
    jsr add_resid
    inc layer
    lda layer
    cmp #DM
    bne emb_loop
    rts

emb_sec:
    .fill VCHUNKS, MAT.get("EMB" + i).get(0)
emb_lo:
    .fill VCHUNKS, <MAT.get("EMB" + i).get(1)
emb_hi:
    .fill VCHUNKS, >MAT.get("EMB" + i).get(1)


// =========================================================================
// Matrix-vector product with 4-bit weights streamed from the SSD.
// Columns of mvrows/2 bytes (two rows per byte, low nibble first, offset 8).
// Result: ACCL/ACCH[64-mvrows .. 63].
// For each input x_j, build P[n] = (n-8)*x_j and look up every weight.
// =========================================================================

matvec:
    lda mvrows
    lsr
    sta colbytes
    tax
    lda mac_entry_lo,x
    sta mv_call+1
    lda mac_entry_hi,x
    sta mv_call+2
    lda #64
    sec
    sbc mvrows
    tax
!:  stz ACCL,x
    stz ACCH,x
    inx
    cpx #64
    bne !-
    stz mvcol
mv_col:
    jsr next_column
    ldy mvcol
    lda (mvx),y
    beq mv_skip                     // zero input: nothing to add
    jsr build_p
    ldy #0
mv_call:
    jsr $ffff
mv_skip:
    inc mvcol
    lda mvcol
    cmp mvcols
    bne mv_col
    rts

// Point wp at the next column of colbytes bytes, moving to the next sector if it doesn't fit
next_column:
    lda waddr
    clc
    adc colbytes
    sta ne
    lda waddr+1
    adc #0
    sta ne+1
    cmp #$90
    bcc !+
    bne nc_sector
    lda ne
    beq !+
nc_sector:
    inc wsec
    ldy wsec
    lda SECLIST,y
    sta SECREG
    lda #$00
    sta waddr
    lda #$81
    sta waddr+1
    bra next_column
!:  lda waddr
    sta wp
    lda waddr+1
    sta wp+1
    lda ne
    sta waddr
    lda ne+1
    sta waddr+1
    rts

// Build P table for x = A (nonzero int8): PL/PH[n] = PL/PH[16n] = (n-8)*x
build_p:
    sta xl
    sta t0
    ldx #0
    cmp #0
    bpl !+
    ldx #$ff
!:  stx t1
    asl t0                          // 8x
    rol t1
    asl t0
    rol t1
    asl t0
    rol t1
    sec                             // v = -8x
    lda #0
    sbc t0
    tay
    lda #0
    sbc t1
    tax
    tya
    bit xl
    bpl !+
    jmp bp_neg
!:
.for (var n = 0; n < 16; n++) {
    sta PL + n
    .if (n > 0) sta PL + 16 * n
    stx PH + n
    .if (n > 0) stx PH + 16 * n
    .if (n < 15) {
        clc
        adc xl
        bcc !+
        inx
    !:
    }
}
    rts
bp_neg:
.for (var n = 0; n < 16; n++) {
    sta PL + n
    .if (n > 0) sta PL + 16 * n
    stx PH + n
    .if (n > 0) stx PH + 16 * n
    .if (n < 15) {
        clc
        adc xl
        bcs !+
        dex
    !:
    }
}
    rts

// Unrolled multiply-accumulate: 32 fragments of two rows each
.var mac_entries = List()
mac_code:
.for (var k = 0; k < 32; k++) {
    .eval mac_entries.add(*)
    lda (wp),y
    and #$0f
    tax
    clc
    lda PL,x
    adc ACCL + 2 * k
    sta ACCL + 2 * k
    lda PH,x
    adc ACCH + 2 * k
    sta ACCH + 2 * k
    lda (wp),y
    and #$f0
    tax
    clc
    lda PL,x
    adc ACCL + 2 * k + 1
    sta ACCL + 2 * k + 1
    lda PH,x
    adc ACCH + 2 * k + 1
    sta ACCH + 2 * k + 1
    iny
}
    rts
mac_entry_lo:                       // indexed by pairs = rows/2
    .fill 33, i == 0 ? 0 : <mac_entries.get(32 - i)
mac_entry_hi:
    .fill 33, i == 0 ? 0 : >mac_entries.get(32 - i)


// =========================================================================
// Requantize accumulators: v = round(acc * m >> k), then store by mode
// =========================================================================

requant:
    stz rq_i
rq_loop:
    lda rq_src
    clc
    adc rq_i
    tax
    lda ACCL,x
    sta ma
    lda ACCH,x
    sta ma+1
    ldy rq_i
    lda (rq_m),y
    sta mb
    stz mb+1
    lda rq_k
    sta mk
    jsr mulshift
    ldy rq_i
    lda rq_mode
    beq rq_int8
    cmp #RQ_RELU
    beq rq_relu
    cmp #RQ_LOGIT
    bne rq_resid
    lda rq_d
    clc
    adc rq_i
    tax
    lda mr
    sta LOGL,x
    lda mr+1
    sta LOGH,x
    bra rq_next
rq_resid:
    ldx rq_i                        // residual add
    jsr add_resid
    bra rq_next
rq_relu:
    lda mr+3
    bmi rq_zero
    jsr clamp8
    bra rq_store
rq_zero:
    lda #0
    bra rq_store
rq_int8:
    jsr clamp8
rq_store:
    sta (rq_d),y
rq_next:
    inc rq_i
    lda rq_i
    cmp rq_n
    bne rq_loop
    rts

// A = mr clamped to -127..127
clamp8:
    lda mr+3
    bmi c8_neg
    ora mr+2
    ora mr+1
    bne c8_max
    lda mr
    cmp #$80
    bcs c8_max
    rts
c8_max:
    lda #127
    rts
c8_neg:
    and mr+2
    and mr+1
    cmp #$ff
    bne c8_min
    lda mr
    cmp #$81
    bcc c8_min
    rts
c8_min:
    lda #$81
    rts

// X[x] = clamp(X[x] + mr, -XMAX, XMAX)
add_resid:
    ldy #0
    lda XH,x
    bpl !+
    dey
!:  sty msign                       // sign extension of X
    lda XL,x
    clc
    adc mr
    sta mr
    lda XH,x
    adc mr+1
    sta mr+1
    lda msign
    adc mr+2
    sta mr+2                        // 24-bit sum (mr+3 ignored)
    bmi ar_neg
    bne ar_max
    lda mr+1
    cmp #>XMAX
    bcc ar_store
    bne ar_max
    lda mr
    cmp #<XMAX
    bcc ar_store
    beq ar_store
ar_max:
    lda #<XMAX
    sta XL,x
    lda #>XMAX
    sta XH,x
    rts
ar_neg:
    cmp #$ff
    bne ar_min
    lda mr+1
    cmp #>(-XMAX & $ffff)
    bcc ar_min
    bne ar_store
    lda mr
    cmp #<(-XMAX & $ffff)
    bcc ar_min
ar_store:
    lda mr
    sta XL,x
    lda mr+1
    sta XH,x
    rts
ar_min:
    lda #<(-XMAX & $ffff)
    sta XL,x
    lda #>(-XMAX & $ffff)
    sta XH,x
    rts


// =========================================================================
// Arithmetic
// =========================================================================

// A * Y (unsigned) -> umlo, A = high byte. Quarter squares: ab = f(a+b) - f(|a-b|)
umul8:
    sta p1
    sta p3
    eor #$ff
    sta p2
    sta p4
    sec
    lda (p1),y
    sbc (p2),y
    sta umlo
    lda (p3),y
    sbc (p4),y
    rts

// mr = ma * mb, unsigned 16 x 16
umul16:
    stz mr+2
    stz mr+3
    lda ma
    ldy mb
    jsr umul8
    sta mr+1
    lda umlo
    sta mr
    lda ma+1
    ldy mb
    jsr umul8
    tax
    lda umlo
    clc
    adc mr+1
    sta mr+1
    txa
    adc #0
    sta mr+2
    ldy mb+1
    beq !+
    lda ma
    jsr umul8
    tax
    lda umlo
    clc
    adc mr+1
    sta mr+1
    txa
    adc mr+2
    sta mr+2
    lda #0
    adc #0
    sta mr+3
    lda ma+1
    ldy mb+1
    jsr umul8
    tax
    lda umlo
    clc
    adc mr+2
    sta mr+2
    txa
    adc mr+3
    sta mr+3
!:  rts

// mr = floor((ma * mb + 2^(mk-1)) / 2^mk), ma signed, mb unsigned, 1 <= mk <= 24
mulshift:
    jsr umul16                      // ma as unsigned 16-bit
    bit ma+1
    bpl !+
    sec                             // ma < 0: subtract mb << 16
    lda mr+2
    sbc mb
    sta mr+2
    lda mr+3
    sbc mb+1
    sta mr+3
!:  ldx mk                          // add 2^(mk-1)
    dex
    txa
    lsr
    lsr
    lsr
    tay                             // byte
    txa
    and #7
    tax
    lda bit_value,x
    clc
    adc mr,y
    sta mr,y
    bcc ms_shift
!:  iny                             // carry into the next byte
    cpy #4
    beq ms_shift
    lda mr,y
    adc #1                          // carry is clear after cpy
    sta mr,y
    bcs !-
ms_shift:
    ldy mk
    // fall through

// Arithmetic shift mr right by Y bits
asr32:
    cpy #8
    bcc as_bits
    lda mr+1
    sta mr
    lda mr+2
    sta mr+1
    lda mr+3
    sta mr+2
    and #$80
    beq !+
    lda #$ff
!:  sta mr+3
    tya
    sbc #8                          // carry set from cpy
    tay
    bra asr32
as_bits:
    cpy #0
    beq !+
    lda mr+3
    cmp #$80
    ror mr+3
    ror mr+2
    ror mr+1
    ror mr
    dey
    bra as_bits
!:  rts

bit_value:
    .byte 1, 2, 4, 8, 16, 32, 64, 128

neg32:
    sec
    ldx #0
    ldy #4
!:  lda #0
    sbc mr,x
    sta mr,x
    inx
    dey
    bne !-
    rts


// =========================================================================
// RMS norm of XL/XH into rq_d:  h = x * F >> (6 + e + s),
// F = RSQ[M >> 8] * C >> 16 where sum(x^2) = M * 4^e, M in [2^14, 2^16).
// t0/t1 = C, t2 = s, t3 = 1 for the final norm (gain, 4 extra bits)
// =========================================================================

norm:
    stz mr
    stz mr+1
    stz mr+2
    stz mr+3
    ldx #0
nm_sq:
    lda XL,x                        // |x| into t4 (lo), t5 (hi)
    sta t4
    lda XH,x
    sta t5
    bpl !+
    sec
    lda #0
    sbc t4
    sta t4
    lda #0
    sbc t5
    sta t5
!:  lda t4                          // lo^2
    tay
    jsr umul8
    tay
    lda umlo
    clc
    adc mr
    sta mr
    tya
    adc mr+1
    sta mr+1
    bcc !+
    inc mr+2
    bne !+
    inc mr+3
!:  lda t5                          // 2 lo hi at byte 1
    beq nm_next
    ldy t4
    jsr umul8
    asl umlo
    rol
    tay
    lda #0
    rol
    sta msign                       // bit 16 of 2*lo*hi
    lda umlo
    clc
    adc mr+1
    sta mr+1
    tya
    adc mr+2
    sta mr+2
    lda msign
    adc mr+3
    sta mr+3
    lda t5                          // hi^2 at byte 2
    tay
    jsr umul8
    tay
    lda umlo
    clc
    adc mr+2
    sta mr+2
    tya
    adc mr+3
    sta mr+3
nm_next:
    inx
    cpx #DM
    bne nm_sq

    ldx #0                          // e in X (signed)
nm_down:
    lda mr+2
    ora mr+3
    beq nm_up
    lsr mr+3
    ror mr+2
    ror mr+1
    ror mr
    lsr mr+3
    ror mr+2
    ror mr+1
    ror mr
    inx
    bra nm_down
nm_up:
    lda mr
    ora mr+1
    beq nm_zero
!:  lda mr+1
    cmp #$40
    bcs !+
    asl mr
    rol mr+1
    asl mr
    rol mr+1
    dex
    bra !-
!:  ldy mr+1                        // index 64..255
    lda rsq_lo - 64,y
    sta ma
    lda rsq_hi - 64,y
    sta ma+1
    lda t0
    sta mb
    lda t1
    sta mb+1
    phx
    jsr umul16                      // F = (RSQ * C) >> 16
    plx
    lda mr+2
    sta nm_f
    lda mr+3
    sta nm_f+1
    txa
    clc
    adc #6
    clc                             // e may be negative: drop the carry from adding 6
    adc t2
    bpl !+
    lda #1
!:  bne !+
    lda #1
!:  sta t4                          // shift = 6 + e + s (at least 1)
    bra nm_apply
nm_zero:
    stz nm_f
    stz nm_f+1
    lda #1
    sta t4
nm_apply:
    stz nm_i
nm_loop:
    ldx nm_i
    lda XL,x
    sta ma
    lda XH,x
    sta ma+1
    lda nm_f
    sta mb
    lda nm_f+1
    sta mb+1
    lda t4
    sta mk
    jsr mulshift
    lda t3
    bne nm_final
    jsr clamp8
    bra nm_store
nm_final:
    // h = mr (int16, 4 extra bits); out = clamp(h * g >> (KG + 4)), negating h for g < 0
    ldx nm_i
    lda PARAMS + PO.get("GF"),x
    bpl !+
    eor #$ff
    inc
    sta mb
    sec
    lda #0
    sbc mr
    sta ma
    lda #0
    sbc mr+1
    sta ma+1
    bra nf_mul
!:  sta mb
    lda mr
    sta ma
    lda mr+1
    sta ma+1
nf_mul:
    stz mb+1
    lda #MC.get("KG") + 4
    sta mk
    jsr mulshift
    jsr clamp8
nm_store:
    ldy nm_i
    sta (rq_d),y
    inc nm_i
    lda nm_i
    cmp #DM
    bne nm_loop
    rts


// =========================================================================
// Attention for one layer (multi-query: one key/value head shared by NH query heads).
// Keys/values are cached in offset binary (k + 128), so products use unsigned
// quarter squares and q.k = sum(Q'K') - 128 sum Q' - 128 sum K' + 16384 HD (mod 2^16).
// =========================================================================

att_a:  .byte 0
att_ka: .byte 0
att_qs: .word 0
att_e:  .word 0
att_r:  .word 0
att_ps: .word 0

attention:
    // count = valid slots = min(npos + 1, NW)
    lda npos
    cmp #NW
    bcc !+
    lda #NW - 1
!:  inc
    sta count

    // store key column-wise: KC[layer][c][slot], and 128 * sum
    ldx layer
    lda kc_layer_lo,x
    sta ptr
    lda kc_layer_hi,x
    sta ptr+1
    stz t0                          // sum of K' (16-bit)
    stz t1
    ldx #0
ks_loop:
    lda KVV,x
    eor #$80
    ldy slot
    sta (ptr),y
    clc
    adc t0
    sta t0
    bcc !+
    inc t1
!:  lda ptr
    clc
    adc #NW
    sta ptr
    bcc !+
    inc ptr+1
!:  inx
    cpx #HD
    bne ks_loop
    // KS = sum << 7
    lda layer
    asl
    asl
    asl
    asl
    asl                             // layer * 32
    clc
    adc slot
    tax
    lda t1
    lsr
    lda t0
    ror
    sta KSH,x
    lda #0
    ror
    sta KSL,x

    // store value row: VC[layer][slot][c]
    jsr v_row_ptr                   // ptr = VC + (layer*NW + slot)*HD
    ldy #0
!:  lda KVV + HD,y
    eor #$80
    sta (ptr),y
    iny
    cpy #HD
    bne !-

    stz head
att_head:
    // Q' = q + 128 for this head, QS = 128 * sum Q'
    lda head
    tax
    lda head_off,x
    tax
    ldy #0
    stz t0
    stz t1
!:  lda QV,x
    eor #$80
    sta qbuf,y
    clc
    adc t0
    sta t0
    bcc !+
    inc t1
!:  inx
    iny
    cpy #HD
    bne !--
    lda t1
    lsr
    lda t0
    ror
    sta att_qs+1
    lda #0
    ror
    sta att_qs

    // score[s] = C0 - QS - KS[s]
    lda layer
    asl
    asl
    asl
    asl
    asl
    sta t2
    ldx count
    dex
!:  txa
    clc
    adc t2
    tay
    sec
    lda #<ATT_C0
    sbc att_qs
    sta t0
    lda #>ATT_C0
    sbc att_qs+1
    sta t1
    sec
    lda t0
    sbc KSL,y
    sta ACCL,x
    lda t1
    sbc KSH,y
    sta ACCH,x
    dex
    bpl !-

    // score[s] += Q'_c * K'[c][s]
    lda layer
    tax
    lda kc_layer_lo,x
    sta qk_col+1
    lda kc_layer_hi,x
    sta qk_col+2
    ldy #0
att_qk_c:
    sty t3
    lda qbuf,y
    sta p1
    sta p3
    eor #$ff
    sta p2
    sta p4
    ldx count
    dex
qk_loop:
qk_col:
    ldy $ffff,x
    sec
    lda (p1),y
    sbc (p2),y
    sta t0
    lda (p3),y
    sbc (p4),y
    tay
    clc
    lda t0
    adc ACCL,x
    sta ACCL,x
    tya
    adc ACCH,x
    sta ACCH,x
    dex
    bpl qk_loop
    lda qk_col+1
    clc
    adc #NW
    sta qk_col+1
    bcc !+
    inc qk_col+2
!:  ldy t3
    iny
    cpy #HD
    bne att_qk_c

    // z[s] = (score * A >> kA) + bias[head][(slot - s) & (NW-1)], clamped to int16; track max
    lda #$00
    sta att_e                       // max z (starts at -32768)
    lda #$80
    sta att_e+1
    ldx count
    dex
att_z:
    phx
    lda ACCL,x
    sta ma
    lda ACCH,x
    sta ma+1
    lda att_a
    sta mb
    stz mb+1
    lda att_ka
    sta mk
    jsr mulshift
    plx
    stx t3                          // slot index
    lda slot                        // distance to this slot
    sec
    sbc t3
    and #NW - 1
    sta t0
    lda head
    asl
    asl
    asl
    asl
    asl                             // head * NW
    ora t0
    tay
    ldx #0
att_bh:
    lda $ffff,y                     // bias high byte (patched per layer)
    sta t2
    bpl !+
    dex
!:  stx t1                          // and its sign extension
att_bl:
    lda $ffff,y                     // bias low byte
    clc
    adc mr
    sta mr
    lda t2
    adc mr+1
    sta mr+1
    lda t1
    adc mr+2
    sta mr+2
    // clamp 24-bit to int16
    bmi az_neg
    bne az_max
    lda mr+1
    bpl az_ok
az_max:
    lda #$ff
    sta mr
    lda #$7f
    sta mr+1
    bra az_ok
az_neg:
    cmp #$ff
    bne az_min
    lda mr+1
    bmi az_ok
az_min:
    stz mr
    lda #$80
    sta mr+1
az_ok:
    ldx t3
    lda mr
    sta ZL,x
    lda mr+1
    sta ZH,x
    // signed compare with max
    lda mr
    cmp att_e
    lda mr+1
    sbc att_e+1
    bvc !+
    eor #$80
!:  bmi !+
    lda mr
    sta att_e
    lda mr+1
    sta att_e+1
!:  dex
    bmi !+
    jmp att_z
!:

    // e[s] = EXP[min(max - z, 255)], E = sum
    stz t0
    stz t1
    ldx count
    dex
!:  sec
    lda att_e
    sbc ZL,x
    tay
    lda att_e+1
    sbc ZH,x
    beq !+
    ldy #255
!:  lda exp_table,y
    sta EV,x
    clc
    adc t0
    sta t0
    bcc !+
    inc t1
!:  dex
    bpl !---

    // R = 65536 / E  (E >= 255, so R <= 257)
    jsr recip
    // p[s] = min(e[s] * R >> 8, 255); PS = sum p
    stz att_ps
    stz att_ps+1
    ldx count
    dex
att_p:
    lda EV,x
    beq ap_store
    ldy att_r
    jsr umul8                       // A = hi(e * R_lo)
    ldy att_r+1
    beq !+
    clc
    adc EV,x
    bcc !+
    lda #255
!:
ap_store:
    sta EV,x
    clc
    adc att_ps
    sta att_ps
    bcc !+
    inc att_ps+1
!:  dex
    bpl att_p

    // O[c] = -128 * PS
    lda att_ps+1
    lsr
    lda att_ps
    ror
    sta t1
    lda #0
    ror
    sta t0                          // t1:t0 = PS << 7
    ldx #HD - 1
!:  sec
    lda #0
    sbc t0
    sta ACCL + OACC,x
    lda #0
    sbc t1
    sta ACCH + OACC,x
    dex
    bpl !-

    // O[c] += p[s] * V'[s][c]
    lda count
    dec
    sta t3
av_slot:
    ldx t3
    lda EV,x
    beq av_next
    sta p1
    sta p3
    eor #$ff
    sta p2
    sta p4
    lda t3
    sta t4                          // slot s
    jsr v_row_ptr_s
    lda ptr
    sta av_row+1
    lda ptr+1
    sta av_row+2
    ldx #HD - 1
av_loop:
av_row:
    ldy $ffff,x
    sec
    lda (p1),y
    sbc (p2),y
    sta t0
    lda (p3),y
    sbc (p4),y
    tay
    clc
    lda t0
    adc ACCL + OACC,x
    sta ACCL + OACC,x
    tya
    adc ACCH + OACC,x
    sta ACCH + OACC,x
    dex
    bpl av_loop
av_next:
    dec t3
    bpl av_slot

    // o = clamp((O + 128) >> 8)
    lda head
    tax
    lda head_off,x
    tay
    ldx #0
!:  lda ACCL + OACC,x
    clc
    adc #$80
    lda ACCH + OACC,x
    adc #0
    bvs ao_max
    cmp #$80
    bne ao_store
    lda #$81
    bra ao_store
ao_max:
    lda #127
ao_store:
    sta OV,y
    iny
    inx
    cpx #HD
    bne !-

    inc head
    lda head
    cmp #NH
    beq !+
    jmp att_head
!:  rts

// ptr = VC + (layer * NW + slot) * HD
v_row_ptr:
    lda slot
    sta t4
v_row_ptr_s:                        // same for slot t4
    lda layer
    asl
    asl
    asl
    asl
    asl
    clc
    adc t4
    tay
    lda vrow_lo,y
    sta ptr
    lda vrow_hi,y
    sta ptr+1
    rts

// att_r = 65536 / (t1:t0)
recip:
    stz att_r
    stz att_r+1
    lda #1                          // remainder starts at 0; dividend 0x10000: shift in 17 bits
    sta t2                          // dividend high bit
    stz t3                          // remainder lo
    stz t4                          // remainder hi
    stz t5                          // remainder bit 16
    ldx #17
rc_loop:
    // remainder = remainder * 2 + next dividend bit (only the first bit is 1)
    lda t2
    lsr
    stz t2
    rol t3
    rol t4
    rol t5
    // if remainder >= E: subtract, quotient bit 1
    lda t3
    sec
    sbc t0
    tay
    lda t4
    sbc t1
    pha
    lda t5
    sbc #0
    bcc rc_zero
    sta t5
    pla
    sta t4
    sty t3
    sec
    bra rc_shift
rc_zero:
    pla
    clc
rc_shift:
    rol att_r
    rol att_r+1
    dex
    bne rc_loop
    rts

qbuf:
    .fill 16, 0
head_off:
    .fill NH, i * HD
kc_layer_lo:
    .fill NL, <(KC + i * HD * NW)
kc_layer_hi:
    .fill NL, >(KC + i * HD * NW)
vrow_lo:
    .fill NL * NW, <(VC + i * HD)
vrow_hi:
    .fill NL * NW, >(VC + i * HD)


// =========================================================================
// Sampling: z' = z * TEMP_MUL >> 8, w = EXP[min(max - z', 255)], drop w < CUTOFF,
// then pick with r = rand * sum >> 16.  Returns token in A.
// =========================================================================

sample:
    // logits were requantized into ACC... see head: requant(RQ_INT8) is not used; logits in LOGL/LOGH
    lda #$00
    sta att_e
    lda #$80
    sta att_e+1
    ldx #0
sp_temp:
    phx
    lda LOGL,x
    sta ma
    lda LOGH,x
    sta ma+1
    lda #<TEMP_MUL
    sta mb
    lda #>TEMP_MUL
    sta mb+1
    lda #8
    sta mk
    jsr mulshift
    plx
    lda mr
    sta LOGL,x
    lda mr+1
    sta LOGH,x
    lda mr
    cmp att_e
    lda mr+1
    sbc att_e+1
    bvc !+
    eor #$80
!:  bmi !+
    lda mr
    sta att_e
    lda mr+1
    sta att_e+1
!:  inx
    bne sp_temp

    stz t0
    stz t1
    ldx #0
sp_exp:
    sec
    lda att_e
    sbc LOGL,x
    tay
    lda att_e+1
    sbc LOGH,x
    beq !+
    ldy #255
!:  lda exp_table,y
    cmp #CUTOFF
    bcs !+
    lda #0
!:  sta ET,x
    clc
    adc t0
    sta t0
    bcc !+
    inc t1
!:  inx
    bne sp_exp

    jsr rand
    lda rng
    sta ma
    lda rng+1
    sta ma+1
    lda t0
    sta mb
    lda t1
    sta mb+1
    jsr umul16                      // r = mr+2, mr+3
    stz t0
    stz t1
    ldx #0
sp_walk:
    lda ET,x
    clc
    adc t0
    sta t0
    bcc !+
    inc t1
!:  lda mr+2                        // cum > r ?
    cmp t0
    lda mr+3
    sbc t1
    bcc sp_done
    inx
    bne sp_walk
    dex
sp_done:
    txa
    rts

// xorshift16 (7, 9, 8)
rand:
    lda rng+1
    lsr
    lda rng
    ror
    eor rng+1
    sta rng+1
    ror
    eor rng
    sta rng
    eor rng+1
    sta rng+1
    rts


// =========================================================================
// Tokenizer: characters -> ids, then apply BPE merges in order
// PROMPT (null terminated) -> TOKBUF, t5 = count
// =========================================================================

tokenize:
    ldy #0
    stz t5
tk_char:
    lda PROMPT,y
    beq tk_merge
    ldx #NCHARS - 1
!:  cmp chars,x
    beq !+
    dex
    bne !-
    bra tk_skip                     // unknown character
!:  txa
    ldx t5
    sta TOKBUF,x
    inc t5
tk_skip:
    iny
    bra tk_char
tk_merge:
    stz t4                          // merge index
tk_rule:
    ldx #0
tk_scan:
    txa
    inc
    cmp t5
    bcs tk_next_rule
    ldy t4
    lda TOKBUF,x
    cmp PARAMS + PO.get("MERGE_A"),y
    bne tk_adv
    lda TOKBUF+1,x
    cmp PARAMS + PO.get("MERGE_B"),y
    bne tk_adv
    tya                             // merge: TOK[x] = NCHARS + rule, delete TOK[x+1]
    clc
    adc #NCHARS
    sta TOKBUF,x
    phx
!:  lda TOKBUF+2,x
    sta TOKBUF+1,x
    inx
    cpx t5
    bcc !-
    plx
    dec t5
tk_adv:
    inx
    bra tk_scan
tk_next_rule:
    inc t4
    lda t4
    cmp #NMERGE
    bne tk_rule
    lda t5
    sta ntok
    rts


// =========================================================================
// Text output with word wrap
// =========================================================================

// Print the characters of token A
print_token:
    cmp #NCHARS
    bcs !+
    tax
    lda chars,x
    jmp putc
!:  sec
    sbc #NCHARS
    tax
    lda PARAMS + PO.get("MERGE_B"),x
    pha
    lda PARAMS + PO.get("MERGE_A"),x
    jsr print_token
    pla
    jmp print_token

// ptr = VRAM + crow * 32 + ccol
cursor_ptr:
    lda crow
    lsr
    lsr
    lsr
    clc
    adc #>VRAM
    sta ptr+1
    lda crow
    asl
    asl
    asl
    asl
    asl
    ora ccol
    sta ptr
    rts

// Write A at the cursor without wrapping logic, advance
put_raw:
    pha
    jsr cursor_ptr
    pla
    phy
    ldy #0
    jsr vid_char
    ply
    inc ccol
    rts

// Store screen code for ASCII A at (ptr),y (like vid.write_ascii)
vid_char:
    cmp #$60
    bcc !+
    and #$1f
!:  sta (ptr),y
    rts

putc:
    phx
    phy
    cmp #10
    bne !+
    ldx ccol                        // a line break at the start of a line is already there
    beq pc_done
    jsr newline
    bra pc_done
!:  cmp #' '
    bne pc_char
    ldx ccol
    beq pc_done                     // no leading spaces
    cpx #32
    bne pc_char
    jsr newline                     // space at end of line becomes the break
    bra pc_done
pc_char:
    ldx ccol
    cpx #32
    bne pc_put
    pha
    jsr wrap_word
    pla
pc_put:
    jsr put_raw
pc_done:
    ply
    plx
    rts

newline:
    stz ccol
    inc crow
    lda crow
    cmp #16
    bcc !+
    jsr vid.shift_up_1_clear_bottom
    lda #15
    sta crow
!:  rts

// Line is full and a word continues: move the partial word to the next line
wrap_word:
    lda #0
    sta ccol
    jsr cursor_ptr
    ldy #31
!:  lda (ptr),y
    cmp #' '
    beq !+
    dey
    bne !-
    jmp newline                     // no space on the line: hard break
!:  iny
    cpy #32
    bne !+
    jmp newline                     // the line ends in a space: nothing to move
!:  ldx #0
!:  lda (ptr),y                     // copy word to WBUF, blank it
    sta WBUF,x
    lda #' '
    sta (ptr),y
    inx
    iny
    cpy #32
    bne !-
    stx t4
    jsr newline
    jsr cursor_ptr
    ldy #0
!:  lda WBUF,y
    sta (ptr),y
    iny
    cpy t4
    bne !-
    sty ccol
    rts

show_busy:
    lda ccol
    cmp #32
    beq !+
    jsr cursor_ptr
    lda #vid.CURSOR_ON
    sta (ptr)
!:  rts

clear_busy:
    lda ccol
    cmp #32
    beq !+
    jsr cursor_ptr
    lda #' '
    sta (ptr)
!:  rts


// =========================================================================
// Prompt input
// =========================================================================

#if !TEST
read_prompt:
    lda #'>'
    jsr put_raw
    lda #' '
    jsr put_raw
    stz t5                          // length
rp_loop:
    jsr show_busy
rp_wait:
    inc rng                         // seed from typing time
    bne !+
    inc rng+1
!:  jsr kb.get_press
    beq rp_wait
    cmp #kb.ASCII_ESC
    bne !+
    jmp exit
!:  cmp #kb.ASCII_NEWLINE
    beq rp_done
    cmp #kb.ASCII_BACKSPACE
    beq rp_back
    cmp #$80
    bcs rp_loop
    cmp #'A'
    bcc !+
    cmp #'Z' + 1
    bcs !+
    ora #$20                        // lower case
!:  cmp #' '
    bcc rp_loop
    ldx #NCHARS - 1                 // only characters the model knows
!:  cmp chars,x
    beq !+
    dex
    bne !-
    bra rp_loop
!:  ldx t5
    cpx #PROMPT_MAX
    bcs rp_loop
    sta PROMPT,x
    inc t5
    pha
    jsr clear_busy
    pla
    jsr putc
    bra rp_loop
rp_back:
    lda t5
    beq rp_loop
    dec t5
    jsr clear_busy
    lda ccol
    beq rp_loop
    dec ccol
    jsr cursor_ptr
    lda #' '
    sta (ptr)
    bra rp_loop
rp_done:
    jsr clear_busy
    ldx t5                          // drop trailing spaces
!:  beq !+
    lda PROMPT-1,x
    cmp #' '
    bne !+
    dex
    bra !-
!:  stz PROMPT,x
    stx t5
    lda rng                         // never seed with 0
    ora rng+1
    bne !+
    inc rng
!:  rts
#endif

wait_key:
    jsr kb.get_press
    beq wait_key
    rts


// =========================================================================
// Setup
// =========================================================================

// Quarter-square tables. f(n+1) = f(n) + ceil(n/2)
gen_squares:
    stz t0                          // f
    stz t1
    stz t2                          // n
    stz t3
    ldy #0
.for (var pg = 0; pg < 2; pg++) {
gs_loop:
    lda t0
    sta SQ1L + pg * 256,y
    lda t1
    sta SQ1H + pg * 256,y
    lda t2                          // (n + 1) >> 1
    clc
    adc #1
    sta t4
    lda t3
    adc #0
    lsr
    ror t4
    sta t5
    lda t0
    clc
    adc t4
    sta t0
    lda t1
    adc t5
    sta t1
    inc t2
    bne !+
    inc t3
!:  iny
    bne gs_loop
}
    // SQ2[n] = SQ1[|n - 255|]
    ldy #0
!:  tya
    eor #$ff
    tax
    lda SQ1L,x
    sta SQ2L,y
    lda SQ1H,x
    sta SQ2H,y
    lda SQ1L+1,y
    sta SQ2L+256,y
    lda SQ1H+1,y
    sta SQ2H+256,y
    iny
    bne !-
    rts

// Find the first sector of the weight file (data file whose data starts with "KGPT" and
// this model's id) and follow its links. Carry set if not found.
find_weights:
    ldx #0
fw_loop:
    stx SECREG
    lda $8000
    bne fw_next
    lda $8001
    cmp #$20
    bne fw_next
    ldy #7
!:  lda $8100,y
    cmp magic,y
    bne fw_next
    dey
    bpl !-
    ldy #0
fw_chain:
    txa
    sta SECLIST,y
    iny
    cpy #NSECTORS
    beq fw_found
    lda $8008
    cmp #64
    bcs fw_fail
    tax
    stx SECREG
    lda $8000
    bne fw_fail
    bra fw_chain
fw_found:
    clc
    rts
fw_next:
    inx
    cpx #64
    bne fw_loop
fw_fail:
    sec
    rts

magic:
    .text "KGPT"
    .fill 4, MODEL_ID.get(i)

// Copy the parameter blob to PARAMS, check magic and model id. Carry set on mismatch.
load_blob:
    stz wsec
    lda SECLIST
    sta SECREG
    lda #$00
    sta ptr
    lda #$81
    sta ptr+1
    lda #<PARAMS
    sta wp
    lda #>PARAMS
    sta wp+1
    lda #<BLOB_SIZE
    sta t0
    lda #>BLOB_SIZE
    sta t1
lb_loop:
    lda (ptr)
    sta (wp)
    inc wp
    bne !+
    inc wp+1
!:  inc ptr
    bne !+
    inc ptr+1
    lda ptr+1
    cmp #$90
    bne !+
    lda #$81
    sta ptr+1
    inc wsec
    ldx wsec
    lda SECLIST,x
    sta SECREG
!:  lda t0
    bne !+
    dec t1
!:  dec t0
    lda t0
    ora t1
    bne lb_loop
    ldx #7
!:  lda PARAMS,x
    cmp magic,x
    bne !+
    dex
    bpl !-
    clc
    rts
!:  sec
    rts

#import "tables.inc"

.assert "program fits below TOKBUF", * <= TOKBUF, true
