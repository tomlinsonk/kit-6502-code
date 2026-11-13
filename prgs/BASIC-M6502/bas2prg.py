#!/usr/bin/env python3
"""Turn a BASIC text file into a prg that saves it to the KiT's SSD.

The output is upload.prg (built with m6502.asm) with the tokenized
program appended. Load it with the monitor's l command and press r to
save the program as a data file, then LOAD it in BASIC.
"""

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUFLEN = 240
NAME_LEN = 16
SECTORS = 64


class BasicError(Exception):
    pass


def read_symbols(path):
    symbols = {}
    for line in path.read_text().splitlines():
        match = re.match(r"\.label (\w+)=\$([0-9a-fA-F]+)", line)
        if match:
            symbols[match.group(1)] = int(match.group(2), 16)
    return symbols


def read_prg(path):
    data = path.read_bytes()
    return data[0] | data[1] << 8, data[2:]


def read_keywords(basic_prg, reslst):
    load, data = read_prg(basic_prg)
    pos = reslst - load
    keywords = []
    while data[pos]:
        end = pos
        while data[end] < 0x80:
            end += 1
        keywords.append(bytes(data[pos:end]) + bytes([data[end] & 0x7F]))
        pos = end + 1
    return keywords


def uppercase(line):
    out = []
    quoted = False
    for ch in line:
        if ch == '"':
            quoted = not quoted
        elif not quoted and "a" <= ch <= "z":
            ch = ch.upper()
        out.append(ch)
    return "".join(out)


def crunch(body, keywords, tokens):
    """Tokenize a line body the way BASIC's CRUNCH does."""
    out = bytearray()
    crunching = True
    i = 0
    while i < len(body):
        ch = body[i]
        if ch == 0x22:
            end = body.find(b'"', i + 1)
            end = len(body) if end < 0 else end + 1
            out += body[i:end]
            i = end
            continue
        i += 1
        if ch != 0x20 and crunching:
            if ch == 0x3F:
                ch = tokens["PRINTK"]
            elif not 48 <= ch < 60:
                for index, word in enumerate(keywords):
                    start = i - 1
                    if body[start:start + len(word)] == word:
                        ch = 0x80 + index
                        i = start + len(word)
                        break
        out.append(ch)
        if ch == 0x3A:
            crunching = True
        elif ch == tokens["DATATK"]:
            crunching = False
        elif ch == tokens["REMTK"]:
            out += body[i:]
            break
    return bytes(out)


def parse_line(text, keywords, tokens):
    if len(text) > BUFLEN - 1:
        raise BasicError(f"line is longer than {BUFLEN - 1} characters")
    for ch in text:
        if not " " <= ch <= "~":
            raise BasicError(f"unsupported character {ch!r}")
    line = uppercase(text).encode("ascii")
    i = 0
    while i < len(line) and line[i] == 0x20:
        i += 1
    if i == len(line) or not chr(line[i]).isdigit():
        raise BasicError("missing line number")
    number = 0
    while i < len(line) and (chr(line[i]).isdigit() or line[i] == 0x20):
        if line[i] != 0x20:
            if number >= 6400:
                raise BasicError("line number is above 63999")
            number = number * 10 + line[i] - 48
        i += 1
    return number, crunch(line[i:], keywords, tokens)


def tokenize(source, keywords, tokens, txttab):
    lines = {}
    for line_no, text in enumerate(source.splitlines(), 1):
        text = text.rstrip("\r")
        if not text.strip():
            continue
        try:
            number, body = parse_line(text, keywords, tokens)
        except BasicError as error:
            raise BasicError(f"line {line_no}: {error}") from None
        if body:
            lines[number] = body
        else:
            lines.pop(number, None)
    if not lines:
        raise BasicError("no program lines")
    program = bytearray()
    for number in sorted(lines):
        body = lines[number]
        link = txttab + len(program) + 4 + len(body) + 1
        program += bytes([link & 0xFF, link >> 8, number & 0xFF, number >> 8])
        program += body + b"\0"
    return bytes(program + b"\0\0")


def check_name(name):
    if not 1 <= len(name) <= NAME_LEN:
        raise BasicError(f"name must be 1-{NAME_LEN} characters")
    if any(not " " <= ch <= "~" or ch == '"' for ch in name):
        raise BasicError("name must be printable and must not contain quotes")
    return name.encode("ascii")


def main():
    parser = argparse.ArgumentParser(
        description="Make a prg that saves a BASIC program to the KiT's SSD.")
    parser.add_argument("source", type=Path, help="BASIC program text")
    parser.add_argument("-o", "--output", type=Path,
                        help="output prg (default: SOURCE with .prg)")
    parser.add_argument("-n", "--name",
                        help="SSD file name (default: SOURCE file name)")
    parser.add_argument("-s", "--sector", type=lambda s: int(s, 0),
                        help="first sector, 0-63 (default: replace the file "
                             "with this name or use the first free sectors)")
    parser.add_argument("--basic-dir", type=Path, default=HERE,
                        help="directory with m6502.prg, m6502.sym, upload.prg")
    args = parser.parse_args()

    try:
        name = check_name(args.name if args.name is not None else args.source.stem)
        if args.sector is not None and not 0 <= args.sector < SECTORS:
            raise BasicError(f"sector must be 0-{SECTORS - 1}")
        symbols = read_symbols(args.basic_dir / "m6502.sym")
        keywords = read_keywords(args.basic_dir / "m6502.prg", symbols["RESLST"])
        upload_load, upload = read_prg(args.basic_dir / "upload.prg")
        if upload_load != symbols["upload"]:
            raise BasicError("upload.prg does not match m6502.sym; rebuild BASIC")
        program = tokenize(args.source.read_text(), keywords, symbols,
                           symbols["RAMLOC"] + 1)
        limit = symbols["upload_memtop"] - symbols["upload_program"]
        if len(program) > limit:
            raise BasicError(f"program is {len(program)} bytes; "
                             f"the limit is {limit}")
    except KeyError as error:
        sys.exit(f"bas2prg: missing symbol {error}; rebuild m6502.asm")
    except (BasicError, OSError) as error:
        sys.exit(f"bas2prg: {error}")

    stub = bytearray(upload[:symbols["upload_program"] - upload_load])

    def patch(label, data):
        offset = symbols[label] - upload_load
        stub[offset:offset + len(data)] = data

    patch("upload_name", name.ljust(NAME_LEN + 1, b"\0"))
    patch("upload_sector", bytes([0xFF if args.sector is None else args.sector]))
    patch("upload_size", len(program).to_bytes(2, "little"))
    output = args.output or args.source.with_suffix(".prg")
    output.write_bytes(upload_load.to_bytes(2, "little") + stub + program)
    where = "first free sectors" if args.sector is None else f"sector {args.sector}"
    print(f"{output}: {len(program)} bytes, saves as \"{name.decode()}\" to {where}")


if __name__ == "__main__":
    main()
