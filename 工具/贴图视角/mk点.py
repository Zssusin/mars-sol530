import re, json, sys
txt = open(sys.argv[1], encoding="utf-8").read()
H = {}
for l in txt.splitlines():
    m = re.match(r"\[贴图高\] (\S+),(\S+) (.*)", l)
    if m: H[(float(m[1]), float(m[2]))] = [float(x) for x in m[3].split()]
def c(E, N): return H[(float(E), float(N))][12]
spots = {"A近": (5, 3, [-2, -17, -57], [5, 20, 60]), "B中": (60, 20, [15, 0, -40], [5, 20, 60]), "C远": (-30, -120, [-125, -140, -180], [5, 20, 60])}
out = {}
for k, (E, N, cn, ds) in spots.items():
    out[k] = dict(E=E, N=N, y0=c(E, N), grid=H[(float(E), float(N))], cam_gy={str(d): c(E, n) for d, n in zip(ds, cn)})
json.dump(out, open("点.json", "w"), ensure_ascii=False, indent=1)
print(json.dumps(out, ensure_ascii=False)[:600])
