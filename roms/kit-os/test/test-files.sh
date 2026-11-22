#!/bin/sh
# Usage: ./test-files.sh [path/to/KickAss.jar] [path/to/kit-emu]
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
kickass=${1:-$source_dir/../../../KickAss.jar}
case $kickass in /*) ;; *) kickass=$PWD/$kickass ;; esac
emulator_dir=$(CDPATH= cd -- "${2:-$source_dir/../../../../kit-emu}" && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/kit-os-files-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
trap 'exit 1' HUP INT TERM

cd "$source_dir/.."
java -jar "$kickass" -libdir ../../lib -binfile kit_os.asm > "$build_dir/kickass.log" \
    || { cat "$build_dir/kickass.log"; exit 1; }
mkdir "$build_dir/classes" "$build_dir/run"
javac -d "$build_dir/classes" "$emulator_dir"/*.java "$source_dir/FilesTest.java"

# The emulator reads these from its working directory; the test changes a copy of the SSD
cp kit_os.bin "$emulator_dir/character-set.png" "$build_dir/run"
# The tests expect the files on kit-emu's committed SSD image.
git -C "$emulator_dir" show HEAD:ssd.bin > "$build_dir/run/ssd.bin" 2>/dev/null ||
    cp "$emulator_dir/ssd.bin" "$build_dir/run"
sym=$PWD/kit_os.sym
cd "$build_dir/run"
status=0
java -ea -Djava.awt.headless=true -cp "$build_dir/classes" FilesTest "$sym" > log 2>&1 || status=$?
grep -v '^ERASE ' log || true
exit $status
