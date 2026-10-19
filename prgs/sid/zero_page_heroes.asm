/* =========================================================================
   ZERO PAGE HEROES
   An original SID tune for the KiT 6502

   E minor, 125 BPM, 50 Hz player, about 100 seconds before it loops.

     power on     fades in through a slowly opening filter: soft arpeggio
                  chords and a held bass, then the bass starts galloping,
                  voice 3 (hard-synced to it) sweeps upward, and a drum
                  fill and bass walk-up lead into the theme
     zero page    main theme: PWM lead with delayed vibrato and glides,
                  plucky filtered saw bass, drums interleaved with arps
     stack climb  pumping PWM bass with filter wah, busier drums, tom fill
     ring bells   breakdown: ring-modulated bells over a slowly
                  opening resonant pad
     sync rise    climbing sequence on a brassy hard-sync lead that grows
                  out of the breakdown through an opening filter, with
                  bass and drums sharing voice 2
     heroes       theme again with a sawtooth lead
     stack climb  ...then back to the main theme

   Assemble:  ka -libdir ../../roms/video-mon zero_page_heroes.asm
   Press any key to stop and return to the monitor.
   ========================================================================= */

.cpu _65c02
.encoding "ascii"
.filenamespace zph

#define PCB
#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/kb.lib"

#import "video_mon.sym"


.label SID = $7e00
.label SID_FILT_LO = SID + $15
.label SID_FILT_HI = SID + $16
.label SID_RES_FILT = SID + $17
.label SID_MODE_VOL = SID + $18

.const TIMER_HI = $90                           // $9000 cycles at 1.8432 MHz = 50 Hz
.const SPEED = 6                                // frames per row (one row = a 16th note)
.const FADE_END = 240                           // fade in over 240 frames (volume 0 to 15)

// zero page scratch (general-purpose zp registers)
.label ptr = zp.B                               // two bytes: current pattern
.label optr = zp.D                              // two bytes: current order list
.label tmp = zp.F
.label tmp2 = zp.G
.label vp = zp.H                                // two bytes: video pointer for the display


// ---------------------------------------------------------------- notes
.enum {
    C0, Cs0, D0, Ds0, E0, F0, Fs0, G0, Gs0, A0, As0, B0,
    C1, Cs1, D1, Ds1, E1, F1, Fs1, G1, Gs1, A1, As1, B1,
    C2, Cs2, D2, Ds2, E2, F2, Fs2, G2, Gs2, A2, As2, B2,
    C3, Cs3, D3, Ds3, E3, F3, Fs3, G3, Gs3, A3, As3, B3,
    C4, Cs4, D4, Ds4, E4, F4, Fs4, G4, Gs4, A4, As4, B4,
    C5, Cs5, D5, Ds5, E5, F5, Fs5, G5, Gs5, A5, As5, B5,
    C6, Cs6, D6, Ds6, E6, F6, Fs6, G6, Gs6, A6, As6, B6,
    C7, Cs7, D7, Ds7, E7, F7, Fs7, G7, Gs7, A7, As7, B7
}


// ---------------------------------------------------------------- pattern commands
// $00-$5f  note (plus the voice's transpose), plays for the current duration
.const REST  = $60                              // gate off for the current duration
.const GLIDE = $61                              // GLIDE, speed: next note slides in without retriggering
.const PEND  = $ff                              // end of pattern
.function DUR(rows) { .return $80 + rows }      // set duration for following notes (1-63 rows)
.function INS(i)    { .return $c0 + i }         // set instrument for following notes

// ---------------------------------------------------------------- order list commands
// $00-$7f  play pattern
.const SEC   = $fc                              // SEC, n: section marker (shown on screen)
.const OINS  = $fd                              // OINS, i: set instrument
.const OLOOP = $fe                              // OLOOP, pos: jump to position in this order list
.function TR(n) { .return $a0 + n }             // transpose following patterns by n semitones (-32..31)


// ---------------------------------------------------------------- wavetable
// One entry per frame: waveform (without gate), note.
// Note $00-$7f is relative to the played note, $80+n is absolute note n.
// Waveform 0 keeps the previous waveform. WT_JMP jumps to the index in the note byte.
.const TRI = $10
.const SAW = $20
.const PUL = $40
.const NOI = $80
.const RING = $04
.const SYNC = $02
.const WT_STOP = $fe
.const WT_JMP = $ff
.function ABS(n) { .return $80 + n }

.var wtw = List()
.var wtn = List()
.function wt(w, n) {
    .eval wtw.add(w)
    .eval wtn.add(n)
    .return wtw.size() - 1
}

.var WT_PULSE = wt(PUL, 0)
.eval wt(WT_STOP, 0)
.var WT_SAW = wt(SAW, 0)
.eval wt(WT_STOP, 0)
.var WT_TRI = wt(TRI, 0)
.eval wt(WT_STOP, 0)
.var WT_BELL = wt(TRI | RING, 0)
.eval wt(WT_STOP, 0)
.var WT_SYNC = wt(SAW | SYNC, 0)
.eval wt(WT_STOP, 0)

.var WT_SYNCLEAD = wt(SAW | SYNC, 5)            // slave sweeps up above its master: "yow"
.eval wt(0, 7)
.eval wt(0, 9)
.eval wt(0, 12)
.eval wt(0, 14)
.eval wt(0, 16)
.eval wt(0, 19)
.eval wt(WT_STOP, 0)

.var WT_MINOR = wt(PUL, 0)
.eval wt(0, 3)
.eval wt(0, 7)
.eval wt(WT_JMP, WT_MINOR)

.var WT_MAJOR = wt(PUL, 0)
.eval wt(0, 4)
.eval wt(0, 7)
.eval wt(WT_JMP, WT_MAJOR)

.var WT_KICK = wt(NOI, ABS(D7))                 // click, then a fast pitch drop
.eval wt(PUL, ABS(A4))
.eval wt(0, ABS(D4))
.eval wt(0, ABS(A3))
.eval wt(0, ABS(E3))
.eval wt(0, ABS(B2))
.eval wt(0, ABS(G2))
.eval wt(0, ABS(E2))
.eval wt(WT_STOP, 0)

.var WT_SNARE = wt(PUL, ABS(C5))                // body, then a falling noise burst
.eval wt(NOI, ABS(C7))
.eval wt(0, ABS(A6))
.eval wt(0, ABS(Fs6))
.eval wt(0, ABS(E6))
.eval wt(0, ABS(D6))
.eval wt(WT_STOP, 0)

.var WT_HAT = wt(NOI, ABS(B7))
.eval wt(WT_STOP, 0)

.var WT_CRASH = wt(NOI, ABS(A7))
.eval wt(0, ABS(Fs7))
.eval wt(WT_STOP, 0)

.var WT_TOM = wt(NOI, 19)                       // relative, so toms follow the pattern notes
.eval wt(PUL, 12)
.eval wt(0, 8)
.eval wt(0, 5)
.eval wt(0, 3)
.eval wt(0, 1)
.eval wt(0, 0)
.eval wt(WT_STOP, 0)


// ---------------------------------------------------------------- filter settings
// start: cutoff hi byte when a note starts ($ff keeps the current cutoff)
// delta: signed cutoff change per frame, in 1/16ths of the hi byte
// end:   cutoff where the sweep stops
.struct Filt {start, delta, end, res, mode}
.const LP = $10
.const BP = $20
.const HP = $40

.var filts = List()
.function filt(f) {
    .eval filts.add(f)
    .return filts.size() - 1
}
.eval filt(Filt(0, 0, 0, 0, 0))                 // 0 = not filtered
.var F_PLUCK  = filt(Filt($50, -$60, $14, $c0, LP))
.var F_PAD    = filt(Filt($08,  $03, $78, $e0, LP))
.var F_PADC   = filt(Filt($ff,  $03, $78, $e0, LP))
.var F_WAH    = filt(Filt($18,  $50, $68, $d0, LP))
.var F_INTRO  = filt(Filt($ff,  $02, $78, $90, LP))
.var F_LEADIN = filt(Filt($0c,  $03, $58, $60, LP))
.var F_LEAD   = filt(Filt($ff,  $03, $58, $60, LP))


// ---------------------------------------------------------------- instruments
// pw: starting pulse width hi byte, pwspd: pulse width change per frame,
// bouncing between pwmin and pwmax (hi bytes).
// vdel: frames before vibrato, vshift: depth (freq >> vshift per frame, 0 = off),
// vq: quarter period of vibrato in frames. gate 0 = silent modulator voice.
.struct Inst {ad, sr, wt, pw, pwspd, pwmin, pwmax, vdel, vshift, vq, filt, gate}

.var insts = List()
.function inst(i) {
    .eval insts.add(i)
    .return insts.size() - 1
}
//                          ad   sr   wt         pw   pwspd min  max  vdel vsh vq filt     gate
.var I_LEAD   = inst(Inst($0a, $b9, WT_PULSE, $06, $30, $03, $0d, 18,  7,  2, 0,       1))
.var I_BASS   = inst(Inst($07, $a7, WT_SAW,   $08, $00, $00, $00, 0,   0,  0, F_PLUCK, 1))
.var I_ARPMIN = inst(Inst($00, $a6, WT_MINOR, $04, $40, $02, $0c, 0,   0,  0, 0,       1))
.var I_ARPMAJ = inst(Inst($00, $a6, WT_MAJOR, $04, $40, $02, $0c, 0,   0,  0, 0,       1))
.var I_KICK   = inst(Inst($08, $00, WT_KICK,  $08, $00, $00, $00, 0,   0,  0, 0,       1))
.var I_SNARE  = inst(Inst($09, $00, WT_SNARE, $08, $00, $00, $00, 0,   0,  0, 0,       1))
.var I_HAT    = inst(Inst($04, $00, WT_HAT,   $08, $00, $00, $00, 0,   0,  0, 0,       1))
.var I_TOM    = inst(Inst($09, $00, WT_TOM,   $08, $00, $00, $00, 0,   0,  0, 0,       1))
.var I_BELL   = inst(Inst($0b, $5b, WT_BELL,  $08, $00, $00, $00, 0,   0,  0, 0,       1))
.var I_RMOD   = inst(Inst($00, $00, WT_TRI,   $08, $00, $00, $00, 0,   0,  0, 0,       0))
.var I_SYNCL  = inst(Inst($09, $a9, WT_SYNCLEAD, $08, $00, $00, $00, 0, 0,  0, F_LEAD,  1))
.var I_SYNCL_IN = inst(Inst($09, $a9, WT_SYNCLEAD, $08, $00, $00, $00, 0, 0, 0, F_LEADIN, 1))
.var I_SYNCM  = inst(Inst($00, $00, WT_TRI,   $08, $00, $00, $00, 18,  7,  2, 0,       0))
.var I_PAD    = inst(Inst($a8, $c9, WT_PULSE, $04, $18, $02, $0e, 0,   0,  0, F_PAD,   1))
.var I_PADC   = inst(Inst($a8, $c9, WT_PULSE, $04, $18, $02, $0e, 0,   0,  0, F_PADC,  1))
.var I_BASS2  = inst(Inst($08, $a7, WT_PULSE, $08, $60, $02, $0e, 0,   0,  0, F_WAH,   1))
.var I_CRASH  = inst(Inst($0b, $00, WT_CRASH, $08, $00, $00, $00, 0,   0,  0, 0,       1))
.var I_LEAD2  = inst(Inst($0a, $b9, WT_SAW,   $08, $00, $00, $00, 12,  7,  2, 0,       1))
.var I_BASSIN = inst(Inst($07, $a7, WT_SAW,   $08, $00, $00, $00, 0,   0,  0, F_INTRO, 1))
.var I_BASSB  = inst(Inst($08, $a8, WT_PULSE, $06, $20, $04, $0a, 0,   0,  0, 0,       1))
.var I_ARPMIN_IN = inst(Inst($a6, $b9, WT_MINOR, $04, $20, $02, $0c, 0, 0, 0, F_INTRO, 1))
.var I_ARPMAJ_IN = inst(Inst($a6, $b9, WT_MAJOR, $04, $20, $02, $0c, 0, 0, 0, F_INTRO, 1))
.var I_RISER_IN  = inst(Inst($d0, $c4, WT_SYNC,  $08, $00, $00, $00, 0, 0, 0, F_INTRO, 1))


// ---------------------------------------------------------------- display
.const METER_MAX = 44                           // half-blocks in a level meter
.const BAR_COL = 8
.const BAR_W = 22
.const VOICE_ROW = 5                            // voice 1 row; voices are 2 rows apart
.const SECTION_ROW = 12
.const SECTION_COL = 13

// ASCII to 6847 screen code (lower case shows normal, upper case inverse)
.function scr(c) {
    .if (c >= 'a' && c <= 'z') .return c - $60
    .return c
}


.segment Code [outPrg="zero_page_heroes.prg", start=$1000]
start:
    sei
    jsr init_player
    jsr draw_screen

    mov2 #irq : zp.irq_addr
    lda #(via.INT_ENABLE | via.TIMER2_INT)          // enable timer 2 interrupts
    sta via.IER
    stz via.T2_LO
    lda #TIMER_HI
    sta via.T2_HI
    cli

flush_keys:
    jsr kb.get_press
    bne flush_keys

main_loop:
    lda frame_flag
    beq main_loop
    stz frame_flag
    jsr play_frame
    jsr update_display
    jsr kb.get_press
    beq main_loop

    sei
    lda #via.TIMER2_INT                             // disable timer 2 interrupts
    sta via.IER
    cli
    jsr silence
    brk


/* -------------------------------------------------------------------------
Reset the SID and all player state, and fetch the first note of each voice
*/
init_player:
    jsr silence

    ldx #2
init_voice:
    stz ord_pos,x
    stz transpose,x
    stz inst,x
    stz cur_inst,x
    stz note,x
    stz gate,x
    stz wave,x
    stz wt_on,x
    stz glide_spd,x
    stz pend_glide,x
    stz vib_step_lo,x
    stz vib_step_hi,x
    stz vib_off_lo,x
    stz vib_off_hi,x
    stz vib_delay,x
    stz freq_lo,x
    stz freq_hi,x
    stz pw_lo,x
    stz pw_hi,x
    stz sh_ad,x
    stz sh_sr,x
    stz meter,x
    lda #1
    sta dur,x
    sta rows_left,x
    jsr next_pattern
    jsr fetch
    dex
    bpl init_voice

    stz tick
    stz frame_flag
    stz filt_lo
    lda #$0c
    sta filt_hi
    stz filt_dlo
    stz filt_dhi
    stz filt_end
    stz filt_res
    stz filt_route
    lda #LP
    sta filt_mode
    stz fade
    lda #$ff
    sta last_section
    rts


silence:
    lda #0
.for (var r = 0; r <= $18; r++) {
    sta SID + r
}
    rts


/* -------------------------------------------------------------------------
Advance one frame (called at 50 Hz)
*/
play_frame:
    ldx #0
voice_loop:
    lda tick
    bne not_row_start
    dec rows_left,x                                 // new row: count down the current note
    bne effects
    jsr trigger                                     // note is over, start the pending one
    bra effects

not_row_start:
    cmp #SPEED-1
    bne effects
    lda rows_left,x                                 // last frame of the note?
    cmp #1
    bne effects
    jsr fetch                                       // read ahead to the next note
    lda pend_type,x
    bne effects                                     // rests don't need a hard restart
    lda pend_glide,x
    bne effects                                     // neither do glides
    stz gate,x                                      // hard restart: gate off, ADSR to zero
    stz sh_ad,x                                     // so the next attack is crisp
    stz sh_sr,x

effects:
    jsr voice_effects
    inx
    cpx #3
    bne voice_loop

    jsr write_sid
    jsr filter_update

    inc tick
    lda tick
    cmp #SPEED
    bcc play_frame_done
    stz tick
play_frame_done:
    rts


/* -------------------------------------------------------------------------
Load the next pattern for voice X from its order list
*/
next_pattern:
    lda ord_tab_lo,x
    sta optr
    lda ord_tab_hi,x
    sta optr+1
np_loop:
    ldy ord_pos,x
    lda (optr),y
    inc ord_pos,x

    cmp #OLOOP
    bne np_not_loop
    iny
    lda (optr),y
    sta ord_pos,x
    bra np_loop
np_not_loop:

    cmp #OINS
    bne np_not_ins
    iny
    lda (optr),y
    sta inst,x
    inc ord_pos,x
    bra np_loop
np_not_ins:

    cmp #SEC
    bne np_not_sec
    iny
    lda (optr),y
    sta section,x
    inc ord_pos,x
    bra np_loop
np_not_sec:

    cmp #$80
    bcc np_pattern
    sec
    sbc #$a0
    sta transpose,x
    bra np_loop

np_pattern:
    tay
    lda pat_tab_lo,y
    sta pat_lo,x
    sta ptr
    lda pat_tab_hi,y
    sta pat_hi,x
    sta ptr+1
    stz pat_pos,x
    rts


/* -------------------------------------------------------------------------
Read voice X's pattern up to the next note or rest, and store it as pending
*/
fetch:
    lda pat_lo,x
    sta ptr
    lda pat_hi,x
    sta ptr+1
fetch_loop:
    ldy pat_pos,x
    lda (ptr),y
    inc pat_pos,x

    cmp #PEND
    bne fetch_not_end
    jsr next_pattern
    bra fetch_loop
fetch_not_end:

    cmp #$c0
    bcc fetch_not_ins
    and #$3f
    sta inst,x
    bra fetch_loop
fetch_not_ins:

    cmp #$80
    bcc fetch_not_dur
    and #$3f
    sta dur,x
    bra fetch_loop
fetch_not_dur:

    cmp #GLIDE
    bne fetch_not_glide
    iny
    lda (ptr),y
    sta pend_glide,x
    inc pat_pos,x
    bra fetch_loop
fetch_not_glide:

    cmp #REST
    bne fetch_note
    lda #1
    sta pend_type,x
    bra fetch_done

fetch_note:
    clc
    adc transpose,x
    sta pend_note,x
    stz pend_type,x

fetch_done:
    lda dur,x
    sta pend_dur,x
    lda inst,x
    sta pend_inst,x
    rts


/* -------------------------------------------------------------------------
Start voice X's pending note or rest
*/
trigger:
    lda pend_dur,x
    sta rows_left,x
    lda pend_type,x
    beq trigger_note
    stz gate,x                                      // rest: release
    rts

trigger_note:
    lda pend_note,x
    sta note,x
    lda pend_glide,x
    beq trigger_new
    sta glide_spd,x                                 // glide: keep the envelope, slide to the new note
    stz pend_glide,x
    ldy note,x
    lda note_lo,y
    sta glide_tgt_lo,x
    lda note_hi,y
    sta glide_tgt_hi,x
    rts

trigger_new:
    stz glide_spd,x
    lda pend_inst,x
    sta cur_inst,x
    tay

    lda inst_ad,y
    sta sh_ad,x
    lda inst_sr,y
    sta sh_sr,x
    lda inst_wt,y
    sta wt_pos,x
    lda #1
    sta wt_on,x
    stz pw_lo,x
    lda inst_pw,y
    sta pw_hi,x
    stz pw_dir,x
    lda inst_gate,y
    sta gate,x
    beq no_meter
    lda #METER_MAX
    sta meter,x
no_meter:

    lda inst_vdel,y                                 // vibrato
    sta vib_delay,x
    lda inst_vq,y
    sta vib_cnt,x
    stz vib_dir,x
    stz vib_off_lo,x
    stz vib_off_hi,x
    stz vib_step_lo,x
    stz vib_step_hi,x
    lda inst_vshift,y
    beq trigger_filter
    sta tmp
    ldy note,x                                      // vibrato step = note frequency >> vshift
    lda note_hi,y
    sta tmp2
    lda note_lo,y
vib_shift:
    lsr tmp2
    ror
    dec tmp
    bne vib_shift
    sta vib_step_lo,x
    lda tmp2
    sta vib_step_hi,x

trigger_filter:
    ldy cur_inst,x
    lda inst_filt,y
    bne filter_on
    lda voice_bit,x                                 // unfiltered: take this voice off the filter
    eor #$ff
    and filt_route
    sta filt_route
    rts

filter_on:
    tay
    lda voice_bit,x
    ora filt_route
    sta filt_route
    lda flt_start,y
    cmp #$ff
    beq keep_cutoff
    sta filt_hi
    stz filt_lo
keep_cutoff:
    lda flt_delta,y                                 // delta << 4, sign extended to 16 bits
    asl
    asl
    asl
    asl
    sta filt_dlo
    lda flt_delta,y
    cmp #$80
    ror
    cmp #$80
    ror
    cmp #$80
    ror
    cmp #$80
    ror
    sta filt_dhi
    lda flt_end,y
    sta filt_end
    lda flt_res,y
    sta filt_res
    lda flt_mode,y
    sta filt_mode
    rts


/* -------------------------------------------------------------------------
Run voice X's wavetable, glide, vibrato, and pulse width modulation,
then write its SID registers
*/
voice_effects:
    lda wt_on,x
    beq wt_done
    ldy wt_pos,x
wt_read:
    lda wt_wave,y
    cmp #WT_JMP
    bne wt_not_jmp
    lda wt_note,y
    tay
    bra wt_read
wt_not_jmp:
    cmp #WT_STOP
    bne wt_step
    stz wt_on,x
    bra wt_done
wt_step:
    cmp #0
    beq wt_keep_wave
    sta wave,x
wt_keep_wave:
    lda wt_note,y
    bmi wt_absolute
    clc
    adc note,x
    bra wt_set_freq
wt_absolute:
    and #$7f
wt_set_freq:
    phy
    tay
    lda note_lo,y
    sta freq_lo,x
    lda note_hi,y
    sta freq_hi,x
    ply
    iny
    tya
    sta wt_pos,x
wt_done:

    lda glide_spd,x
    beq glide_done
    lda freq_lo,x                                   // carry set if freq >= target
    cmp glide_tgt_lo,x
    lda freq_hi,x
    sbc glide_tgt_hi,x
    bcs glide_down
    clc
    lda freq_lo,x
    adc glide_spd,x
    sta freq_lo,x
    lda freq_hi,x
    adc #0
    sta freq_hi,x
    bcs glide_snap
    lda freq_lo,x
    cmp glide_tgt_lo,x
    lda freq_hi,x
    sbc glide_tgt_hi,x
    bcc glide_done
    bra glide_snap
glide_down:
    sec
    lda freq_lo,x
    sbc glide_spd,x
    sta freq_lo,x
    lda freq_hi,x
    sbc #0
    sta freq_hi,x
    bcc glide_snap
    lda freq_lo,x
    cmp glide_tgt_lo,x
    lda freq_hi,x
    sbc glide_tgt_hi,x
    bcs glide_done
glide_snap:
    lda glide_tgt_lo,x
    sta freq_lo,x
    lda glide_tgt_hi,x
    sta freq_hi,x
    stz glide_spd,x
glide_done:

    lda vib_delay,x
    beq vib_run
    dec vib_delay,x
    bra vib_done
vib_run:
    lda vib_step_lo,x
    ora vib_step_hi,x
    beq vib_done
    lda vib_dir,x
    bne vib_down
    clc
    lda vib_off_lo,x
    adc vib_step_lo,x
    sta vib_off_lo,x
    lda vib_off_hi,x
    adc vib_step_hi,x
    sta vib_off_hi,x
    bra vib_count
vib_down:
    sec
    lda vib_off_lo,x
    sbc vib_step_lo,x
    sta vib_off_lo,x
    lda vib_off_hi,x
    sbc vib_step_hi,x
    sta vib_off_hi,x
vib_count:
    dec vib_cnt,x
    bne vib_done
    ldy cur_inst,x
    lda inst_vq,y                                   // full swing is twice the quarter period
    asl
    sta vib_cnt,x
    lda vib_dir,x
    eor #1
    sta vib_dir,x
vib_done:

    ldy cur_inst,x
    lda inst_pwspd,y
    beq pw_done
    sta tmp
    lda pw_dir,x
    bne pw_down
    clc
    lda pw_lo,x
    adc tmp
    sta pw_lo,x
    lda pw_hi,x
    adc #0
    sta pw_hi,x
    cmp inst_pwmax,y
    bcc pw_done
    lda #1
    sta pw_dir,x
    bra pw_done
pw_down:
    sec
    lda pw_lo,x
    sbc tmp
    sta pw_lo,x
    lda pw_hi,x
    sbc #0
    sta pw_hi,x
    cmp inst_pwmin,y
    bcs pw_done
    stz pw_dir,x
pw_done:

    lda gate,x                                      // level meter falls to the sustain level
    beq meter_floor_zero
    lda inst_floor,y
    bra meter_fall
meter_floor_zero:
    lda #0
meter_fall:
    sta tmp
    sec
    lda meter,x
    sbc #2
    bcc meter_to_floor
    cmp tmp
    bcs meter_store
meter_to_floor:
    lda tmp
    cmp meter,x
    bcs meter_done
meter_store:
    sta meter,x
meter_done:
    rts


/* -------------------------------------------------------------------------
Write all three voices to the SID. Only absolute stores here: indexed
stores do a dummy read of the SID right before the write, and the KiT's
SID drops those writes.
*/
write_sid:
.for (var v = 0; v < 3; v++) {
    clc
    lda freq_lo + v
    adc vib_off_lo + v
    sta SID + v*7 + 0
    lda freq_hi + v
    adc vib_off_hi + v
    sta SID + v*7 + 1
    lda pw_lo + v
    sta SID + v*7 + 2
    lda pw_hi + v
    sta SID + v*7 + 3
    lda sh_ad + v
    sta SID + v*7 + 5
    lda sh_sr + v
    sta SID + v*7 + 6
    lda wave + v
    ora gate + v
    sta SID + v*7 + 4
}
    rts


/* -------------------------------------------------------------------------
Sweep the filter cutoff and write the global filter registers
*/
filter_update:
    lda filt_dlo
    ora filt_dhi
    beq filter_write
    clc
    lda filt_lo
    adc filt_dlo
    sta filt_lo
    lda filt_hi
    adc filt_dhi
    sta filt_hi
    bit filt_dhi
    bmi filter_falling
    bcs filter_clamp
    cmp filt_end
    bcc filter_write
    bra filter_clamp
filter_falling:
    bcc filter_clamp
    cmp filt_end
    bcs filter_write
filter_clamp:
    lda filt_end
    sta filt_hi
    stz filt_lo
    stz filt_dlo
    stz filt_dhi
filter_write:
    lda filt_lo
    lsr
    lsr
    lsr
    lsr
    lsr
    sta SID_FILT_LO
    lda filt_hi
    sta SID_FILT_HI
    lda filt_res
    ora filt_route
    sta SID_RES_FILT
    lda fade                                        // fade in: volume = fade / 16
    cmp #FADE_END
    bcs fade_done
    inc fade
fade_done:
    lsr
    lsr
    lsr
    lsr
    ora filt_mode
    sta SID_MODE_VOL
    rts


/* -------------------------------------------------------------------------
Display
*/
draw_screen:
    jsr vid.blank_screen
    set_vid_ptr(1, 8)
    vid_write_string("ZERO PAGE HEROES")
    set_vid_ptr(2, 6)
    vid_write_string("a sid tune for the kit")
    set_vid_ptr(VOICE_ROW, 1)
    vid_write_string("1")
    set_vid_ptr(VOICE_ROW + 2, 1)
    vid_write_string("2")
    set_vid_ptr(VOICE_ROW + 4, 1)
    vid_write_string("3")
    set_vid_ptr(SECTION_ROW, 3)
    vid_write_string("section:")
    set_vid_ptr(14, 4)
    vid_write_string("press any key to stop")
    rts


update_display:
    ldx #0
draw_voice_loop:
    jsr draw_voice
    inx
    cpx #3
    bne draw_voice_loop

    lda section
    cmp last_section
    beq update_display_done
    sta last_section
    asl
    asl
    asl
    asl
    tay
    ldx #0
draw_section_loop:
    lda section_names,y
    sta vid.VRAM_START + SECTION_ROW*32 + SECTION_COL,x
    iny
    inx
    cpx #16
    bne draw_section_loop
update_display_done:
    rts


draw_voice:
    lda voice_row_lo,x
    sta vp
    lda voice_row_hi,x
    sta vp+1

    lda meter,x
    bne draw_note
    lda #'-'
    ldy #3
    sta (vp),y
    iny
    sta (vp),y
    iny
    sta (vp),y
    bra draw_bar

draw_note:
    lda note,x
    ldy #0
octave_loop:
    cmp #12
    bcc octave_done
    sbc #12
    iny
    bra octave_loop
octave_done:
    phy
    tay
    lda note_name1,y
    sta tmp
    lda note_name2,y
    ldy #4
    sta (vp),y
    lda tmp
    dey
    sta (vp),y
    pla
    ora #'0'
    ldy #5
    sta (vp),y

draw_bar:
    lda meter,x
    lsr
    sta tmp                                         // full cells
    lda #0
    rol
    sta tmp2                                        // half cell
    lda tmp
    clc
    adc #BAR_COL
    sta tmp
    ldy #BAR_COL
bar_full_loop:
    cpy tmp
    bcs bar_full_done
    lda bar_full,x
    sta (vp),y
    iny
    bra bar_full_loop
bar_full_done:
    lda tmp2
    beq bar_empty_loop
    lda bar_half,x
    sta (vp),y
    iny
bar_empty_loop:
    cpy #BAR_COL + BAR_W
    bcs bar_done
    lda #$80
    sta (vp),y
    iny
    bra bar_empty_loop
bar_done:
    rts


/* -------------------------------------------------------------------------
Interrupts: keyboard, cursor timer, and the 50 Hz music timer
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
    ror                                             // CA2
    ror                                             // CA1
    bcc no_ca1_irq
    handle_kb_irq()
no_ca1_irq:
    ror                                             // shift register
    ror                                             // CB2
    ror                                             // CB1
    ror                                             // timer 2
    bcc no_timer2_irq
    stz via.T2_LO
    ldx #TIMER_HI
    stx via.T2_HI
    inc frame_flag
no_timer2_irq:
    ror                                             // timer 1
    bcc no_timer1_irq
    handle_cursor_timer_irq()
no_timer1_irq:

    ply
    pla
    plx
    rti


/* -------------------------------------------------------------------------
Tables
*/
voice_bit:      .byte 1, 2, 4
voice_row_lo:   .fill 3, <(vid.VRAM_START + (VOICE_ROW + i*2)*32)
voice_row_hi:   .fill 3, >(vid.VRAM_START + (VOICE_ROW + i*2)*32)
bar_full:       .byte $bf, $8f, $ff                 // red, green, orange blocks
bar_half:       .byte $ba, $8a, $fa

note_name1:     .fill 12, scr("ccddeffggaab".charAt(i))
note_name2:     .fill 12, scr("-#-#--#-#-#-".charAt(i))

.var sections = List().add("power on", "zero page", "stack climb", "ring bells", "sync rise", "heroes")
section_names:
.for (var s = 0; s < sections.size(); s++) {
    .var name = sections.get(s)
    .fill 16, i < name.size() ? scr(name.charAt(i)) : ' '
}

// Frequencies for C0-B7 with A4 = 440 Hz and the SID clocked at 1.8432 MHz
note_lo:        .fill 96, <round(440 * pow(2, (i - 57) / 12) * 16777216 / 1843200)
note_hi:        .fill 96, >round(440 * pow(2, (i - 57) / 12) * 16777216 / 1843200)

wt_wave:        .fill wtw.size(), wtw.get(i)
wt_note:        .fill wtn.size(), wtn.get(i)

flt_start:      .fill filts.size(), filts.get(i).start
flt_delta:      .fill filts.size(), filts.get(i).delta & $ff
flt_end:        .fill filts.size(), filts.get(i).end
flt_res:        .fill filts.size(), filts.get(i).res
flt_mode:       .fill filts.size(), filts.get(i).mode

inst_ad:        .fill insts.size(), insts.get(i).ad
inst_sr:        .fill insts.size(), insts.get(i).sr
inst_wt:        .fill insts.size(), insts.get(i).wt
inst_pw:        .fill insts.size(), insts.get(i).pw
inst_pwspd:     .fill insts.size(), insts.get(i).pwspd
inst_pwmin:     .fill insts.size(), insts.get(i).pwmin
inst_pwmax:     .fill insts.size(), insts.get(i).pwmax
inst_vdel:      .fill insts.size(), insts.get(i).vdel
inst_vshift:    .fill insts.size(), insts.get(i).vshift
inst_vq:        .fill insts.size(), insts.get(i).vq
inst_filt:      .fill insts.size(), insts.get(i).filt
inst_gate:      .fill insts.size(), insts.get(i).gate
inst_floor:     .fill insts.size(), min(METER_MAX, (insts.get(i).sr >> 4) * 3)


/* =========================================================================
   SONG
   ========================================================================= */

.enum {
    P_INTRO, P_RISE3, P_BA, P_BB, P_MA1, P_MA2, P_MB1, P_MB2, P_BK1, P_BK2,
    P_PAD, P_BRIDGE, P_BD, P_BD_FILL,
    P_DA_MIN, P_DA_MAJ, P_DA_MIN_CR, P_DB_MIN, P_DB_MAJ, P_DB_MIN_CR, P_FILL,
    P_PEDAL, P_REST4, P_INTRO2, P_BA_RUN, P_BR_HEAD, P_BD_SOFT
}

pat_tab_lo:
    .byte <pat_intro, <pat_rise3, <pat_ba, <pat_bb, <pat_ma1, <pat_ma2, <pat_mb1, <pat_mb2, <pat_bk1, <pat_bk2
    .byte <pat_pad, <pat_bridge, <pat_bd, <pat_bd_fill
    .byte <pat_da_min, <pat_da_maj, <pat_da_min_cr, <pat_db_min, <pat_db_maj, <pat_db_min_cr, <pat_fill
    .byte <pat_pedal, <pat_rest4, <pat_intro2, <pat_ba_run, <pat_br_head, <pat_bd_soft
pat_tab_hi:
    .byte >pat_intro, >pat_rise3, >pat_ba, >pat_bb, >pat_ma1, >pat_ma2, >pat_mb1, >pat_mb2, >pat_bk1, >pat_bk2
    .byte >pat_pad, >pat_bridge, >pat_bd, >pat_bd_fill
    .byte >pat_da_min, >pat_da_maj, >pat_da_min_cr, >pat_db_min, >pat_db_maj, >pat_db_min_cr, >pat_fill
    .byte >pat_pedal, >pat_rest4, >pat_intro2, >pat_ba_run, >pat_br_head, >pat_bd_soft

ord_tab_lo:     .byte <ord1, <ord2, <ord3
ord_tab_hi:     .byte >ord1, >ord2, >ord3


// ---------------------------------------------------------------- voice 1: lead
ord1:
    .byte SEC, 0, TR(0), P_INTRO, P_INTRO2, P_FILL
ord1_loop:
    .byte SEC, 1, TR(0), OINS, I_LEAD, P_MA1, P_MA2
    .byte SEC, 2, P_MB1, P_MB2
    .byte SEC, 3, OINS, I_BELL, TR(-12), P_BK1, P_BK2
    .byte SEC, 4, OINS, I_SYNCL_IN, TR(0), P_BR_HEAD          // synced to voice 3
    .byte OINS, I_SYNCL, P_BRIDGE
    .byte SEC, 5, OINS, I_LEAD2, P_MA1, P_MA2
    .byte SEC, 2, OINS, I_LEAD, P_MB1, P_MB2
    .byte OLOOP, ord1_loop - ord1

// ---------------------------------------------------------------- voice 2: bass
ord2:
    .byte SEC, 0, OINS, I_BASSIN, TR(0), P_PEDAL
    .byte P_BA, TR(-4), P_BA, TR(-2), P_BA, TR(0), P_BA_RUN
ord2_loop:
    .byte SEC, 1, OINS, I_BASS
    .byte TR(0), P_BA, TR(-4), P_BA, TR(3), P_BA, TR(-2), P_BA
    .byte TR(0), P_BA, TR(-4), P_BA, TR(5), P_BA, TR(-5), P_BA
    .byte SEC, 2, OINS, I_BASS2
    .byte TR(-4), P_BB, TR(-2), P_BB, TR(3), P_BB, TR(0), P_BB
    .byte TR(-4), P_BB, TR(-2), P_BB, TR(-5), P_BB, P_BB
    .byte SEC, 3, TR(0), P_PAD
    .byte SEC, 4, TR(0), P_BD_SOFT, TR(3), P_BD_SOFT, TR(5), P_BD, TR(2), P_BD_FILL
    .byte SEC, 5, OINS, I_BASS
    .byte TR(0), P_BA, TR(-4), P_BA, TR(3), P_BA, TR(-2), P_BA
    .byte TR(0), P_BA, TR(-4), P_BA, TR(5), P_BA, TR(-5), P_BA
    .byte SEC, 2, OINS, I_BASS2
    .byte TR(-4), P_BB, TR(-2), P_BB, TR(3), P_BB, TR(0), P_BB
    .byte TR(-4), P_BB, TR(-2), P_BB, TR(-5), P_BB, P_BB
    .byte OLOOP, ord2_loop - ord2

// ---------------------------------------------------------------- voice 3: drums, arps, sync, ring mod
ord3:
    .byte SEC, 0, TR(0), P_REST4, P_RISE3
ord3_loop:
    .byte SEC, 1
    .byte TR(0), P_DA_MIN_CR, TR(-4), P_DA_MAJ, TR(3), P_DA_MAJ, TR(-2), P_DA_MAJ
    .byte TR(0), P_DA_MIN, TR(-4), P_DA_MAJ, TR(5), P_DA_MIN, TR(-5), P_DA_MAJ
    .byte SEC, 2
    .byte TR(-4), P_DB_MAJ, TR(-2), P_DB_MAJ, TR(3), P_DB_MAJ, TR(0), P_DB_MIN
    .byte TR(-4), P_DB_MAJ, TR(-2), P_DB_MAJ, TR(-5), P_DB_MAJ, TR(0), P_FILL
    .byte SEC, 3, OINS, I_RMOD, TR(7), P_BK1, P_BK2           // ring modulator: bells +19 semitones
    .byte SEC, 4, OINS, I_SYNCM, TR(0), P_BR_HEAD, P_BRIDGE   // silent sync master: sets the lead's pitch
    .byte SEC, 5
    .byte TR(0), P_DB_MIN_CR, TR(-4), P_DB_MAJ, TR(3), P_DB_MAJ, TR(-2), P_DB_MAJ
    .byte TR(0), P_DB_MIN, TR(-4), P_DB_MAJ, TR(5), P_DB_MIN, TR(-5), P_DB_MAJ
    .byte SEC, 2
    .byte TR(-4), P_DB_MAJ, TR(-2), P_DB_MAJ, TR(3), P_DB_MAJ, TR(0), P_DB_MIN
    .byte TR(-4), P_DB_MAJ, TR(-2), P_DB_MAJ, TR(-5), P_DB_MAJ, TR(0), P_FILL
    .byte OLOOP, ord3_loop - ord3


// ---------------------------------------------------------------- patterns (one bar = 16 rows)

// intro: one held arpeggio chord per bar, soft attack, filtered  (Em C D B)
pat_intro:
    .byte INS(I_ARPMIN_IN), DUR(16), E4, INS(I_ARPMAJ_IN), C4, D4, B3, PEND

// intro bars 5-7; bar 8 is the drum fill  (Em C D)
pat_intro2:
    .byte INS(I_ARPMIN_IN), DUR(16), E4, INS(I_ARPMAJ_IN), C4, D4, PEND

// intro bar 8: bass gallop on B, then a walk up B D# F# A B into the theme
pat_ba_run:
    .byte DUR(2), B1, DUR(1), B2, B1, DUR(2), B1, B2
    .byte DUR(1), B1, B1, DUR(2), Ds2, Fs2, DUR(1), A2, B2
    .byte PEND

// intro: held bass roots under the first four bars
pat_pedal:
    .byte DUR(16), E2, C2, D2, B1, PEND

// four bars of silence
pat_rest4:
    .byte DUR(32), REST, REST, PEND

// intro: voice 3 hard-synced to the bass, sweeping up four bars
pat_rise3:
    .byte INS(I_RISER_IN), DUR(1), E3, GLIDE, 20, DUR(63), B5, PEND

// sync lead: played by voice 1 and its master, voice 3, at once  (Am C D B)
// The first note sets the lead's filter dark; the rest sweep it open.
pat_br_head:
    .byte DUR(2), A3, PEND
pat_bridge:
    .byte DUR(2), E3, A3, B3, DUR(6), C4, DUR(2), B3
    .byte DUR(2), C4, G3, C4, D4, DUR(6), E4, DUR(2), D4
    .byte DUR(2), D4, A3, D4, E4, DUR(6), Fs4, DUR(2), E4
    .byte DUR(2), Ds4, Fs4, A4, DUR(10), B4
    .byte PEND

// bass and drums on one voice; the bass follows the transpose
pat_bd_soft:
    .byte INS(I_KICK), DUR(1), C4, INS(I_BASSB), DUR(7), A1
    .byte INS(I_KICK), DUR(1), C4, INS(I_BASSB), DUR(5), A1, DUR(2), E2
    .byte PEND

pat_bd:
    .byte INS(I_KICK), DUR(1), C4, INS(I_BASSB), A1, DUR(2), A2
    .byte INS(I_SNARE), DUR(1), C4, INS(I_BASSB), A1, DUR(2), A2
    .byte INS(I_KICK), DUR(1), C4, INS(I_BASSB), A1, INS(I_KICK), C4, INS(I_BASSB), A2
    .byte INS(I_SNARE), DUR(2), C4, INS(I_BASSB), DUR(1), E2, A2
    .byte PEND

pat_bd_fill:
    .byte INS(I_KICK), DUR(1), C4, INS(I_BASSB), A1, DUR(2), A2
    .byte INS(I_SNARE), DUR(1), C4, INS(I_BASSB), A1, DUR(2), A2
    .byte INS(I_SNARE), DUR(1), C4, C4, INS(I_TOM), A4, A4, E4, E4, INS(I_SNARE), C4, C4
    .byte PEND

// bass, main theme
pat_ba:
    .byte DUR(2), E2, DUR(1), E3, E2, DUR(2), E2, E3, E2, DUR(1), E3, E2, DUR(2), B2, E3, PEND

// bass, pumping octaves
pat_bb:
    .byte DUR(2), E2, E3, DUR(1), E2, E2, DUR(2), E3, E2, E3, B2, E3, PEND

// main theme  (Em C G D | Em C Am B)
pat_ma1:
    .byte DUR(4), E5, DUR(2), B4, E5, DUR(4), G5, DUR(2), Fs5, G5
    .byte DUR(6), A5, DUR(2), G5, DUR(4), E5, C5
    .byte DUR(4), D5, DUR(2), G5, B5, GLIDE, $c0, DUR(6), D6, DUR(2), B5
    .byte DUR(6), A5, DUR(2), G5, DUR(4), Fs5, D5
    .byte PEND
pat_ma2:
    .byte DUR(4), E5, DUR(2), B4, E5, DUR(4), G5, DUR(2), Fs5, G5
    .byte DUR(6), A5, DUR(2), B5, DUR(4), C6, DUR(2), B5, A5
    .byte GLIDE, $ff, DUR(4), E6, C6, B5, DUR(2), A5, G5
    .byte DUR(8), Fs5, DUR(2), A5, G5, Fs5, Ds5
    .byte PEND

// lift  (C D G Em | C D B B)
pat_mb1:
    .byte DUR(4), G5, E5, DUR(6), C6, DUR(2), B5
    .byte DUR(6), A5, DUR(2), Fs5, DUR(4), D5, A5
    .byte DUR(4), G5, B5, DUR(8), D6
    .byte GLIDE, $60, DUR(12), E6, DUR(2), D6, B5
    .byte PEND
pat_mb2:
    .byte DUR(4), C6, B5, G5, E5
    .byte DUR(4), Fs5, A5, DUR(6), D6, DUR(2), C6
    .byte DUR(8), B5, DUR(4), A5, Fs5
    .byte DUR(4), Ds5, Fs5, B5, Ds6
    .byte PEND

// ring bells  (Am Em C D | Am Em C B)
pat_bk1:
    .byte DUR(6), A5, DUR(2), B5, DUR(8), C6
    .byte DUR(6), B5, DUR(2), G5, DUR(8), E5
    .byte DUR(4), E5, G5, DUR(6), C6, DUR(2), B5
    .byte DUR(12), A5, DUR(4), Fs5
    .byte PEND
pat_bk2:
    .byte DUR(6), A5, DUR(2), B5, DUR(6), C6, DUR(2), D6
    .byte DUR(8), E6, DUR(4), D6, B5
    .byte DUR(6), C6, DUR(2), B5, DUR(4), A5, G5
    .byte DUR(8), Fs5, DUR(4), B5, Ds6
    .byte PEND

// breakdown pad: the first note resets the filter, the rest keep sweeping it open
pat_pad:
    .byte INS(I_PAD), DUR(16), A2, INS(I_PADC), E2, C2, D2, A2, E2, C2, B1, PEND

// drums with arpeggios between the hits; the arp chord follows the transpose
.macro drums_a(arp, crash) {
    .if (crash) {
        .byte INS(I_CRASH), DUR(4), C4
    } else {
        .byte INS(I_KICK), DUR(1), C4, INS(arp), DUR(3), E4
    }
    .byte INS(I_SNARE), DUR(1), C4, INS(arp), DUR(3), E4
    .byte INS(I_KICK), DUR(1), C4, INS(arp), E4, INS(I_KICK), C4, INS(arp), E4
    .byte INS(I_SNARE), C4, INS(arp), DUR(3), E4
    .byte PEND
}

.macro drums_b(arp, crash) {
    .if (crash) {
        .byte INS(I_CRASH), DUR(2), C4
    } else {
        .byte INS(I_KICK), DUR(1), C4, INS(arp), E4
    }
    .byte INS(I_HAT), DUR(1), C4, INS(arp), E4, INS(I_SNARE), C4, INS(arp), E4, INS(I_HAT), C4, INS(arp), E4
    .byte INS(I_KICK), C4, INS(arp), E4, INS(I_KICK), C4, INS(arp), E4
    .byte INS(I_SNARE), C4, INS(arp), E4, INS(I_HAT), C4, INS(I_HAT), C4
    .byte PEND
}

pat_da_min:     drums_a(I_ARPMIN, false)
pat_da_maj:     drums_a(I_ARPMAJ, false)
pat_da_min_cr:  drums_a(I_ARPMIN, true)
pat_db_min:     drums_b(I_ARPMIN, false)
pat_db_maj:     drums_b(I_ARPMAJ, false)
pat_db_min_cr:  drums_b(I_ARPMIN, true)

// tom fill
pat_fill:
    .byte INS(I_SNARE), DUR(2), C4, DUR(1), C4, C4, DUR(2), C4, C4
    .byte INS(I_TOM), DUR(1), A4, A4, E4, E4, B3, B3, INS(I_SNARE), C4, C4
    .byte PEND


/* -------------------------------------------------------------------------
Player state
*/
.segment Variables [start=*, virtual]
frame_flag:     .byte 0
tick:           .byte 0
last_section:   .byte 0
fade:           .byte 0

filt_lo:        .byte 0
filt_hi:        .byte 0
filt_dlo:       .byte 0
filt_dhi:       .byte 0
filt_end:       .byte 0
filt_res:       .byte 0
filt_route:     .byte 0
filt_mode:      .byte 0

// per voice
section:        .fill 3, 0
ord_pos:        .fill 3, 0
transpose:      .fill 3, 0
pat_lo:         .fill 3, 0
pat_hi:         .fill 3, 0
pat_pos:        .fill 3, 0
dur:            .fill 3, 0
inst:           .fill 3, 0
rows_left:      .fill 3, 0
pend_type:      .fill 3, 0
pend_note:      .fill 3, 0
pend_dur:       .fill 3, 0
pend_inst:      .fill 3, 0
pend_glide:     .fill 3, 0
note:           .fill 3, 0
cur_inst:       .fill 3, 0
gate:           .fill 3, 0
wave:           .fill 3, 0
sh_ad:          .fill 3, 0
sh_sr:          .fill 3, 0
wt_on:          .fill 3, 0
wt_pos:         .fill 3, 0
freq_lo:        .fill 3, 0
freq_hi:        .fill 3, 0
glide_spd:      .fill 3, 0
glide_tgt_lo:   .fill 3, 0
glide_tgt_hi:   .fill 3, 0
vib_delay:      .fill 3, 0
vib_cnt:        .fill 3, 0
vib_dir:        .fill 3, 0
vib_step_lo:    .fill 3, 0
vib_step_hi:    .fill 3, 0
vib_off_lo:     .fill 3, 0
vib_off_hi:     .fill 3, 0
pw_lo:          .fill 3, 0
pw_hi:          .fill 3, 0
pw_dir:         .fill 3, 0
meter:          .fill 3, 0
