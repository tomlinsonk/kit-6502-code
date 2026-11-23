"""Train a tiny GPT for the KiT.

    python train.py --name c64 --tok char --d 64 --layers 2 --ff 128 --ctx 128 --minutes 20
"""
import argparse
import json
import math
import os
import time

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, 'data')


def fake_quant_rows(w, bits):
    """Symmetric per-row quantization with a clip search, straight-through gradient."""
    if not bits:
        return w
    qmax = 2 ** (bits - 1) - 1
    with torch.no_grad():
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
    q = torch.clamp(torch.round(w / best), -qmax - 1, qmax) * best
    return w + (q - w).detach()


def mse_scale(w, bits):
    """Per-row scale minimizing quantization MSE (same search as fake_quant_rows)."""
    qmax = 2 ** (bits - 1) - 1
    with torch.no_grad():
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
    return best


def lsq_quant(w, log_s, bits):
    """Learned step size quantization: w ~ s * clamp(round(w / s)), gradients to w (STE) and s."""
    qmax = 2 ** (bits - 1) - 1
    s = log_s.exp()
    v = w / s
    v = v + (torch.round(v) - v).detach()
    return torch.clamp(v, -qmax - 1, qmax) * s


class QLinear(nn.Linear):
    bits = 0
    lsq = False

    def __init__(self, n_in, n_out):
        super().__init__(n_in, n_out, bias=False)
        self.log_s = nn.Parameter(torch.zeros(n_out, 1))
        self.register_buffer('qinit', torch.zeros(()))

    def qweight(self):
        if not QLinear.bits:
            return self.weight
        if not QLinear.lsq:
            return fake_quant_rows(self.weight, QLinear.bits)
        if not self.qinit:
            with torch.no_grad():
                self.log_s.copy_(mse_scale(self.weight, QLinear.bits).log())
                self.qinit.fill_(1)
        return lsq_quant(self.weight, self.log_s, QLinear.bits)

    def forward(self, x):
        return F.linear(x, self.qweight())


class RMSNorm(nn.Module):
    def __init__(self, d, gain=True):
        super().__init__()
        self.g = nn.Parameter(torch.ones(d), requires_grad=gain)

    def forward(self, x):
        return x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + 1e-5) * self.g


class Block(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.c = c
        hd = c['head_dim']
        self.n1 = RMSNorm(c['d'], c.get('inner_gain', True))
        self.q = QLinear(c['d'], c['heads'] * hd)
        self.k = QLinear(c['d'], c['kv_heads'] * hd)
        self.v = QLinear(c['d'], c['kv_heads'] * hd)
        self.o = QLinear(c['heads'] * hd, c['d'])
        self.n2 = RMSNorm(c['d'], c.get('inner_gain', True))
        self.up = QLinear(c['d'], c['ff'])
        self.down = QLinear(c['ff'], c['d'])

    def forward(self, x, bias):
        c = self.c
        B, T, _ = x.shape
        hd, H, KV = c['head_dim'], c['heads'], c['kv_heads']
        h = self.n1(x)
        q = self.q(h).view(B, T, H, hd).transpose(1, 2)
        k = self.k(h).view(B, T, KV, hd).transpose(1, 2).repeat_interleave(H // KV, dim=1)
        v = self.v(h).view(B, T, KV, hd).transpose(1, 2).repeat_interleave(H // KV, dim=1)
        a = F.scaled_dot_product_attention(q, k, v, attn_mask=bias)
        x = x + self.o(a.transpose(1, 2).reshape(B, T, H * hd))
        u = self.up(self.n2(x))
        u = F.relu(u) if c['act'] == 'relu' else F.relu(u) ** 2
        return x + self.down(u)


class GPT(nn.Module):
    def __init__(self, c):
        super().__init__()
        self.c = c
        self.emb = QLinear(c['d'], c['vocab'])       # tied embedding, rows are tokens
        nn.init.normal_(self.emb.weight, std=0.5)
        self.blocks = nn.ModuleList(Block(c) for _ in range(c['layers']))
        self.norm = RMSNorm(c['d'])
        H, T = c['heads'], c['ctx']
        slopes = torch.tensor([2 ** (-8 * (i + 1) / H) for i in range(H)])
        dist = torch.arange(T).float()
        # Learned bias per head and distance, initialized to ALiBi
        self.rel = nn.Parameter(-slopes[:, None] * dist[None, :] * 4, requires_grad=c['pos'] == 'relbias')

    def attn_bias(self, T):
        i = torch.arange(T)
        dist = (i[:, None] - i[None, :])
        b = self.rel[:, dist.clamp(0, self.c['ctx'] - 1)]
        return b.masked_fill(dist < 0, float('-inf'))[None]

    def forward(self, idx, targets=None):
        emb = self.emb.qweight()
        x = F.embedding(idx, emb)
        bias = self.attn_bias(idx.shape[1]) if self.c['pos'] != 'none' else \
            torch.zeros(idx.shape[1], idx.shape[1]).masked_fill(
                torch.ones(idx.shape[1], idx.shape[1], dtype=torch.bool).triu(1), float('-inf'))
        for i in range(self.c['loops']):
            for b in self.blocks:
                x = b(x, bias)
        logits = F.linear(self.norm(x), emb)
        if targets is None:
            return logits
        return logits, F.cross_entropy(logits.view(-1, logits.size(-1)), targets.reshape(-1))


def quant_bytes(c):
    """Bytes for 4-bit weights plus one scale byte per row."""
    d, hd, H, KV, ff, V = c['d'], c['head_dim'], c['heads'], c['kv_heads'], c['ff'], c['vocab']
    mats = [(H * hd, d), (KV * hd, d), (KV * hd, d), (d, H * hd), (ff, d), (d, ff)]
    per_layer = sum(r * k / 2 + r for r, k in mats)
    return c['layers'] * per_layer + V * d * c.get('emb_bits', 4) / 8 + V


def batches(data, B, T, gen):
    ix = torch.randint(len(data) - T - 1, (B,), generator=gen)
    x = torch.stack([torch.from_numpy(data[i:i + T].astype(np.int64)) for i in ix])
    y = torch.stack([torch.from_numpy(data[i + 1:i + 1 + T].astype(np.int64)) for i in ix])
    return x, y


@torch.no_grad()
def evaluate(model, val, T, n=200):
    model.eval()
    gen = torch.Generator().manual_seed(1234)
    losses = []
    for _ in range(n // 50):
        x, y = batches(val, 50, T, gen)
        losses.append(model(x, y)[1].item())
    model.train()
    return float(np.mean(losses))


@torch.no_grad()
def sample(model, tok, n=300, temp=0.8, seed=0):
    model.eval()
    g = torch.Generator().manual_seed(seed)
    idx = torch.zeros(1, 1, dtype=torch.long)   # start of story
    T = model.c['ctx']
    for _ in range(n):
        logits = model(idx[:, -T:])[0, -1] / temp
        nxt = torch.multinomial(F.softmax(logits, -1), 1, generator=g)
        idx = torch.cat([idx, nxt[None]], 1)
    model.train()
    return ''.join(tok['vocab'][i] for i in idx[0].tolist()).replace('\x00', '|')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--name', required=True)
    p.add_argument('--tok', default='char')
    p.add_argument('--d', type=int, default=64)
    p.add_argument('--layers', type=int, default=2)
    p.add_argument('--loops', type=int, default=1, help='apply the layer stack this many times')
    p.add_argument('--heads', type=int, default=4)
    p.add_argument('--head-dim', type=int, default=16)
    p.add_argument('--kv-heads', type=int, default=1)
    p.add_argument('--ff', type=int, default=128)
    p.add_argument('--ctx', type=int, default=64)
    p.add_argument('--pos', default='relbias', choices=['relbias', 'alibi', 'none'])
    p.add_argument('--act', default='relu', choices=['relu', 'relu2'])
    p.add_argument('--bits', type=int, default=4)
    p.add_argument('--qat-start', type=float, default=0.5, help='fraction of training before QAT starts')
    p.add_argument('--batch', type=int, default=64)
    p.add_argument('--lr', type=float, default=3e-3)
    p.add_argument('--wd', type=float, default=0.05)
    p.add_argument('--minutes', type=float, default=20)
    p.add_argument('--threads', type=int, default=6)
    p.add_argument('--init', help='checkpoint to start from')
    p.add_argument('--teacher', help='float checkpoint to distill from')
    p.add_argument('--kd', type=float, default=0.7, help='weight of the distillation loss')
    p.add_argument('--emb-bits', type=int, default=4)
    p.add_argument('--lsq', type=int, default=1, help='learn quantization scales')
    p.add_argument('--inner-gain', type=int, default=1, help='learn gains for the norms inside blocks')
    args = p.parse_args()

    torch.set_num_threads(args.threads)
    torch.manual_seed(0)
    tok = json.load(open(os.path.join(DATA, f'{args.tok}.json')))
    train = np.load(os.path.join(DATA, f'{args.tok}-train.npy'), mmap_mode='r')
    val = np.load(os.path.join(DATA, f'{args.tok}-val.npy'), mmap_mode='r')
    chars_per_tok = tok.get('val_chars', 21881417) / len(val)
    c = dict(vocab=len(tok['vocab']), d=args.d, layers=args.layers, loops=args.loops, heads=args.heads,
             head_dim=args.head_dim, kv_heads=args.kv_heads, ff=args.ff, ctx=args.ctx, pos=args.pos,
             act=args.act, tok=args.tok, bits=args.bits, inner_gain=bool(args.inner_gain), emb_bits=args.emb_bits, lsq=bool(args.lsq))
    QLinear.lsq = c['lsq']
    model = GPT(c)
    if args.init:
        model.load_state_dict(torch.load(args.init)['model'])
    teacher = None
    if args.teacher:
        tck = torch.load(args.teacher)
        teacher = GPT(tck['cfg'])
        teacher.load_state_dict(tck['model'])
        teacher.eval()
        for q in teacher.parameters():
            q.requires_grad_(False)
    n_params = sum(p.numel() for n, p in model.named_parameters() if n != 'rel' and 'log_s' not in n)
    print(f'{args.name}: {n_params} params, ~{quant_bytes(c):.0f} bytes at 4 bits, {chars_per_tok:.2f} chars/token')

    decay = [p for n, p in model.named_parameters() if p.dim() == 2 and n != 'rel' and 'log_s' not in n]
    other = [p for n, p in model.named_parameters() if p.dim() != 2 or n == 'rel' or 'log_s' in n]
    opt = torch.optim.AdamW([{'params': decay, 'weight_decay': args.wd}, {'params': other, 'weight_decay': 0}],
                            lr=args.lr, betas=(0.9, 0.95))
    out = os.path.join(HERE, 'runs', args.name)
    os.makedirs(out, exist_ok=True)
    log = open(os.path.join(out, 'log.txt'), 'a')
    gen = torch.Generator().manual_seed(0)
    budget = args.minutes * 60
    t0 = time.time()
    step, tokens = 0, 0
    QLinear.bits = 0
    while True:
        frac = (time.time() - t0) / budget
        if frac >= 1:
            break
        if args.bits and frac >= args.qat_start and QLinear.bits == 0:
            QLinear.bits = args.bits
            print(f'step {step}: starting {args.bits}-bit QAT')
        lr = args.lr * min(1, (step + 1) / 200) * (0.1 + 0.9 * 0.5 * (1 + math.cos(math.pi * frac)))
        for g in opt.param_groups:
            g['lr'] = lr
        x, y = batches(train, args.batch, args.ctx, gen)
        logits, loss = model(x, y)
        if teacher is not None:
            bits, QLinear.bits = QLinear.bits, 0
            with torch.no_grad():
                tl = teacher(x)
            QLinear.bits = bits
            kd = F.kl_div(F.log_softmax(logits, -1), F.log_softmax(tl, -1), log_target=True, reduction='batchmean') / x.shape[1]
            loss = args.kd * kd + (1 - args.kd) * loss
        opt.zero_grad(set_to_none=True)
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step()
        step += 1
        tokens += x.numel()
        if step % 500 == 0:
            vl = evaluate(model, val, args.ctx)
            msg = (f'step {step} tokens {tokens / 1e6:.1f}M loss {loss.item():.3f} val {vl:.3f} '
                   f'bpc {vl / chars_per_tok / math.log(2):.3f} lr {lr:.2e} {time.time() - t0:.0f}s')
            print(msg, flush=True)
            log.write(msg + '\n')
            log.flush()
            torch.save({'model': model.state_dict(), 'cfg': c, 'val': vl, 'step': step}, os.path.join(out, 'last.pt'))
    QLinear.bits = args.bits
    vl = evaluate(model, val, args.ctx, n=1000)
    bpc = vl / chars_per_tok / math.log(2)
    s = sample(model, tok)
    msg = f'FINAL {args.name} steps {step} tokens {tokens / 1e6:.1f}M val {vl:.4f} bpc {bpc:.4f} bytes {quant_bytes(c):.0f}'
    print(msg)
    print(s)
    log.write(msg + '\n' + s + '\n')
    torch.save({'model': model.state_dict(), 'cfg': c, 'val': vl, 'bpc': bpc}, os.path.join(out, 'model.pt'))


if __name__ == '__main__':
    main()
