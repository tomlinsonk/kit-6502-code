.cpu _65c02
.encoding "ascii"




*=$8000       

reset:
    

done:

    lda #11
    ldy #22
    brk
    nop
loop:
    adc #1
    jmp loop   

irq:
    lda #42
    ldy $7810
    rti


    *=$fffc                                     
    .word reset                               
    .word irq                              
