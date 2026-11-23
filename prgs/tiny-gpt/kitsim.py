"""Integer model for the KiT: export a trained checkpoint and simulate the 6502 arithmetic exactly.

    python kitsim.py runs/NAME/model.pt --eval 200       # compare float vs integer bits per char
    python kitsim.py runs/NAME/model.pt --sample 3       # integer samples
"""
import argparse
import json
import math
import os

import numpy as np
import torch

import train

HERE = os.path.dirname(os.path.abspath(__file__))
EXP_UNIT = 32            # attention and logit scores are in 1/32 nat
XMAX = 8191              # residual saturation, keeps sum of squares under 2^32


def rshift(v, k):
    """Round half up, then arithmetic shift right (what the 6502 does)."""
    v = np.asarray(v, dtype=np.int64)
    return (v + (1 << (k - 1))) >> k if k > 0 else v << -k


def quant_rows(w, bits=4):
    """Same clip search as train.fake_quant_rows; returns integer levels and float row scales."""
    w = torch.as_tensor(w, dtype=torch.float32)
    qmax = 2 ** (bits - 1) - 1
    amax = w.abs().amax(dim=1, keepdim=True).clamp_min(1e-8)
    best, best_err = None, None
    for c in (1.0, 0.95, 0.9, 0.85, 0.8, 0.75, 0.7, 0.65, 0.6):
        s = amax * c / qmax
        err = ((torch.clamp(torch.round(w / s), -qmax - 1, qmax) * s - w) ** 2).sum(dim=1, keepdim=True)
        if best is None:
            best, best_err = s, err
        else:
            better = err < best_err
            best = torch.where(better, s, best)
            best_err = torch.where(better, err, best_err)
    q = torch.clamp(torch.round(w / best), -qmax - 1, qmax)
    return q.numpy().astype(np.int64), best[:, 0].numpy().astype(np.float64)


def multipliers(f):
    """Approximate positive factors f_i as m_i / 2^k with 8-bit m_i and one shift for the whole vector."""
    f = np.asarray(f, dtype=np.float64)
    k = int(math.floor(math.log2(255.5 / f.max())))
    m = np.round(f * 2.0 ** k).astype(np.int64)
    assert m.max() <= 255 and k >= 1, (m.max(), k)
    return m, k


EXP = np.array([int(round(255 * math.exp(-i / EXP_UNIT))) for i in range(256)], dtype=np.int64)
RSQ = np.array([int(round(2 ** 22 / math.sqrt(i * 256 + 128))) if i >= 64 else 0 for i in range(256)],
               dtype=np.int64)


def isqrt_norm(S):
    """Normalize S = M * 4^e with M in [2^14, 2^16); returns (RSQ[M >> 8], e)."""
    S = np.asarray(S, dtype=np.int64)
    e = np.zeros_like(S)
    M = S.copy()
    for _ in range(16):
        big = M >= 1 << 16
        M = np.where(big, M >> 2, M)
        e = e + big
    for _ in range(16):
        small = (M < 1 << 14) & (M > 0)
        M = np.where(small, M << 2, M)
        e = e - small
    return RSQ[np.clip(M >> 8, 0, 255)], e


@torch.no_grad()
def calibrate(model, data, n=64, T=None):
    """Record activation magnitudes from the fake-quant float model."""
    c = model.c
    T = T or c['ctx']
    gen = torch.Generator().manual_seed(99)
    x, _ = train.batches(data, n, T, gen)
    stats = {}

    def rec(name, t):
        a = t.abs().flatten().numpy()
        stats.setdefault(name, []).append(a)

    emb = model.emb.qweight()
    xs = torch.nn.functional.embedding(x, emb)
    rec('x', xs)
    bias = model.attn_bias(T)
    for li, b in enumerate(model.blocks):
        B_, T_, _ = xs.shape
        hd, H = c['head_dim'], c['heads']
        hn = b.n1(xs)
        rec(f'h1.{li}', hn)
        q = b.q(hn)
        k = b.k(hn)
        v = b.v(hn)
        rec(f'q.{li}', q)
        rec(f'k.{li}', k)
        rec(f'v.{li}', v)
        qh = q.view(B_, T_, H, hd).transpose(1, 2)
        kh = k.view(B_, T_, 1, hd).transpose(1, 2).expand(-1, H, -1, -1)
        rec(f'score.{li}', (qh @ kh.transpose(-1, -2)).tril())
        vh = v.view(B_, T_, 1, hd).transpose(1, 2).expand(-1, H, -1, -1)
        a = torch.nn.functional.scaled_dot_product_attention(qh, kh, vh, attn_mask=bias)
        xs = xs + b.o(a.transpose(1, 2).reshape(B_, T_, H * hd))
        rec('x', xs)
        h2 = b.n2(xs)
        rec(f'h2.{li}', h2)
        u = torch.relu(b.up(h2))
        rec(f'u.{li}', u)
        xs = xs + b.down(u)
        rec('x', xs)
    hf = model.norm(xs)
    rec('hf', hf / model.norm.g)
    return {k: np.concatenate(v) for k, v in stats.items()}


def export(ckpt_path, calib_n=64, window=32):
    ck = torch.load(ckpt_path)
    c = ck['cfg']
    assert c['kv_heads'] == 1 and c['loops'] == 1 and c['act'] == 'relu'
    train.QLinear.lsq = c.get('lsq', False)
    model = train.GPT(c)
    missing = model.load_state_dict(ck['model'], strict=False)
    assert not missing.unexpected_keys and all('log_s' in k or 'qinit' in k for k in missing.missing_keys)
    assert not (c.get('lsq') and c.get('inner_gain', True)), 'LSQ export needs --inner-gain 0'
    model.eval()
    train.QLinear.bits = c['bits']
    tok = json.load(open(os.path.join(train.DATA, f"{c['tok']}.json")))
    val = np.load(os.path.join(train.DATA, f"{c['tok']}-val.npy"), mmap_mode='r')
    st = calibrate(model, val, calib_n)
    pct = lambda name, p=99.99: float(np.percentile(st[name], p))
    d, H, hd, L = c['d'], c['heads'], c['head_dim'], c['layers']

    xmax = max(float(st['x'].max()), 1e-3)
    RX = int(math.floor(math.log2(XMAX / 2 / xmax)))
    img = dict(cfg=c, RX=RX, W=window, tok=tok, layers=[], stats={k: (pct(k), float(st[k].max())) for k in st})

    def levels(mod, gain=None):
        W = mod.weight.detach().numpy().astype(np.float64)
        if c.get('lsq'):
            s = np.exp(mod.log_s.detach().numpy()[:, 0].astype(np.float64))
            return np.clip(np.round(W / s[:, None]), -8, 7).astype(np.int64), s
        if gain is not None:
            W = W * gain[None, :]
        return quant_rows(W, 4)

    def requant(mod, in_scale, out_scale, gain=None):
        lv, s = levels(mod, gain)
        m, k = multipliers(s * out_scale / in_scale)
        return dict(lv=lv, m=m, k=k)

    for li, b in enumerate(model.blocks):
        g1 = b.n1.g.detach().numpy().astype(np.float64)
        g2 = b.n2.g.detach().numpy().astype(np.float64)
        SH1 = 127 / pct(f'h1.{li}')
        SH2 = 127 / pct(f'h2.{li}')
        SQ = 127 / pct(f'q.{li}')
        SK = 127 / pct(f'k.{li}')
        # keep the largest q.k seen with a 2x margin inside 16 bits
        peak = float(st[f'score.{li}'].max()) * SQ * SK * 2
        if peak > 32767:
            SQ, SK = SQ * math.sqrt(32767 / peak), SK * math.sqrt(32767 / peak)
        SV = 127 / pct(f'v.{li}')
        SU = 127 / pct(f'u.{li}')
        lay = dict(
            SH1=SH1, SH2=SH2,
            q=requant(b.q, SH1, SQ, g1),
            k=requant(b.k, SH1, SK, g1),
            v=requant(b.v, SH1, SV, g1),
            o=requant(b.o, SV, 2.0 ** RX),
            up=requant(b.up, SH2, SU, g2),
            down=requant(b.down, SU, 2.0 ** RX),
        )
        # attention score multiplier: z = score * A >> kA, z in 1/32 nat
        a = EXP_UNIT / (math.sqrt(hd) * SQ * SK)
        kA = int(math.floor(math.log2(255.5 / a)))
        lay['A'], lay['kA'] = int(round(a * 2 ** kA)), kA
        rel = model.rel.detach().numpy() if c['pos'] != 'none' else np.zeros((H, c['ctx']))
        lay['bias'] = np.clip(np.round(rel[:, :window] * EXP_UNIT), -32768, 32767).astype(np.int64)
        lay['n1'] = norm_const(SH1, d)
        lay['n2'] = norm_const(SH2, d)
        img['layers'].append(lay)

    # tied embedding: 4-bit rows; one multiplier set for input, one for logits
    SF = 127 / pct('hf')
    lv, s = levels(model.emb)
    m_in, k_in = multipliers(s * 2.0 ** RX)
    m_out, k_out = multipliers(s * EXP_UNIT / SF)
    img['emb'] = dict(lv=lv, m_in=m_in, k_in=k_in, m=m_out, k=k_out)
    g = model.norm.g.detach().numpy().astype(np.float64)
    kg = int(math.floor(math.log2(127.5 / np.abs(g).max())))
    img['gf'] = np.round(g * 2 ** kg).astype(np.int64)
    img['kg'] = kg
    img['nf'] = norm_const(SF, d, extra=4)
    return img, model


def norm_const(S, d, extra=0):
    """h = x * S * sqrt(d) / sqrt(sum x^2): C = S*sqrt(d)*2^s fits 16 bits, applied as (RSQ*C)>>16."""
    v = S * math.sqrt(d) * 2 ** extra
    s = int(math.floor(math.log2(65535.5 / v)))
    return dict(C=int(round(v * 2 ** s)), s=s)


class Sim:
    """Integer inference, vectorized over B independent sequences."""

    def __init__(self, img, B=1):
        self.img, self.B = img, B
        c = img['cfg']
        self.W = img['W']
        self.reset()
        self.overflow = {}
        self.peak = {}

    def reset(self):
        c = self.img['cfg']
        L, hd = c['layers'], c['head_dim']
        self.K = np.zeros((L, self.B, self.W, hd), dtype=np.int64)
        self.V = np.zeros((L, self.B, self.W, hd), dtype=np.int64)
        self.n = 0

    def wrap16(self, v, what):
        v = np.asarray(v, dtype=np.int64)
        self.peak[what] = max(self.peak.get(what, 0), int(np.abs(v).max()))
        n = int(((v > 32767) | (v < -32768)).sum())
        if n:
            self.overflow[what] = self.overflow.get(what, 0) + n
        return ((v + 32768) & 0xFFFF) - 32768

    def matvec(self, M, x, what='acc'):
        """acc_i = sum_j lv_ij * x_j (16-bit wrap)."""
        return self.wrap16(x @ M['lv'].T, what)

    def requant(self, M, acc):
        return rshift(acc * M['m'], M['k'])

    def normq(self, x, nc):
        # x * S*sqrt(d) / sqrt(sum x^2) = x * F >> (6 + e + s), F = RSQ * C >> 16
        S = (x * x).sum(-1)
        r, e = isqrt_norm(S)
        F = (r * nc['C']) >> 16
        sh = 6 + e + nc['s']
        return np.stack([rshift(x[b] * F[b], int(sh[b])) for b in range(x.shape[0])])

    def step(self, tok, trace=None):
        """tok: (B,) int array. Returns logits z (B, V) in 1/32 nat. trace: dict to record intermediates."""
        rec = (lambda k, v: trace.__setitem__(k, np.array(v[0]))) if trace is not None else (lambda k, v: None)
        img = self.img
        c = img['cfg']
        H, hd, W = c['heads'], c['head_dim'], self.W
        tok = np.asarray(tok)
        E = img['emb']
        x = rshift(E['lv'][tok] * E['m_in'][tok][:, None], E['k_in'])
        x = np.clip(x, -XMAX, XMAX)
        rec('x0', x)
        slot = self.n % W
        count = min(self.n + 1, W)
        slots = np.array([(slot - dd) % W for dd in range(count)])   # distance dd -> slot
        for li, lay in enumerate(img['layers']):
            h = np.clip(self.normq(x, lay['n1']), -127, 127)
            rec(f'h1.{li}', h)
            q = np.clip(self.requant(lay['q'], self.matvec(lay['q'], what='q', x=h)), -127, 127)
            k = np.clip(self.requant(lay['k'], self.matvec(lay['k'], what='k', x=h)), -127, 127)
            v = np.clip(self.requant(lay['v'], self.matvec(lay['v'], what='v', x=h)), -127, 127)
            rec(f'q.{li}', q)
            rec(f'k.{li}', k)
            rec(f'v.{li}', v)
            self.K[li, :, slot] = k
            self.V[li, :, slot] = v
            Ks = self.K[li][:, slots]                       # (B, count, hd)
            Vs = self.V[li][:, slots]
            o = np.zeros((self.B, H * hd), dtype=np.int64)
            for hh in range(H):
                qh = q[:, hh * hd:(hh + 1) * hd]
                score = self.wrap16((Ks * qh[:, None, :]).sum(-1), 'score')      # (B, count)
                z = rshift(score * lay['A'], lay['kA']) + lay['bias'][hh, :count][None, :]
                z = np.clip(z, -32768, 32767)
                mx = z.max(-1, keepdims=True)
                e = EXP[np.minimum(mx - z, 255)]
                R = 65536 // e.sum(-1, keepdims=True)
                p = np.minimum((e * R) >> 8, 255)
                ov = self.wrap16((p[:, :, None] * Vs).sum(1), 'o')
                o[:, hh * hd:(hh + 1) * hd] = np.clip(rshift(ov, 8), -127, 127)
            rec(f'o.{li}', o)
            x = np.clip(x + self.requant(lay['o'], self.matvec(lay['o'], what='o', x=o)), -XMAX, XMAX)
            rec(f'xa.{li}', x)
            h = np.clip(self.normq(x, lay['n2']), -127, 127)
            rec(f'h2.{li}', h)
            u = self.requant(lay['up'], self.matvec(lay['up'], what='up', x=h))
            u = np.clip(u, 0, 127)
            rec(f'u.{li}', u)
            x = np.clip(x + self.requant(lay['down'], self.matvec(lay['down'], what='down', x=u)), -XMAX, XMAX)
            rec(f'xf.{li}', x)
        hf = self.normq(x, img['nf'])                        # 4 extra fraction bits
        hf = np.clip(rshift(hf * img['gf'][None, :], img['kg'] + 4), -127, 127)
        rec('hf', hf)
        acc = self.wrap16(hf @ E['lv'].T, 'logit')
        z = rshift(acc * E['m'][None, :], E['k'])
        rec('z', z)
        self.n += 1
        return z


class Rng:
    """xorshift16 (7, 9, 8), as on the 6502."""

    def __init__(self, seed=1):
        self.x = seed & 0xFFFF or 1

    def next(self):
        x = self.x
        x ^= (x << 7) & 0xFFFF
        x ^= x >> 9
        x ^= (x << 8) & 0xFFFF
        self.x = x
        return x


def sample_token(z, rng, temp_mul=320, cutoff=0):
    """z: (V,) logits in 1/32 nat. temp_mul = 256 / temperature."""
    zz = rshift(np.asarray(z) * temp_mul, 8)
    e = EXP[np.minimum(zz.max() - zz, 255)]
    e = np.where(e < cutoff, 0, e)
    total = int(e.sum())
    r = (rng.next() * total) >> 16
    cum = np.cumsum(e)
    return int(np.searchsorted(cum, r, side='right'))


def decode(tok, ids):
    return ''.join(tok['vocab'][i] for i in ids).replace('\x00', '|')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('ckpt')
    p.add_argument('--eval', type=int, default=0, help='number of val sequences to score')
    p.add_argument('--sample', type=int, default=0)
    p.add_argument('--len', type=int, default=200)
    p.add_argument('--temp', type=float, default=256 / 384, help='as TEMP_MUL in tinygpt.asm')
    p.add_argument('--cutoff', type=int, default=20, help='as CUTOFF in tinygpt.asm')
    args = p.parse_args()
    img, model = export(args.ckpt)
    c = img['cfg']
    print('RX', img['RX'], 'stats', {k: tuple(round(x, 2) for x in v) for k, v in img['stats'].items()})
    if args.eval:
        val = np.load(os.path.join(train.DATA, f"{c['tok']}-val.npy"), mmap_mode='r')
        cpt = img['tok'].get('val_chars', 21881417) / len(val)
        T = c['ctx'] * 2
        gen = torch.Generator().manual_seed(7)
        x, y = train.batches(val, args.eval, T, gen)
        # float reference with the same sliding window as the integer model
        sim = Sim(img, B=args.eval)
        nll_i, nll_f = [], []
        for t in range(T):
            z = sim.step(x[:, t].numpy())
            lp = z / EXP_UNIT
            lp = lp - lp.max(-1, keepdims=True)
            lp = lp - np.log(np.exp(lp).sum(-1, keepdims=True))
            nll_i.append(-lp[np.arange(args.eval), y[:, t].numpy()])
            with torch.no_grad():
                lo = max(0, t + 1 - sim.W)
                lf = torch.log_softmax(model(x[:, lo:t + 1])[:, -1], -1)
            nll_f.append(-lf[torch.arange(args.eval), y[:, t]].numpy())
        nll_i, nll_f = np.array(nll_i), np.array(nll_f)
        f = lambda a: a.mean() / cpt / math.log(2)
        print(f'bpc float {f(nll_f):.4f} int {f(nll_i):.4f}  (second half: float {f(nll_f[T//2:]):.4f} '
              f'int {f(nll_i[T//2:]):.4f})  overflows {sim.overflow}')
        print('peak |acc|', sim.peak)
    for s in range(args.sample):
        sim = Sim(img)
        rng = Rng(1234 + s)
        ids = [0]
        tm = int(round(256 / args.temp))
        for _ in range(args.len):
            z = sim.step(np.array([ids[-1]]))[0]
            ids.append(sample_token(z, rng, tm, args.cutoff))
            if ids[-1] == 0:
                break
        print(f'--- sample {s}:', decode(img['tok'], ids))


if __name__ == '__main__':
    main()
