// Settings for the arXiv paper title model (see tinygpt.asm)
.const TEMP_MUL = 341           // 256 / temperature
.const CUTOFF = 10               // drop tokens less than CUTOFF/255 as likely as the best one
.const MAX_TOKENS = 90          // per title
.const STREAM = 1               // 1: with no prompt, keep starting new ones until esc

.macro intro() {
    .text "arxiv, by a 4-bit transformer"
    .byte 10
    .text "enter: new papers until esc."
    .byte 10
    .text "or type the start of a title."
    .byte 10, 10
}
