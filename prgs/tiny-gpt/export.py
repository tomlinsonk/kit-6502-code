"""Pack a trained model for the KiT.

    python export.py models/titles/model.pt      # write build/titles/model.inc, tables.inc, weights.bin, ...

The model's name is its directory name. The weights live in a KSF data file (lib/ssd.lib) named
"<name>-weights", one 4 KB sector per part, with
3840 bytes of data per sector at $8100-$8fff. The data stream starts with a parameter blob that the
program copies to RAM (row multipliers, attention biases, BPE merges), followed by 4-bit weight
matrices stored column by column. A column never straddles two sectors.
"""
import argparse
import hashlib
import math
import os

import numpy as np

import kitsim
import pack

HERE = os.path.dirname(os.path.abspath(__file__))
SECTOR_DATA = 3840
DATA_START = 0x8100
MAX_SECTORS = 8
CHUNK = 64                      # rows per matrix-vector pass (zero-page accumulators)
MAGIC = b'KGPT'


class Stream:
    def __init__(self):
        self.sectors = [bytearray()]

    def pos(self):
        return len(self.sectors) - 1, DATA_START + len(self.sectors[-1])

    def put(self, data, column=False):
        """Append bytes; a column moves to the next sector if it doesn't fit."""
        data = bytes(data)
        if column:
            assert len(data) <= SECTOR_DATA
            if len(self.sectors[-1]) + len(data) > SECTOR_DATA:
                self.sectors.append(bytearray())
            self.sectors[-1] += data
            return
        while data:
            room = SECTOR_DATA - len(self.sectors[-1])
            if room == 0:
                self.sectors.append(bytearray())
                continue
            self.sectors[-1] += data[:room]
            data = data[room:]

    def size(self):
        return sum(len(s) for s in self.sectors)


def pack_columns(lv):
    """lv: (rows, cols) ints in [-8, 7]. Byte k of column j holds rows 2k (low nibble) and 2k+1."""
    rows, cols = lv.shape
    assert rows % 2 == 0 and lv.min() >= -8 and lv.max() <= 7
    u = (lv + 8).astype(np.uint8)
    return [bytes(u[0::2, j] | (u[1::2, j] << 4)) for j in range(cols)]


def u8(a):
    a = np.asarray(a)
    assert a.min() >= 0 and a.max() <= 255, (a.min(), a.max())
    return bytes(a.astype(np.uint8))


def s8(a):
    a = np.asarray(a)
    assert a.min() >= -128 and a.max() <= 127
    return bytes((a & 0xFF).astype(np.uint8))


def build(img):
    c = img['cfg']
    tok = img['tok']
    D, H, HD, L, FF, V, W = c['d'], c['heads'], c['head_dim'], c['layers'], c['ff'], c['vocab'], img['W']
    assert H * HD == D and V % CHUNK == 0 and D <= CHUNK and 2 * HD <= CHUNK and W == 32
    merges = np.array(tok['merges']).reshape(-1, 2)
    nchars = len(tok['vocab']) - len(merges)
    model_id = hashlib.sha1(repr(img['emb']['lv'].tolist()).encode()).digest()[:4]

    dims = dict(DM=D, NH=H, HD=HD, NL=L, FF=FF, NV=V, NW=W, NCHARS=nchars, NMERGE=len(merges),
                VCHUNKS=V // CHUNK)
    consts = dict(EMB_KIN=img['emb']['k_in'], EMB_K=img['emb']['k'], KG=img['kg'],
                  NF_C=img['nf']['C'], NF_S=img['nf']['s'])
    mats = {}
    blob = bytearray(MAGIC + model_id)
    offs = {}

    def add(name, data):
        offs[name] = len(blob)
        blob.extend(data)

    add('EMB_MIN', u8(img['emb']['m_in']))
    add('EMB_M', u8(img['emb']['m']))
    add('GF', s8(img['gf']))
    add('MERGE_A', u8(merges[:, 0]))
    add('MERGE_B', u8(merges[:, 1]))
    for i, lay in enumerate(img['layers']):
        p = f'L{i}_'
        for m in ('q', 'k', 'v', 'o', 'up', 'down'):
            add(p + m.upper() + 'M', u8(lay[m]['m']))
            consts[p + m.upper() + 'K'] = lay[m]['k']
        b = lay['bias'][:, :W].reshape(-1)
        add(p + 'BIASL', u8(b & 0xFF))
        add(p + 'BIASH', u8((b >> 8) & 0xFF))
        consts[p + 'ATT_A'], consts[p + 'ATT_KA'] = lay['A'], lay['kA']
        for n in ('n1', 'n2'):
            consts[p + n.upper() + '_C'], consts[p + n.upper() + '_S'] = lay[n]['C'], lay[n]['s']

    st = Stream()
    st.put(blob)
    dims['BLOB_SIZE'] = len(blob)

    def matrix(name, lv):
        cols = pack_columns(lv)
        sec, addr = st.pos()
        if addr + len(cols[0]) > DATA_START + SECTOR_DATA:
            sec, addr = sec + 1, DATA_START
        mats[name] = (sec, addr) + lv.shape
        for col in cols:
            st.put(col, column=True)

    E = img['emb']['lv']
    for ch in range(V // CHUNK):
        matrix(f'EMB{ch}', E[ch * CHUNK:(ch + 1) * CHUNK])
    for i, lay in enumerate(img['layers']):
        p = f'L{i}_'
        matrix(p + 'Q', lay['q']['lv'])
        matrix(p + 'KV', np.concatenate([lay['k']['lv'], lay['v']['lv']]))
        matrix(p + 'O', lay['o']['lv'])
        up = lay['up']['lv']
        for ch in range(0, FF, CHUNK):
            matrix(p + f'UP{ch // CHUNK}', up[ch:ch + CHUNK])
        matrix(p + 'DOWN', lay['down']['lv'])

    n = len(st.sectors)
    print(f'blob {len(blob)} bytes, stream {st.size()} bytes in {n} sectors '
          f'({n * SECTOR_DATA - st.size()} unused)')
    assert n <= MAX_SECTORS, f'model needs {n} sectors'
    dims['NSECTORS'] = n
    return dict(dims=dims, consts=consts, mats=mats, offs=offs, model_id=model_id), [bytes(s) for s in st.sectors]


def write_inc(path, m, name):
    """Dimensions as constants; per-model scalars (MC), matrix stream positions (MAT: sector index,
    address, rows, cols) and blob offsets (PO) as hashtables the program's macros look up by name."""
    with open(path, 'w') as f:
        f.write('// Generated by export.py\n')
        f.write(f'.var NAME = "{name}"\n.var WEIGHTS_NAME = "{pack.weights_name(name)}"\n')
        for k, v in m['dims'].items():
            f.write(f'.const {k} = {v}\n')
        f.write('.var MC = Hashtable()\n')
        for k, v in m['consts'].items():
            f.write(f'.eval MC.put("{k}", {v})\n')
        f.write('.var MAT = Hashtable()\n')
        for k, v in m['mats'].items():
            f.write(f'.eval MAT.put("{k}", List().add(' + ', '.join(str(int(x)) for x in v) + '))\n')
        f.write('.var PO = Hashtable()\n')
        for k, v in m['offs'].items():
            f.write(f'.eval PO.put("{k}", {v})\n')
        f.write('.var MODEL_ID = List().add(' + ', '.join(f'${b:02x}' for b in m['model_id']) + ')\n')


def write_tables(path, chars):
    """Model-independent tables the program carries: exp, 1/sqrt, characters."""
    rsq = kitsim.RSQ
    with open(path, 'w') as f:
        f.write('// Generated by export.py\n.align $100\nexp_table:\n')
        for i in range(0, 256, 16):
            f.write('    .byte ' + ', '.join(str(v) for v in kitsim.EXP[i:i + 16]) + '\n')
        f.write('rsq_lo:\n')
        for i in range(64, 256, 16):
            f.write('    .byte ' + ', '.join(str(v & 255) for v in rsq[i:i + 16]) + '\n')
        f.write('rsq_hi:\n')
        for i in range(64, 256, 16):
            f.write('    .byte ' + ', '.join(str(v >> 8) for v in rsq[i:i + 16]) + '\n')
        f.write('chars:\n    .byte ' + ', '.join(str(ord(ch)) for ch in chars) + '\n')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('ckpt')
    p.add_argument('--name', help='model name (default: the checkpoint directory name)')
    p.add_argument('--out', help='default: build/NAME')
    args = p.parse_args()
    name = args.name or os.path.basename(os.path.dirname(os.path.abspath(args.ckpt)))
    out = args.out or os.path.join(HERE, 'build', name)
    os.makedirs(out, exist_ok=True)
    img, _ = kitsim.export(args.ckpt)
    m, sectors = build(img)
    tok = img['tok']
    write_inc(os.path.join(out, 'model.inc'), m, name)
    write_tables(os.path.join(out, 'tables.inc'), tok['vocab'][:len(tok['vocab']) - len(tok['merges'])])
    data = b''.join(s.ljust(SECTOR_DATA, b'\xff') for s in sectors)
    with open(os.path.join(out, 'weights.bin'), 'wb') as f:
        f.write(data)
    # KSF header templates for the installer (next-sector link filled in on the KiT)
    with open(os.path.join(out, 'headers.bin'), 'wb') as f:
        for i in range(len(sectors)):
            f.write(pack.header(i, len(sectors), data, 0x20, 0, pack.weights_name(name).encode(), 0))
    np.save(os.path.join(out, 'img.npy'), img, allow_pickle=True)
    print('wrote', out)


if __name__ == '__main__':
    main()
