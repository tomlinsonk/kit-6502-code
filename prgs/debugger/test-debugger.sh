#!/bin/sh
# Usage: ./test-debugger.sh [KickAss.jar] [kit-emu directory]
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
kickass=${1:-$source_dir/../../KickAss.jar}
case $kickass in /*) ;; *) kickass=$PWD/$kickass ;; esac
emulator_dir=$(CDPATH= cd -- "${2:-$source_dir/../../../kit-emu}" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-debugger-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
trap 'exit 1' HUP INT TERM

cd "$source_dir"
assemble() {
    java -jar "$kickass" "$@" > "$build_dir/kickass.log" || { cat "$build_dir/kickass.log"; exit 1; }
}
(cd ../../roms/video-mon && assemble -libdir ../../lib -binfile video_mon.asm)
assemble -libdir ../../roms/video-mon debugger.asm
mkdir "$build_dir/classes" "$build_dir/run"
javac -d "$build_dir/classes" "$emulator_dir"/*.java DebuggerTest.java

# The emulator reads video_mon.bin, ssd.bin, and character-set.png from its working directory.
cp ../../roms/video-mon/video_mon.bin "$emulator_dir/ssd.bin" "$emulator_dir/character-set.png" "$build_dir/run"
cd "$build_dir/run"
java -ea -Djava.awt.headless=true -cp "$build_dir/classes" DebuggerTest \
    "$source_dir/debugger.prg" "$source_dir/../../roms/video-mon/video_mon.sym"
