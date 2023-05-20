.cpu _65c02
.encoding "ascii"

#define PCB

#if PCB
    .print "Assembling for PCB KiT"
#else 
    .print "Assembling for Breadboard KiT"
#endif

// RAM addresses

.label text_buffer = $0200                          // 31 bytes (0200-021f)
.label text_buffer_end = $021e                            
.label zp_reg_stash = $0220                         // 16 bytes
.label irq_addr_stash = $0230                       // 2 bytes


// RAM labels
#if !PCB
    .label vram_inline_start = $71e1
#else 
    .label vram_inline_start = $61e1
#endif

*=$8000   
.fill 4096, 0

*=$9000                                             // ROM starts at address $8000
jump_table:
    jmp reset                                       // 8000
    jmp vid.write_ascii                             // 8003
    jmp vid.inc_vid_ptr                             // 8006

#import "kb.lib"
#import "macros.lib"
#import "vid.lib"
#import "uart.lib"
#import "vid_cg1.lib"
#import "vid_rg1.lib"
#import "vid_cg3.lib"
#import "ssd.lib"
#import "sid.lib"

#if !PCB
    #import "lcd.lib"
#endif



reset:
    sei
    mov2 #irq : zp.irq_addr                         // set up irq handler
    cli

    cld

    jsr vid.init
<<<<<<< Updated upstream
    jsr vid.init_cursor

    set_vid_mode_text()
    set_ssd_sector(0)


    set_vid_ptr(7, 14)
    vid_write_string("KiT")
    set_vid_ptr(8, 9)
    vid_write_string("65c02 * 1.8mhz")
    set_vid_ptr(9, 7)
    vid_write_string("24k ram * 256k ssd")



#if !PCB
    jsr lcd.init
#endif

    lda #$42
    ldx #$ff
    ldy #$24
    txs
=======
>>>>>>> Stashed changes

    brk                                             // start the monitor
    nop
    
loop:
    jmp loop


start_mon:    
    // Stack has R_HI, R_LO, P, X, A, Y <
<<<<<<< Updated upstream

    sei                                
    jsr stash_zp_registers
    mov2 #irq : zp.irq_addr                         // set up irq handler
    cli   

=======
    jsr vid.init_cursor
>>>>>>> Stashed changes
    jsr reset_prompt
    jsr kb.init

mon_loop:
    jsr kb.get_press
    bne key_pressed

    ldy #0
    blink_cursor #vid.CURSOR_ON : (zp.txt_ptr),y
    
    jmp mon_loop                        


key_pressed:
    bpl not_extended                                // handle extended
    jmp extended_pressed
not_extended:

    cmp #kb.ASCII_ESC                               // check for esc press
    bne not_esc
    jmp reset
not_esc:

    cmp #kb.ASCII_BACKSPACE                         // check for backspace
    bne not_backspace
    jmp backspace_pressed
not_backspace:

    cmp #kb.ASCII_NEWLINE                           // check for enter
    bne not_enter
    jmp enter_pressed
not_enter:

    ldy #0
    sta (zp.txt_ptr),y                              // save char and write to screen
    jsr vid.write_ascii
    jsr inc_vid_txt_ptrs
    force_cursor_update()

    jmp mon_loop



/*
Main monitor code. Parse and execute command
*/
enter_pressed:
    ldx #0                                          // load offset of 0 for indirect indexed addressing / offset for writing

    ldy #0                                          // cursor off
    lda (zp.txt_ptr),y
    jsr vid.write_ascii

    shift_vid_up(2, 0)                              // move display up                                                    
    fill_vid_row(14, ' ')
    set_vid_ptr(14, 0)

    ldy #0                                          // read the first char
    lda text_buffer,y

    cmp #'r'
    bne not_read
    jmp read_command
not_read:

    cmp #'w'
    bne not_write
    jmp write_command
not_write:

    cmp #'g'
    bne not_go
    jmp go_command
not_go:

    cmp #'s'
    bne not_status
    jmp status_command
not_status:

    cmp #'u'
    bne not_update
    jmp update_command
not_update:

    cmp #'l'
    bne not_load
    jmp load_command
not_load:

    cmp #'x'
    bne not_exit
    jmp exit_command
not_exit:

    cmp #'d'
    bne not_dir
    jmp dir_command
not_dir:

    cmp #'e'
    bne not_erase
    jmp erase_command
not_erase:

    cmp #'f'
    bne not_file
    jmp file_command
not_file:

    cmp #'c'
    bne not_set_sector
    jmp set_sector_command
not_set_sector:

    cmp #'h'
    bne not_help
    jmp help_command
not_help:

enter_reset:
    jsr reset_prompt

    jmp mon_loop


/*
Write command
*/
write_command:                                      
    jsr parse_and_print_addr
    beq enter_reset                                 // if we didn't get an addr, reset

write_byte:
    consume_spaces(print_after_write)               // read spaces until we get something else
    
    jsr parse_hex_byte                              // parse the next byte, incrementing y
    sta (zp.mon_addr,x)                             // write the byte to mon addr pointer (x is 0)
    inc2 zp.mon_addr
    jmp write_byte   

print_after_write:
    mov2 zp.mon_arg1 : zp.mon_addr
    jmp print_8_bytes


/*
Read command
*/
read_command:
    jsr parse_and_print_addr
    beq enter_reset                                 // if we didn't get an addr, reset

print_8_bytes:
    ldy #8                                          // 8 bytes to display
    ldx #0
print_data:
    lda #' '
    jsr vid.write_ascii                             // display space
    inc zp.vid_ptr
    lda (zp.mon_addr,x)                             // load the data at address mon_addr into A// x is still 0
    jsr vid.write_hex                               // display it
    inc2 zp.mon_addr                                // increment address to print
addr_no_carry:
    dey                                             // decrement number of bytes left to print
    bne print_data                                  // if it's not zero, keep printing

    jmp enter_reset


/*
Go command
*/
go_command:
    consume_spaces(enter_reset)                     // read spaces until we get something else

    jsr parse_hex_byte                              // load hi hex byte into A and increment y
    sta zp.mon_addr+1
    iny
    jsr parse_hex_byte                              // load lo hex byte into A
    sta zp.mon_addr
go:
    jsr restore_zp_registers                        // restore zp.B,C,D,...

    ply
    pla
    plx
    plp                                             // restore registers

    jmp (zp.mon_addr)                               // go!


/*
Status command
*/
status_command:
    tsx                                             // put stack pointer in x
    txa
    clc
    adc #6
    tax                                             // x is now SP+6

    vid_write_string("PC")                          // display program counter
    lda $0100,x                                     // read PC hi byte
    jsr vid.write_hex
    dex                                             // x is now SP+5
    lda $0100,x                                     // read PC lo byte
    jsr vid.write_hex

    inc zp.vid_ptr
    
    vid_write_string("P")                           // display processor flags
    dex                                             // x is now SP+4
    lda $0100,x                                     
    jsr vid.write_hex                              

    inc zp.vid_ptr

    vid_write_string("A")                           // display A
    dex 
    dex                                             // x is now SP+2
    lda $0100,x                                     
    jsr vid.write_hex                              

    inc zp.vid_ptr

    vid_write_string("X")                           // display X
    inx                                             // x is now SP+3
    lda $0100,x                                     
    jsr vid.write_hex                              

    inc zp.vid_ptr

    vid_write_string("Y")                           // display Y
    dex
    dex                                             // x is now SP+1
    lda $0100,x                                     
    jsr vid.write_hex     

    inc zp.vid_ptr                         

    vid_write_string("S")                           // display stack pointer
    dex                                             // x is now SP
    txa                                             // transfer SP into A
    jsr vid.write_hex                               // write stack pointer


    jmp enter_reset

/*
Update command
Changes the value of CPU registers, then displays the new status
*/
update_command:
    tsx                                             // put stack pointer in x
    txa
    clc
    adc #6
    tax                                             // x is now SP+6

    consume_spaces(status_command)                  // read spaces until we get something else
    lda text_buffer,y 
    cmp #'-'
    bne do_pc_update                                // if the text buffer char is -, keep PC unchanged
    dex                                             // x in now SP+5
    jmp skip_pc_update
do_pc_update:
    jsr parse_hex_byte                              // load hi hex byte into A and increment y
    sta $0100,x                                     // store hi byte of new PC on stack
    iny
    dex                                             
    jsr parse_hex_byte                              // load lo hex byte into A and increment y
    sta $0100,x                                     // store lo byte of new PC on stack
skip_pc_update:

    dex                                             // x is now SP+4
    consume_spaces(status_command)                  // read spaces until we get something else
    lda text_buffer,y 
    cmp #'-'
    beq skip_p_update                               // if the text buffer char is -, keep stack pointer unchanged
    jsr parse_hex_byte                              // load hex byte into A and increment y
    sta $0100,x                                     
skip_p_update:
    
    dex                                             
    dex                                             // x is now SP+2
    consume_spaces(status_command)                  // read spaces until we get something else
    lda text_buffer,y 
    cmp #'-'
    beq skip_a_update                               // if the text buffer char is -, keep stack pointer unchanged
    jsr parse_hex_byte                              // load hex byte into A and increment y                                           
    sta $0100,x                                     
skip_a_update:

    inx                                             // x is now SP+3
    consume_spaces(status_command)                  // read spaces until we get something else
    lda text_buffer,y 
    cmp #'-'
    beq skip_x_update                               // if the text buffer char is -, keep stack pointer unchanged
    jsr parse_hex_byte                              // load hex byte into A and increment y
    sta $0100,x                                     
skip_x_update:

    dex
    dex                                             // x is now SP+1
    consume_spaces(status_command)                  // read spaces until we get something else
    lda text_buffer,y 
    cmp #'-'
    beq skip_y_update                               // if the text buffer char is -, keep stack pointer unchanged
    jsr parse_hex_byte                              // load hex byte into A and increment y
    sta $0100,x                                     
skip_y_update:

    consume_spaces(status_command)                  // read spaces until we get something else
lda text_buffer,y 
    cmp #'-'
    beq skip_s_update                               // if the text buffer char is -, keep stack pointer unchanged
    jsr parse_hex_byte                              // load hex byte into A and increment y
    tax
    txs                                
skip_s_update:

    jmp status_command



/*
Load command
Loads a file over UART serial port
*/
load_command:

#if !PCB
    jsr uart.init
#else
    jsr uart.init_38400
#endif

    set_vid_ptr(15, 0)
    vid_write_string("loading")

    jsr uart.read_byte                              // read file type
    sta zp.I                                        // store file type in zp.I
    
    jsr uart.read_byte                              // read video mode (or ff for programs)
    sta zp.J                                        // store video mode in zp.J

    uart_read_2(zp.mon_arg1)                        // read file size into mon_arg1
    uart_read_2(zp.E)                               // read checksum in zp.E,F
    uart_read_2(zp.mon_addr)                        // read start addr into mon_addr
    uart_read_2(zp.K)                               // read load addr into zp.K,J

    set_vid_ptr(14, 0)

    vid_write_string("A") 
    lda zp.mon_addr+1
    jsr vid.write_hex
    lda zp.mon_addr
    jsr vid.write_hex                          
    inc zp.vid_ptr                         


    vid_write_string("B")                           
    lda zp.mon_arg1+1
    jsr vid.write_hex
    lda zp.mon_arg1
    jsr vid.write_hex  
    inc zp.vid_ptr       

    vid_write_string("C") 
    lda zp.E
    jsr vid.write_hex
    lda zp.F
    jsr vid.write_hex    

    uart_read_n_with_checksum(zp.mon_arg1, zp.K, zp.G)     // read n bytes and save checksum at zp.G,H

    vid_write_string("=")                           
    lda zp.G
    jsr uart.write_byte                                           // send the checksum back as ack
    jsr vid.write_hex
    lda zp.G+1
    jsr uart.write_byte
    jsr vid.write_hex

    set_vid_ptr(15, 0)
    vid_write_string("done! Run, Save, or Cancel?")

get_yn_loop:
    jsr kb.get_press
    beq get_yn_loop

    cmp #'r'
    bne dont_run
    jmp go
dont_run:

    cmp #'s'
    bne dont_save
    jsr save_to_ssd
dont_save:


    jmp enter_reset


/*
Save the file loaded over UART to SSD
*/ 
save_to_ssd:
    jsr set_sector_prompt

    jsr vid.shift_up_1_clear_bottom
    vid_write_string("filename: ")

    jsr clear_text_buffer
    ldy #0

fname_loop:
    jsr kb.get_press
    beq fname_loop

    cmp #kb.ASCII_NEWLINE
    beq fname_done

    sta text_buffer,y
    jsr vid.write_ascii
    inc_vid_ptr()
    iny
    cpy #16
    bcc fname_loop
fname_done:

    jsr vid.shift_up_1_clear_bottom
    ssd_save_file(zp.mon_addr, zp.K, zp.mon_arg1, zp.G, text_buffer, zp.I, zp.J)

    jsr vid.shift_up_1

    jmp enter_reset

wait_loop:
    jsr kb.get_press
    beq wait_loop

    rts

set_sector_prompt:
    jsr vid.shift_up_1_clear_bottom
    vid_write_string("sector (hex 00-39): ")
    
get_sector_nibble1_loop:
    jsr kb.get_press
    beq get_sector_nibble1_loop

    sta text_buffer
    jsr vid.write_ascii

    inc_vid_ptr()

get_sector_nibble2_loop:
    jsr kb.get_press
    beq get_sector_nibble2_loop

    sta text_buffer+1
    jsr vid.write_ascii
    inc_vid_ptr()

    ldy #0
    jsr parse_hex_byte
    jsr ssd.set_sector

    rts


/*
File command
Loads the contents of file given as hex argument
*/
file_command: 
    consume_spaces(file_done)
    jsr parse_hex_byte

    jsr ssd.set_sector

    lda ssd.file_type_addr
    cmp #ssd.IMAGE
    bne not_image
    lda ssd.vid_mode_addr
    sta vid.MODE_REG    
not_image:

    jsr ssd.load_file

    lda ssd.file_type_addr
    beq run_program                                 // if file is program, run it!

    cmp #ssd.IMAGE
    beq wait_for_esc

    jmp file_done                                   // otherwise, do nothing

run_program:
    jmp (ssd.load_addr)
                            

wait_for_esc:
    jsr kb.get_press
    beq wait_for_esc                                

    cmp #kb.ASCII_ESC
    bne wait_for_esc   

    set_vid_mode_text()                             
    jmp file_done

file_done:
    jmp enter_reset





/*
Dir command
Lists all files stored on the SSD
*/
dir_command:
    consume_spaces(dir_zero)
    jsr parse_hex_byte
    tax
    jmp display_dir
dir_zero:
    ldx #0
display_dir:

    fill_vid_screen(' ')
    set_vid_ptr(0, 0)

    mov2 #ssd.file_name_addr : zp.B

    ldy #0
sector_loop:
    jsr vid.set_row
    txa
    jsr ssd.set_sector
    jsr vid.write_hex
    inc_vid_ptr()

    lda ssd.START_ADDR
    bne empty_sector

    lda ssd.file_type_addr

    cmp #ssd.IMAGE
    bne write_p
    lda #'I' 
    jsr vid.write_ascii
    jmp write_fname

write_p:
    lda #'P' 
    jsr vid.write_ascii

write_fname:
    inc_vid_ptr()
    inc_vid_ptr()
    jsr vid.write_string
    jmp next_sector 

empty_sector:
    lda #'E' 
    jsr vid.write_ascii
next_sector:
    inx
    cpx #64
    bcs dir_done
    iny
    cpy #15
    bne sector_loop

dir_done:
    jmp enter_reset


set_sector_command:
    consume_spaces(file_done)
    jsr parse_hex_byte
    jsr ssd.set_sector

    vid_write_string("loaded sector ")

    lda zp.ssd_sector
    jsr vid.write_hex


    jmp enter_reset



/*
Erase command
Erases current sector of SSD
*/
erase_command:
    consume_spaces(file_done)
    jsr parse_hex_byte
    jsr ssd.set_sector

    vid_write_string("confirm erase Y/N ")

erase_confirm:
    jsr kb.get_press
    beq erase_confirm
    cmp #'y'
    beq do_erase
    jmp enter_reset

do_erase:
    jsr ssd.erase_sector

    fill_vid_row(15, ' ')
    set_vid_ptr(15, 0)

    vid_write_string("erased ")
    lda zp.ssd_sector
    jsr vid.write_hex
    jsr vid.shift_up_1

    jmp enter_reset

/*
Exit command
Restores all registers and exits the monitor, returning to PC
*/
exit_command:
    jsr restore_zp_registers                        // restore zp.B,C,D,...

    ply
    pla
    plx                                             // restore A,X,Y

    rti                                             // pop P and PC off of stack and return to PC 


/*
Help command
Prints help message
*/
help_command:
    fill_vid_screen(' ')
    .var helps = List().add(
        "Read (addr)",
        "Write (addr) (data)",
        "Go to (addr)",
        "Status of registers",
        "Update (pc p a x y s)",
        "Load over uart",
        "Change (sector)",
        "Directory (sector)",
        "Erase (sector)",
        "File run (sector)",
        "Help",
        "eXit monitor"
    )

    .for(var i=0; i<helps.size(); i++) {
        set_vid_ptr(i, 0)
        vid_write_string(helps.get(i))
    }
    
    jmp enter_reset

/* 
Parse text into zp.mon_arg1 and zp.mon_addr starting at txt_ptr,y
Also, print the address on the output line followed by a colon
If we encounter a null before two bytes, set A to 0. Otherwise, set A to 1 
*/
parse_and_print_addr:
    consume_spaces(exit_parse_print_addr)
    
    jsr parse_hex_byte                              // load hi hex byte into A and increment y
    sta zp.mon_arg1+1                               // store the hi byte    
    sta zp.mon_addr+1                               // store hi byte in mon addr
    jsr vid.write_hex                               // display it in hex    
    iny                                             // increment y again to go to start of next byte
    
    jsr parse_hex_byte                              // load lo hex byte into A and increment y
    sta zp.mon_arg1                                 // store the lo byte    
    sta zp.mon_addr                                 // store lo byte in mon addr
    jsr vid.write_hex                               // display it in hex 

    lda #':'
    jsr vid.write_ascii                             // display colon
    inc zp.vid_ptr
    
    lda #1
exit_parse_print_addr:
    rts


/*
Consume spaces in the text buffer. If we encounter a null, jump to null_branch.
If we encounter anything else, fall through.
*/
.macro consume_spaces(null_branch) {
loop:
    iny
    lda text_buffer,y                               // load the next char to check if it's non-null
    bne next_cmp                                    
    jmp null_branch                                 // if it's null, go to null branch
next_cmp:
    cmp #' '
    beq loop                                        // if it's space, keep looping
}


/*
Handle a backspace press
*/
backspace_pressed:
    ldy #0
    lda (zp.txt_ptr),y                              // load the char under the cursor
    jsr vid.write_ascii                             // write it to the cursor position

    jsr dec_vid_txt_ptrs                            // decrement video pointer

    lda #' '
    sta (zp.txt_ptr),y                              // save a space to the previous character
    jsr vid.write_ascii                             // write that space to the screen
    force_cursor_update()

    jmp mon_loop


/*
Handle the extended and pseudoextended keypresses (arrow keys and function keys)
*/
extended_pressed:
    ldy #0

    cmp #kb.K_LEFT
    bne not_left
    lda (zp.txt_ptr),y                              
    jsr vid.write_ascii                             // write the character under the cursor
    jsr dec_vid_txt_ptrs                            // decrement text pointer
    force_cursor_update()   
    jmp mon_loop
not_left:

    cmp #kb.K_RIGHT
    bne not_right
    lda (zp.txt_ptr),y                              
    jsr vid.write_ascii                             // write the character under the cursor
    jsr inc_vid_txt_ptrs                            // increment text pointer
    force_cursor_update()
    jmp mon_loop    
not_right:

    cmp #kb.K_F1
    bne not_f1
    set_vid_mode_text()
    jmp mon_loop                          
not_f1:

    cmp #kb.K_F2
    bne not_f2
    set_vid_mode_sg6()
    jmp mon_loop                        
not_f2:

    cmp #kb.K_F3
    bne not_f3
    set_vid_mode_cg1()
    jmp mon_loop                          
not_f3:

    cmp #kb.K_F4
    bne not_f4
    set_vid_mode_rg1()
    jmp mon_loop                         
not_f4:

    cmp #kb.K_F5
    bne not_f5
    set_vid_mode_cg2()
    jmp mon_loop                              
not_f5:

    cmp #kb.K_F6
    bne not_f6
    set_vid_mode_rg2()
    jmp mon_loop                             
not_f6:

    cmp #kb.K_F7
    bne not_f7
    set_vid_mode_cg3()
    jmp mon_loop                              
not_f7:

    cmp #kb.K_F8
    bne not_f8
    set_vid_mode_rg3()
    jmp mon_loop                             
not_f8:

    cmp #kb.K_F9
    bne not_f9
    set_vid_mode_cg6()
    jmp mon_loop                           
not_f9:

    cmp #kb.K_F10
    bne not_f10
    set_vid_mode_rg6()
    jmp mon_loop                              
not_f10:

    cmp #kb.K_F11
    bne not_f11   
    jmp mon_loop                                                     
not_f11:

    cmp #kb.K_F12
    bne not_f12
    jmp mon_loop                              
not_f12:

not_function_key:    
    jmp mon_loop


/*
Fill the text buffer with 0s
*/
clear_text_buffer:
    pha
    phx

    ldx #31
    lda #0

clear_text_loop:                                        // write 0s to the text buffer
    sta text_buffer,x
    dex
    bpl clear_text_loop

    plx
    pla
    rts

/*
parse the hex byte (lowercase) ascii number starting at TEXT_BUFFER,y and store the result in A. Also increments y
*/
parse_hex_byte:                                         
    lda text_buffer,y                                   // load the first symbol
    jsr parse_hex_char                                  // parse it

    asl
    asl
    asl
    asl                                                 // move it into the hi nibble
    sta zp.B                                            // stash hi nibble in B

    iny
    lda text_buffer,y
    jsr parse_hex_char                                  // parse lo nibble

    ora zp.B                                            // load in hi nibble into A
    rts

parse_hex_char:                                         // parse the hex char (lower case) in A, store the result in A
    cmp #'a'                                            // check if it's a letter
    bcs parse_letter
    sec
    sbc #'0'                                            // get the offset from '0' for 0-9
    rts
parse_letter:
    sec
    sbc #('a'-10)                                       // get the offset from 'a' (plus 10) for a-f
    rts


/*
Redraw the prompt, clear the text buffer, and reset the vid and txt pointers
*/
reset_prompt:
    set_vid_ptr(15, 0)
    ldy #31
    lda #' '

reset_prompt_loop:
    sta (zp.vid_ptr),y
    dey
    bpl reset_prompt_loop

    lda #'>'                                                // write prompt
    jsr vid.write_ascii
    inc zp.vid_ptr

    jsr clear_text_buffer                                   // clear the text buffer
    set_txt_ptr(text_buffer)
    rts


inc_vid_txt_ptrs:
    pha
    inc2 zp.vid_ptr
    clamp_max2 zp.vid_ptr : vid.VRAM_TXT_END
    inc2 zp.txt_ptr
    clamp_max2 zp.txt_ptr : text_buffer_end
    pla
    rts


dec_vid_txt_ptrs:
    pha
    dec2 zp.vid_ptr
    clamp_min2 zp.vid_ptr : vram_inline_start
    dec2 zp.txt_ptr
    clamp_min2 zp.txt_ptr : text_buffer
    pla
    rts


stash_zp_registers:
    move_block(zp.B, zp_reg_stash, 16)
    mov2 zp.irq_addr : irq_addr_stash
    rts

restore_zp_registers:
    move_block(zp_reg_stash, zp.B, 16)
    mov2 irq_addr_stash : zp.irq_addr
    rts

.macro set_txt_ptr(addr) {
    lda #(<addr)
    sta zp.txt_ptr                                  
    lda #(>addr)
    sta zp.txt_ptr+1 
}


break:
    phy
    // Now stack has R_HI, R_LO, P, X, A, Y <
    jmp start_mon

irq:
    phx                                                     // stash X on stack
    tsx                                                     // put stack pointer in X
    pha                                                     // stash A on stack
    inx 
    inx                                                     // increment X twice so it points to the processor flags
    lda $100,x                                              // load the processor flags on the stack
    and #$10                                                // check for brk
    bne break                                               // if break bit is set, go to break handler
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
    ldx #$ff
    stx via.T2_HI 
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


raw_irq:
    jmp (zp.irq_addr)


*=$fffc                                             // the CPU reads address $fffc to read start of program address
    .word reset                                     // reset address
    .word raw_irq                                   // IRQ handler address