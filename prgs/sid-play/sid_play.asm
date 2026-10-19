/* =========================================================================
   SID PLAY
   Plays C64 .sid tunes saved on the SSD.

   Convert a tune on your computer with sid2kit.py, send it with
   pcb_serial_send.py, and save it to the SSD from the monitor. This
   program lists every converted tune on the SSD and plays it by running
   the tune's own 6502 code.

   Keys:  up/down pick   return play   left/right subtune
          space stop/start   esc quit

   Assemble:  ka -libdir ../../roms/video-mon sid_play.asm

   How it plays a tune:
     - Tunes live in $0300-$4fff; this program lives in $5000-$5fff.
     - sid2kit.py points the tune's I/O at shadow pages here, and turns
       each SID store into a call to sid_commit, which sends the register
       to the real SID straight away. Frequencies and envelope rates are
       corrected on the way, because the KiT clocks its SID at 1.8432 MHz
       and a C64 at about 1 MHz.
     - VIA timer 1 calls the tune at its own rate: 50 Hz, or whatever its
       CIA timer was set to (Wizball's main theme runs at 200 Hz).
     - Tunes use zero page freely. The KiT's part of zero page ($00-$2f:
       keyboard, video, interrupt vector) is swapped out around every call
       into the tune.
   ========================================================================= */

.cpu _65c02
.encoding "ascii"
.filenamespace sidplay

#define PCB
#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/kb.lib"

#import "video_mon.sym"


.label SID = $7e00
.label SHADOW_SID = $5d00                       // these addresses must match sid2kit.py
.label SHADOW_CIA = $5e00
.label SHADOW_IO = $5f00
.label COMMIT = $5003
.label SCREEN = $6000
.label T1_LATCH_LO = $7816
.label T1_LATCH_HI = $7817
.label SECTOR_REG = via.PORTD

// SSD sector window (KiT filesystem: header page, then up to 15 pages of data)
.label SSD = $8000
.label SSD_LOAD = $8002
.label SSD_SIZE = $8004
.label SSD_NEXT = $8008
.label FILE = $8100

// Song header, at the start of the file
.const H_MAGIC = 1
.const H_VERSION = 5
.const H_INIT = 10
.const H_PLAY = 12
.const H_SONGS = 14
.const H_START = 15
.const H_SPEED = 16
.const H_FREQ_MUL = 20
.const H_CIA_MUL = 21
.const H_VBI = 22
.const H_NAME = 24
.const H_AUTHOR = 56
.const H_RELEASED = 88
.const HDR_VERSION = 1

.const SWAP_END = $2f                           // zero page the KiT needs: $00-$2f
.const LATCH_60HZ = 1843200/60 - 2
.const CYCLES_PER_SEC = 1843200
.const CYCLES_PER_TICK = 1843200/50             // the display updates at 50 Hz

// Screen layout
.const LIST_TOP = 1
.const LIST_ROWS = 7
.const INFO_ROW = 9
.const TUNE_ROW = 13
.const VOICE_ROW = 14
.const VOICE_W = 11                             // "c#4 " and a 5-cell bar, plus a gap
.const LEVEL_MAX = 15

.label row_ptr = zp.D                           // two bytes
.label src_ptr = zp.B                           // two bytes
.label dst_ptr = zp.F                           // two bytes


// ASCII to 6847 screen code: letters show normal, inv sets inverse video
.function scr(c, inv) {
    .var v = c
    .if (c >= 'a' && c <= 'z') .eval v = c - $60
    .if (c >= 'A' && c <= 'Z') .eval v = c - $40
    .return inv ? v | $40 : v
}

// Draw a fixed string at row, col
.macro text_at(row, col, str, inv) {
    lda #<data
    sta src_ptr
    lda #>data
    sta src_ptr+1
    lda #row
    ldy #col
    jsr static_text
    bra done
data:
    .fill str.size(), scr(str.charAt(i), inv)
    .byte $ff
done:
}


.segment Code [outPrg="sid_play.prg", start=$5000]
    jmp start
    jmp sid_commit                                  // $5003: called by the tune for every SID store
.assert "sid_commit entry", * - 3, COMMIT

start:
    sei
    mov2 #irq : zp.irq_addr
    lda #(via.TIMER1_INT | via.TIMER2_INT)          // timers off until a tune plays
    sta via.IER
    lda via.ACR                                     // timer 1: continuous interrupts
    and #%00111111
    ora #via.T1_CONTINUOUS
    sta via.ACR
    lda #$ff
    sta via.DDD                                     // SSD sector register is an output
    cli

    stz vid.MODE_REG                                // text mode
    jsr silence
    stz playing
    lda #$ff
    sta loaded
    stz sel
    stz top
    jsr scan_songs
    jsr draw_screen

main_loop:
    jsr kb.get_press
    beq no_key
    jsr handle_key
no_key:
    lda loaded
    bmi main_loop
    jsr update_status
    bra main_loop


/* -------------------------------------------------------------------------
Keys
*/
key_ignore:
    rts

handle_key:
    cmp #kb.K_UP
    bne not_up
    lda sel
    beq key_ignore
    dec sel
    lda sel
    cmp top
    bcs list_changed
    sta top
    bra list_changed
not_up:

    cmp #kb.K_DOWN
    bne not_down
    lda sel
    inc
    cmp count
    bcs key_ignore
    sta sel
    sec
    sbc #LIST_ROWS - 1
    bcc list_changed
    cmp top
    bcc list_changed
    sta top
list_changed:
    jmp draw_list
not_down:

    cmp #kb.ASCII_NEWLINE
    bne not_enter
    lda count
    beq key_ignore
    jmp load_song
not_enter:

    ldx loaded
    bmi not_loaded_keys

    cmp #kb.K_LEFT
    bne not_left
    lda cur_song
    cmp #2
    bcc key_ignore
    dec cur_song
    jmp start_tune
not_left:

    cmp #kb.K_RIGHT
    bne not_right
    lda cur_song
    cmp songs
    bcs key_ignore
    inc cur_song
    jmp start_tune
not_right:

    cmp #' '
    bne not_space
    lda playing
    beq resume
    jsr stop
    jmp draw_voices
resume:
    jmp start_tune
not_space:

not_loaded_keys:
    cmp #kb.ASCII_ESC
    bne key_unused
    jsr stop
    lda #$ff                                        // hand timer 1 back to the cursor blink
    sta via.T1_LO
    sta via.T1_HI
    lda #(via.INT_ENABLE | via.TIMER1_INT)
    sta via.IER
    brk
    nop
key_unused:
    rts


/* -------------------------------------------------------------------------
Find songs on the SSD: sectors whose file starts with the sid2kit header
*/
scan_songs:
    stz count
    ldx #0
scan_loop:
    stx SECTOR_REG
    lda SSD                                         // 0 = sector holds a file
    bne scan_next
    lda FILE                                        // header starts with a BRK
    bne scan_next
    ldy #3
scan_magic:
    lda FILE+H_MAGIC,y
    cmp magic,y
    bne scan_next
    dey
    bpl scan_magic
    lda FILE+H_VERSION
    cmp #HDR_VERSION
    bne scan_next
    ldy count
    txa
    sta song_sector,y
    inc count
scan_next:
    inx
    cpx #64
    bne scan_loop
    rts

magic:  .text "KSID"


/* -------------------------------------------------------------------------
Load the selected song into RAM and play its default subtune
*/
load_song:
    jsr stop
    ldx sel
    stx loaded
    lda song_sector,x
    sta cur_sector
    sta SECTOR_REG

    mov2 FILE+H_INIT : init_addr
    mov2 FILE+H_PLAY : play_addr
    mov2 FILE+H_VBI : vbi_latch
    lda FILE+H_SONGS
    sta songs
    lda FILE+H_START
    sta cur_song
    lda FILE+H_FREQ_MUL
    sta freq_mul
    lda FILE+H_CIA_MUL
    sta cia_mul
    ldx #3
copy_speed:
    lda FILE+H_SPEED,x
    sta speed,x
    dex
    bpl copy_speed

    lda cur_sector                                  // copy the file, following its sectors
load_sector:
    sta SECTOR_REG
    mov2 #FILE : src_ptr
    mov2 SSD_LOAD : dst_ptr
    mov2 SSD_SIZE : bytes_left
    ldy #0
load_byte:
    lda bytes_left
    ora bytes_left+1
    beq load_done
    lda src_ptr+1
    cmp #>(SSD + $1000)
    bcs load_next_sector
    lda (src_ptr),y
    sta (dst_ptr),y
    inc src_ptr
    bne load_src_ok
    inc src_ptr+1
load_src_ok:
    inc dst_ptr
    bne load_dst_ok
    inc dst_ptr+1
load_dst_ok:
    dec2 bytes_left
    bra load_byte
load_next_sector:
    lda SSD_NEXT
    bra load_sector
load_done:

    jsr draw_list
    jsr draw_info
    jmp start_tune


/* -------------------------------------------------------------------------
Start subtune cur_song of the loaded tune
*/
start_tune:
    jsr stop

    ldx #0                                          // clear the shadow pages
    lda #0
clear_shadow:
    sta SHADOW_SID,x
    sta SHADOW_CIA,x
    sta SHADOW_IO,x
    inx
    bne clear_shadow
    ldx #SWAP_END
clear_tune_zp:
    stz tune_zp,x
    dex
    bpl clear_tune_zp
    ldx #$18
clear_committed:
    stz committed,x
    dex
    bpl clear_committed

    ldx #2
reset_voice:
    lda #1                                          // frequency 1 scales to 0, so the cache starts valid
    sta freq_in_lo,x
    stz freq_in_hi,x
    stz freq_out_lo,x
    stz freq_out_hi,x
    stz last_gate,x
    stz level,x
    stz level_hit,x
    lda #$ff
    sta shown_note,x
    dex
    bpl reset_voice
    stz minutes
    stz seconds
    stz time_acc
    stz time_acc+1
    stz time_acc+2
    stz tick_acc
    stz tick_acc+1
    stz tick_acc+2
    lda #$ff
    sta shown_seconds

    lda via.IER                                     // no interrupts while the tune initialises,
    sta saved_ier                                   // in case it turns them back on
    lda #$7f
    sta via.IER
    jsr swap_zp
    lda cur_song
    dec
    ldx #0
    ldy #0
    jsr call_init
    cld
    jsr swap_zp
    jsr flush
    lda saved_ier
    ora #via.INT_ENABLE
    sta via.IER

    lda cur_song                                    // which timer? bit n-1 of speed (bit 31 for 32+)
    dec
    cmp #31
    bcc speed_bit
    lda #31
speed_bit:
    tax
    and #7
    tay
    txa
    lsr
    lsr
    lsr
    tax
    lda speed,x
speed_shift:
    dey
    bmi speed_test
    lsr
    bra speed_shift
speed_test:
    and #1
    sta cia_mode
    beq use_vbi
    mov2 SHADOW_CIA+4 : last_cia
    jsr cia_latch
    bra set_timer
use_vbi:
    mov2 vbi_latch : latch
set_timer:
    lda latch
    sta via.T1_LO
    lda latch+1
    sta via.T1_HI                                   // starts timer 1
    lda #1
    sta playing
    lda #(via.INT_ENABLE | via.TIMER1_INT)
    sta via.IER
    jmp draw_tune


stop:
    lda #via.TIMER1_INT
    sta via.IER
    stz playing
    // fall through
silence:
    lda #0
.for (var r = 0; r <= $18; r++) {
    sta SID + r                                     // absolute stores only: the KiT's SID misses
}                                                   // the dummy read of an indexed store
    rts


call_init:
    jmp (init_addr)
call_play:
    jmp (play_addr)


/* -------------------------------------------------------------------------
Timer 1 latch for the tune's CIA timer value in last_cia:
cia * KiT clock / C64 clock = cia + cia * cia_mul / 256
*/
cia_latch:
    lda last_cia
    ora last_cia+1
    bne cia_scale
    mov2 #LATCH_60HZ : latch                        // timer never set: 60 Hz
    rts
cia_scale:
    mov2 last_cia : mul_in
    lda cia_mul
    jsr mul16x8
    clc
    lda last_cia
    adc mul_out
    sta latch
    lda last_cia+1
    adc mul_out+1
    sta latch+1
    bcc cia_latch_done
    lda #$ff                                        // too slow for the VIA: clamp
    sta latch
    sta latch+1
cia_latch_done:
    rts


/* -------------------------------------------------------------------------
mul_out = mul_in * A / 256
*/
mul16x8:
    sta mul_m
    stz mul_lo
    lda #0
    ldx #8
mul_loop:
    lsr mul_m
    bcc mul_shift
    tay
    clc
    lda mul_lo
    adc mul_in
    sta mul_lo
    tya
    adc mul_in+1
mul_shift:
    ror
    ror mul_lo
    dex
    bne mul_loop
    sta mul_out+1
    lda mul_lo
    sta mul_out
    rts


/* -------------------------------------------------------------------------
Swap the KiT's zero page with the tune's copy
*/
swap_zp:
    ldx #SWAP_END
swap_loop:
    lda $00,x
    ldy tune_zp,x
    sta tune_zp,x
    sty $00,x
    dex
    bpl swap_loop
    rts


/* -------------------------------------------------------------------------
Send shadow SID register Y to the real SID. Called by the tune (through
code sid2kit.py adds) right after it stores to the register, so the SID
sees every write in the tune's own order. Uses A, X, Y.
*/
sid_commit:
    tya
    and #$1f
    cmp #$19
    bcs commit_none
    asl
    tax
    jmp (commit_table,x)
commit_none:
    rts

commit: .for (var r = 0; r < $19; r++) {             // one handler per SID register
    .var v = floor(r / 7)
    .var b = v * 7
    .var off = r - b
handler:
    .if (r >= $15) {
        lda SHADOW_SID+r
        sta committed+r
        sta SID+r
        rts
    } else .if (off == 0) {                         // frequency: scale both bytes
        ldx #v
        jsr scale_freq
        lda freq_out_lo+v
        sta SID+b
        lda freq_out_hi+v
        sta SID+b+1
        rts
    } else .if (off == 4) {                         // control: also watch the gate for the display
        lda SHADOW_SID+r
        sta committed+r
        sta SID+r
        and #1
        cmp last_gate+v
        beq gate_same
        sta last_gate+v
        cmp #0
        beq gate_same
        sta level_hit+v
    gate_same:
        rts
    } else .if (off == 5) {                         // attack/decay: slow the rates down
        lda SHADOW_SID+r
        sta committed+r
        jsr map_ad
        sta SID+r
        rts
    } else .if (off == 6) {                         // sustain/release
        lda SHADOW_SID+r
        sta committed+r
        jsr map_sr
        sta SID+r
        rts
    } else .if (off != 1) {
        lda SHADOW_SID+r
        sta committed+r
        sta SID+r
        rts
    }
}

commit_table:
.for (var r = 0; r < $19; r++) {
    .var off = r - floor(r / 7) * 7
    .if (r < $15 && off == 1) {
        .word commit[r - 1].handler                 // frequency high byte: same as low
    } else {
        .word commit[r].handler
    }
}


// Scale voice X's shadow frequency for the KiT's SID clock into freq_out
scale_freq:
    ldy voice_reg,x
    lda SHADOW_SID,y
    sta committed,y
    lda SHADOW_SID+1,y
    sta committed+1,y
    lda SHADOW_SID,y
    cmp freq_in_lo,x
    bne freq_changed
    lda SHADOW_SID+1,y
    cmp freq_in_hi,x
    beq freq_same
freq_changed:
    lda SHADOW_SID,y
    sta freq_in_lo,x
    sta mul_in
    lda SHADOW_SID+1,y
    sta freq_in_hi,x
    sta mul_in+1
    phx
    lda freq_mul
    jsr mul16x8
    plx
    lda mul_out
    sta freq_out_lo,x
    lda mul_out+1
    sta freq_out_hi,x
freq_same:
    rts


// Envelope rates run 1.87x faster on the KiT's SID: swap each attack, decay,
// and release nibble for the setting closest to the C64 timing
map_ad:
    tay
    and #$0f
    tax
    lda rate_map,x
    sta adsr_tmp
    tya
    lsr
    lsr
    lsr
    lsr
    tax
    lda rate_map,x
    asl
    asl
    asl
    asl
    ora adsr_tmp
    rts

map_sr:
    tay
    and #$f0
    sta adsr_tmp
    tya
    and #$0f
    tax
    lda rate_map,x
    ora adsr_tmp
    rts


// Send any shadow registers the tune changed without going through sid_commit
flush:
    ldx #$18
flush_loop:
    lda SHADOW_SID,x
    cmp committed,x
    beq flush_next
    phx
    txa
    tay
    jsr sid_commit
    plx
flush_next:
    dex
    bpl flush_loop
    rts


/* -------------------------------------------------------------------------
Interrupts: keyboard and the music timer
*/
irq:
    phx
    tsx
    pha
    inx
    inx
    lda $100,x                                      // check the stacked flags for brk
    and #$10
    beq no_break
    jmp break
no_break:
    phy

    lda via.IFR
    and #via.CA1_INT
    beq no_kb_irq
    handle_kb_irq()
no_kb_irq:

    lda via.IFR
    and #via.TIMER1_INT
    beq no_timer_irq
    lda via.T1_LO                                   // clear the interrupt
    lda playing
    beq no_timer_irq
    jsr music_tick
no_timer_irq:

    ply
    pla
    plx
    rti


music_tick:
    lda #via.CA1_INT                                // keep the keyboard out while the tune
    sta via.IER                                     // owns zero page
    jsr swap_zp
    jsr call_play
    cld
    jsr swap_zp
    lda #(via.INT_ENABLE | via.CA1_INT)
    sta via.IER
    jsr flush

    lda cia_mode                                    // follow tempo changes
    beq tick_time
    lda SHADOW_CIA+4
    cmp last_cia
    bne cia_changed
    lda SHADOW_CIA+5
    cmp last_cia+1
    beq tick_time
cia_changed:
    mov2 SHADOW_CIA+4 : last_cia
    jsr cia_latch
    lda latch
    sta T1_LATCH_LO
    lda latch+1
    sta T1_LATCH_HI

tick_time:
    clc                                             // count elapsed time in KiT clock cycles
    lda time_acc
    adc latch
    sta time_acc
    lda time_acc+1
    adc latch+1
    sta time_acc+1
    lda time_acc+2
    adc #0
    sta time_acc+2
    sec
    lda time_acc
    sbc #<CYCLES_PER_SEC
    tax
    lda time_acc+1
    sbc #>CYCLES_PER_SEC
    tay
    lda time_acc+2
    sbc #(CYCLES_PER_SEC >> 16)
    bcc tick_display
    sta time_acc+2
    sty time_acc+1
    stx time_acc
    inc seconds
    lda seconds
    cmp #60
    bcc tick_display
    stz seconds
    inc minutes

tick_display:
    clc
    lda tick_acc
    adc latch
    sta tick_acc
    lda tick_acc+1
    adc latch+1
    sta tick_acc+1
    lda tick_acc+2
    adc #0
    sta tick_acc+2
tick_display_loop:
    sec
    lda tick_acc+1
    sbc #>CYCLES_PER_TICK
    tay
    lda tick_acc+2
    sbc #0
    bcc tick_done
    sta tick_acc+2
    sty tick_acc+1
    inc disp_tick
    bra tick_display_loop
tick_done:
    rts


/* -------------------------------------------------------------------------
Display
*/
draw_screen:
    jsr vid.blank_screen
    lda #0
    jsr set_row
    ldy #31
    lda #scr(' ', true)
title_fill:
    sta (row_ptr),y
    dey
    bpl title_fill
    text_at(0, 1, "sid play", true)

    lda #0                                          // "n songs" at the right
    jsr set_row
    ldy #25
    lda count
    cmp #10
    bcc count_col
    dey
count_col:
    jsr print_dec
    lda #0
    jsr set_row
    ldy #22
invert_count:
    lda (row_ptr),y
    ora #$40
    sta (row_ptr),y
    iny
    cpy #26
    bne invert_count
    lda count
    cmp #1
    bne songs_plural
    text_at(0, 27, "song", true)
    bra songs_label_done
songs_plural:
    text_at(0, 27, "songs", true)
songs_label_done:

    lda #INFO_ROW-1
    jsr set_row
    ldy #31
    lda #'-'
separator:
    sta (row_ptr),y
    dey
    bpl separator
    text_at(15, 0, "ret play  <> tune  spc stop  esc", false)
    jsr draw_list
    jmp draw_info


draw_list:
    lda count
    beq list_empty
    jmp list_rows
list_empty:
    text_at(LIST_TOP+1, 1, "no songs on the ssd", false)
    text_at(LIST_TOP+3, 1, "convert one with sid2kit.py,", false)
    text_at(LIST_TOP+4, 1, "send it, and save it from", false)
    text_at(LIST_TOP+5, 1, "the monitor", false)
    rts
list_rows:
    stz list_row
list_row_loop:
    lda list_row
    clc
    adc #LIST_TOP
    jsr set_row
    lda list_row
    clc
    adc top
    sta list_idx
    cmp count
    bcc list_entry
    ldy #31                                         // past the end of the list
    lda #' '
clear_list_row:
    sta (row_ptr),y
    dey
    bpl clear_list_row
    bra list_next

list_entry:
    stz inv_mask
    cmp sel
    bne not_selected
    lda #$40
    sta inv_mask
not_selected:
    ldx list_idx
    lda song_sector,x
    sta SECTOR_REG
    lda #' '
    cpx loaded
    bne not_loaded
    lda #'*'
not_loaded:
    ora inv_mask
    ldy #0
    sta (row_ptr),y
    iny
    ldx #H_NAME
    jsr flash_text

list_next:
    inc list_row
    lda list_row
    cmp #LIST_ROWS
    bne list_row_loop
    rts


draw_info:
    stz inv_mask
    lda loaded
    bmi info_done
    lda cur_sector
    sta SECTOR_REG
    lda #INFO_ROW
    jsr set_row
    ldy #0
    ldx #H_NAME
    jsr flash_text
    lda #INFO_ROW+1
    jsr set_row
    ldy #0
    ldx #H_AUTHOR
    jsr flash_text
    lda #INFO_ROW+2
    jsr set_row
    ldy #0
    ldx #H_RELEASED
    jsr flash_text
info_done:
    rts


draw_tune:
    lda #TUNE_ROW
    jsr set_row
    ldy #31
    lda #' '
clear_tune:
    sta (row_ptr),y
    dey
    bpl clear_tune
    text_at(TUNE_ROW, 0, "tune", false)
    ldy #5
    lda cur_song
    jsr print_dec
    lda #'/'
    sta (row_ptr),y
    iny
    lda songs
    jsr print_dec
    lda #$ff
    sta shown_seconds
    jmp draw_voices


update_status:
    lda playing
    beq status_done
    lda seconds                                     // time
    cmp shown_seconds
    beq time_same
    sta shown_seconds
    lda #TUNE_ROW
    jsr set_row
    ldy #27
    lda minutes
    cmp #10
    bcs minutes_wide
    lda #' '
    sta (row_ptr),y
    iny
    lda minutes
minutes_wide:
    jsr print_dec
    lda #':'
    sta (row_ptr),y
    iny
    lda seconds
    jsr print_2dig
time_same:
    lda disp_tick                                   // voices, at 50 Hz
    cmp shown_tick
    beq status_done
    sta shown_tick
    jsr update_levels
    jmp draw_voices
status_done:
    rts


// Rough envelope for each voice: jump to full when a note starts, fall to the
// sustain level while the gate is on, and to zero after it's released
update_levels:
    ldx #2
level_voice:
    jsr voice_note
    sta cur_note
    ldy voice_reg,x
    lda SHADOW_SID+4,y
    and #$f0                                        // no waveform: silent
    beq level_zero
    lda level_hit,x
    bne level_full
    lda last_gate,x
    beq level_target_zero
    lda cur_note                                    // a new note while the gate is held
    cmp shown_note,x
    bne level_full
    lda SHADOW_SID+6,y
    lsr
    lsr
    lsr
    lsr
    bra level_toward
level_target_zero:
    lda #0
level_toward:
    cmp level,x
    bcs level_set                                   // at or above the target: jump there
    dec level,x
    bra level_done
level_full:
    stz level_hit,x
    lda #LEVEL_MAX
    bra level_set
level_zero:
    lda #0
level_set:
    sta level,x
level_done:
    lda cur_note
    sta shown_note,x
    dex
    bpl level_voice
    rts


// Note number (0-95) nearest voice X's frequency, in A (keeps X)
voice_note:
    lda freq_out_lo,x
    sta note_freq
    lda freq_out_hi,x
    sta note_freq+1
    ldy #0
note_search:
    lda note_freq
    cmp note_mid_lo,y
    lda note_freq+1
    sbc note_mid_hi,y
    bcc note_found
    iny
    cpy #95
    bne note_search
note_found:
    tya
    rts


draw_voices:
    lda #VOICE_ROW
    jsr set_row
    ldx #0
    ldy #0
draw_voice:
    lda playing
    beq voice_blank
    lda level,x
    beq voice_blank
    phy                                             // note name, like "c#4"
    lda shown_note,x
    ldy #'0'
octave_loop:
    cmp #12
    bcc octave_done
    sbc #12
    iny
    bra octave_loop
octave_done:
    sty octave_char
    tay
    lda note_letter,y
    sta letter_char
    lda note_sharp,y
    ply
    pha
    lda letter_char
    sta (row_ptr),y
    iny
    pla
    sta (row_ptr),y
    iny
    lda octave_char
    sta (row_ptr),y
    iny
    bra voice_bar
voice_blank:
    lda #'-'
    sta (row_ptr),y
    iny
    sta (row_ptr),y
    iny
    sta (row_ptr),y
    iny
    stz level,x
voice_bar:
    iny
    phy
    ldy level,x
    lda level_halves,y
    ply
    sta bar_half_cells
    lda #5
    sta bar_cells_left
bar_cell:
    lda bar_half_cells
    cmp #2
    bcs bar_full_cell
    cmp #1
    beq bar_part_cell
    lda #$80
    bra bar_put
bar_full_cell:
    sbc #2
    sta bar_half_cells
    lda bar_full,x
    bra bar_put
bar_part_cell:
    stz bar_half_cells
    lda bar_half,x
bar_put:
    sta (row_ptr),y
    iny
    dec bar_cells_left
    bne bar_cell
    iny
    iny
    inx
    cpx #3
    beq voices_done
    jmp draw_voice
voices_done:
    rts


// Copy a header string from the SSD window (offset X) to the row at column Y,
// padding to the end of the row
flash_text:
    stz text_ended
flash_text_loop:
    lda text_ended
    bne flash_text_pad
    lda FILE,x
    bne flash_text_char
    inc text_ended
flash_text_pad:
    lda #' '
    bra flash_text_put
flash_text_char:
    jsr to_screen
flash_text_put:
    ora inv_mask
    sta (row_ptr),y
    inx
    iny
    cpy #32
    bne flash_text_loop
    rts


// ASCII in A to a screen code
to_screen:
    cmp #$20
    bcc not_printable
    cmp #$7f
    bcs not_printable
    cmp #$40
    bcc printable
    and #$1f
printable:
    rts
not_printable:
    lda #' '
    rts


// Draw screen codes from src_ptr ($ff ends) on row A from column Y
static_text:
    jsr set_row
static_loop:
    lda (src_ptr)
    cmp #$ff
    beq static_done
    sta (row_ptr),y
    iny
    inc src_ptr
    bne static_loop
    inc src_ptr+1
    bra static_loop
static_done:
    rts


// Point row_ptr at screen row A (keeps Y)
set_row:
    tax
    lda row_lo,x
    sta row_ptr
    lda row_hi,x
    sta row_ptr+1
    rts


// Draw A in decimal at column Y without leading zeros; Y moves past it
print_dec:
    ldx #0
    stx digits_shown
hundreds:
    cmp #100
    bcc hundreds_done
    sbc #100
    inx
    bra hundreds
hundreds_done:
    jsr put_digit_if
    ldx #0
tens:
    cmp #10
    bcc tens_done
    sbc #10
    inx
    bra tens
tens_done:
    jsr put_digit_if
    tax
    inc digits_shown
    jmp put_digit_if

// Draw A (0-99) as two digits at column Y
print_2dig:
    ldx #0
tens2:
    cmp #10
    bcc tens2_done
    sbc #10
    inx
    bra tens2
tens2_done:
    pha
    txa
    ora #'0'
    sta (row_ptr),y
    iny
    pla
    ora #'0'
    sta (row_ptr),y
    iny
    rts

// Draw digit X at column Y unless it's a leading zero (keeps A)
put_digit_if:
    pha
    txa
    ora digits_shown
    beq skip_digit
    txa
    ora #'0'
    sta (row_ptr),y
    iny
    sta digits_shown
skip_digit:
    pla
    rts


/* -------------------------------------------------------------------------
Tables
*/
row_lo:         .fill 16, <(SCREEN + i*32)
row_hi:         .fill 16, >(SCREEN + i*32)
voice_reg:      .byte 0, 7, 14
bar_full:       .byte $bf, $8f, $ff                 // red, green, orange
bar_half:       .byte $ba, $8a, $fa
level_halves:   .fill LEVEL_MAX + 1, round(i * 10 / LEVEL_MAX)

// KiT SID frequency halfway between note i and note i+1 (C0 = 0)
.function kit_freq(n) { .return 440 * pow(2, (n - 57) / 12) * 16777216 / 1843200 }
note_mid_lo:    .fill 95, <round(kit_freq(i + 0.5))
note_mid_hi:    .fill 95, >round(kit_freq(i + 0.5))
note_letter:    .fill 12, scr("ccddeffggaab".charAt(i), false)
note_sharp:     .text "-#-#--#-#-#-"

.var adsr_ms = List().add(2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000)
.function slower(n) {
    .var target = log(adsr_ms.get(n) * 1843200 / 985248)
    .var best = 0
    .for (var w = 1; w < 16; w++) {
        .if (abs(log(adsr_ms.get(w)) - target) < abs(log(adsr_ms.get(best)) - target)) .eval best = w
    }
    .return best
}
rate_map:       .fill 16, slower(i)
.print "envelope rate map: " + List().add(slower(0),slower(1),slower(2),slower(3),slower(4),slower(5),slower(6),slower(7),slower(8),slower(9),slower(10),slower(11),slower(12),slower(13),slower(14),slower(15))

code_end:


/* -------------------------------------------------------------------------
Variables
*/
.segment Variables [start=code_end, virtual]
playing:        .byte 0
loaded:         .byte 0                             // list index of the loaded song, $ff = none
count:          .byte 0
sel:            .byte 0
top:            .byte 0
song_sector:    .fill 64, 0

cur_sector:     .byte 0
cur_song:       .byte 0
songs:          .byte 0
init_addr:      .word 0
play_addr:      .word 0
speed:          .fill 4, 0
freq_mul:       .byte 0
cia_mul:        .byte 0
vbi_latch:      .word 0
bytes_left:     .word 0

cia_mode:       .byte 0
last_cia:       .word 0
latch:          .word 0
saved_ier:      .byte 0
tune_zp:        .fill SWAP_END + 1, 0
committed:      .fill $19, 0                        // last value sent to each SID register

mul_in:         .word 0
mul_out:        .word 0
mul_m:          .byte 0
mul_lo:         .byte 0

freq_in_lo:     .fill 3, 0
freq_in_hi:     .fill 3, 0
freq_out_lo:    .fill 3, 0
freq_out_hi:    .fill 3, 0
last_gate:      .fill 3, 0
level_hit:      .fill 3, 0
level:          .fill 3, 0
shown_note:     .fill 3, 0

time_acc:       .fill 3, 0
tick_acc:       .fill 3, 0
minutes:        .byte 0
seconds:        .byte 0
shown_seconds:  .byte 0
disp_tick:      .byte 0
shown_tick:     .byte 0

list_row:       .byte 0
list_idx:       .byte 0
inv_mask:       .byte 0
text_ended:     .byte 0
digits_shown:   .byte 0
cur_note:       .byte 0
note_freq:      .word 0
letter_char:    .byte 0
octave_char:    .byte 0
bar_half_cells: .byte 0
adsr_tmp:       .byte 0
bar_cells_left: .byte 0
vars_end:

.assert "player fits below the shadow pages", vars_end <= SHADOW_SID, true
