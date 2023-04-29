.cpu _65c02
.encoding "ascii"
.filenamespace life

#define PCB

#import "../../roms/video-mon/video_mon.sym"

#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/vid_rg1.lib"
#import "../../lib/kb.lib"
#import "../../lib/uart.lib"

.label rng = zp.B 										// two bytes -- also uses zp.C
.label neighbor_ptr = zp.D 								// two bytes -- alse uses zp.E
.label chunk_counter = zp.F 							// one byte
.label new_byte = zp.G 									// one byte


.label live_neighbors = $2000							// 8Kb; must begin at page start
.label vram = vid_rg1.VRAM_START

.segment Code [outPrg="life.prg", start=$1000] 
reset:

#if PCB
	set_vid_mode_rg1()
#endif

	lda #1
	sta rng
	sta rng+1

	// jsr rand_fill
	jsr clear_screen


	// gosper glider gun 
	lda #%11000000
	sta vram + 132
	sta vram + 132 - 16

	lda #%00100010
	sta vram + 132 + 1

	lda #%00100000
	sta vram + 132 + 1 - 16
	sta vram + 132 + 1 + 16

	lda #%00010001
	sta vram + 132 + 1 - 16*2
	sta vram + 132 + 1 + 16*2

	lda #%00001100
	sta vram + 132 + 1 - 16*3
	sta vram + 132 + 1 + 16*3


	lda #%11000010
	sta vram + 132 + 2 

	lda #%10000000
	sta vram + 132 + 2 + 16

	lda #%10001100
	sta vram + 132 + 2 - 16

	lda #%00001100
	sta vram + 132 + 2 - 16*2
	sta vram + 132 + 2 - 16*3

	lda #%00000010
	sta vram + 132 + 2 - 16*4

	lda #%10000000
	sta vram + 132 + 3
	sta vram + 132 + 3 + 16
	sta vram + 132 + 3 - 16*4
	sta vram + 132 + 3 - 16*5

	lda #%00110000
	sta vram + 132 + 4 - 16*2
	sta vram + 132 + 4 - 16*3



main_loop:
	jsr clear_live_neighbors

	lda #<(live_neighbors - 129) 
	sta neighbor_ptr
	lda #>(live_neighbors - 129)
	sta neighbor_ptr+1

	lda #4
	sta chunk_counter

	ldx #0 												// x is the offset from vram into current grid
x_loop:
	lda vram,x 											// the vram address gets modified to offset start address
	bne some_nonzero
	jmp all_zeros
some_nonzero:
	
	.for (var i = 0; i < 8; i++) {
		rol

		bcc bit_clear
		update_live_neighbors()
	bit_clear:

		inc neighbor_ptr
		bne no_carry
		inc neighbor_ptr+1
	no_carry:
	}

	jmp no_carry_4

all_zeros:
	lda #8
	clc
	adc neighbor_ptr
	sta neighbor_ptr
	bcc no_carry_4
	inc neighbor_ptr+1
no_carry_4:

	inx

	beq x_carry
	jmp x_loop
x_carry:

	inc x_loop+2 										// increment vram start address to read next block

	dec chunk_counter
	beq chunk_carry
	jmp x_loop
chunk_carry:

	lda #>vram
	sta x_loop+2										// reset the vram address

	jsr draw_step

	jmp main_loop


/**
 Clear the screen in RG1 mode.
 */
clear_screen: {
	phx

	ldx #0
loop1:
	stz vram,x
	inx 
	bne loop1
loop2:
	stz (vram+256),x
	inx 
	bne loop2
loop3:
	stz (vram+512),x
	inx 
	bne loop3
loop4:
	stz (vram+768),x
	inx 
	bne loop4

	plx
	rts
}


/**
 Clear live neighbors. Uses self-modifying code
 */
clear_live_neighbors: {
	phx
	phy

	ldy #32
	ldx #0

loop:
	stz live_neighbors,x
	inx
	bne loop
	inc loop+2										// modify code to increment high byte of store addr
	dey
	bne loop

	ldy #>live_neighbors
	sty loop+2 										// restore code to original state

	ply
	plx
	rts
}

/**
16-bit RNG from https://github.com/bbbradsmith/prng_6502/blob/master/galois16.s
Uses a linear feedback shift register and puts (pseudo-)random bits in rng,rng+1
*/
galois16o:
	lda rng+1
	tay // store copy of high byte
	// compute rng+1 ($39>>1 = %11100)
	lsr // shift to consume zeroes on left...
	lsr
	lsr
	sta rng+1 // now recreate the remaining bits in reverse order... %111
	lsr
	eor rng+1
	lsr
	eor rng+1
	eor rng+0 // recombine with original low byte
	sta rng+1
	// compute rng+0 ($39 = %111001)
	tya // original high byte
	sta rng+0
	asl
	eor rng+0
	asl
	eor rng+0
	asl
	asl
	asl
	eor rng+0
	sta rng+0
	rts



/**
Update live_neighbors
*/
.macro update_live_neighbors() {
	pha
	lda neighbor_ptr
	pha
	lda neighbor_ptr+1
	pha
	
	ldy #0

	lda (neighbor_ptr),y
	inc
	sta (neighbor_ptr),y
	iny
	lda (neighbor_ptr),y
	inc
	sta (neighbor_ptr),y
	iny
	lda (neighbor_ptr),y
	inc
	sta (neighbor_ptr),y

	ldy #128
	
	lda (neighbor_ptr),y
	inc
	sta (neighbor_ptr),y
	iny
	lda #%10000000
	ora (neighbor_ptr),y
	sta (neighbor_ptr),y 									// set top bit in live cell
	iny
	lda (neighbor_ptr),y
	inc
	sta (neighbor_ptr),y

	lda neighbor_ptr
	clc
	adc #128
	bcc no_carry_3
	inc neighbor_ptr+1
no_carry_3:
	sta neighbor_ptr

	lda (neighbor_ptr),y
	inc
	sta (neighbor_ptr),y
	dey
	lda (neighbor_ptr),y
	inc
	sta (neighbor_ptr),y
	dey
	lda (neighbor_ptr),y
	inc
	sta (neighbor_ptr),y


	pla 
	sta neighbor_ptr+1
	pla
	sta neighbor_ptr

	pla
}



draw_step: {
	lda #<live_neighbors
	sta neighbor_ptr

	lda #>live_neighbors
	sta neighbor_ptr+1

	ldx #0
	ldy #0


loop:
	.for (var i = 0; i < 8; i++) {
		lda (neighbor_ptr),y

		cmp #3
		bne not_dead_to_live
		sec
		rol new_byte
		jmp next
not_dead_to_live:
		cmp #%10000011
		beq alive
		cmp #%10000010
		beq alive
		clc
		rol new_byte
		jmp next
alive:
		sec
		rol new_byte
next:
		iny

	}

	lda new_byte
vram_addr:
	sta vram,x

	inx
	bne no_x_carry
	inc vram_addr+2
no_x_carry:
	
	cpy #0
	beq y_carry
	jmp loop
y_carry:

	inc neighbor_ptr+1
	lda neighbor_ptr+1
	cmp #((>live_neighbors) + 32)

	beq done
	jmp loop
done:

	lda #>vram
	sta vram_addr+2

	rts
}


/**
 Fill the screen with random bytes in RG1 mode.
 */
rand_fill: {
	phx
	pha

	ldx #0
loop1:
	jsr galois16o
	lda rng
	sta vram,x
	inx 
	bne loop1
loop2:
	jsr galois16o
	lda rng
	sta (vram+256),x
	inx 
	bne loop2
loop3:
	jsr galois16o
	lda rng
	sta (vram+512),x
	inx 
	bne loop3
loop4:
	jsr galois16o
	lda rng
	sta (vram+768),x
	inx 
	bne loop4

	pla
	plx
	rts
}