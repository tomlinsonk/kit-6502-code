// Settings for the TinyStories model (see tinygpt.asm)
.const TEMP_MUL = 384           // 256 / temperature
.const CUTOFF = 20              // drop tokens less than CUTOFF/255 as likely as the best one
.const MAX_TOKENS = 250         // per story
.const STREAM = 0               // 1: with no prompt, keep starting new ones until esc

.macro intro() {
    .text "tiny gpt: 4-bit transformer"
    .byte 10
    .text "on " + NSECTORS + " sectors of ssd. type a"
    .byte 10
    .text "story start, or just enter."
    .byte 10, 10
}
