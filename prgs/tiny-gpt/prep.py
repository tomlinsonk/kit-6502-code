"""Normalize a corpus and encode it with a char or BPE tokenizer.

Stories (TinyStories, data/TinyStoriesV2-GPT4-*.txt):
    python prep.py --chars 300000000            # write data/stories-{train,val}.txt
    python prep.py --tok char                   # data/char.json, data/char-{train,val}.npy
    python prep.py --tok bpe --vocab 128        # data/bpe128.json, data/bpe128-{train,val}.npy

Paper titles (arXiv metadata parquet files in data/arxiv/):
    python prep.py --titles                     # write data/titles-{train,val}.txt
    python prep.py --corpus titles --tok bpe --vocab 256    # data/titles-bpe256.*
"""
import argparse
import glob
import json
import os
import random
import re
import unicodedata
from collections import Counter

import numpy as np

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data')
EOS = '\x00'                                         # end of story or title, always token 0
CHARS = EOS + "\n !\"',-.?abcdefghijklmnopqrstuvwxyz"
TITLE_CHARS = EOS + " !\"&'()+,-./0123456789:?abcdefghijklmnopqrstuvwxyz"
REPLACE = {'\u2019': "'", '\u2018': "'", '\u201c': '"', '\u201d': '"', '\u2014': '-', '\u2013': '-',
           '\u2026': '...', ':': ',', ';': ',', '`': "'", '\x92': "'", '\x93': '"', '\x94': '"'}
TITLE_REPLACE = {'`': "'", ';': ',', '[': '(', ']': ')'}
PRETOKEN = re.compile(r" ?[a-z0-9']+| ?[^a-z0-9'\n \x00]+|\n|\x00| ")


def normalize(story):
    s = story.strip().lower()
    for a, b in REPLACE.items():
        s = s.replace(a, b)
    s = re.sub(r'[ \t]+', ' ', s)
    s = re.sub(r' *\n[\n ]*', '\n', s)
    if not s or any(c not in CHARS[1:] for c in s):
        return None
    return s


def normalize_title(title):
    t = unicodedata.normalize('NFKD', title)
    t = ''.join(ch for ch in t if not unicodedata.combining(ch))
    t = ' '.join(t.split()).lower()
    for a, b in TITLE_REPLACE.items():
        t = t.replace(a, b)
    if not t or any(c not in TITLE_CHARS[1:] for c in t):
        return None
    return t


def write_titles(n_val=20000):
    import pyarrow.parquet as pq
    titles = []
    for f in sorted(glob.glob(os.path.join(DATA, 'arxiv', '*.parquet'))):
        titles += pq.read_table(f, columns=['title'])['title'].to_pylist()
    kept = [t for t in map(normalize_title, titles) if t]
    random.Random(0).shuffle(kept)
    for split, part in (('val', kept[:n_val]), ('train', kept[n_val:])):
        with open(os.path.join(DATA, f'titles-{split}.txt'), 'w') as f:
            f.write(EOS.join(part) + EOS)
        print(f'{split}: {len(part)} titles, {sum(len(t) + 1 for t in part)} chars')
    print(f'dropped {len(titles) - len(kept)} of {len(titles)} titles')


def write_text(n_chars):
    for split, src in (('val', 'TinyStoriesV2-GPT4-valid.txt'), ('train', 'TinyStoriesV2-GPT4-train.txt')):
        out, total, dropped = [], 0, 0
        buf = ''
        with open(os.path.join(DATA, src), encoding='utf-8', errors='replace') as f:
            for line in f:
                if '<|endoftext|>' not in line:
                    buf += line
                    continue
                s = normalize(buf + line.split('<|endoftext|>')[0])
                buf = ''
                if s is None:
                    dropped += 1
                    continue
                out.append(s)
                total += len(s) + 1
                if split == 'train' and total >= n_chars:
                    break
        with open(os.path.join(DATA, f'stories-{split}.txt'), 'w') as f:
            f.write(EOS.join(out) + EOS)
        print(f'{split}: {len(out)} stories, {total} chars, dropped {dropped}')


def train_bpe(text, vocab_size, chars):
    words = Counter(PRETOKEN.findall(text))
    vocab = list(chars)
    words = {tuple(vocab.index(c) for c in w): n for w, n in words.items()}
    merges = []
    while len(vocab) < vocab_size:
        pairs = Counter()
        for w, n in words.items():
            for a, b in zip(w, w[1:]):
                pairs[a, b] += n
        (a, b), _ = pairs.most_common(1)[0]
        new = len(vocab)
        vocab.append(vocab[a] + vocab[b])
        merges.append((a, b))
        merged = {}
        for w, n in words.items():
            out, i = [], 0
            while i < len(w):
                if i + 1 < len(w) and w[i] == a and w[i + 1] == b:
                    out.append(new)
                    i += 2
                else:
                    out.append(w[i])
                    i += 1
            merged[tuple(out)] = merged.get(tuple(out), 0) + n
        words = merged
    return vocab, merges


def bpe_encode_word(word, merges, vocab):
    nchars = len(vocab) - len(merges)
    ids = [vocab.index(c) for c in word]
    for r, (a, b) in enumerate(merges):
        if len(ids) < 2:
            break
        out, i = [], 0
        while i < len(ids):
            if i + 1 < len(ids) and ids[i] == a and ids[i + 1] == b:
                out.append(nchars + r)
                i += 2
            else:
                out.append(ids[i])
                i += 1
        ids = out
    return ids


def encode(text, tok):
    if tok['type'] == 'char':
        lut = np.zeros(256, dtype=np.uint8)
        for i, c in enumerate(tok['vocab']):
            lut[ord(c)] = i
        return lut[np.frombuffer(text.encode('ascii'), dtype=np.uint8)]
    cache, out = {}, []
    merges = [tuple(m) for m in tok['merges']]
    for w in PRETOKEN.findall(text):
        ids = cache.get(w)
        if ids is None:
            ids = cache[w] = bpe_encode_word(w, merges, tok['vocab'])
        out.extend(ids)
    return np.array(out, dtype=np.uint8 if len(tok['vocab']) <= 256 else np.uint16)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--chars', type=int, default=0, help='write normalized text with this many train chars')
    p.add_argument('--tok', choices=['char', 'bpe'])
    p.add_argument('--vocab', type=int, default=128)
    p.add_argument('--titles', action='store_true', help='write normalized arXiv titles')
    p.add_argument('--corpus', default='stories', choices=['stories', 'titles'])
    args = p.parse_args()
    if args.chars:
        write_text(args.chars)
    if args.titles:
        write_titles()
    if not args.tok:
        return
    train = open(os.path.join(DATA, f'{args.corpus}-train.txt')).read()
    val = open(os.path.join(DATA, f'{args.corpus}-val.txt')).read()
    chars = CHARS if args.corpus == 'stories' else TITLE_CHARS
    prefix = '' if args.corpus == 'stories' else args.corpus + '-'
    if args.tok == 'char':
        name, tok = prefix + 'char', {'type': 'char', 'vocab': list(chars), 'merges': []}
    else:
        name = f'{prefix}bpe{args.vocab}'
        vocab, merges = train_bpe(train[:20_000_000], args.vocab, chars)
        tok = {'type': 'bpe', 'vocab': vocab, 'merges': merges}
    tok['val_chars'] = len(val)
    json.dump(tok, open(os.path.join(DATA, f'{name}.json'), 'w'))
    for split, text in (('train', train), ('val', val)):
        ids = encode(text, tok)
        np.save(os.path.join(DATA, f'{name}-{split}.npy'), ids)
        print(f'{name} {split}: {len(text)} chars -> {len(ids)} tokens ({len(text) / len(ids):.2f} chars/token)')
    if tok['type'] == 'bpe':
        print(' '.join(repr(v) for v in tok['vocab'][len(chars):]))


if __name__ == '__main__':
    main()
