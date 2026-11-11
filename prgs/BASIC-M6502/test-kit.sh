#!/bin/sh
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
emulator_dir=$(CDPATH= cd -- "${1:-$source_dir/../../../kit-emu}" && pwd)
kickass=${KICKASS:-$source_dir/../../KickAss.jar}
case $kickass in /*) ;; *) kickass=$PWD/$kickass ;; esac
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-basic-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
trap 'exit 1' HUP INT TERM

cd "$source_dir"
(cd ../../roms/video-mon && java -jar "$kickass" -libdir ../../lib -binfile video_mon.asm)
java -jar "$kickass" -libdir ../../roms/video-mon m6502.asm
javac -d "$build_dir" "$emulator_dir"/*.java KiTBasicTest.java

# Run with this checkout's monitor and a scratch copy of the emulator's SSD image.
cp ../../roms/video-mon/video_mon.bin "$emulator_dir/ssd.bin" "$emulator_dir/character-set.png" "$build_dir"
cd "$build_dir"
java -ea -Djava.awt.headless=true -cp "$build_dir" KiTBasicTest "$source_dir/m6502.prg"
