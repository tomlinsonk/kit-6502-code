// upload.prg: saves the BASIC program that bas2prg.py appends to it
// as an SSD data file, then returns to the monitor. It loads just
// above the interpreter, so BASIC stays intact in RAM.

.segmentdef Upload [start=RAMLOC]
.file [name="upload.prg", segments="Upload"]
.segment Upload

upload:
	tsx
	stx upload_stack
	ldx #SSD_NAME_LEN
!copy:
	lda upload_name,x
	sta file_name,x
	dex
	bpl !copy-
	ldx #0
!length:
	lda file_name,x
	beq !counted+
	inx
	cpx #SSD_NAME_LEN
	bcc !length-
!counted:
	stx file_name_len
	txa
	bne !size+
	jmp upload_empty
!size:
	lda upload_size
	sta file_size
	lda upload_size+1
	sta file_size+1
	ora file_size
	bne !save+
	jmp upload_empty
!save:
	lda upload_sector
	sta file_sector
	LDWDI(upload_program)
	STWD(file_src)
	LDWDI(RAMLOC+1)
	STWD(file_addr)
	jsr upload_ksf.SSD_SAVE

	jsr vid.shift_up_1_clear_bottom
	vid_write_string("saved to sector ")
	lda file_sector
	ldx #0
!tens:
	cmp #10
	bcc !ones+
	sbc #10
	inx
	bra !tens-
!ones:
	ora #'0'
	sta upload_digit
	txa
	beq !last+
	ora #'0'
	jsr vid.write_ascii
	inc_vid_ptr()
!last:
	lda upload_digit
	jsr vid.write_ascii
	inc_vid_ptr()
	bra upload_exit

upload_empty:
	LDWDI(upload_empty_text)
	bra upload_error
upload_full:
	LDWDI(upload_full_text)
	bra upload_error
upload_in_use:
	LDWDI(upload_in_use_text)
upload_error:
	STWD(zp.ssd_read_addr)
	ldx upload_stack
	txs
	jsr vid.shift_up_1_clear_bottom
	ldy #0
!char:
	lda (zp.ssd_read_addr),y
	beq upload_exit
	jsr vid.write_ascii
	inc_vid_ptr()
	iny
	bra !char-
upload_exit:
	jsr vid.shift_up_1
	brk
	nop

upload_ksf: SSD_SAVE_CODE(upload_full, upload_in_use)

upload_empty_text:
	.text "error: no program"
	.byte 0
upload_full_text:
	.text "error: ssd full"
	.byte 0
upload_in_use_text:
	.text "error: sector in use"
	.byte 0
upload_stack:
	.byte 0
upload_digit:
	.byte 0

// bas2prg.py fills in these fields and appends the program.
upload_name:
	.fill SSD_NAME_LEN+1, 0
upload_sector:
	.byte $ff
upload_size:
	.word 0
upload_program:
.label upload_memtop = MEMTOP

.assert "Upload stub must leave room for programs", upload_program < MEMTOP-$2000, true
