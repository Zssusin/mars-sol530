"""对拍比较：C++（cpp_*.bin）对 GDScript 原版（gd_*.bin）。逐位相同才算过；不同时报最大差。
用法：python3 parity_compare.py <目录>
"""
import struct
import sys

d = sys.argv[1]


def rd(name):
    with open(f"{d}/{name}", "rb") as f:
        return f.read()


class R:
    def __init__(self, b):
        self.b, self.o = b, 0

    def i32(self):
        v = struct.unpack_from("<i", self.b, self.o)[0]
        self.o += 4
        return v

    def f64(self):
        v = struct.unpack_from("<d", self.b, self.o)[0]
        self.o += 8
        return v

    def raw(self, n):
        v = self.b[self.o : self.o + n]
        self.o += n
        return v


ok = True


def report(name, same, total, maxdiff=None):
    global ok
    ok = ok and same == total
    extra = "" if maxdiff is None else f"，最大差 {maxdiff:.3g}"
    print(f"  {'✓' if same == total else '✗'} {name}：{same}/{total} 逐位相同{extra}")


# 1 逐点：每点 10 个 double
names = ["h_data(k0)", "h_data(k3)", "dem_l", "W0", "W1", "W2", "W3", "地貌 h", "margin", "h_cpu"]
a, b = rd("cpp_points.bin"), rd("gd_points.bin")
n = len(a) // 80
print(f"1 逐点（{n} 点）")
for k, nm in enumerate(names):
    same, md = 0, 0.0
    for i in range(n):
        x = a[(i * 10 + k) * 8 : (i * 10 + k) * 8 + 8]
        y = b[(i * 10 + k) * 8 : (i * 10 + k) * 8 + 8]
        if x == y:
            same += 1
        else:
            md = max(md, abs(struct.unpack("<d", x)[0] - struct.unpack("<d", y)[0]))
    report(nm, same, n, md if same != n else None)

# 2 区块
print("2 撒石区块")
ra, rb = R(rd("cpp_tiles.bin")), R(rd("gd_tiles.bin"))
nt = struct.unpack_from("<i", rd("tiles.bin"), 0)[0]
same_t, rows, same_rows, md = 0, 0, 0, 0.0
for t in range(nt):
    ka, kb = ra.i32(), rb.i32()
    ta, tb = {}, {}
    for _ in range(ka):
        ty, sz = ra.i32(), ra.i32()
        ta[ty] = ra.raw(sz * 4)
    for _ in range(kb):
        ty, sz = rb.i32(), rb.i32()
        tb[ty] = rb.raw(sz * 4)
    if ta == tb and list(ta) == list(tb):
        same_t += 1
    for ty in set(ta) | set(tb):
        xa, xb = ta.get(ty, b""), tb.get(ty, b"")
        na, nb = len(xa) // 64, len(xb) // 64
        rows += max(na, nb)
        for r in range(min(na, nb)):
            if xa[r * 64 : r * 64 + 64] == xb[r * 64 : r * 64 + 64]:
                same_rows += 1
            else:
                fa = struct.unpack("<16f", xa[r * 64 : r * 64 + 64])
                fb = struct.unpack("<16f", xb[r * 64 : r * 64 + 64])
                md = max(md, max(abs(p - q) for p, q in zip(fa, fb)))
report("区块（类型顺序与内容）", same_t, nt)
report("石块行（16 float）", same_rows, rows, md if same_rows != rows else None)

# 3 选块
print("3 CDLOD 选块")
ra, rb = R(rd("cpp_select.bin")), R(rd("gd_select.bin"))
for c in range(3):
    na, nb = ra.i32(), rb.i32()
    la = [(ra.i32(), ra.raw(32), ra.i32()) for _ in range(na)]
    lb = [(rb.i32(), rb.raw(32), rb.i32()) for _ in range(nb)]
    report(f"机位 {c}：{na} 块 / {nb} 块", sum(1 for p, q in zip(la, lb) if p == q), max(na, nb))

# 4 收集（实例顺序不要求相同：比多重集）
print("4 撒石收集（每类型每级的实例多重集）")
ra, rb = R(rd("cpp_collect.bin")), R(rd("gd_collect.bin"))
for c in range(3):
    sa = (ra.i32(), ra.i32())
    sb = (rb.i32(), rb.i32())
    tot, same = 0, 0
    for ty in range(5):
        for l in range(3):
            xa = ra.raw(ra.i32() * 4)
            xb = rb.raw(rb.i32() * 4)
            A = sorted(xa[i : i + 64] for i in range(0, len(xa), 64))
            B = sorted(xb[i : i + 64] for i in range(0, len(xb), 64))
            tot += max(len(A), len(B))
            same += sum(1 for p, q in zip(A, B) if p == q) if len(A) == len(B) else 0
    report(f"机位 {c}：区块/石块 C++ {sa} GDScript {sb}", same, tot)

print("\n全部逐位一致" if ok else "\n有不一致")
sys.exit(0 if ok else 1)
