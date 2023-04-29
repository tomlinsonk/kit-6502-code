.cpu _65c02
.encoding "ascii"
.filenamespace sid_play


#define PCB
#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/vid_cg1.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"
#import "../../lib/sid.lib"

#import "video_mon.sym"



.label triangle_on = %00010001
.label off = %00000000

.label timer_int_hi = $60

.const sh = $f0 
.const LOOP = $fe
.const END = $ff





.segment Code [outPrg="sid.prg", start=$1000] 
start:	

	lda #%10000010
	sta sid.res_filter

	 mov2 #$1fff : sid.filter_cutoff

	lda #$1F
	sta sid.mode_vol

	lda #$ff
	sta track1_curr_note
	sta track2_curr_note
	sta track3_curr_note

	sta track1_curr_pattern
	sta track2_curr_pattern
	sta track3_curr_pattern

	sta track1_pattern_done
	sta track2_pattern_done
	sta track3_pattern_done

	stz track1_duration_left
	stz track2_duration_left
	stz track3_duration_left

	stz is_done

	sei
	mov2 #irq : zp.irq_addr 
	lda via.IER
	ora #(via.INT_ENABLE | via.TIMER2_INT)
	sta via.IER 									// enable timer 2 interrupts
	
	stz via.T2_LO                                   // set up timer 2 for 50Hz interrupts
    ldx #timer_int_hi
    stx via.T2_HI
	cli


done:
	jmp done

music_irq:
	pha

	lda is_done
	beq play_tracks
	lda #off
	sta sid.voice1_control
	sta sid.voice2_control
	sta sid.voice3_control

	brk

play_tracks:
    play_track(track1_duration_left, track1_curr_note, track1_curr_pattern, track1_patterns,
			   track1_pattern_done, zp.track1_notes_addr, zp.track1_lengths_addr, zp.track1_insts_addr,
		       sid.voice1_freq, sid.voice1_atk_dec, sid.voice1_sus_rel, sid.voice1_control, sid.voice1_pw)

    play_track(track2_duration_left, track2_curr_note, track2_curr_pattern, track2_patterns,
			   track2_pattern_done, zp.track2_notes_addr, zp.track2_lengths_addr, zp.track2_insts_addr,
		       sid.voice2_freq, sid.voice2_atk_dec, sid.voice2_sus_rel, sid.voice2_control, sid.voice2_pw)

    play_track(track3_duration_left, track3_curr_note, track3_curr_pattern, track3_patterns,
    		   track3_pattern_done, zp.track3_notes_addr, zp.track3_lengths_addr, zp.track3_insts_addr,
		       sid.voice3_freq, sid.voice3_atk_dec, sid.voice3_sus_rel, sid.voice3_control, sid.voice3_pw)

music_irq_done:
	pla
	rts


/* -------------------------------------------------------------------------
Play a particular track (1, 2, or 3) with the given variables, table references,
and registers
*/
.macro play_track(duration_left, curr_note, curr_pattern, patterns,
				  pattern_done, notes_addr, lengths_addr, insts_addr,
	 			  freq_reg, atk_dec_reg, sus_rel_reg, control_reg, pw_reg) {

	lda pattern_done
	beq same_pattern
load_pattern:
	stz pattern_done
	inc curr_pattern
	ldx curr_pattern
	ldy patterns,x

	cpy #END
	bne not_end
	dec is_done
	jmp track_done
not_end:

	cpy #LOOP
	bne not_loop
	stz curr_pattern
	ldx curr_pattern
	ldy patterns,x
not_loop:

	lda #$ff
	sta curr_note
	stz duration_left

	lda pattern_notes_lo,y
	sta notes_addr
	lda pattern_notes_hi,y
	sta notes_addr+1

	lda pattern_lengths_lo,y
	sta lengths_addr
	lda pattern_lengths_hi,y
	sta lengths_addr+1

	lda pattern_insts_lo,y
	sta insts_addr
	lda pattern_insts_hi,y
	sta insts_addr+1

same_pattern:
	lda duration_left
	beq new_note
	dec duration_left
	jmp track_done

new_note:
	inc curr_note
	ldy curr_note

	lda (lengths_addr),y
	dec
	sta duration_left

	lda (notes_addr),y
	tax
	cpx #END
	bne not_done
	jmp load_pattern
not_done:

	cpx #sh
	beq do_rest

	lda note_table.lo,x
	sta freq_reg
	lda note_table.hi,x
	sta freq_reg+1

	lda (insts_addr),y
	tax
	lda inst_atk_dec,x
	sta atk_dec_reg

	lda inst_sus_rel,x
	sta sus_rel_reg

	lda inst_pw_lo,x
	sta pw_reg

	lda inst_pw_hi,x
	sta pw_reg+1

	lda inst_control,x
	sta control_reg

	jmp track_done

do_rest:
	lda #off
	sta control_reg	

track_done:				
}


irq:
    phx                                                     // stash X on stack
    tsx                                                     // put stack pointer in X
    pha                                                     // stash A on stack
    inx 
    inx                                                     // increment X twice so it points to the processor flags
    lda $100,x                                              // load the processor flags on the stack
    and #$10                                                // check for brk
    beq no_break                                            // if break bit is set, go to break handler
    jmp break
no_break:
    phy
       
    lda via.IFR

    ror
//     bcc no_ca2_irq
//     handle_ca2_irq()
// no_ca2_irq:

    ror 
    bcc no_ca1_irq
    handle_kb_irq()   
no_ca1_irq:

    ror
//     bcc no_shift_irq
//     handle_shift_irq()
// no_shift_irq:

    ror
//     bcc no_cb2_irq
//     handle_cb2_irq()
// no_cb2_irq:

    ror
//     bcc no_cb1_irq
//     handle_cb1_irq()
// no_cb1_irq:

    ror
    bcc no_timer2_irq
    stz via.T2_LO                                                   // write zeros to timer 2 lo
    ldx #timer_int_hi
    stx via.T2_HI
    jsr music_irq 
no_timer2_irq:

    ror
    bcc no_timer1_irq
    handle_cursor_timer_irq()
no_timer1_irq:

    // check_and_handle_uart_irq()

    ply
    pla
    plx
    rti

// Compute the lo and hi bytes for 8 octaves (C0 - B7) of notes
// Based on A4 = 440Hz and a 1.8432Mhz clock
note_table: 
	.lohifill 96, 440 * pow(2, i/12 - 4.75) / (1843200 / 16777216)


// Notes! For easier typing 
.const C0 = 0
.const c0 = 1
.const D0 = 2
.const d0 = 3
.const E0 = 4
.const F0 = 5
.const f0 = 6
.const G0 = 7
.const g0 = 8
.const A0 = 9
.const a0 = 10
.const B0 = 11
.const C1 = 12
.const c1 = 13
.const D1 = 14
.const d1 = 15
.const E1 = 16
.const F1 = 17
.const f1 = 18
.const G1 = 19
.const g1 = 20
.const A1 = 21
.const a1 = 22
.const B1 = 23
.const C2 = 24
.const c2 = 25
.const D2 = 26
.const d2 = 27
.const E2 = 28
.const F2 = 29
.const f2 = 30
.const G2 = 31
.const g2 = 32
.const A2 = 33
.const a2 = 34
.const B2 = 35
.const C3 = 36
.const c3 = 37
.const D3 = 38
.const d3 = 39
.const E3 = 40
.const F3 = 41
.const f3 = 42
.const G3 = 43
.const g3 = 44
.const A3 = 45
.const a3 = 46
.const B3 = 47
.const C4 = 48
.const c4 = 49
.const D4 = 50
.const d4 = 51
.const E4 = 52
.const F4 = 53
.const f4 = 54
.const G4 = 55
.const g4 = 56
.const A4 = 57
.const a4 = 58
.const B4 = 59
.const C5 = 60
.const c5 = 61
.const D5 = 62
.const d5 = 63
.const E5 = 64
.const F5 = 65
.const f5 = 66
.const G5 = 67
.const g5 = 68
.const A5 = 69
.const a5 = 70
.const B5 = 71
.const C6 = 72
.const c6 = 73
.const D6 = 74
.const d6 = 75
.const E6 = 76
.const F6 = 77
.const f6 = 78
.const G6 = 79
.const g6 = 80
.const A6 = 81
.const a6 = 82
.const B6 = 83
.const C7 = 84
.const c7 = 85
.const D7 = 86
.const d7 = 87
.const E7 = 88
.const F7 = 89
.const f7 = 90
.const G7 = 91
.const g7 = 92
.const A7 = 93
.const a7 = 94



track1_patterns:
	.byte $00, LOOP

track2_patterns:
	.byte $01, LOOP

track3_patterns:
	.byte $02, LOOP



pattern_notes_lo:
	.byte <pattern0_notes, <pattern1_notes, <pattern2_notes, <pattern3_notes

pattern_notes_hi:
	.byte >pattern0_notes, >pattern1_notes, >pattern2_notes, >pattern3_notes

pattern_lengths_lo:
	.byte <pattern0_lengths, <pattern1_lengths, <pattern2_lengths, <pattern3_lengths

pattern_lengths_hi:
	.byte >pattern0_lengths, >pattern1_lengths, >pattern2_lengths, >pattern3_lengths

pattern_insts_lo:
	.byte <pattern0_insts, <pattern1_insts, <pattern2_insts, <pattern3_insts

pattern_insts_hi:
	.byte >pattern0_insts, >pattern1_insts, >pattern2_insts, >pattern3_insts



// Index into note_table
pattern0_notes:
	.byte  E5,  sh,  B4,  sh,  C5,  sh,  D5,  sh
	.byte  C5,  sh,  B4,  sh,  A4,  sh,  A4,  sh
	.byte  C5,  sh,  E5,  sh,  D5,  sh,  C5,  sh
	.byte  B4,  sh,  C5,  sh,  D5,  sh,  E5,  sh
	.byte  C5,  sh,  A4,  sh,  A4,  sh
	.byte  sh,  D5,  sh,  F5,  sh,  A5,  sh,  G5
	.byte  sh,  F5,  sh,  E5,  sh,  C5,  sh,  E5
	.byte  sh,  D5,  sh,  C5,  sh,  B4,  sh,  B4
	.byte  sh,  C5,  sh,  D5,  sh,  E5,  sh,  C5
	.byte  sh,  A4,  sh,  A4,  sh, END

pattern0_lengths:
	.byte  16,  16,  04,  12,  04,  12,  16,  16
	.byte  04,  12,  04,  12,  16,  16,  04,  12
	.byte  04,  12,  16,  16,  04,  12,  04,  12
	.byte  32,  16,  04,  12,  16,  16,  16,  16
	.byte  16,  16,  16,  16,  48,  16
	.byte  16,  16,  16,  04,  12,  16,  16,  04
	.byte  12,  04,  12,  32,  16,  04,  12,  16
	.byte  16,  04,  12,  04,  12,  16,  16,  04
	.byte  12,  04,  12,  16,  16,  16,  16,  16
	.byte  16,  16,  16,  16,  48, END

pattern0_insts:
	.byte  00,  00,  00,  00,  00,  00,  00,  00
	.byte  00,  00,  00,  00,  00,  00,  00,  00
	.byte  00,  00,  00,  00,  00,  00,  00,  00
	.byte  00,  00,  00,  00,  00,  00,  00,  00
	.byte  00,  00,  00,  00,  00,  00
	.byte  00,  00,  00,  00,  00,  00,  00,  00
	.byte  00,  00,  00,  00,  00,  00,  00,  00
	.byte  00,  00,  00,  00,  00,  00,  00,  00
	.byte  00,  00,  00,  00,  00,  00,  00,  00
	.byte  00,  00,  00,  00,  00,  00, END



pattern1_notes:
	.byte  E2,  sh,  E3,  sh,  E2,  sh,  E3,  sh
	.byte  E2,  sh,  E3,  sh,  E2,  sh,  E3,  sh
	.byte  A2,  sh,  A3,  sh,  A2,  sh,  A3,  sh
	.byte  A2,  sh,  A3,  sh,  A2,  sh,  A3,  sh
	.byte  g2,  sh,  g3,  sh,  g2,  sh,  g3,  sh
	.byte  g2,  sh,  g3,  sh,  g2,  sh,  g3,  sh
	.byte  A2,  sh,  A3,  sh,  A2,  sh,  A3,  sh
	.byte  A2,  sh,  A3,  sh,  B2,  sh,  C3,  sh
	.byte  D3,  sh,  D2,  sh,  D3,  sh,  D2,  sh
	.byte  D3,  sh,  D2,  sh,  A2,  sh,  F2,  sh
	.byte  C2,  sh,  C3,  sh,  C2,  sh,  C3,  sh
	.byte  C2,  sh,  C3,  sh,  G2,  sh,  G3,  sh
	.byte  B2,  sh,  B3,  sh,  B2,  sh,  B3,  sh
	.byte  E2,  sh,  E3,  sh,  g2,  sh,  g3,  sh
	.byte  A2,  sh,  E3,  sh,  A2,  sh,  E3,  sh
	.byte  A2,  sh, END

pattern1_lengths:
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  12,  04,  12,  04,  12,  04,  12
	.byte  04,  60, END

pattern1_insts:
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01,  01,  01,  01,  01,  01,  01
	.byte  01,  01, END



pattern2_notes:
	.byte  sh, a7, sh,  a7, sh,  a7, sh, a7
	.byte  sh, a7, sh,  a7, sh
	.byte  sh, a7, sh,  a7, sh,  a7, sh, a7
	.byte  sh, a7, sh, END


pattern2_lengths:
	.byte  16,  04,  28,  04,  28,  04,  04,  04
	.byte  04,  04,  12,  04,  12
	.byte  16,  04,  28,  04,  28,  04,  12,  04
	.byte  12,  04,  12, END

pattern2_insts:
	.byte  02,  02,  02,  02,  02,  02,  02,  02
	.byte  02,  02,  02,  02,  02
	.byte  02,  02,  02,  02,  02,  02,  02,  02
	.byte  02,  02,  02, END


pattern3_notes:
	.byte sh, END


pattern3_lengths:
	.byte 192, END


pattern3_insts:
	.byte  00, END









// track1_patterns:
// 	.byte $00, $00, $03, $03, $00, END

// track2_patterns:
// 	.byte $01, $03, $01, $03, $01, END

// track3_patterns:
// 	.byte $02, $03, $03, $02, $02, END



// pattern_notes_lo:
// 	.byte <pattern0_notes, <pattern1_notes, <pattern2_notes, <pattern3_notes

// pattern_notes_hi:
// 	.byte >pattern0_notes, >pattern1_notes, >pattern2_notes, >pattern3_notes

// pattern_lengths_lo:
// 	.byte <pattern0_lengths, <pattern1_lengths, <pattern2_lengths, <pattern3_lengths

// pattern_lengths_hi:
// 	.byte >pattern0_lengths, >pattern1_lengths, >pattern2_lengths, >pattern3_lengths

// pattern_insts_lo:
// 	.byte <pattern0_insts, <pattern1_insts, <pattern2_insts, <pattern3_insts

// pattern_insts_hi:
// 	.byte >pattern0_insts, >pattern1_insts, >pattern2_insts, >pattern3_insts



// // Index into note_table
// pattern0_notes:
// 	.byte  48, sh,  47,  45, sh,  43, sh,  41
// 	.byte sh,  43,  45, sh,  48, sh,  47, sh
// 	.byte  45,  43, sh,  41, sh,  40, sh, END

// pattern0_lengths:
// 	.byte  12,  06,  06,  06,  06,  06,  06,  12
// 	.byte  06,  06,  06,  06,  06,  06,  12,  06
// 	.byte  06,  06,  06,  06,  06,  24,  24, END

// pattern0_insts:
// 	.byte  00,  00,  00,  00,  00,  00,  00,  00
// 	.byte  00,  00,  00,  00,  00,  00,  00,  00
// 	.byte  00,  00,  00,  00,  00,  00,  00, END



// pattern1_notes:
// 	.byte  33,  26,  31,  24, END

// pattern1_lengths:
// 	.byte  48,  48,  48,  48, END

// pattern1_insts:
// 	.byte  01,  01,  01,  01, END



// pattern2_notes:
// 	.byte  36, sh,  72, sh,  36, sh,  72, sh
// 	.byte  36, sh,  72, sh,  36, sh,  72, sh
// 	.byte  36, sh,  72, sh,  36, sh,  72, sh
// 	.byte  36, sh,  72, sh,  36, sh,  72, sh, END


// pattern2_lengths:
// 	.byte  06,  06,  06,  06,  06,  06,  06,  06
// 	.byte  06,  06,  06,  06,  06,  06,  06,  06
// 	.byte  06,  06,  06,  06,  06,  06,  06,  06
// 	.byte  06,  06,  06,  06,  06,  06,  06,  06, END

// pattern2_insts:
// 	.byte  02,  02,  02,  02,  02,  02,  02,  02
// 	.byte  02,  02,  02,  02,  02,  02,  02,  02
// 	.byte  02,  02,  02,  02,  02,  02,  02,  02
// 	.byte  02,  02,  02,  02,  02,  02,  02,  02, END


// pattern3_notes:
// 	.byte sh, END


// pattern3_lengths:
// 	.byte 192, END


// pattern3_insts:
// 	.byte  00, END

 
// Instruments
inst_pw_lo:
	.byte $40, $80, $00
inst_pw_hi:
	.byte $80, $00, $80
inst_atk_dec:
	.byte $62, $88, $14
inst_sus_rel:
	.byte $6d, $8a, $33
inst_control:
	.byte $21, $41, $81


.segment Variables [start=*, virtual]
track1_duration_left:
	.byte $00 
track1_curr_note:
	.byte $00
track1_curr_pattern:
	.byte $00
track1_pattern_done:
	.byte $00

track2_duration_left:
	.byte $00 
track2_curr_note:
	.byte $00
track2_curr_pattern:
	.byte $00
track2_pattern_done:
	.byte $00

track3_duration_left:
	.byte $00 
track3_curr_note:
	.byte $00
track3_curr_pattern:
	.byte $00
track3_pattern_done:
	.byte $00

is_done:
	.byte $00

