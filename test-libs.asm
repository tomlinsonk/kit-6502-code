.cpu _65c02
.encoding "ascii"

// Library code
*=$8000 
#import "lib-lcd.asm"


// Main code
reset:
    jsr lcd.init

    ldx #0
print_loop:
    lda message,x
    beq done_print
    jsr lcd.write_ascii
    inx
    jmp print_loop

done_print:
    lda #$40
    jsr lcd.set_addr


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
done:
    jmp done

message:
    .text "Life, etc."
    .byte $00
    

irq:
    rti

*=$fffc                               // the CPU reads address $fffc to read start of program address
    .word reset                               // reset address
    .word irq                                 // IRQ handler address
