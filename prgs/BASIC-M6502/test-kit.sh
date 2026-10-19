#!/bin/sh
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
emulator_dir=$(CDPATH= cd -- "${1:-$source_dir/../../../kit-emu}" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-basic-tests.XXXXXX")
trap 'rm -f "$build_dir"/*.class; rmdir "$build_dir"' EXIT
trap 'exit 1' HUP INT TERM

cd "$source_dir"
(cd ../../roms/video-mon && java -jar ../../KickAss.jar -libdir ../../lib -binfile video_mon.asm)
java -jar ../../KickAss.jar -libdir ../../roms/video-mon m6502.asm
javac -d "$build_dir" "$emulator_dir"/*.java KiTBasicTest.java

cd "$emulator_dir"
java -ea -Djava.awt.headless=true -cp "$build_dir" KiTBasicTest "$source_dir/m6502.prg"
