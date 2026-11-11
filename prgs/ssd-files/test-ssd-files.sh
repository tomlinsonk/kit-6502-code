#!/bin/sh
# Usage: ./test-ssd-files.sh [path/to/KickAss.jar] [path/to/kit-emu]
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
kickass=${1:-$source_dir/../../KickAss.jar}
case $kickass in /*) ;; *) kickass=$PWD/$kickass ;; esac
emulator_dir=$(CDPATH= cd -- "${2:-$source_dir/../../../kit-emu}" && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/ssd-files-tests.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT
trap 'exit 1' HUP INT TERM

cd "$source_dir"
(cd ../../roms/video-mon && java -jar "$kickass" -libdir ../../lib -binfile video_mon.asm > /dev/null)
java -jar "$kickass" -libdir ../../roms/video-mon ssd_files.asm > /dev/null
javac -d "$work_dir/classes" "$emulator_dir"/*.java SsdFilesTest.java

# The emulator reads these from its working directory; the test changes a copy of the SSD
cp ../../roms/video-mon/video_mon.bin "$emulator_dir/ssd.bin" "$emulator_dir/character-set.png" "$work_dir"
cd "$work_dir"
status=0
java -ea -Djava.awt.headless=true -cp classes SsdFilesTest "$source_dir/ssd_files.prg" > log 2>&1 || status=$?
grep -v '^ERASE ' log || true
exit $status
