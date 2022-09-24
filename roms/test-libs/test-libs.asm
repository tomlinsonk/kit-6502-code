.cpu _65c02
.encoding "ascii"

// Library code
*=$8000 
#import "lcd.lib"
#import "kb.lib"
#import "macros.lib"
#import "vid.lib"


// Main code
reset:
    cli
    cld

    jsr lcd.init
    jsr kb.init
    jsr vid.init

    ldx #0
print_loop:
    lda message,x
    beq done_print
    jsr lcd.write_ascii
    inx
    jmp print_loop

done_print:
    lda #$92
    jsr lcd.write_hex
    sta lcd.num_to_dec

    lda #$10
    jsr lcd.write_hex
    sta lcd.num_to_dec+1

    lda #'='
    jsr lcd.write_ascii

    jsr lcd.write_dec16

    lda #' '
    jsr lcd.write_ascii

    jsr lcd.read_addr
    jsr lcd.write_hex

    lda #$40
    jsr lcd.set_addr

done:
    jsr kb.get_press
    beq done                            // don't print if there was no press
    bmi extended                        // for extended, print scancode
    jsr lcd.write_ascii                 // otherwise, print ascii
    jsr vid.write_ascii
    jmp done
extended:
    jmp done

message:
    .text "Life: "
    .byte $00
    

irq:
    pha
    phx
    phy

    lda via.IFR

    ror
//     bcc no_ca2_irq
//     handle_ca2_irq()
// no_ca2_irq:

    ror 
    bcc no_ca1_irq
    kb_handle_irq()   
no_ca1_irq:

//     ror
//     bcc no_shift_irq
//     handle_shift_irq()
// no_shift_irq:

//     ror
//     bcc no_cb2_irq
//     handle_cb2_irq()
// no_cb2_irq:

//     ror
//     bcc no_cb1_irq
//     handle_cb1_irq()
// no_cb1_irq:

//     ror
//     bcc no_timer2_irq
//     handle_timer2_irq()
// no_timer2_irq:

//     ror
//     bcc no_timer1_irq
//     handle_timer1_irq()
// no_timer1_irq:

    ply
    plx
    pla

    rti

*=$fffc                               // the CPU reads address $fffc to read start of program address
    .word reset                               // reset address
    .word irq                                 // IRQ handler address
