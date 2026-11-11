#!/bin/sh
# Build the monitor and mini-asm, then run the emulator tests.
# Usage: ./test-mini-asm.sh [KickAss.jar] [kit-emu directory]
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
kickass=$(CDPATH= cd -- "$(dirname -- "${1:-$source_dir/../../KickAss.jar}")" && pwd)/$(basename -- "${1:-KickAss.jar}")
emulator_dir=$(CDPATH= cd -- "${2:-$source_dir/../../../kit-emu}" && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/mini-asm-tests.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM

cd "$source_dir"
(cd ../../roms/video-mon && java -jar "$kickass" -libdir ../../lib -binfile video_mon.asm > /dev/null)
java -jar "$kickass" -libdir ../../roms/video-mon -symbolfile mini-asm.asm > /dev/null
mkdir "$work_dir/classes"
javac -d "$work_dir/classes" "$emulator_dir"/*.java MiniAsmTest.java

# The emulator reads video_mon.bin, ssd.bin, and character-set.png from its working directory
cp ../../roms/video-mon/video_mon.bin "$emulator_dir/ssd.bin" "$emulator_dir/character-set.png" "$work_dir"
cd "$work_dir"
java -ea -Djava.awt.headless=true -cp "$work_dir/classes" MiniAsmTest \
    "$source_dir/mini-asm.prg" "$source_dir/../../roms/video-mon/video_mon.sym" "$kickass"
