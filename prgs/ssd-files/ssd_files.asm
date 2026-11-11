/* =========================================================================
   SSD FILES
   File manager for the KiT's SSD (KSF filesystem, see lib/ssd.lib).

   Lists every file once, however many sectors it spans, with a map of
   used and free sectors. Runs, renames, deletes, and copies files.

   Keys:  up/down pick   left/right or pgup/pgdn page   return run/view
          r rename   d delete   c copy   esc quit

   Assemble:  ka -libdir ../../roms/video-mon ssd_files.asm

   Memory:
     $1000-$1fff   program
     $2000-$2fff   sector tables, read from the headers at startup
     $3000-$3fff   one-sector buffer for rename and copy
   ========================================================================= */

.cpu _65c02
.encoding "ascii"
.filenamespace ssdfiles

#define PCB
#define MACROS_ONLY
#import "../../lib/macros.lib"
#import "../../lib/vid.lib"
#import "../../lib/kb.lib"

#import "video_mon.sym"


.label SCREEN = $6000
.label SSD = $8000                                  // header page of the selected sector
.label SSD_TYPE = $8001
.label SSD_LOAD = $8002
.label SSD_SIZE = $8004
.label SSD_NEXT = $8008
.label SSD_VID_MODE = $8009
.label SSD_NAME = $8010
.label SSD_END = $9000

.const SECTORS = 64
.const NAME_LEN = 16
.const PROGRAM = $00
.const IMAGE = $10
.const DATA = $20

.const FOOTPRINT_START = $1000                      // images loading here would overwrite us
.const FOOTPRINT_END = $4000

// Screen layout
.const TITLE_ROW = 0
.const LABEL_ROW = 1
.const LIST_TOP = 2
.const LIST_ROWS = 10
.const INFO_ROW = 12
.const MAP_ROW = 13
.const HELP_ROW = 15

.const COL_TYPE = 3
.const COL_FLAG = 4
.const COL_NAME = 5
.const COL_SIZE = 22
.const COL_COUNT = 29

.label str_ptr = zp.B                               // two bytes
.label row_ptr = zp.D                               // two bytes
.label src_ptr = zp.F                               // two bytes
.label num = zp.H                                   // two bytes
.label tmp = zp.J
.label inv_mask = zp.K                              // $40 draws inverse video
.label digit = zp.L
.label started = zp.M
.label col = zp.N


// Print a string at row, col
.macro text_at(row, col, str) {
    lda #row
    jsr set_row
    ldy #col
    jsr print_inline
    .text str
    .byte 0
}

// Clear the help row and print a message there
.macro message(str) {
    stz inv_mask
    lda #HELP_ROW
    jsr clear_row
    ldy #0
    jsr print_inline
    .text str
    .byte 0
}


.segment Code [outPrg="ssd_files.prg", start=$1000]
start:
    stz vid.MODE_REG                                // text mode
    lda zp.kb_write_ptr                             // drop keys typed at the monitor
    sta zp.kb_read_ptr
    stz sel
    stz top
    jsr scan
    jsr draw_screen

main_loop:
    jsr kb.get_press
    beq main_loop
    jsr handle_key
    bra main_loop


/* -------------------------------------------------------------------------
Keys
*/
handle_key:
    cmp #kb.K_UP
    bne not_up
    lda sel
    beq key_done
    dec sel
    bra moved
not_up:

    cmp #kb.K_DOWN
    bne not_down
    lda sel
    inc
    cmp file_count
    bcs key_done
    sta sel
    bra moved
not_down:

    cmp #kb.K_LEFT
    beq pg_up
    cmp #kb.K_PG_UP
    bne not_pg_up
pg_up:
    lda sel
    sec
    sbc #LIST_ROWS
    bcs pg_up_ok
    lda #0
pg_up_ok:
    sta sel
    bra moved
not_pg_up:

    cmp #kb.K_RIGHT
    beq pg_down
    cmp #kb.K_PG_DOWN
    bne not_pg_down
pg_down:
    lda file_count
    beq key_done
    lda sel
    clc
    adc #LIST_ROWS
    cmp file_count
    bcc pg_down_ok
    lda file_count
    dec
pg_down_ok:
    sta sel
    bra moved
not_pg_down:

    cmp #kb.ASCII_ESC
    bne not_esc
    jsr vid.blank_screen
    brk                                             // back to the monitor
    nop
not_esc:

    ldx file_count                                  // the rest need a file
    beq key_done

    cmp #kb.ASCII_NEWLINE
    bne not_enter
    jmp open_file
not_enter:

    cmp #'r'
    bne not_rename
    jmp rename_file
not_rename:

    cmp #'d'
    bne not_delete
    jmp delete_file
not_delete:

    cmp #'c'
    bne not_copy
    jmp copy_file
not_copy:

key_done:
    rts

moved:
    jsr select_changed
    jsr draw_list
    jsr draw_info
    jsr draw_map
    jmp draw_help


/* -------------------------------------------------------------------------
Read every header into the sector tables, then group sectors into files.

A sector's next-sector link is followed only if the next sector holds a
file with the same name, so a sector reused after its file was partly
erased isn't mistaken for part of that file.
*/
scan:
    ldx #0
read_header:
    txa
    jsr ssd.set_sector
    lda SSD
    sta used,x                                      // 0 = sector holds a file
    lda SSD_TYPE
    sta type,x
    lda SSD_LOAD
    sta load_lo,x
    lda SSD_LOAD+1
    sta load_hi,x
    lda SSD_SIZE
    sta size_lo,x
    lda SSD_SIZE+1
    sta size_hi,x
    lda SSD_NEXT
    sta next,x
    lda #$ff
    sta link,x
    sta owner,x
    stz pointed,x
    jsr name_ptr
    ldy #0
copy_name:
    lda SSD_NAME,y
    sta (src_ptr),y
    iny
    cpy #NAME_LEN
    bne copy_name
    inx
    cpx #SECTORS
    bne read_header

    ldx #0                                          // find valid links
find_links:
    lda used,x
    bne no_link
    ldy next,x
    cpy #SECTORS
    bcs no_link
    stx tmp
    cpy tmp
    beq no_link
    lda used,y
    bne no_link
    jsr names_match
    bcs no_link
    tya
    sta link,x
    lda #1
    sta pointed,y
no_link:
    inx
    cpx #SECTORS
    bne find_links

    stz file_count                                  // files start at sectors nothing links to
    ldx #0
find_heads:
    lda used,x
    bne not_head
    lda pointed,x
    bne not_head
    jsr add_file
not_head:
    inx
    cpx #SECTORS
    bne find_heads

    ldx #0                                          // anything left over is in a loop of links
find_loops:
    lda used,x
    bne not_loop
    lda owner,x
    cmp #$ff
    bne not_loop
    jsr add_file
not_loop:
    inx
    cpx #SECTORS
    bne find_loops

    stz free_count
    ldx #0
count_free:
    lda used,x
    beq count_next
    inc free_count
count_next:
    inx
    cpx #SECTORS
    bne count_free

    lda sel                                         // keep the selection in range
    cmp file_count
    bcc sel_ok
    lda file_count
    beq sel_zero
    dec
sel_zero:
    sta sel
sel_ok:
    jmp select_changed


/*
Add the file starting at sector X to the file list, claiming its sectors.
Preserves X.
*/
add_file:
    phx
    ldy file_count
    txa
    sta head,y
    sta tmp                                         // tmp = head sector
    lda #0
    sta broken,y
    sta count,y
claim:
    lda owner,x
    cmp #$ff
    bne claim_broken                                // two files link into one sector
    lda tmp
    sta owner,x
    lda count,y
    inc
    sta count,y
    lda link,x
    cmp #$ff
    beq claim_end
    tax
    bra claim
claim_end:
    lda next,x                                      // a link we couldn't follow
    cmp #$ff
    beq claim_done
claim_broken:
    lda #1
    sta broken,y
claim_done:
    inc file_count
    plx
    rts


/*
Clear carry if sectors X and Y have the same name. Preserves X, Y.
*/
names_match:
    phx
    phy
    jsr name_ptr                                    // src_ptr = name of X
    lda src_ptr
    sta str_ptr
    lda src_ptr+1
    sta str_ptr+1
    tya
    tax
    jsr name_ptr                                    // src_ptr = name of Y
    ldy #NAME_LEN-1
match_loop:
    lda (src_ptr),y
    cmp (str_ptr),y
    sec
    bne match_done
    dey
    bpl match_loop
    clc
match_done:
    ply
    plx
    rts


/*
Point src_ptr at the stored name of sector X. Preserves X, Y.
*/
name_ptr:
    txa
    asl
    asl
    asl
    asl
    sta src_ptr
    txa
    lsr
    lsr
    lsr
    lsr
    clc
    adc #>names
    sta src_ptr+1
    rts


/*
Update sel_head and scroll the list to show the selection
*/
select_changed:
    lda #$ff
    sta sel_head
    lda file_count
    beq scrolled
    ldx sel
    lda head,x
    sta sel_head
    lda sel
    cmp top
    bcs not_above
    sta top
not_above:
    sec
    sbc #LIST_ROWS-1
    bcc scrolled
    cmp top
    bcc scrolled
    sta top
scrolled:
    rts


/*
List the sectors of the selected file in chain, in order
*/
build_chain:
    ldy #0
    lda sel_head
chain_loop:
    sta chain,y
    iny
    tax
    lda link,x
    cmp #$ff
    beq chain_done
    tax
    lda owner,x
    cmp sel_head
    bne chain_done
    txa
    cpy #SECTORS
    bcc chain_loop
chain_done:
    sty chain_len
    rts


/* -------------------------------------------------------------------------
Commands
*/

/*
Return: run a program, or show an image until a key is pressed
*/
open_file:
    ldx sel_head
    lda type,x
    cmp #PROGRAM
    beq run_program
    cmp #IMAGE
    beq show_image
    message("only programs and images open")
    rts

run_program:
    lda sel_head
    jsr ssd.set_sector
    jsr vid.blank_screen
    set_vid_ptr(0, 0)
    ldx #(trampoline_end - trampoline - 1)          // the program may load over us,
copy_trampoline:                                    // so load it from the bottom of the stack page
    lda trampoline,x
    sta $0100,x
    dex
    bpl copy_trampoline
    jmp $0100

trampoline:
    jsr ssd.load_file
    jmp (SSD_LOAD)
trampoline_end:

show_image:
    lda load_hi,x                                   // refuse images that would load over us
    cmp #>FOOTPRINT_END
    bcs image_ok
    clc
    lda load_lo,x
    adc size_lo,x
    sta tmp
    lda load_hi,x
    adc size_hi,x
    bcs image_overlaps
    cmp #>FOOTPRINT_START
    bcc image_ok
    bne image_overlaps
    lda tmp
    beq image_ok
image_overlaps:
    message("image would load over this prg")
    rts

image_ok:
    lda sel_head
    jsr ssd.set_sector
    lda SSD_VID_MODE
    sta vid.MODE_REG
    jsr ssd.load_file
wait_key:
    jsr kb.get_press
    beq wait_key
    stz vid.MODE_REG
    jmp draw_screen


/*
d: erase every sector of the selected file
*/
delete_file:
    stz inv_mask
    lda #HELP_ROW
    jsr clear_row
    ldy #0
    jsr print_inline
    .text "delete "
    .byte 0
    ldx sel_head
    jsr print_name
    jsr print_inline
    .text "? y/n"
    .byte 0

    jsr confirm
    bcs cancelled

    message("deleting...")
    jsr build_chain
    ldx #0
delete_loop:
    lda chain,x
    jsr ssd.set_sector
    jsr ssd.erase_sector
    inx
    cpx chain_len
    bne delete_loop

    jsr scan
    jsr draw_screen
    message("deleted")
    rts

cancelled:
    jmp draw_help


/*
r: rewrite every sector of the selected file with a new name
*/
rename_file:
    jsr start_name_edit
    jsr edit_name
    bcs cancelled

    ldx sel_head                                    // nothing to do if it's unchanged
    jsr name_ptr
    ldy #NAME_LEN-1
same_name:
    lda (src_ptr),y
    cmp new_name,y
    bne rename_changed
    dey
    bpl same_name
    jmp draw_help

rename_changed:
    message("renaming...")
    jsr build_chain
    ldx #0
rename_loop:
    lda chain,x
    jsr read_sector
    jsr set_buffer_name
    lda chain,x
    jsr write_sector
    inx
    cpx chain_len
    bne rename_loop

    jsr scan
    jsr draw_screen
    message("renamed")
    rts


/*
c: copy the selected file to the lowest free sectors
*/
copy_file:
    jsr build_chain
    ldx #0                                          // find a free sector for each one
    ldy #0
find_free:
    lda used,x
    beq free_next
    txa
    sta dest,y
    iny
    cpy chain_len
    beq found_free
free_next:
    inx
    cpx #SECTORS
    bne find_free
    message("not enough free sectors")
    rts

found_free:
    jsr start_name_edit
    jsr edit_name
    bcc copy_named
    jmp draw_help

copy_named:
    message("copying...")
    ldx #0
copy_loop:
    lda chain,x
    jsr read_sector
    jsr set_buffer_name
    lda #$ff                                        // link to the next copied sector
    ldy chain_len
    dey
    stx tmp
    cpy tmp
    beq copy_last
    lda dest+1,x
copy_last:
    sta buffer + <SSD_NEXT
    lda dest,x
    jsr write_sector
    inx
    cpx chain_len
    bne copy_loop

    jsr scan
    ldx #0                                          // select the copy
find_copy:
    lda head,x
    cmp dest
    beq copy_found
    inx
    cpx file_count
    bne find_copy
    ldx #0
copy_found:
    stx sel
    jsr select_changed
    jsr draw_screen
    message("copied to sector ")
    lda dest
    jmp print_hex


/*
Copy sector A into the buffer. Preserves X.
*/
read_sector:
    phx
    jsr ssd.set_sector
    stz src_ptr
    lda #>SSD
    sta src_ptr+1
    stz str_ptr
    lda #>buffer
    sta str_ptr+1
    ldx #>(SSD_END - SSD)
    ldy #0
read_loop:
    lda (src_ptr),y
    sta (str_ptr),y
    iny
    bne read_loop
    inc src_ptr+1
    inc str_ptr+1
    dex
    bne read_loop
    plx
    rts


/*
Erase sector A and write the buffer to it. Erased flash reads $ff,
so only other bytes need writing. Preserves X.
*/
write_sector:
    jsr ssd.set_sector
    jsr ssd.erase_sector
    stz src_ptr
    lda #>buffer
    sta src_ptr+1
    stz zp.ssd_write_addr
    lda #>SSD
    sta zp.ssd_write_addr+1
write_loop:
    ldy zp.ssd_write_addr
    lda (src_ptr),y
    cmp #$ff
    beq write_skip
    jsr ssd.write_byte
write_skip:
    inc zp.ssd_write_addr
    bne write_loop
    inc src_ptr+1
    inc zp.ssd_write_addr+1
    lda zp.ssd_write_addr+1
    cmp #>SSD_END
    bne write_loop
    rts


set_buffer_name:
    ldy #NAME_LEN-1
set_name_loop:
    lda new_name,y
    sta buffer + <SSD_NAME,y
    dey
    bpl set_name_loop
    rts


/*
Wait for y (carry clear) or any other key (carry set)
*/
confirm:
    jsr kb.get_press
    beq confirm
    cmp #'y'
    beq confirmed
    sec
    rts
confirmed:
    clc
    rts


/*
Start editing new_name from the selected file's name
*/
start_name_edit:
    ldx sel_head
    jsr name_ptr
    ldy #0
start_edit_loop:
    lda (src_ptr),y
    beq start_edit_pad
    sta new_name,y
    iny
    cpy #NAME_LEN
    bne start_edit_loop
start_edit_pad:
    sty name_len
    lda #0
pad_loop:
    cpy #NAME_LEN+1
    beq pad_done
    sta new_name,y
    iny
    bra pad_loop
pad_done:
    rts


/*
Edit new_name on the help row. Carry clear when accepted, set when
cancelled with esc
*/
edit_name:
    message("name: ")
    ldx #0
show_name:
    cpx name_len
    beq name_shown
    lda new_name,x
    jsr put_char
    inx
    bra show_name
name_shown:
    cpx #NAME_LEN
    bcs edit_key
    lda #$40                                        // cursor
    sta inv_mask
    lda #' '
    jsr put_char
    stz inv_mask

edit_key:
    jsr kb.get_press
    beq edit_key
    bmi edit_key

    cmp #kb.ASCII_ESC
    bne edit_not_esc
    sec
    rts
edit_not_esc:

    cmp #kb.ASCII_NEWLINE
    bne edit_not_enter
    lda name_len
    beq edit_key
    clc
    rts
edit_not_enter:

    cmp #kb.ASCII_BACKSPACE
    bne edit_not_backspace
    ldx name_len
    beq edit_key
    dex
    stz new_name,x
    stx name_len
    bra edit_name
edit_not_backspace:

    cmp #' '
    bcc edit_key
    cmp #$7f
    bcs edit_key
    ldx name_len
    cpx #NAME_LEN
    bcs edit_key
    sta new_name,x
    inc name_len
    bra edit_name


/* -------------------------------------------------------------------------
Display
*/
draw_screen:
    jsr vid.blank_screen

    lda #$40
    sta inv_mask
    lda #TITLE_ROW
    jsr clear_row
    ldy #1
    jsr print_inline
    .text "ssd files"
    .byte 0
    ldy #13
    lda file_count
    jsr print_dec2
    jsr print_inline
    .text " files"
    .byte 0
    ldy #23
    lda free_count
    jsr print_dec2
    jsr print_inline
    .text " free"
    .byte 0
    stz inv_mask

    text_at(LABEL_ROW, 0, "sc t name")
    text_at(LABEL_ROW, COL_SIZE, "bytes sec")

    jsr draw_list
    jsr draw_info
    jsr draw_map
    jmp draw_help


draw_help:
    stz inv_mask
    lda #HELP_ROW
    jsr clear_row
    text_at(HELP_ROW, 0, "ret:run r:ren d:del c:copy esc")
    rts


draw_list:
    stz list_row
list_loop:
    stz inv_mask
    lda list_row
    clc
    adc #LIST_TOP
    jsr clear_row
    lda list_row
    clc
    adc top
    cmp file_count
    bcs list_next
    jsr draw_entry
list_next:
    inc list_row
    lda list_row
    cmp #LIST_ROWS
    bne list_loop

    lda file_count
    bne list_done
    text_at(LIST_TOP+1, COL_NAME, "no files")
list_done:
    rts


/*
Draw file A of the list on the row in row_ptr
*/
draw_entry:
    tax
    cmp sel
    bne entry_colors_set
    lda #$40
    sta inv_mask
    ldy #31
    lda #' '|$40
fill_selected:
    sta (row_ptr),y
    dey
    bpl fill_selected
entry_colors_set:
    lda count,x
    sta entry_count
    ldy #COL_FLAG
    lda broken,x
    beq entry_whole
    lda #'!'
    jsr put_char
entry_whole:
    lda head,x
    tax                                             // x = head sector from here on
    ldy #0
    jsr print_hex
    ldy #COL_TYPE
    lda type,x
    jsr type_char
    jsr put_char
    ldy #COL_NAME
    jsr print_name
    lda size_lo,x
    sta num
    lda size_hi,x
    sta num+1
    ldy #COL_SIZE
    ldx #0
    jsr print_dec
    ldy #COL_COUNT
    lda entry_count
    jsr print_dec2
    stz inv_mask
    rts


/*
Selected file's type and load address
*/
draw_info:
    stz inv_mask
    lda #INFO_ROW
    jsr clear_row
    ldx sel_head
    cpx #$ff
    beq info_done
    ldy #0
    lda type,x
    cmp #PROGRAM
    bne info_not_program
    jsr print_inline
    .text "program"
    .byte 0
    bra info_addr
info_not_program:
    cmp #IMAGE
    bne info_not_image
    jsr print_inline
    .text "image"
    .byte 0
    bra info_addr
info_not_image:
    cmp #DATA
    bne info_unknown
    jsr print_inline
    .text "data"
    .byte 0
    bra info_addr
info_unknown:
    jsr print_inline
    .text "type "
    .byte 0
    lda type,x
    jsr print_hex
info_addr:
    jsr print_inline
    .text " at $"
    .byte 0
    lda load_hi,x
    jsr print_hex
    lda load_lo,x
    jsr print_hex

    ldx sel
    lda broken,x
    beq info_done
    ldy #18
    jsr print_inline
    .text "! chain broken"
    .byte 0
info_done:
    rts


/*
Sector map: two rows of 32. Free sectors show '.', used ones their
file's type, with the selected file in inverse video
*/
draw_map:
    ldx #0
map_loop:
    txa
    lsr
    lsr
    lsr
    lsr
    lsr
    clc
    adc #MAP_ROW
    jsr set_row
    txa
    and #31
    tay
    stz inv_mask
    lda used,x
    beq map_used
    lda #'.'
    bra map_put
map_used:
    lda owner,x
    cmp sel_head
    bne map_not_sel
    lda #$40
    sta inv_mask
    lda owner,x
map_not_sel:
    phx
    tax
    lda type,x
    plx
    jsr type_char
map_put:
    jsr put_char
    inx
    cpx #SECTORS
    bne map_loop
    stz inv_mask
    rts


/*
Letter for file type A
*/
type_char:
    cmp #PROGRAM
    bne not_p
    lda #'p'
    rts
not_p:
    cmp #IMAGE
    bne not_i
    lda #'i'
    rts
not_i:
    cmp #DATA
    bne not_d
    lda #'d'
    rts
not_d:
    lda #'?'
    rts


/*
Point row_ptr at screen row A. Clobbers A
*/
set_row:
    pha
    lsr
    lsr
    lsr
    clc
    adc #>SCREEN
    sta row_ptr+1
    pla
    asl
    asl
    asl
    asl
    asl
    sta row_ptr
    rts


/*
Fill screen row A with spaces in the current video; leaves row_ptr there
*/
clear_row:
    jsr set_row
    phy
    ldy #31
    lda #' '
    eor inv_mask
clear_loop:
    sta (row_ptr),y
    dey
    bpl clear_loop
    ply
    rts


/*
Write ASCII char A at row_ptr,Y and advance Y. Preserves X
*/
put_char:
    cmp #$20
    bcs not_control
    lda #'?'
not_control:
    cmp #$60
    bcc store_char
    and #$1f                                        // lower case shows as normal letters
store_char:
    eor inv_mask
    sta (row_ptr),y
    iny
    rts


/*
Print the null-terminated string following the jsr. Preserves X
*/
print_inline:
    pla
    sta str_ptr
    pla
    sta str_ptr+1
inline_loop:
    inc str_ptr
    bne inline_no_carry
    inc str_ptr+1
inline_no_carry:
    lda (str_ptr)
    beq inline_done
    jsr put_char
    bra inline_loop
inline_done:
    lda str_ptr+1
    pha
    lda str_ptr
    pha
    rts


/*
Print the name of sector X (up to 16 chars). Preserves X
*/
print_name:
    jsr name_ptr
    sty col
    ldy #0
name_loop:
    lda (src_ptr),y
    beq name_done
    phy
    ldy col
    jsr put_char
    sty col
    ply
    iny
    cpy #NAME_LEN
    bne name_loop
name_done:
    ldy col
    rts


print_hex:
    pha
    lsr
    lsr
    lsr
    lsr
    jsr print_nibble
    pla
    and #$0f
print_nibble:
    cmp #10
    bcc nibble_digit
    adc #('a' - 10 - 1)                             // carry is set
    jmp put_char
nibble_digit:
    ora #'0'
    jmp put_char


/*
Print A as two right-aligned decimal digits. Preserves X
*/
print_dec2:
    sta num
    stz num+1
    phx
    ldx #3
    jsr print_dec
    plx
    rts


/*
Print num in decimal with leading spaces, starting from power X
(0 = five digits, 3 = two digits)
*/
print_dec:
    stz started
dec_digit:
    stz digit
dec_sub:
    sec
    lda num
    sbc pow_lo,x
    sta tmp
    lda num+1
    sbc pow_hi,x
    bcc dec_sub_done
    sta num+1
    lda tmp
    sta num
    inc digit
    bra dec_sub
dec_sub_done:
    lda digit
    ora started
    bne dec_show
    cpx #4
    beq dec_show
    lda #' '
    bra dec_put
dec_show:
    sta started
    lda digit
    ora #'0'
dec_put:
    jsr put_char
    inx
    cpx #5
    bne dec_digit
    rts

pow_lo: .byte <10000, <1000, <100, <10, <1
pow_hi: .byte >10000, >1000, >100, >10, >1


/* -------------------------------------------------------------------------
Variables
*/
sel:         .byte 0                                // selected file
top:         .byte 0                                // first file shown
sel_head:    .byte 0                                // selected file's first sector
file_count:  .byte 0
free_count:  .byte 0
list_row:    .byte 0
entry_count: .byte 0
chain_len:   .byte 0
name_len:    .byte 0
new_name:    .fill NAME_LEN+1, 0

.assert "Program fits below its tables", * <= names, true


*=$2000 "Tables" virtual
names:      .fill SECTORS*NAME_LEN, 0               // 16-byte name of each sector
used:       .fill SECTORS, 0                        // header byte 0: 0 = holds a file
type:       .fill SECTORS, 0
load_lo:    .fill SECTORS, 0
load_hi:    .fill SECTORS, 0
size_lo:    .fill SECTORS, 0
size_hi:    .fill SECTORS, 0
next:       .fill SECTORS, 0                        // next-sector byte from the header
link:       .fill SECTORS, 0                        // next sector of the same file, or $ff
pointed:    .fill SECTORS, 0                        // 1 if another sector links here
owner:      .fill SECTORS, 0                        // first sector of the file holding this one
head:       .fill SECTORS, 0                        // file list: first sector,
count:      .fill SECTORS, 0                        //   number of sectors,
broken:     .fill SECTORS, 0                        //   1 if a link couldn't be followed
chain:      .fill SECTORS, 0                        // sectors of the selected file
dest:       .fill SECTORS+1, 0                      // sectors to copy it to

*=$3000 "Buffer" virtual
buffer:     .fill $1000, 0
