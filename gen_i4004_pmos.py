#!/usr/bin/env python3
"""
gen_i4004_pmos.py - PMOS-only, transistor-level Intel 4004 for LTSpice / ngspice
=================================================================================

Generates a full-chip re-implementation of the Intel 4004 built the way the
1971 original was: p-channel MOS only, ratioed logic with load transistors,
two-phase dynamic latches, bootstrapped output drivers, VSS = 0 V / VDD = -15 V,
negative logic, original 16-pin pinout, 740 kHz two-phase clock.  Every
transistor is an instance of ONE subcircuit, PFET, so the device technology is
a single substitutable definition.

Outputs (in --out):
  i4004_pmos_tb.cir    self-contained LTSpice deck (memory played back as PWL)
  i4004_pmos_va.cir    ngspice deck; the program/data come from a Verilog-A
                       MCS-4 memory model (mcs4mem.va, compiled with OpenVAF)
  mcs4mem.va           the Verilog-A 4001 ROM + 4002 RAM model
  i4004_pmos.lib       the chip library alone

  python3 gen_i4004_pmos.py                 # demo program
  python3 gen_i4004_pmos.py --asm prog.asm  # your own 4004 assembly in ROM
  python3 gen_i4004_pmos.py --verify        # gate-level check vs ISA model

Assembler syntax: 'label:'  'MNEMONIC args'  'ORG addr'  'DB b,b,..'  ';comment'
(Intel mnemonics, registers R0..R15, pairs P0..P7).  A label named 'halt'
ends the generated simulation shortly after the program reaches it twice.
"""


import math
import re
import sys
from collections import defaultdict

ZERO, ONE = 'vss', 'vdd'          # logic 0 = VSS (0 V), logic 1 = VDD (-15 V)

# Original 16-pin DIP order (pin 1 .. pin 16)
PINS = ['d0', 'd1', 'd2', 'd3', 'vss', 'phi1', 'phi2', 'sync', 'reset', 'test',
        'cmrom', 'vdd', 'cmram3', 'cmram2', 'cmram1', 'cmram0']

# ----------------------------------------------------------------------------
# sizing constants (units of the unit device WUNIT x LUNIT); RATIO / LLOAD are
# SPICE .params so they can be retuned for other devices
# ----------------------------------------------------------------------------
RATIO = 2            # switch W per series level (beta ratio = RATIO * LLOAD)
LMAX = 6 * RATIO     # load (in switch-width units) one S=1 driver may carry
SMAX = 6             # max strength multiplier before a buffer tree is inserted
BS_SW = 4            # BSINV switch strength (x RATIO)
PAD_W = 12           # output transistor widths


# ============================================================================
# switch networks
#   tree := int (input index) | ('s', (tree,...)) series | ('p', (tree,...)) parallel
# ============================================================================

def tdepth(t):
    if isinstance(t, int):
        return 1
    if t[0] == 's':
        return sum(tdepth(c) for c in t[1])
    return max(tdepth(c) for c in t[1])


def tleaves(t):
    if isinstance(t, int):
        return [t]
    out = []
    for c in t[1]:
        out += tleaves(c)
    return out


def texpr(t, names):
    if isinstance(t, int):
        return names[t]
    op = ' & ' if t[0] == 's' else ' | '
    return '(' + op.join(texpr(c, names) for c in t[1]) + ')'


class Shape:
    def __init__(self, name, tree, nin, pins):
        self.name, self.tree, self.nin, self.pins = name, tree, nin, pins
        self.depth = tdepth(tree)


SHAPES = {}


def shape_for(tree, nin):
    key = repr(tree)
    if key in SHAPES:
        return SHAPES[key]
    leaves = tleaves(tree)
    distinct = sorted(leaves) == list(range(nin))
    name = None
    if distinct:
        if isinstance(tree, int):
            name = 'PINV'
        elif tree[0] == 's' and all(isinstance(c, int) for c in tree[1]):
            name = f'PNAND{nin}'
        elif tree[0] == 'p' and all(isinstance(c, int) for c in tree[1]):
            name = f'PNOR{nin}'
        elif tree[0] == 'p' and all(isinstance(c, int) or
                                    (c[0] == 's' and all(isinstance(x, int) for x in c[1]))
                                    for c in tree[1]):
            name = 'PAOI' + ''.join(str(1 if isinstance(c, int) else len(c[1])) for c in tree[1])
    if name is None or any(s.name == name for s in SHAPES.values()):
        name = f'PCG{len(SHAPES)}'
    pins = list('ABCDEFGHJKLMNPQRSTUVWXYZ')[:nin] if nin <= 24 else [f'I{k}' for k in range(nin)]
    SHAPES[key] = Shape(name, tree, nin, pins)
    return SHAPES[key]


# register cells (fixed internal structure, see emit)
REG_TREES = {
    'DLR':  (('s', (0, 1)), ['RB', 'D']),
    'DLER': (('s', (0, ('p', (('s', (1, 2)), ('s', (3, 4)))))), ['RB', 'EN', 'D', 'ENB', 'Q']),
    'DL':   (0, ['D']),
}


# ============================================================================
# chip builder
# ============================================================================

class Chip:
    def __init__(self, name, ports):
        self.name, self.ports = name, ports
        self.gates = []
        self.cache = {}
        self.cnt = 0
        self.rb = 'rb'
        self.sec = ''

    def new(self):
        self.cnt += 1
        return f'n{self.cnt}'

    def section(self, text):
        self.sec = text
        self.gates.append(dict(kind='COMMENT', text=text))

    def emit(self, kind, **kw):
        kw['kind'] = kind
        kw.setdefault('S', 1)
        self.gates.append(kw)
        return kw

    # ------------------------------------------------------------ primitive
    def _const(self, v, out):
        if out is None:
            return v
        # constant with a name: an inverter fed from the opposite rail
        self.emit('CG', shape=shape_for(0, 1), ins=[ZERO if v == ONE else ONE], out=out)
        return out

    def cg(self, terms, out=None):
        """out = NOT( OR_i AND_j terms[i][j] )   (one ratioed complex gate)"""
        T = []
        for t in terms:
            t = tuple(dict.fromkeys(t))
            if ZERO in t:
                continue
            t = tuple(x for x in t if x != ONE)
            if not t:
                return self._const(ZERO, out)
            T.append(t)
        if not T:
            return self._const(ONE, out)
        T = sorted(set(T), key=lambda t: (-len(t), t))
        assert len(T) <= 8 and all(len(t) <= 4 for t in T), T
        key = ('cg', tuple(T))
        if out is None and key in self.cache:
            return self.cache[key]
        ins, idx = [], {}

        def ix(n):
            if n not in idx:
                idx[n] = len(ins)
                ins.append(n)
            return idx[n]
        br = []
        for t in T:
            lits = [ix(n) for n in t]
            br.append(lits[0] if len(lits) == 1 else ('s', tuple(lits)))
        tree = br[0] if len(br) == 1 else ('p', tuple(br))
        y = out or self.new()
        self.emit('CG', shape=shape_for(tree, len(ins)), ins=ins, out=y)
        if out is None:
            self.cache[key] = y
        return y

    # ------------------------------------------------------------ logic ops
    def inv(self, a, out=None):
        if a in (ZERO, ONE):
            return self._const(ONE if a == ZERO else ZERO, out)
        if out is None and ('inv', a) in self.cache:
            return self.cache[('inv', a)]
        y = self.cg([[a]], out)
        if out is None:
            self.cache[('inv', a)] = y
            self.cache.setdefault(('inv', y), a)
        return y

    def buf(self, a, out):
        return self.inv(self.inv(a), out=out)

    def _fold_and(self, ins):
        ins = list(dict.fromkeys(ins))
        if ZERO in ins:
            return None
        return [i for i in ins if i != ONE]

    def _fold_or(self, ins):
        ins = list(dict.fromkeys(ins))
        if ONE in ins:
            return None
        return [i for i in ins if i != ZERO]

    def nand(self, *ins, out=None):
        f = self._fold_and(ins)
        if f is None:
            return self._const(ONE, out)
        if not f:
            return self._const(ZERO, out)
        if len(f) <= 3:
            return self.cg([f], out)
        return self.inv(self.and_(*f), out)

    def nor(self, *ins, out=None):
        f = self._fold_or(ins)
        if f is None:
            return self._const(ZERO, out)
        if not f:
            return self._const(ONE, out)
        if len(f) <= 8:
            return self.cg([[i] for i in f], out)
        return self.inv(self.or_(*f), out)

    def and_(self, *ins, out=None):
        f = self._fold_and(ins)
        if f is None:
            return self._const(ZERO, out)
        if not f:
            return self._const(ONE, out)
        if len(f) == 1:
            return f[0] if out is None else self.buf(f[0], out)
        if len(f) <= 3:
            return self.inv(self.nand(*f), out)
        groups = [f[i:i + 3] for i in range(0, len(f), 3)]
        if len(groups) <= 8:
            return self.nor(*[self.nand(*g) for g in groups], out=out)
        return self.and_(*[self.and_(*g) for g in groups], out=out)

    def or_(self, *ins, out=None):
        f = self._fold_or(ins)
        if f is None:
            return self._const(ONE, out)
        if not f:
            return self._const(ZERO, out)
        if len(f) == 1:
            return f[0] if out is None else self.buf(f[0], out)
        if len(f) <= 8:
            return self.inv(self.nor(*f), out)
        groups = [f[i:i + 8] for i in range(0, len(f), 8)]
        if len(groups) <= 3:
            return self.nand(*[self.nor(*g) for g in groups], out=out)
        return self.or_(*[self.or_(*g) for g in groups], out=out)

    def xor(self, a, b, out=None):
        if a == ZERO:
            return b if out is None else self.buf(b, out)
        if b == ZERO:
            return a if out is None else self.buf(a, out)
        if a == ONE:
            return self.inv(b, out)
        if b == ONE:
            return self.inv(a, out)
        return self.cg([[a, b], [self.inv(a), self.inv(b)]], out)

    def xnor(self, a, b, out=None):
        if a in (ZERO, ONE) or b in (ZERO, ONE):
            return self.inv(self.xor(a, b), out)
        return self.cg([[a, self.inv(b)], [self.inv(a), b]], out)

    def mux(self, s, d0, d1, out=None):
        """s ? d1 : d0"""
        if s == ZERO or d0 == d1:
            return d0 if out is None else self.buf(d0, out)
        if s == ONE:
            return d1 if out is None else self.buf(d1, out)
        if d0 == ZERO and d1 == ONE:
            return s if out is None else self.buf(s, out)
        if d0 == ONE and d1 == ZERO:
            return self.inv(s, out)
        if d0 == ZERO:
            return self.and_(s, d1, out=out)
        if d1 == ZERO:
            return self.and_(self.inv(s), d0, out=out)
        if d0 == ONE:
            return self.or_(self.inv(s), d1, out=out)
        if d1 == ONE:
            return self.or_(s, d0, out=out)
        return self.inv(self.cg([[s, d1], [self.inv(s), d0]]), out)

    def sop(self, terms, out=None):
        """OR of AND-terms"""
        T = []
        for t in terms:
            t = list(dict.fromkeys(t))
            if ZERO in t:
                continue
            t = [x for x in t if x != ONE]
            if not t:
                return self._const(ONE, out)
            if len(t) > 3:
                t = t[:2] + [self.and_(*t[2:])]
            T.append(t)
        if not T:
            return self._const(ZERO, out)
        if len(T) == 1:
            return self.and_(*T[0], out=out)
        if len(T) <= 4:
            return self.inv(self.cg(T), out)
        k = min(6, math.ceil(len(T) / 3))
        groups = [T[i:i + k] for i in range(0, len(T), k)]
        gs = [self.cg(g) for g in groups]
        if len(gs) <= 3:
            return self.nand(*gs, out=out)
        return self.or_(*[self.inv(g) for g in gs], out=out)

    def lit(self, net, val):
        return net if val else self.inv(net)

    # ------------------------------------------------------------ storage
    def reg(self, q, d, en=ONE, rst=True, name=None):
        name = name or f'r_{q}'
        if not rst:
            assert en == ONE
            return self.emit('REG', typ='DL', q=q, pins={'D': d}, name=name)
        if en == ONE:
            return self.emit('REG', typ='DLR', q=q, pins={'RB': self.rb, 'D': d}, name=name)
        return self.emit('REG', typ='DLER', q=q, name=name,
                         pins={'RB': self.rb, 'EN': en, 'D': d, 'ENB': self.inv(en), 'Q': q})

    # ------------------------------------------------------------ pads
    def out_pin(self, pin, a):
        g1 = self.inv(a)
        g2 = self.new()
        self.emit('BSINV', a=g1, y=g2, name=f'bs_{pin}')
        self.emit('PAD', pad=pin, g1=g1, g2=g2, name=f'pad_{pin}')

    def io_pin(self, pin, a, oe):
        g1 = self.nor(a, self.inv(oe))
        x = self.nand(oe, a)
        g2 = self.new()
        self.emit('BSINV', a=x, y=g2, name=f'bs_{pin}')
        self.emit('PAD', pad=pin, g1=g1, g2=g2, name=f'pad_{pin}')


# ============================================================================
# gate inputs/outputs and automatic sizing / buffering
# ============================================================================

def gate_inputs(g):
    """[(net, load_units, pinkey)] for every input of gate g"""
    k = g['kind']
    if k == 'CG':
        sh = g['shape']
        w = RATIO * sh.depth * g['S']
        return [(g['ins'][i], w, ('ins', i)) for i in tleaves(sh.tree)]
    if k == 'REG':
        tree, pins = REG_TREES[g['typ']]
        w = RATIO * tdepth(tree)
        return [(g['pins'][pins[i]], w, ('pins', pins[i])) for i in tleaves(tree)]
    if k == 'BSINV':
        return [(g['a'], RATIO * BS_SW, ('a',))]
    if k == 'PAD':
        return [(g['g1'], PAD_W, ('g1',)), (g['g2'], PAD_W, ('g2',))]
    return []


def gate_output(g):
    k = g['kind']
    if k == 'CG':
        return g['out']
    if k == 'REG':
        return g['q']
    if k == 'BSINV':
        return g['y']
    return None


def set_input(g, key, net):
    if key[0] == 'ins':
        g['ins'][key[1]] = net
    elif key[0] == 'pins':
        g['pins'][key[1]] = net
        if key[1] == 'Q':
            raise RuntimeError('cannot rebuffer register feedback')
    else:
        g[key[0]] = net


def size_chip(chip):
    gates = [g for g in chip.gates if g['kind'] != 'COMMENT']
    order = {id(g): k for k, g in enumerate(gates)}
    # --- buffer trees for very high fan-out nets
    for it in range(3):
        readers = defaultdict(list)
        for g in gates:
            for net, w, key in gate_inputs(g):
                if key == ('pins', 'Q'):
                    continue
                readers[net].append((g, w, key))
        changed = False
        for net, rl in readers.items():
            if net in (ZERO, ONE, 'phi1', 'phi2'):
                continue
            total = sum(w for _, w, _ in rl)
            if total <= LMAX * SMAX:
                continue
            cap = LMAX * SMAX * 0.6
            groups, cur, cw = [], [], 0
            for r in sorted(rl, key=lambda r: (order.get(id(r[0]), 10**9), r[2])):
                if cur and cw + r[1] > cap:
                    groups.append(cur)
                    cur, cw = [], 0
                cur.append(r)
                cw += r[1]
            groups.append(cur)
            if not any(g.get('kind') == 'COMMENT' and 'buffer' in g['text'] for g in chip.gates):
                chip.section('fan-out buffer trees (inserted automatically)')
            first = chip.new()
            g1 = chip.emit('CG', shape=shape_for(0, 1), ins=[net], out=first, buf=True)
            gates.append(g1)
            order[id(g1)] = len(order)
            for k, grp in enumerate(groups):
                bn = f'{net}_b{k}'
                gb = chip.emit('CG', shape=shape_for(0, 1), ins=[first], out=bn, buf=True)
                gates.append(gb)
                order[id(gb)] = len(order)
                for g, w, key in grp:
                    set_input(g, key, bn)
            changed = True
        if not changed:
            break
    # --- strength sizing
    for it in range(6):
        load = defaultdict(float)
        for g in gates:
            for net, w, key in gate_inputs(g):
                load[net] += w
        changed = False
        for g in gates:
            if g['kind'] not in ('CG', 'REG'):
                continue
            o = gate_output(g)
            s = min(SMAX, max(1, math.ceil(load[o] / LMAX)))
            if s != g['S']:
                g['S'] = s
                changed = True
        if not changed:
            break
    return load


# ============================================================================
# logic simulator (two-phase, latch accurate)
# ============================================================================

def expand(chip):
    """flatten into primitives: ('CG', tree, ins, out) ('PASS', src, dst, clk)
    ('BSINV', a, y) ('PAD', pad, g1, g2)"""
    P = []
    for g in chip.gates:
        k = g['kind']
        if k == 'CG':
            P.append(('CG', g['shape'].tree, list(g['ins']), g['out']))
        elif k == 'REG':
            tree, pins = REG_TREES[g['typ']]
            nm = g['name']
            dn, mm, mb = f'{nm}.dn', f'{nm}.m', f'{nm}.mb'
            P.append(('CG', tree, [g['pins'][p] for p in pins], dn))
            P.append(('PASS', dn, mm, 'phi2'))
            P.append(('CG', 0, [mm], mb))
            P.append(('PASS', mb, g['q'], 'phi1'))
        elif k == 'BSINV':
            P.append(('BSINV', g['a'], g['y']))
        elif k == 'PAD':
            P.append(('PAD', g['pad'], g['g1'], g['g2']))
    return P


class LogicSim:
    def __init__(self, chip):
        prims = expand(chip)
        self.ids = {ZERO: 0, ONE: 1}

        def nid(n):
            if n not in self.ids:
                self.ids[n] = len(self.ids)
            return self.ids[n]
        nid('phi1'), nid('phi2')
        comb, self.passes = [], {'phi1': [], 'phi2': []}
        for p in prims:
            if p[0] == 'PASS':
                self.passes[p[3]].append((nid(p[1]), nid(p[2])))
            else:
                comb.append(p)
        driver = {}
        for i, p in enumerate(comb):
            out = p[3] if p[0] == 'CG' else (p[2] if p[0] == 'BSINV' else p[1])
            if out in driver:
                raise RuntimeError('multiple drivers on ' + out)
            driver[out] = i
        pass_dst = {d for lst in self.passes.values() for _, d in lst}
        for n in pass_dst:
            name = [k for k, v in self.ids.items() if v == n][0]
            if name in driver:
                raise RuntimeError('pass destination also driven: ' + name)

        def ins_of(p):
            if p[0] == 'CG':
                return p[2]
            if p[0] == 'BSINV':
                return [p[1]]
            return [p[2], p[3]]
        deps = [[driver[n] for n in ins_of(p) if n in driver] for p in comb]
        order, state = [], [0] * len(comb)
        sys.setrecursionlimit(100000)

        def visit(i):
            if state[i] == 2:
                return
            if state[i] == 1:
                raise RuntimeError('combinational loop at ' + repr(comb[i]))
            state[i] = 1
            for d in deps[i]:
                visit(d)
            state[i] = 2
            order.append(i)
        for i in range(len(comb)):
            visit(i)
        lines = ['def comb(v, ext):']
        self.padnames = []
        for i in order:
            p = comb[i]
            if p[0] == 'CG':
                names = [f'v[{nid(n)}]' for n in p[2]]
                lines.append(f' v[{nid(p[3])}] = 1 - {texpr(p[1], names)}')
            elif p[0] == 'BSINV':
                lines.append(f' v[{nid(p[2])}] = 1 - v[{nid(p[1])}]')
            else:
                pad, g1, g2 = nid(p[1]), nid(p[2]), nid(p[3])
                if p[1].startswith('d'):
                    k = int(p[1][1:])
                    lines.append(f' v[{pad}] = 0 if v[{g1}] else (1 if v[{g2}] else ext[{k}])')
                else:
                    lines.append(f' v[{pad}] = 0 if v[{g1}] else (1 if v[{g2}] else 0)')
                lines.append(f' if v[{g1}] and v[{g2}]: raise RuntimeError("pad short {p[1]}")')
        ns = {}
        exec('\n'.join(lines), ns)
        self.comb = ns['comb']
        self.v = [0] * len(self.ids)
        self.v[1] = 1

    def net(self, name):
        return self.v[self.ids[name]]

    def word(self, names):
        return sum(self.net(n) << i for i, n in enumerate(names))

    def set_in(self, **kw):
        for k, val in kw.items():
            self.v[self.ids[k]] = val

    def period(self, reset, test, drive, rnd):
        v = self.v

        def ext():
            if drive is not None:
                return [drive >> k & 1 for k in range(4)]
            return [rnd.getrandbits(1) for _ in range(4)]
        # PHI1 high: slaves transparent
        self.set_in(phi1=1, phi2=0, reset=reset, test=test)
        self.comb(v, ext())
        for s, d in self.passes['phi1']:
            v[d] = v[s]
        self.comb(v, ext())
        outs = {k: self.net(k) for k in ('sync', 'cmrom', 'cmram0', 'cmram1', 'cmram2',
                                         'cmram3', 'doe')}
        outs['dout'] = self.word([f'do{i}' for i in range(4)])
        # PHI2 high: masters transparent
        self.set_in(phi1=0, phi2=1)
        self.comb(v, ext())
        if outs['doe'] != self.net('doe'):
            raise RuntimeError('bus enable changed during PHI2')
        outs['bus'] = outs['dout'] if outs['doe'] else drive
        for s, d in self.passes['phi2']:
            v[d] = v[s]
        return outs


# ============================================================================
# SPICE emission
# ============================================================================

def emit_shape(sh):
    pins = sh.pins[:sh.nin]
    out = [f'.subckt {sh.name} Y ' + ' '.join(pins) + ' vss vdd params: S=1',
           'XL vdd vdd Y vss PFET WM={S} LM={LLOAD}']
    cnt = [0]
    devs = []
    w = f'{{{sh.depth}*RATIO*S}}'

    def rec(t, top, bot):
        if isinstance(t, int):
            devs.append(f'X{pins[t]}{len(devs)+1} {top} {pins[t]} {bot} vss PFET WM={w}')
        elif t[0] == 'p':
            for c in t[1]:
                rec(c, top, bot)
        else:
            nodes = [top]
            for _ in range(len(t[1]) - 1):
                cnt[0] += 1
                nodes.append(f'x{cnt[0]}')
            nodes.append(bot)
            for j, c in enumerate(t[1]):
                rec(c, nodes[j], nodes[j + 1])
    rec(sh.tree, 'Y', 'vss')
    return '\n'.join(out + devs + [f'.ends {sh.name}'])


CELL_LIB = """\
*---------------------------------------------------------------------------
* Dynamic register cells (two-phase, recirculating).  The master node M and
* the slave/output node Q are dynamic: charge on gate capacitance, written
* through PFET pass transistors clocked directly by PHI2 / PHI1.
*   PHI2: M <- DN (input gate)      PHI1: Q <- NOT M      (Q updates on PHI1)
* DLR : Q' = RB & D                         (load every cycle, reset)
* DLER: Q' = RB & (EN ? D : Q)              (load enable, reset)
*---------------------------------------------------------------------------
.subckt DLR Q D RB PHI1 PHI2 vss vdd params: S=1
XL vdd vdd dn vss PFET WM=1 LM={LLOAD}
XA dn RB x1 vss PFET WM={2*RATIO}
XB x1 D vss vss PFET WM={2*RATIO}
XPM dn PHI2 m vss PFET WM=2
XL2 vdd vdd mb vss PFET WM={S} LM={LLOAD}
XS2 mb m vss vss PFET WM={RATIO*S}
XPS mb PHI1 Q vss PFET WM={2*S}
.ends DLR

.subckt DLER Q D EN ENB RB PHI1 PHI2 vss vdd params: S=1
XL vdd vdd dn vss PFET WM=1 LM={LLOAD}
XA dn RB x1 vss PFET WM={3*RATIO}
XB x1 EN x2 vss PFET WM={3*RATIO}
XC x2 D vss vss PFET WM={3*RATIO}
XD x1 ENB x3 vss PFET WM={3*RATIO}
XE x3 Q vss vss PFET WM={3*RATIO}
XPM dn PHI2 m vss PFET WM=2
XL2 vdd vdd mb vss PFET WM={S} LM={LLOAD}
XS2 mb m vss vss PFET WM={RATIO*S}
XPS mb PHI1 Q vss PFET WM={2*S}
.ends DLER

.subckt DL Q D PHI1 PHI2 vss vdd params: S=1
XL vdd vdd dn vss PFET WM=1 LM={LLOAD}
XA dn D vss vss PFET WM={RATIO}
XPM dn PHI2 m vss PFET WM=2
XL2 vdd vdd mb vss PFET WM={S} LM={LLOAD}
XS2 mb m vss vss PFET WM={RATIO*S}
XPS mb PHI1 Q vss PFET WM={2*S}
.ends DL

*---------------------------------------------------------------------------
* BSINV: bootstrapped inverter (Faggin's bootstrap load).  XI precharges G
* to about VDD+|VT|; when Y falls, the MOS capacitor XC pushes G below VDD so
* the load XL stays fully on and Y reaches the full VDD level.
*---------------------------------------------------------------------------
.subckt BSINV Y A vss vdd
XS Y A vss vss PFET WM={BSW*RATIO}
XL vdd G Y vss PFET WM=1 LM=2
XI vdd vdd G vss PFET WM=1
XC Y G Y vss PFET WM=4 LM=4
.ends BSINV

*---------------------------------------------------------------------------
* PADDRV: push-pull PMOS output stage.  G1 (logic 1) pulls PAD to VSS
* (logic 0); G2 (logic 1, bootstrapped) pulls PAD toward VDD (logic 1).
*---------------------------------------------------------------------------
.subckt PADDRV PAD G1 G2 vss vdd
XT1 PAD G1 vss vss PFET WM={PADW}
XT2 PAD G2 vdd vss PFET WM={PADW}
.ends PADDRV
"""


def emit_chip(chip):
    lines = []
    port_line = f'.subckt {chip.name} ' + ' '.join(chip.ports)
    lines.append(port_line)
    cnt = defaultdict(int)
    for g in chip.gates:
        k = g['kind']
        if k == 'COMMENT':
            lines.append(f'* ---- {g["text"]}')
            continue
        cnt[k] += 1
        if k == 'CG':
            sh = g['shape']
            nets = [g['out']] + list(g['ins'])
            s = f' S={g["S"]}' if g['S'] != 1 else ''
            lines.append(wrap(f'XG{cnt[k]} ' + ' '.join(nets) + f' vss vdd {sh.name}{s}'))
        elif k == 'REG':
            typ = g['typ']
            if typ == 'DLR':
                nets = [g['q'], g['pins']['D'], g['pins']['RB']]
            elif typ == 'DLER':
                p = g['pins']
                nets = [g['q'], p['D'], p['EN'], p['ENB'], p['RB']]
            else:
                nets = [g['q'], g['pins']['D']]
            s = f' S={g["S"]}' if g['S'] != 1 else ''
            nm = re.sub(r'[^A-Za-z0-9_]', '_', g['name'])
            lines.append(wrap(f'X{nm} ' + ' '.join(nets) + f' phi1 phi2 vss vdd {typ}{s}'))
        elif k == 'BSINV':
            lines.append(f'X{g["name"]} {g["y"]} {g["a"]} vss vdd BSINV')
        elif k == 'PAD':
            lines.append(f'X{g["name"]} {g["pad"]} {g["g1"]} {g["g2"]} vss vdd PADDRV')
    lines.append(f'.ends {chip.name}')
    return '\n'.join(lines)


def wrap(line, width=100):
    if len(line) <= width:
        return line
    words, out, cur = line.split(' '), [], ''
    for w in words:
        if len(cur) + len(w) + 1 > width and cur:
            out.append(cur)
            cur = '+ ' + w
        else:
            cur = (cur + ' ' + w) if cur else w
    out.append(cur)
    return '\n'.join(out)


def transistor_count(chip):
    n = 0
    for g in chip.gates:
        k = g['kind']
        if k == 'CG':
            n += 1 + len(tleaves(g['shape'].tree))
        elif k == 'REG':
            n += {'DLR': 7, 'DLER': 10, 'DL': 6}[g['typ']]
        elif k == 'BSINV':
            n += 4
        elif k == 'PAD':
            n += 2
    return n



def build_chip():
    m = Chip('I4004P', PINS)
    I, A, O, X, S = m.inv, m.and_, m.or_, m.xor, m.sop
    rng = range(4)

    # ------------------------------------------------------------------ pads
    m.section('input receivers (RESET, TEST, data bus)')
    m.inv('reset', out='rb')                 # rb = NOT reset (logic), buffered tree added later
    rst = I('rb')
    ntest = m.inv('test', out='ntest')
    busin = [m.inv(m.inv(f'd{i}'), out=f'bi{i}') for i in rng]

    acc = [f'acc{i}' for i in rng]
    opr = [f'opr{i}' for i in rng]
    opa = [f'opa{i}' for i in rng]
    rd = [f'rd{i}' for i in rng]
    srd = [f'srd{i}' for i in rng]           # address-stack read nibble
    cy, dc = 'cy', 'dc'

    # ------------------------------------------------------------------ timing
    m.section('timing generator: 3-bit Gray counter A1 A2 A3 M1 M2 X1 X2 X3')

    def st(code, name):
        return A(m.lit('t2', code >> 2 & 1), m.lit('t1', code >> 1 & 1),
                 m.lit('t0', code & 1), out=name)
    A1, A2, A3 = st(0b000, 's_a1'), st(0b001, 's_a2'), st(0b011, 's_a3')
    M1, M2 = st(0b010, 's_m1'), st(0b110, 's_m2')
    X1, X2, X3 = st(0b111, 's_x1'), st(0b101, 's_x2'), st(0b100, 's_x3')
    m.reg('t0', m.xnor('t1', 't2'))
    m.reg('t1', m.mux('t0', 't1', I('t2')))
    m.reg('t2', m.mux('t0', 't1', 't2'))

    # ------------------------------------------------------------------ decode
    m.section('instruction decoder')

    def dec(bits, k, name=None):
        return A(*[m.lit(bits[j], k >> j & 1) for j in range(4)], out=name)
    names = {1: 'i_jcn', 4: 'i_jun', 5: 'i_jms', 6: 'i_inc', 7: 'i_isz', 8: 'i_add',
             9: 'i_sub', 10: 'i_ld', 11: 'i_xch', 12: 'i_bbl', 13: 'i_ldm', 14: 'i_io',
             15: 'i_acc'}
    dr = {k: dec(opr, k, names.get(k)) for k in range(1, 16)}
    da = {k: dec(opa, k) for k in range(16)}
    JCN, JUN, JMS, INC, ISZ = dr[1], dr[4], dr[5], dr[6], dr[7]
    ADD, SUB, LD, XCH, BBL, LDM, IO, FG = dr[8], dr[9], dr[10], dr[11], dr[12], dr[13], dr[14], dr[15]
    pairop = A(I(opr[3]), I(opr[2]), opr[1], out='i_pair')
    FIM = A(dr[2], I(opa[0]), out='i_fim')
    SRC = A(dr[2], opa[0], out='i_src')
    FIN = A(dr[3], I(opa[0]), out='i_fin')
    JIN = A(dr[3], opa[0], out='i_jin')
    jj = A(I(opr[3]), opr[2], I(opr[1]), out='i_jj')          # JUN | JMS
    IOW = A(IO, I(opa[3]), out='i_iow')
    IOR = A(IO, opa[3], out='i_ior')
    SBM, ADM = A(IO, da[8]), A(IO, da[11])
    RDBUS = A(IO, O(da[9], da[10], da[12], da[13], da[14], da[15]))
    f = {k: A(FG, da[k]) for k in range(14)}
    CLB, CLC, IAC, CMC, CMA, RAL, RAR, TCC = (f[k] for k in range(8))
    DAC, TCS, STC, DAA, KBP, DCLI = f[8], f[9], f[10], f[11], f[12], f[13]

    ndc = I(dc, out='ndc')
    fin2 = A(dc, FIN, out='fin2')
    nfin2 = I(fin2)
    twocyc = O(JCN, FIM, FIN, JUN, JMS, ISZ)

    m.section('instruction register OPR/OPA, double-cycle flag, JCN condition latch')
    en_opr = A(ndc, M1, out='en_opr')
    en_opa = A(ndc, M2, out='en_opa')
    for i in rng:
        m.reg(opr[i], busin[i], en_opr)
        m.reg(opa[i], busin[i], en_opa)
    m.reg(dc, A(ndc, twocyc), X3)

    # ------------------------------------------------------------------ index registers
    m.section('index register array 16 x 4 (1 read / 1 write port)')
    ra = [m.mux(fin2, m.mux(pairop, opa[0], X3), A1, out='ra0')] + \
         [A(opa[i], nfin2, out=f'ra{i}') for i in (1, 2, 3)]
    wa = [m.mux(dc, opa[0], M2, out='wa0'), opa[1], opa[2], opa[3]]
    rf_we = O(A(ndc, X1, O(XCH, INC, ISZ)), A(dc, O(M1, M2), O(FIM, FIN)), out='rf_we')
    rdinc, c = [], ONE
    for i in rng:
        rdinc.append(X(rd[i], c))
        c = A(rd[i], c)
    wd = [m.mux(dc, m.mux(opr[3], rdinc[i], acc[i]), busin[i], out=f'rf_wd{i}') for i in rng]
    rlon = [m.nand(m.lit(ra[1], k >> 1 & 1), m.lit(ra[0], k & 1)) for k in range(4)]
    rhin = [m.nand(m.lit(ra[3], k >> 1 & 1), m.lit(ra[2], k & 1)) for k in range(4)]
    rsel = [m.nor(rhin[k >> 2], rlon[k & 3], out=f'rsel{k}') for k in range(16)]
    wlon = [m.nand(m.lit(wa[1], k >> 1 & 1), m.lit(wa[0], k & 1)) for k in range(4)]
    whin = [m.nand(rf_we, m.lit(wa[3], k >> 1 & 1), m.lit(wa[2], k & 1)) for k in range(4)]
    for k in range(16):
        wen = m.nor(whin[k >> 2], wlon[k & 3], out=f'wen{k}')
        for i in rng:
            m.reg(f'r{k}_{i}', wd[i], wen, name=f'r{k}_{i}')
    for i in rng:
        S([[rsel[k], f'r{k}_{i}'] for k in range(16)], out=rd[i])

    # ------------------------------------------------------------------ ALU
    m.section('ALU, accumulator, carry')
    selR, selM, sub = O(ADD, SUB), O(ADM, SBM), O(SUB, SBM, out='alu_sub')
    arith = O(ADD, SUB, ADM, SBM)
    adj = O(cy, A(acc[3], O(acc[2], acc[1])))
    daaadj = A(DAA, adj, out='daa_adj')
    b = []
    for i in rng:
        terms = [[selR, rd[i]], [selM, busin[i]], [DAC]]
        if i in (1, 2):
            terms.append([daaadj])
        b.append(X(S(terms), sub))
    c = O(A(arith, X(cy, sub)), IAC, out='alu_cin')
    s = []
    for i in rng:
        p = X(acc[i], b[i])
        s.append(X(p, c, out=f'alu_s{i}'))
        c = m.nand(m.nand(acc[i], b[i]), m.nand(p, c), out=f'alu_c{i+1}')
    cout = c
    err = O(*[A(acc[i], acc[j]) for i in rng for j in rng if i < j])
    kbp = [O(err, acc[0], acc[2]), O(err, acc[1], acc[2]), O(err, acc[3]), err]
    sel_sum = O(arith, IAC, DAC, DAA)
    sel_rd, sel_opa = O(LD, XCH), O(BBL, LDM)
    ral = [cy, acc[0], acc[1], acc[2]]
    rar = [acc[1], acc[2], acc[3], cy]
    acc_d = []
    for i in rng:
        terms = [[sel_sum, s[i]], [sel_rd, rd[i]], [sel_opa, opa[i]], [RDBUS, busin[i]],
                 [CMA, I(acc[i])], [RAL, ral[i]], [RAR, rar[i]], [KBP, kbp[i]]]
        if i == 0:
            terms += [[TCC, cy], [TCS, I(cy)]]
        if i == 1:
            terms += [[TCS, cy]]
        if i == 3:
            terms += [[TCS]]
        acc_d.append(S(terms, out=f'acc_d{i}'))
    acc1 = O(ADD, SUB, LD, XCH, BBL, LDM,
             A(FG, O(da[0], da[2], da[4], da[5], da[6], da[7], da[8], da[9], da[11], da[12])))
    acc_we = A(ndc, O(A(X1, acc1), A(X2, IOR)), out='acc_we')
    for i in rng:
        m.reg(acc[i], acc_d[i], acc_we)
    selC = O(arith, IAC, DAC)
    cy_d = S([[selC, cout], [DAA, cy], [DAA, cout], [CMC, I(cy)], [STC],
              [RAL, acc[3]], [RAR, acc[0]]], out='cy_d')
    cy1 = O(ADD, SUB, A(FG, O(*[da[k] for k in (0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 11)])))
    cy_we = A(ndc, O(A(X1, cy1), A(X2, selM)), out='cy_we')
    m.reg(cy, cy_d, cy_we)

    m.section('DCL bank register')
    dcl_we = A(ndc, X1, DCLI, out='dcl_we')
    for i in range(3):
        m.reg(f'dcl{i}', acc[i], dcl_we)

    # ------------------------------------------------------------------ JCN / ISZ condition
    m.section('jump condition (sampled at A3 of the second word)')
    accz = m.nor(*acc, out='acc_zero')
    jc = S([[opa[2], accz], [opa[1], cy], [opa[0], ntest]])
    jcond = X(jc, opa[3], out='jcn_cond')
    m.reg('cond', jcond, A(dc, A3))
    rdnz = O(*rd, out='rd_nz')
    take2 = A(dc, O(JUN, JMS, A(JCN, 'cond'), A(ISZ, rdnz)), out='take2')

    # ------------------------------------------------------------------ address stack
    m.section('address stack 4 x 12 (PC + 3 levels), nibble-serial incrementer')
    spp1 = [I('sp0'), X('sp1', 'sp0')]
    spm1 = [I('sp0'), m.xnor('sp1', 'sp0')]
    sp_we = O(A(dc, A3, JMS), A(ndc, X1, BBL), out='sp_we')
    for i in range(2):
        m.reg(f'sp{i}', m.mux(dc, spm1[i], spp1[i]), sp_we)
    spsel = [A(m.lit('sp1', l >> 1), m.lit('sp0', l & 1), out=f'spsel{l}') for l in range(4)]
    Aany = O(A1, A2, A3, out='s_aany')
    M12, X23 = O(M1, M2), O(X2, X3)
    # incrementer: carry in = 1 at A1, else the carry saved from the previous nibble
    m.reg('acarry', A(O(A1, A2), 'inc_c4'))
    c = O(A1, 'acarry', out='inc_c0')
    inc = []
    for i in rng:
        inc.append(X(srd[i], c, out=f'inc{i}'))
        c = A(srd[i], c, out=f'inc_c{i+1}')
    stk_we = S([[Aany, nfin2], [M12, take2], [X1, dc, jj], [X23, ndc, JIN]], out='stk_we')
    nw = [O(A1, M2, X3, out='nw0'), O(A2, M1, X2, out='nw1'), O(A3, X1, out='nw2')]
    stk_wd = [S([[Aany, inc[i]], [M12, busin[i]], [X1, opa[i]], [X23, rd[i]]], out=f'stk_wd{i}')
              for i in rng]
    rn = [A1, A2, A3]
    for l in range(4):
        for n in range(3):
            we = A(stk_we, spsel[l], nw[n], out=f'swen{l}_{n}')
            for i in rng:
                m.reg(f's{l}_{n}_{i}', stk_wd[i], we, name=f's{l}_{n}_{i}')
    rsl = {(l, n): A(spsel[l], rn[n], out=f'srsel{l}_{n}') for l in range(4) for n in range(3)}
    for i in rng:
        S([[rsl[(l, n)], f's{l}_{n}_{i}'] for l in range(4) for n in range(3)], out=srd[i])

    # ------------------------------------------------------------------ bus output
    m.section('data bus output')
    sel_stk = O(A(O(A1, A2), nfin2), A3)
    selRDo = O(A(fin2, O(A1, A2)), A(ndc, SRC, X23))
    selACCo = A(ndc, X2, IOW)
    dout = [S([[sel_stk, srd[i]], [selRDo, rd[i]], [selACCo, acc[i]]], out=f'do{i}') for i in rng]
    # bus enable is registered one sub-cycle ahead so the pads release the bus
    # right at the start of the next sub-cycle (no contention with memory)
    doe_next = O(rst, X3, A1, A2, A(ndc, X1, O(SRC, IOW)), A(ndc, X2, SRC), out='doe_next')
    m.reg('doe', doe_next, rst=False)
    for i in rng:
        m.io_pin(f'd{i}', dout[i], 'doe')

    # ------------------------------------------------------------------ control outputs
    m.section('SYNC, CM-ROM, CM-RAM outputs (registered: clocked out at the sub-cycle start)')
    # computed one sub-cycle ahead: A3 <- A2, M2 <- M1 with OPR=1110 on the bus, X2 <- X1 SRC
    bus_io = A(busin[3], busin[2], busin[1], I(busin[0]), out='bus_is_io')
    cm_next = O(A2, A(ndc, M1, bus_io), A(ndc, X1, SRC), out='cm_next')
    m.reg('q_sync', X2)
    m.reg('q_cmrom', cm_next)
    m.reg('q_cmram0', A(cm_next, m.nor('dcl0', 'dcl1', 'dcl2')))
    for k in range(3):
        m.reg(f'q_cmram{k+1}', A(cm_next, f'dcl{k}'))
    m.out_pin('sync', 'q_sync')
    m.out_pin('cmrom', 'q_cmrom')
    for k in range(4):
        m.out_pin(f'cmram{k}', f'q_cmram{k}')
    load = size_chip(m)
    return m

DEVICE_KNOBS = """\
*=============================================================================
*  DEVICE KNOB  -  the only transistor definition in the whole design
*=============================================================================
*  Every transistor in the chip (logic, loads, pass gates, bootstrap capacitors,
*  pad drivers) is an instance of the single subcircuit PFET below.  Swap the
*  p-channel technology by replacing its body; keep the interface:
*
*     .subckt PFET D G S B params: WM=1 LM=1
*        D G S B : drain, gate, source, body (body = VSS = most positive rail;
*                  may be ignored by your model, e.g. a GAA / nanosheet device)
*        WM, LM  : width / length multiples of the unit device WUNIT x LUNIT
*
*  Example with your own model:
*     .subckt PFET D G S B params: WM=1 LM=1
*     X1 D G S B MY_PFET_MODEL W={WM*WUNIT} L={LM*LUNIT}
*     .ends PFET
*  If your device has a fixed L, emulate LM by stacking LM devices in series
*  (only the load devices use LM > 1).
*
*  The default body is a Level-1 card in the spirit of Intel's 1971 10 um
*  silicon-gate PMOS process (VT ~ -1.8 V, tox 120 nm, strong body effect).
*  Design ratios (change together with the device):
*     RATIO : switch width per series level  (switch:load beta ratio
*             = RATIO*LLOAD, 24 by default -> logic-0 level ~ -0.35 V)
*     LLOAD : load-device length multiple (longer = less static power,
*             slower logic-1 edges; defaults give ~0.9 W, original max 1 W)
*-----------------------------------------------------------------------------
.param WUNIT=10u LUNIT=10u LDIF=10u
.param RATIO=2 LLOAD=12 BSW=4 PADW=12

.subckt PFET D G S B params: WM=1 LM=1
M1 D G S B P4004 W={WUNIT*WM} L={LUNIT*LM} AD={WUNIT*WM*LDIF} AS={WUNIT*WM*LDIF}
+ PD={2*WUNIT*WM+2*LDIF} PS={2*WUNIT*WM+2*LDIF}
.ends PFET

.model P4004 PMOS(LEVEL=1 VTO=-1.8 KP=8u GAMMA=0.6 PHI=0.6 LAMBDA=0.02 TOX=120n
+ LD=0.8u CJ=1e-4 MJ=0.5 CJSW=5e-10 MJSW=0.33 PB=0.8 CGSO=2.3e-10 CGDO=2.3e-10
+ CGBO=2e-10)
"""

# ============================================================================
# ISA reference model, MCS-4 bus model, assembler, programs, raw reader
# ============================================================================
KBP_T = {0: 0, 1: 1, 2: 2, 4: 3, 8: 4}


def active_banks(dcl):
    return [0] if dcl == 0 else [k + 1 for k in range(3) if dcl >> k & 1]


class MemState:
    def __init__(self, rnd):
        self.ram = [[[[rnd.randrange(16) for _ in range(16)] for _ in range(4)]
                     for _ in range(4)] for _ in range(4)]
        self.stat = [[[[rnd.randrange(16) for _ in range(4)] for _ in range(4)]
                      for _ in range(4)] for _ in range(4)]
        self.ramport = [[0] * 4 for _ in range(4)]
        self.romport = [0] * 16
        self.rom_in = [(7 * k + 3) & 15 for k in range(16)]
        self.rom_src = 0
        self.ram_src = [(0, 0, 0)] * 4

    def snapshot(self):
        return (repr(self.ram), repr(self.stat), repr(self.ramport), repr(self.romport))

    def io_write(self, cmd, banks, val):
        if cmd == 2:
            self.romport[self.rom_src] = val
        for b in banks:
            ch, rg, cr = self.ram_src[b]
            if cmd == 0:
                self.ram[b][ch][rg][cr] = val
            elif cmd == 1:
                self.ramport[b][ch] = val
            elif 4 <= cmd <= 7:
                self.stat[b][ch][rg][cmd - 4] = val

    def io_read(self, cmd, banks):
        if cmd == 10:
            return self.rom_in[self.rom_src]
        val = 0
        for b in banks:
            ch, rg, cr = self.ram_src[b]
            val |= self.ram[b][ch][rg][cr] if cmd in (8, 9, 11) else self.stat[b][ch][rg][cmd - 12]
        return val


class BusSystem:
    """ROM + 4002 RAM banks + ports, driven only by what it sees on the pins."""
    def __init__(self, rom, mem):
        self.rom, self.mem = rom, mem
        self.pos = 0
        self.addr = [0, 0, 0]
        self.io_cmd, self.io_banks = None, []
        self.src_banks, self.src_hi = None, 0
        self.fetches = []

    def drive(self):
        a = self.addr[0] | self.addr[1] << 4 | self.addr[2] << 8
        if self.pos == 3:
            return self.rom[a] >> 4
        if self.pos == 4:
            return self.rom[a] & 15
        if self.pos == 6 and self.io_cmd is not None and self.io_cmd >= 8:
            return self.mem.io_read(self.io_cmd, self.io_banks)
        return None

    def observe(self, o, reset):
        if reset:
            self.pos = 0
            return
        pos, bus = self.pos, o['bus']
        cm = [o[f'cmram{k}'] for k in range(4)]
        if pos in (0, 1, 2):
            assert o['doe'], 'CPU not driving address'
            self.addr[pos] = bus
            if pos == 2:
                assert o['cmrom'], 'CM-ROM missing at A3'
                self.fetches.append(self.addr[0] | self.addr[1] << 4 | self.addr[2] << 8)
        elif pos == 4:
            self.io_cmd = bus if o['cmrom'] else None
            self.io_banks = [k for k in range(4) if cm[k]]
        elif pos == 6:
            if self.io_cmd is not None:
                if self.io_cmd < 8:
                    self.mem.io_write(self.io_cmd, self.io_banks, bus)
            elif o['cmrom']:
                self.mem.rom_src = bus
                self.src_banks, self.src_hi = [k for k in range(4) if cm[k]], bus
        elif pos == 7:
            assert o['sync'], 'SYNC missing at X3'
            if self.src_banks is not None:
                for k in self.src_banks:
                    self.mem.ram_src[k] = (self.src_hi >> 2, self.src_hi & 3, bus)
                self.src_banks = None
            self.io_cmd = None
        if pos != 7:
            assert not o['sync'], 'unexpected SYNC'
        self.pos = (pos + 1) % 8


class Golden:
    """Instruction-level Intel 4004 reference model."""
    def __init__(self, rom, mem, test_fn):
        self.rom, self.mem, self.test_fn = rom, mem, test_fn
        self.stack, self.sp, self.acc, self.cy = [0] * 4, 0, 0, 0
        self.r, self.dcl, self.cycles = [0] * 16, 0, 0
        self.fetches = []

    @property
    def pc(self):
        return self.stack[self.sp]

    @pc.setter
    def pc(self, v):
        self.stack[self.sp] = v & 0xFFF

    def fetch(self):
        self.fetches.append(self.pc)
        b = self.rom[self.pc]
        self.pc += 1
        self.cycles += 1
        return b

    def state(self):
        return (self.acc, self.cy, tuple(self.r), self.sp, tuple(self.stack), self.dcl)

    def step(self):
        c0 = self.cycles
        b1 = self.fetch()
        opr, opa = b1 >> 4, b1 & 15
        r, mem = self.r, self.mem
        if opr == 1:                                    # JCN
            b2 = self.fetch()
            t = self.test_fn(c0 + 1)
            c = (opa & 4 and self.acc == 0) or (opa & 2 and self.cy) or (opa & 1 and t == 0)
            if opa & 8:
                c = not c
            if c:
                self.pc = (self.pc & 0xF00) | b2
        elif opr == 2:
            p = opa & 14
            if opa & 1 == 0:                            # FIM
                b2 = self.fetch()
                r[p], r[p + 1] = b2 >> 4, b2 & 15
            else:                                       # SRC
                mem.rom_src = r[p]
                for b in active_banks(self.dcl):
                    mem.ram_src[b] = (r[p] >> 2, r[p] & 3, r[p + 1])
        elif opr == 3:
            p = opa & 14
            if opa & 1 == 0:                            # FIN
                a = (self.pc & 0xF00) | r[0] << 4 | r[1]
                self.fetches.append(a)
                self.cycles += 1
                b2 = self.rom[a]
                r[p], r[p + 1] = b2 >> 4, b2 & 15
            else:                                       # JIN
                self.pc = (self.pc & 0xF00) | r[p] << 4 | r[p + 1]
        elif opr == 4:                                  # JUN
            b2 = self.fetch()
            self.pc = opa << 8 | b2
        elif opr == 5:                                  # JMS
            b2 = self.fetch()
            self.sp = (self.sp + 1) & 3
            self.pc = opa << 8 | b2
        elif opr == 6:                                  # INC
            r[opa] = (r[opa] + 1) & 15
        elif opr == 7:                                  # ISZ
            b2 = self.fetch()
            r[opa] = (r[opa] + 1) & 15
            if r[opa]:
                self.pc = (self.pc & 0xF00) | b2
        elif opr in (8, 9):                             # ADD / SUB
            self.add(r[opa], opr == 9)
        elif opr == 10:
            self.acc = r[opa]
        elif opr == 11:
            self.acc, r[opa] = r[opa], self.acc
        elif opr == 12:                                 # BBL
            self.sp = (self.sp - 1) & 3
            self.acc = opa
        elif opr == 13:
            self.acc = opa
        elif opr == 14:
            banks = active_banks(self.dcl)
            if opa < 8:
                mem.io_write(opa, banks, self.acc)
            else:
                val = mem.io_read(opa, banks)
                if opa in (8, 11):
                    self.add(val, opa == 8)
                else:
                    self.acc = val
        elif opr == 15:
            a, cy = self.acc, self.cy
            if opa == 0:
                self.acc, self.cy = 0, 0
            elif opa == 1:
                self.cy = 0
            elif opa == 2:
                self.acc, self.cy = (a + 1) & 15, (a + 1) >> 4
            elif opa == 3:
                self.cy = 1 - cy
            elif opa == 4:
                self.acc = a ^ 15
            elif opa == 5:
                self.acc, self.cy = ((a << 1) | cy) & 15, a >> 3
            elif opa == 6:
                self.acc, self.cy = (a >> 1) | (cy << 3), a & 1
            elif opa == 7:
                self.acc, self.cy = cy, 0
            elif opa == 8:
                self.acc, self.cy = (a + 15) & 15, (a + 15) >> 4
            elif opa == 9:
                self.acc, self.cy = (10 if cy else 9), 0
            elif opa == 10:
                self.cy = 1
            elif opa == 11:
                if a > 9 or cy:
                    t = a + 6
                    self.acc = t & 15
                    if t > 15:
                        self.cy = 1
            elif opa == 12:
                self.acc = KBP_T.get(a, 15)
            elif opa == 13:
                self.dcl = a & 7

    def add(self, val, sub):
        if sub:
            t = self.acc + (~val & 15) + (1 - self.cy)
        else:
            t = self.acc + val + self.cy
        self.acc, self.cy = t & 15, t >> 4



ONEBYTE = {'NOP': 0x00, 'WRM': 0xE0, 'WMP': 0xE1, 'WRR': 0xE2, 'WPM': 0xE3, 'WR0': 0xE4,
           'WR1': 0xE5, 'WR2': 0xE6, 'WR3': 0xE7, 'SBM': 0xE8, 'RDM': 0xE9, 'RDR': 0xEA,
           'ADM': 0xEB, 'RD0': 0xEC, 'RD1': 0xED, 'RD2': 0xEE, 'RD3': 0xEF, 'CLB': 0xF0,
           'CLC': 0xF1, 'IAC': 0xF2, 'CMC': 0xF3, 'CMA': 0xF4, 'RAL': 0xF5, 'RAR': 0xF6,
           'TCC': 0xF7, 'DAC': 0xF8, 'TCS': 0xF9, 'STC': 0xFA, 'DAA': 0xFB, 'KBP': 0xFC,
           'DCL': 0xFD}
REGOP = {'INC': 6, 'ADD': 8, 'SUB': 9, 'LD': 10, 'XCH': 11, 'BBL': 12, 'LDM': 13}


def assemble(src):
    """Tiny two-pass assembler. Syntax: 'label:'  'MNEM arg,arg'  'ORG n'  ';comment'."""
    lines = []
    for raw in src.strip().splitlines():
        s = raw.split(';')[0].strip()
        if s:
            lines.append(s)
    for pass_ in (0, 1):
        labels = getattr(assemble, '_labels', {}) if pass_ else {}
        rom, pc = [0] * 4096, 0
        used = set()
        listing = []
        for s in lines:
            while ':' in s:
                lab, s = s.split(':', 1)
                labels[lab.strip()] = pc
                s = s.strip()
            if not s:
                continue
            parts = s.replace(',', ' ').split()
            mn, args = parts[0].upper(), parts[1:]

            def val(x):
                if pass_ == 0 and x in labels:
                    return labels[x]
                if x in labels:
                    return labels[x]
                if x.upper().startswith('P') and x[1:].isdigit():
                    return int(x[1:])
                if x.upper().startswith('R') and x[1:].isdigit():
                    return int(x[1:])
                try:
                    return int(x, 0)
                except ValueError:
                    if pass_ == 0:
                        return 0
                    raise
            if mn == 'ORG':
                pc = val(args[0])
                continue
            start = pc
            if mn in ONEBYTE:
                code = [ONEBYTE[mn]]
            elif mn in REGOP:
                code = [REGOP[mn] << 4 | val(args[0])]
            elif mn == 'SRC':
                code = [0x21 | val(args[0]) << 1]
            elif mn == 'FIN':
                code = [0x30 | val(args[0]) << 1]
            elif mn == 'JIN':
                code = [0x31 | val(args[0]) << 1]
            elif mn == 'FIM':
                code = [0x20 | val(args[0]) << 1, val(args[1]) & 0xFF]
            elif mn in ('JUN', 'JMS'):
                a = val(args[0])
                code = [(0x40 if mn == 'JUN' else 0x50) | a >> 8, a & 0xFF]
            elif mn == 'JCN':
                a = val(args[1])
                code = [0x10 | val(args[0]), a & 0xFF]
            elif mn == 'ISZ':
                a = val(args[1])
                code = [0x70 | val(args[0]), a & 0xFF]
            elif mn == 'DB':
                code = [val(x) & 0xFF for x in args]
            else:
                raise ValueError('unknown mnemonic ' + mn)
            for byte in code:
                if pc in used:
                    raise ValueError(f'ROM overlap at {pc:03X} ({s})')
                used.add(pc)
                rom[pc] = byte
                pc += 1
            listing.append((start, code, s))
        assemble._labels = labels
    return rom, listing, labels



DIRECTED = """
        FIM P0, 0x00
        SRC P0
        LDM 9
        XCH R2
        LDM 7
        CLC
        ADD R2          ; 16 -> 0, cy=1
        DAA             ; 6, cy=1
        SUB R2
        CMC
        SUB R2
        INC R2
        LD R2
        IAC
        IAC
        IAC
        IAC
        IAC
        IAC
        DAC
        CMA
        RAL
        RAR
        RAL
        TCC
        TCS
        STC
        TCS
        LDM 4
        KBP
        LDM 6
        KBP
        LDM 8
        KBP
        CLB
        KBP
        LDM 2
        DCL
        FIM P1, 0x47    ; RAM chip1 reg 0 char 7 of bank 2
        SRC P1
        LDM 0xA
        WRM
        WR0
        LDM 3
        WR3
        WMP
        WRR
        WPM
        CLB
        RDM
        ADM
        SBM
        RD0
        RD3
        RDR
        LDM 0
        DCL
        FIM P0, 0x00
        SRC P0
        RDR
        FIM P0, 0xE0    ; FIN table address
        FIN P3
        LD R6
        LD R7
        FIM P4, 0x5A
        JIN P4          ; -> 0x05A? same page -> 0x05A
        ORG 0x05A
        JMS sub1
        JCN 4, l1       ; acc==0 ?
        NOP
l1:     LDM 3
        JCN 12, l2      ; invert(acc==0) -> jump (acc=3)
        NOP
l2:     STC
        JCN 2, l3
        NOP
l3:     JCN 10, bad     ; not carry -> no jump
        JCN 1, l4       ; test==0
        NOP
l4:     JCN 9, l5
        NOP
l5:     JCN 8, l6       ; invert(nothing) -> always
bad:    NOP
l6:     LDM 13
        XCH R9
loop:   ISZ R9, loop
        ISZ R9, l7
        NOP
l7:     JMS s1
        JMS s1
        JMS s1
        JMS s1          ; 4 deep -> wraps
        JUN 0x0FD
sub1:   BBL 0
s1:     LDM 1
        BBL 5
        ORG 0x0E0
        DB 0x3C
        ORG 0x0FD
        FIM P0, 0x10    ; FIM spanning page boundary (0x0FD..0x0FE), then JCN at 0x0FF
        DB 0x1C, 0x20   ; JCN 12 at 0x0FF/0x100 -> page-1 target 0x120
        ORG 0x120
        ISZ R10, 0x30   ; R10 != 0 -> 0x130
        ORG 0x130
        FIM P0, 0x02
        JUN 0x1FF
        ORG 0x1FF
        DB 0x31         ; JIN P0 at last location of page -> next page (0x2xx)
        ORG 0x202
        FIM P0, 0x10
        JUN 0x2FF
        ORG 0x2FF
        DB 0x30         ; FIN P0 at 0x2FF -> fetch from page 3
        JUN 0x000
        ORG 0x310
        DB 0x77
"""



DEMO = """
; Demo: 3-digit BCD addition 279 + 456 = 735, result sent to ROM output
; port 0 (WRR), stored in RAM and read back, then KBP / JMS / ISZ checks.
        FIM P1, 0x97        ; R2 = 9  (A units)   R3 = 7 (A tens)
        FIM P2, 0x26        ; R4 = 2  (A hundreds) R5 = 6 (B units)
        FIM P3, 0x54        ; R6 = 5  (B tens)     R7 = 4 (B hundreds)
        CLC
        LD  R2
        ADD R5              ; 9 + 6 = 15
        DAA                 ; -> 5, carry 1
        XCH R2
        LD  R3
        ADD R6              ; 7 + 5 + 1 = 13
        DAA                 ; -> 3, carry 1
        XCH R3
        LD  R4
        ADD R7              ; 2 + 4 + 1 = 7
        DAA                 ; -> 7, carry 0
        XCH R4
        FIM P0, 0x00
        SRC P0              ; select ROM port 0 / RAM chip 0 reg 0 char 0
        LD  R4
        WRR                 ; port <- 7
        LD  R3
        WRR                 ; port <- 3
        LD  R2
        WRR                 ; port <- 5
        WRM                 ; RAM char 0 <- 5
        CLB
        RDM                 ; ACC <- 5 (read back)
        JMS twice           ; ACC <- 2*5 = 10 via subroutine, returns 0xA
        WRR                 ; port <- 10 (0xA)
        LDM 14
        XCH R8
cnt:    ISZ R8, cnt         ; loop twice (14, 15 -> 0)
        LDM 8
        KBP                 ; 1000 -> 0100
        WRR                 ; port <- 4
halt:   JUN halt
twice:  RAL                 ; 5 -> 10 (carry was 0)
        WRR                 ; port <- 10 from inside the subroutine
        BBL 10
"""



def read_raw(path):
    """Minimal ngspice binary raw-file reader -> {name: [values]}."""
    import struct
    with open(path, 'rb') as fh:
        data = fh.read()
    hdr_end = data.index(b'Binary:\n') + len(b'Binary:\n')
    hdr = data[:hdr_end].decode('latin-1').splitlines()
    nvar = int(next(h for h in hdr if h.startswith('No. Variables')).split(':')[1])
    npts = int(next(h for h in hdr if h.startswith('No. Points')).split(':')[1])
    vi = hdr.index('Variables:')
    names = [hdr[vi + 1 + k].split()[1].lower() for k in range(nvar)]
    vals = struct.unpack(f'<{nvar*npts}d', data[hdr_end:hdr_end + 8 * nvar * npts])
    return {n: vals[k::nvar] for k, n in enumerate(names)}




# ============================================================================
# testbenches, Verilog-A memory model, result checking
# ============================================================================
import os
import pickle
import random

RESET_PERIODS = 8
VTH = -4.0            # logic threshold used by the memory model / checks (logic 1 below)


def rom_in_default(k):
    return (7 * k + 3) & 15


def gate_state(sim):
    acc = sim.word([f'acc{i}' for i in range(4)])
    r = tuple(sim.word([f'r{k}_{i}' for i in range(4)]) for k in range(16))
    stack = tuple(sum(sim.net(f's{l}_{n}_{i}') << (4 * n + i) for n in range(3) for i in range(4))
                  for l in range(4))
    return (acc, sim.net('cy'), r, sim.word(['sp0', 'sp1']), stack,
            sim.word(['dcl0', 'dcl1', 'dcl2']))


def run_gate(sim, rom, mem, ncycles, test_fn, rnd, record=None):
    bus = BusSystem(rom, mem)
    snaps = []
    for p in range(RESET_PERIODS + 8 * ncycles):
        reset = 1 if p < RESET_PERIODS else 0
        cyc = (p - RESET_PERIODS) // 8 if not reset else -1
        test = test_fn(cyc) if cyc >= 0 else 0
        drive = None if reset else bus.drive()
        o = sim.period(reset, test, drive, rnd)
        if not reset and bus.pos == 0 and sim.net('dc') == 0:
            snaps.append(gate_state(sim))
        if drive is not None and o['doe']:
            raise RuntimeError(f'bus contention in period {p}')
        if record is not None:
            record.append(dict(o, drive=drive, reset=reset, test=test, pos=bus.pos))
        bus.observe(o, reset)
    return bus, snaps


def compare(chip, rom, ncycles, seed, test_fn, label, quiet=False):
    sim = LogicSim(chip)
    rnd = random.Random(seed)
    mem_g, mem_s = MemState(random.Random(seed + 1)), MemState(random.Random(seed + 1))
    bus, snaps = run_gate(sim, rom, mem_s, ncycles, test_fn, rnd)
    gold = Golden(rom, mem_g, test_fn)
    gsnaps = [gold.state()]
    while gold.cycles < ncycles:
        gold.step()
        gsnaps.append(gold.state())
    n = min(len(snaps), len(gsnaps))
    for k in range(n):
        if snaps[k] != gsnaps[k]:
            print(f'[{label}] MISMATCH at instruction {k}\n  gate  : {snaps[k]}\n  golden: {gsnaps[k]}')
            return False
    nf = min(len(bus.fetches), len(gold.fetches))
    if bus.fetches[:nf] != gold.fetches[:nf]:
        k = next(i for i in range(nf) if bus.fetches[i] != gold.fetches[i])
        print(f'[{label}] fetch mismatch at cycle {k}')
        return False
    if gold.cycles == ncycles and mem_g.snapshot() != mem_s.snapshot():
        print(f'[{label}] RAM/port contents differ')
        return False
    if not quiet:
        print(f'[{label}] OK: {n} instructions, {nf} cycles compared')
    return True


def verify(chip, nruns=150, ncycles=250):
    import contextlib
    import io
    rom, _, _ = assemble(DIRECTED)
    ok = compare(chip, rom, 400, 11, lambda c: (c // 3) & 1, 'directed')
    seen = set()
    for sd in range(nruns):
        rnd = random.Random(5000 + sd)
        rom = [rnd.randrange(256) for _ in range(4096)]
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            r = compare(chip, rom, ncycles, 5000 + sd, lambda c, s=sd: ((c * 5 + s) >> 1) & 1, f'r{sd}')
        if not r:
            print(buf.getvalue())
            return False
        gold = Golden(rom, MemState(random.Random(1)), lambda c: 0)
        while gold.cycles < ncycles:
            seen.add(rom[gold.pc])
            gold.step()
    print(f'[random] OK: {nruns} random-ROM runs x {ncycles} cycles, '
          f'{len(seen)}/256 opcode bytes executed')
    return ok


def zero_mem():
    mem = MemState(random.Random(0))
    for b in range(4):
        for c in range(4):
            mem.ramport[b][c] = 0
            for r in range(4):
                mem.ram[b][c][r] = [0] * 16
                mem.stat[b][c][r] = [0] * 4
    mem.romport = [0] * 16
    mem.rom_in = [rom_in_default(k) for k in range(16)]
    return mem


def demo_trace(chip, rom, labels, max_cycles=400):
    """Run the program at gate level with a zero-initialised MCS-4 memory
    system; stop two cycles after the second fetch of label 'halt' (if any)."""
    sim = LogicSim(chip)
    rec = []
    mem = zero_mem()
    bus, _ = run_gate(sim, rom, mem, max_cycles, lambda c: 0, random.Random(5), rec)
    ncycles = max_cycles
    if 'halt' in labels:
        hits = [i for i, a in enumerate(bus.fetches) if a == labels['halt']]
        if len(hits) >= 2:
            ncycles = hits[1] + 2
    rec = rec[:RESET_PERIODS + 8 * ncycles]
    # golden run for final memory state
    gmem = zero_mem()
    gold = Golden(rom, gmem, lambda c: 0)
    while gold.cycles < ncycles:
        gold.step()
    return rec, ncycles, gmem


def wrr_events(rec):
    out = []
    for p, r in enumerate(rec):
        if r['pos'] == 4 and r['cmrom'] and not r['reset'] and r['drive'] == 2 \
                and p + 2 < len(rec) and rec[p + 2]['doe']:
            out.append((p + 2, rec[p + 2]['dout']))
    return out


TB_COMMON = """\
*=============================================================================
*  TESTBENCH KNOBS
*=============================================================================
*  Original MCS-4 conditions: VSS = 0 V (ground), VDD = -15 V, 740 kHz
*  two-phase clock (400 ns pulses, 400 ns PHI1->PHI2, 150 ns PHI2->PHI1).
*  Negative logic: logic 1 = negative voltage, logic 0 = VSS.
*-----------------------------------------------------------------------------
.param VDDV=-15
.param TCLK=1.35u TPW=0.4u TD1=0.4u TRF=20n
.param CBUS=10p CLOAD=10p
.param NPER={nper}
.param TSTOP={{NPER*TCLK}}

* the CPU, pins in DIP order 1..16 (pin 5 VSS = ground, pin 12 VDD)
XCPU d0 d1 d2 d3 0 phi1 phi2 sync reset test cmrom vdd cmram3 cmram2 cmram1 cmram0
+ I4004P

VVDD vdd 0 {{VDDV}}
VPHI1 phi1 0 PULSE(0 {{VDDV}} 0 {{TRF}} {{TRF}} {{TPW-TRF}} {{TCLK}})
VPHI2 phi2 0 PULSE(0 {{VDDV}} {{TPW+TD1}} {{TRF}} {{TRF}} {{TPW-TRF}} {{TCLK}})
* RESET (logic 1 = VDD) held for {nrst} clock periods, released during PHI1
VRESET reset 0 PWL(0 {{VDDV}} {{{nrst}.1*TCLK}} {{VDDV}} {{{nrst}.1*TCLK+TRF}} 0)
* TEST pin at logic 0 (VSS)
VTEST test 0 0

* bus and output loading
CB0 d0 0 {{CBUS}}
CB1 d1 0 {{CBUS}}
CB2 d2 0 {{CBUS}}
CB3 d3 0 {{CBUS}}
RK0 d0 0 1Meg
RK1 d1 0 1Meg
RK2 d2 0 1Meg
RK3 d3 0 1Meg
CL1 sync 0 {{CLOAD}}
CL2 cmrom 0 {{CLOAD}}
CL3 cmram0 0 {{CLOAD}}
CL4 cmram1 0 {{CLOAD}}
CL5 cmram2 0 {{CLOAD}}
CL6 cmram3 0 {{CLOAD}}

* bus nibble as one staircase trace (logic 1 = below -4 V)
BBUS busval 0 V=u(-4-V(d0))+2*u(-4-V(d1))+4*u(-4-V(d2))+8*u(-4-V(d3))
"""


def program_comment(listing, wrr, header):
    prog = '\n'.join(f'*   {a:03X}: {" ".join(f"{b:02X}" for b in code):<6}  {src}'
                     for a, code, src in listing)
    exp = '\n'.join(f'*   period {p:4d}: port <- {v:2d} ({v:04b})' for p, v in wrr)
    return (f'*-----------------------------------------------------------------------------\n'
            f'*  {header}\n'
            f'*-----------------------------------------------------------------------------\n'
            f'{prog}\n*\n*  Expected WRR (ROM port 0) outputs, bus value during X2:\n{exp}\n')


def pwl_memory(rec):
    """External ROM/RAM as switched PWL sources (LTSpice / any SPICE)."""
    en_pts = ['0 0']
    data = [['0 0'] for _ in range(4)]
    cur = [0] * 4
    for p, r in enumerate(rec):
        if r['drive'] is None:
            continue
        for i in range(4):
            bit = r['drive'] >> i & 1
            if bit != cur[i]:
                v0, v1 = ('0', '{VMEM1}') if bit else ('{VMEM1}', '0')
                data[i] += [f'{{{p}*TCLK+TPW}} {v0}', f'{{{p}*TCLK+TPW+TRF}} {v1}']
                cur[i] = bit
        on = f'{p}*TCLK+TPW+0.25*TD1'
        en_pts += [f'{{{on}}} 0', f'{{{on}+TRF}} 1', f'{{{p+1}*TCLK-2*TRF}} 1',
                   f'{{{p+1}*TCLK-TRF}} 0']

    def src(name, node, pts):
        lines = [f'{name} {node} 0 PWL(']
        for k in range(0, len(pts), 6):
            lines.append('+ ' + ' '.join(pts[k:k + 6]))
        lines[-1] += ')'
        return '\n'.join(lines)
    out = ['*-----------------------------------------------------------------------------',
           '*  External ROM / RAM: 4001/4002 bus responses for the program below, played',
           '*  back as switched sources.  Memory drives from 0.25*TD1 after PHI1 until the',
           '*  next PHI1, in every sub-cycle where it owns the bus (M1, M2, I/O reads).',
           '*  Regenerate with gen_i4004_pmos.py to run another program.',
           '*-----------------------------------------------------------------------------',
           '.param VMEM1=-12',
           '.model SWBUS SW(Ron=300 Roff=1e9 Vt=0.5 Vh=0)',
           src('VMEMEN', 'memen', en_pts)]
    for i in range(4):
        out.append(src(f'VMEM{i}', f'mem{i}', data[i]))
        out.append(f'SMEM{i} d{i} mem{i} memen 0 SWBUS')
    return '\n'.join(out) + '\n'


# ----------------------------------------------------------------------------
# Verilog-A MCS-4 memory system
# ----------------------------------------------------------------------------

def verilog_a(rom, rom_in, nchips=4, listing=None):
    used = [(a, b) for a, b in enumerate(rom) if b]
    rows = '\n'.join(f'      {a}: rom = {b};' for a, b in used)
    rin = '\n'.join(f'      {k}: romin = {v};' for k, v in enumerate(rom_in) if v)
    prog = ''
    if listing:
        prog = '\n'.join(f'//   {a:03X}: {" ".join(f"{x:02X}" for x in code):<6} {src}'
                         for a, code, src in listing)
    nodes, eqs, readcase = [], [], []

    def sh(n, w, tgt, clr=True):
        r = ' + gon*rr*V({n})'.format(n=n) if clr else ''
        rr = ' - rr' if clr else ''
        return (f'  I({n}) <+ ch*ddt(V({n})) + gon*({w})*(V({n}) - ({tgt})){r}'
                f' + gref*(1.0 - ({w}){rr})*(V({n}) - floor(V({n}) + 0.5));')
    for c in range(nchips):
        for rg in range(4):
            for k in range(16):
                n = f'm{c}_{rg}_{k}'
                nodes.append(n)
                eqs.append(sh(n, f'wrm*(chip=={c})*(rgi=={rg})*(chr=={k})', 'busval'))
                readcase.append(f'      {c*64 + rg*16 + k}: ramv = V({n});')
            for s_ in range(4):
                n = f'st{c}_{rg}_{s_}'
                nodes.append(n)
                eqs.append(sh(n, f'wst*(scmd=={s_})*(chip=={c})*(rgi=={rg})', 'busval'))
        n = f'mp{c}'
        nodes.append(n)
        eqs.append(sh(n, f'wmp*(chip=={c})', 'busval'))
    for k in range(16):
        n = f'rp{k}'
        nodes.append(n)
        eqs.append(sh(n, f'wrr*(rsrc_i=={k})', 'busval'))
    stcase = []
    for c in range(nchips):
        for rg in range(4):
            for s_ in range(4):
                stcase.append(f'      {c*16 + rg*4 + s_}: stv = V(st{c}_{rg}_{s_});')
    node_decl = []
    for i in range(0, len(nodes), 10):
        node_decl.append('electrical ' + ', '.join(nodes[i:i + 10]) + ';')
    return f"""\
// mcs4mem.va - Intel MCS-4 memory system (4001 ROM + one bank of 4002 RAM)
// as a Verilog-A behavioural model for ngspice (OSDI, compiled with OpenVAF).
// Generated by gen_i4004_pmos.py.
//
// It watches the 4004 pins exactly like real 4001/4002 chips do (PHI1, PHI2,
// SYNC, RESET, CM-ROM, CM-RAM0 and the data bus), and
//   * returns instruction bytes from the ROM table below during M1/M2,
//   * latches SRC addresses (X2/X3),
//   * executes I/O instructions (WRM WMP WRR WR0-3 / SBM RDM RDR ADM RD0-3)
//     on {nchips} 4002 chip(s) of bank 0 (CM-RAM0) and 16 ROM I/O ports.
//
// OpenVAF compiles continuous-time Verilog-A only (no @cross events, no
// variables that keep their value between time steps), so all sequencer and
// RAM state lives on internal nodes: each state variable is a small capacitor
// that is "written" through a clock-gated conductance and otherwise snapped
// to the nearest integer.  Values are integers carried as volts.
//
// Pins (negative logic: logic 1 is below vth):
//   d0..d3  bus (bidirectional), phi1 phi2 sync rst cmrom cmram0 (inputs)
//   rport   output: ROM output port 0 value (0..15 V)   - written by WRR
//   mport   output: RAM chip 0 output port value (0..15 V) - written by WMP
//
// Program (edit the ROM table, or regenerate from assembly, then recompile):
{prog}
`include "disciplines.vams"

module mcs4mem(d0, d1, d2, d3, phi1, phi2, sync, rst, cmrom, cmram0, rport, mport);
inout d0, d1, d2, d3;
inout phi1, phi2, sync, rst, cmrom, cmram0;
inout rport, mport;
electrical d0, d1, d2, d3, phi1, phi2, sync, rst, cmrom, cmram0, rport, mport;

// sequencer state
electrical cnt, cms, a0, a1, a2, iocmd, iov, iob, srch, srcp, srcb, bhi, blo, rsrc;
// RAM characters m<chip>_<reg>_<char>, status st<chip>_<reg>_<n>,
// RAM output ports mp<chip>, ROM output ports rp<n>
{chr(10).join(node_decl)}

parameter real vth  = -4.0;     // input threshold (V)
parameter real vsm  = 0.3;      // input transition softness (V)
parameter real v1   = -12.0;    // output level for logic 1 (V)
parameter real rout = 300.0;    // output resistance when driving (ohm)
parameter real ch   = 1e-12;    // state-node capacitance
parameter real gon  = 1e-3;     // state-node write conductance
parameter real gref = 1e-6;     // integer "refresh" conductance

analog function real lv;        // logic level 0..1 of a pin voltage
  input x, th, sm;
  real x, th, sm;
  lv = 0.5*(1.0 + tanh((th - x)/sm));
endfunction

analog function integer rom;    // program memory (4001 ROM contents)
  input a;
  integer a;
  begin
    case (a)
{rows}
      default: rom = 0;
    endcase
  end
endfunction

analog function integer romin;  // 4001 input-port values read by RDR
  input k;
  integer k;
  begin
    case (k)
{rin}
      default: romin = 0;
    endcase
  end
endfunction

real p1, p2, sy, rr0, rr, cr, c0, busval, nxt, wr, wrm, wst, wmp, wrr, drv, want, ramv, stv, ioval;
integer kc, addr, rbyte, val, cmd, iov_i, iob_i, srcp_i, srcb_i, rsrc_i, chip, rgi, chr, scmd, idx;

analog begin
  p1 = lv(V(phi1), vth, vsm);
  p2 = lv(V(phi2), vth, vsm);
  sy = lv(V(sync), vth, vsm);
  rr0 = lv(V(rst), vth, vsm);
  rr = rr0*p2;
  cr = lv(V(cmrom), vth, vsm);
  c0 = lv(V(cmram0), vth, vsm);
  busval = lv(V(d0), vth, vsm) + 2.0*lv(V(d1), vth, vsm) + 4.0*lv(V(d2), vth, vsm)
           + 8.0*lv(V(d3), vth, vsm);

  // sub-cycle counter: 0..7 = A1 A2 A3 M1 M2 X1 X2 X3; master on PHI2, slave on PHI1;
  // SYNC (X3) or RESET force the next sub-cycle to A1
  kc = floor(V(cnt) + 0.5);
  if (sy > 0.5 || rr0 > 0.5)
    nxt = 0;
  else
    nxt = (kc + 1) % 8;
  I(cms) <+ ch*ddt(V(cms)) + gon*p2*(V(cms) - nxt) + gref*(1.0 - p2)*(V(cms) - floor(V(cms) + 0.5));
  I(cnt) <+ ch*ddt(V(cnt)) + gon*p1*(V(cnt) - V(cms)) + gref*(1.0 - p1)*(V(cnt) - floor(V(cnt) + 0.5));

  // address nibbles A1..A3, I/O command at M2, SRC at X2/X3
{sh('a0', 'p2*(kc==0)', 'busval', False)}
{sh('a1', 'p2*(kc==1)', 'busval', False)}
{sh('a2', 'p2*(kc==2)', 'busval', False)}
{sh('iocmd', 'p2*(kc==4)', 'busval', False)}
{sh('iov', 'p2*(kc==4)', 'cr', False)}
{sh('iob', 'p2*(kc==4)', 'c0', False)}
{sh('srch', 'p2*(kc==6)', 'busval', False)}
{sh('srcp', 'p2*(kc==6)', 'cr', False)}
{sh('srcb', 'p2*(kc==6)', 'c0', False)}
  srcp_i = floor(V(srcp) + 0.5);
  srcb_i = floor(V(srcb) + 0.5);
{sh('rsrc', 'p2*(kc==7)*srcp_i', 'V(srch)', False)}
{sh('bhi', 'p2*(kc==7)*srcp_i*srcb_i', 'V(srch)', False)}
{sh('blo', 'p2*(kc==7)*srcp_i*srcb_i', 'busval', False)}

  addr = floor(V(a0) + 0.5) + 16*floor(V(a1) + 0.5) + 256*floor(V(a2) + 0.5);
  rbyte = rom(addr);
  cmd = floor(V(iocmd) + 0.5);
  iov_i = floor(V(iov) + 0.5);
  iob_i = floor(V(iob) + 0.5);
  rsrc_i = floor(V(rsrc) + 0.5);
  chip = floor(V(bhi) + 0.5) / 4;
  rgi = floor(V(bhi) + 0.5) % 4;
  chr = floor(V(blo) + 0.5);
  scmd = cmd % 4;

  // I/O writes happen during PHI2 of X2
  wr = p2*(kc==6)*iov_i;
  wrm = wr*(cmd==0)*iob_i;
  wmp = wr*(cmd==1)*iob_i;
  wrr = wr*(cmd==2);
  wst = wr*(cmd>=4)*(cmd<=7)*iob_i;

{chr(10).join(eqs)}

  // I/O read data
  idx = chip*64 + rgi*16 + chr;
  ramv = 0.0;
  case (idx)
{chr(10).join(readcase)}
    default: ramv = 0.0;
  endcase
  idx = chip*16 + rgi*4 + scmd;
  stv = 0.0;
  case (idx)
{chr(10).join(stcase)}
    default: stv = 0.0;
  endcase
  if (cmd == 10)
    ioval = romin(rsrc_i);
  else if (cmd >= 12)
    ioval = stv;
  else
    ioval = ramv;

  // bus drive: M1 = OPR, M2 = OPA, X2 = I/O read data; from end of PHI1 to next PHI1
  if (kc == 3) begin
    want = 1.0; val = rbyte / 16;
  end else if (kc == 4) begin
    want = 1.0; val = rbyte % 16;
  end else if (kc == 6 && iov_i == 1 && cmd >= 8 && (cmd == 10 || iob_i == 1)) begin
    want = 1.0; val = floor(ioval + 0.5);
  end else begin
    want = 0.0; val = 0;
  end
  drv = want*(1.0 - p1)*(1.0 - rr0);
  I(d0) <+ drv*(V(d0) - v1*(val % 2))/rout;
  I(d1) <+ drv*(V(d1) - v1*((val / 2) % 2))/rout;
  I(d2) <+ drv*(V(d2) - v1*((val / 4) % 2))/rout;
  I(d3) <+ drv*(V(d3) - v1*((val / 8) % 2))/rout;

  V(rport) <+ V(rp0);
  V(mport) <+ V(mp0);
end
endmodule
"""


def check_raw(path, rec, tclk=1.35e-6, vth=VTH, extra=None):
    import bisect
    w = read_raw(path)
    t = w['time']

    def at(name, tt):
        ys = w[name]
        k = bisect.bisect_left(t, tt)
        k = min(max(k, 1), len(t) - 1)
        t0, t1 = t[k - 1], t[k]
        return ys[k - 1] + (ys[k] - ys[k - 1]) * (tt - t0) / (t1 - t0) if t1 > t0 else ys[k]
    errs, checked, worst = [], 0, 99.0
    for p, r in enumerate(rec):
        if r['reset']:
            continue
        ts = (p + 0.86) * tclk
        exp = {'v(sync)': r['sync'], 'v(cmrom)': r['cmrom']}
        exp.update({f'v(cmram{k})': r[f'cmram{k}'] for k in range(4)})
        bus = r['dout'] if r['doe'] else r['drive']
        if bus is not None:
            exp.update({f'v(d{i})': bus >> i & 1 for i in range(4)})
        for name, bit in exp.items():
            v = at(name, ts)
            checked += 1
            margin = (vth - v) if bit else (v - vth)
            worst = min(worst, margin)
            if (v < vth) != bool(bit):
                errs.append((p, name, bit, round(v, 3)))
    return errs, checked, worst, w

# ============================================================================
# library / deck emission and command line
# ============================================================================
import argparse
import os
import pickle
from collections import Counter


def emit_library(chip):
    ntr = transistor_count(chip)
    used = []
    for g in chip.gates:
        if g['kind'] == 'CG' and g['shape'] not in used:
            used.append(g['shape'])
    cnt = Counter(g['shape'].name if g['kind'] == 'CG' else
                  (g['typ'] if g['kind'] == 'REG' else g['kind'])
                  for g in chip.gates if g['kind'] != 'COMMENT')
    hdr = f"""\
*=============================================================================
*  I4004P - Intel 4004-compatible CPU, full chip, PMOS-only, transistor level
*=============================================================================
*  {ntr} p-channel transistors, every one an instance of PFET.
*  Generated by gen_i4004_pmos.py.
*
*  Circuit style of the 1971 original: PMOS ratioed logic with load devices,
*  two-phase dynamic latches (pass transistors clocked directly by PHI1/PHI2,
*  storage on gate capacitance), bootstrapped output drivers, negative logic.
*
*  Subcircuit pins = 4004 DIP pins 1..16:
*    XCPU D0 D1 D2 D3 VSS PHI1 PHI2 SYNC RESET TEST CMROM VDD CMRAM3 CMRAM2
*    +    CMRAM1 CMRAM0 I4004P
*  VSS = 0 V (most positive), VDD = -15 V.  Logic 1 = negative voltage.
*
*  Timing: one clock period = one sub-cycle (PHI1 pulse, then PHI2 pulse);
*  8 periods = 1 instruction cycle A1 A2 A3 M1 M2 X1 X2 X3:
*    A1..A3  CPU sends PC[3:0], PC[7:4], PC[11:8] (PC is incremented one
*            nibble per sub-cycle as it is sent)
*    M1, M2  memory returns OPR, OPA (CPU samples at the end of PHI2)
*    X1..X3  execute; X2 I/O data (write: CPU drives ACC; read: memory drives);
*            SRC sends the register pair at X2 (even) and X3 (odd)
*  Internal state updates during PHI1; inputs are sampled at the end of PHI2.
*  SYNC is active during X3.  CM-ROM and the DCL-selected CM-RAM line(s) are
*  active at A3, at M2 of I/O instructions and at X2 of SRC.
*  RESET (logic 1) clears all registers; the first sub-cycle after it is A1
*  with PC = 0 and CM-RAM0 selected.
*
*  Cells: {', '.join(f'{k} {v}' for k, v in sorted(cnt.items()))}
*
*  PFET (and the .params RATIO LLOAD BSW PADW) must be defined first.
*=============================================================================
"""
    parts = [hdr, '*----------------------------- logic gates (ratioed PMOS) -----------------',
             '* out = NOT(switch network); a load device pulls Y toward VDD (logic 1),',
             '* conducting switches pull Y to VSS (logic 0).  S = strength multiplier.']
    parts += [emit_shape(sh) for sh in used]
    parts.append(CELL_LIB)
    parts.append('*----------------------------- the chip ------------------------------------')
    parts.append(emit_chip(chip))
    return '\n'.join(parts) + '\n', ntr


TITLE_LT = '* Intel 4004 compatible CPU - PMOS-only full chip, LTSpice testbench (gen_i4004_pmos.py)\n'
TITLE_NG = """\
* Intel 4004 compatible CPU - PMOS-only full chip, ngspice testbench with a
* Verilog-A (OSDI) MCS-4 memory system supplying program and data
*
* How to run (from the directory holding this file and mcs4mem.va):
*   1. compile the memory model with OpenVAF:
*        openvaf-r mcs4mem.va      (OpenVAF-reloaded -> OSDI 0.4, ngspice >= 44)
*     or openvaf mcs4mem.va        (OpenVAF 23.5     -> OSDI 0.3, ngspice >= 39;
*                                   this route was not tested)
*      -> mcs4mem.osdi
*   2. ngspice -b i4004_pmos_va.cir      (writes i4004_pmos_va.raw)
*      or open it interactively and plot v(rport) v(busval) v(sync)
* To run another program: python3 gen_i4004_pmos.py --asm myprog.asm,
* then repeat 1-2 (the ROM contents live in mcs4mem.va).
* Verified with ngspice-47 + OpenVAF-reloaded: ~20 min on one core.
"""


def make_decks(chip, lib, rom, listing, labels, outdir, nchips=4, max_cycles=400):
    rec, ncycles, gmem = demo_trace(chip, rom, labels, max_cycles)
    wrr = wrr_events(rec)
    nper = len(rec)
    common = TB_COMMON.format(nper=nper, nrst=RESET_PERIODS)
    comment = program_comment(listing, wrr, 'Program in the external ROM')

    # ---------------- LTSpice (PWL memory playback)
    lt = [TITLE_LT, DEVICE_KNOBS, lib, common, pwl_memory(rec), comment]
    for k, (p, v) in enumerate(wrr):
        lt.append(f'.meas TRAN PORT_OUT{k+1} FIND V(busval) AT={{({p}+0.8)*TCLK}}')
    lt.append(f'.meas TRAN IDD_AVG AVG I(VVDD) FROM={{{RESET_PERIODS}*TCLK}} TO={{TSTOP}}')
    lt.append('.meas TRAN P_AVG PARAM IDD_AVG*VDDV')
    lt.append('.tran {TCLK/40} {TSTOP} 0 {TCLK/40}')
    lt.append('.end')
    with open(os.path.join(outdir, 'i4004_pmos_tb.cir'), 'w') as fh:
        fh.write('\n'.join(lt) + '\n')

    # ---------------- ngspice + Verilog-A memory
    va = verilog_a(rom, [rom_in_default(k) for k in range(16)], nchips, listing)
    with open(os.path.join(outdir, 'mcs4mem.va'), 'w') as fh:
        fh.write(va)
    ng = [TITLE_NG, DEVICE_KNOBS, lib, common,
          '*-----------------------------------------------------------------------------',
          '*  MCS-4 memory system as a Verilog-A device (mcs4mem.va -> mcs4mem.osdi):',
          '*  4001 ROM holding the program below + 4002 RAM bank 0 + I/O ports.',
          '*  rport = ROM output port 0 value (0..15 V), mport = RAM chip 0 output port.',
          '*  Compile first:   openvaf mcs4mem.va      (OpenVAF / OpenVAF-reloaded)',
          '*-----------------------------------------------------------------------------',
          'NMEM d0 d1 d2 d3 phi1 phi2 sync reset cmrom cmram0 rport mport mcs4mem_m',
          '.model mcs4mem_m mcs4mem',
          comment,
          '.tran {TCLK/40} {TSTOP} 0 {TCLK/40}',
          '.options klu',
          '.control',
          'pre_osdi mcs4mem.osdi',
          'run']
    for k, (p, v) in enumerate(wrr):
        ng.append(f'meas tran port_out{k+1} FIND v(rport) AT={(p + 1.5) * 1.35e-6:.6e}')
    ng += [f'meas tran idd_avg AVG i(vvdd) FROM={RESET_PERIODS * 1.35e-6:.4e} TO={nper * 1.35e-6:.6e}',
           'write i4004_pmos_va.raw v(d0) v(d1) v(d2) v(d3) v(sync) v(cmrom) v(cmram0) v(cmram1)'
           ' v(cmram2) v(cmram3) v(phi1) v(phi2) v(reset) v(rport) v(mport) v(busval) i(vvdd)',
           '.endc', '.end']
    with open(os.path.join(outdir, 'i4004_pmos_va.cir'), 'w') as fh:
        fh.write('\n'.join(ng) + '\n')
    return rec, ncycles, wrr, gmem


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--verify', action='store_true', help='gate-level check vs ISA model')
    ap.add_argument('--asm', help='assembly file to put in ROM instead of the demo')
    ap.add_argument('--cycles', type=int, default=400, help='max instruction cycles to simulate')
    ap.add_argument('--ram-chips', type=int, default=4, help='4002 chips modelled in bank 0')
    ap.add_argument('--out', default='.')
    args = ap.parse_args()
    chip = build_chip()
    lib, ntr = emit_library(chip)
    print(f'I4004P: {ntr} PMOS transistors')
    if args.verify and not verify(chip):
        sys.exit(1)
    src = open(args.asm).read() if args.asm else DEMO
    rom, listing, labels = assemble(src)
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, 'i4004_pmos.lib'), 'w') as fh:
        fh.write('* I4004P library - define PFET and .params RATIO LLOAD BSW PADW first\n' + lib)
    rec, ncycles, wrr, gmem = make_decks(chip, lib, rom, listing, labels, args.out,
                                         args.ram_chips, args.cycles)
    with open(os.path.join(args.out, 'expected_trace.pkl'), 'wb') as fh:
        pickle.dump(dict(rec=rec, wrr=wrr, romport=gmem.romport, ramport=gmem.ramport), fh)
    print(f'program: {ncycles} instruction cycles, {len(rec)} clock periods; '
          f'WRR outputs: {[v for _, v in wrr]}; final ROM port 0 = {gmem.romport[0]}')


if __name__ == '__main__':
    main()
