"""
平面平行大气的蒙特卡洛辐射传输（参照解）：给 火星大气.py 的 Hillaire 多次散射近似做校验 / 定标。
同 今天()：瑞利与尘埃同一标高（10.8 km）→ 平面平行下只有总光学厚度要紧，用光学深度坐标走光子。
相函数同 火星大气.py：瑞利 3/16π(1+c²)，尘埃双 Henyey-Greenstein（前向 g 0.72 占 90%，后向 −0.25）；单次散射反照率按通道；
地面朗伯（反照率同 火星大气.GROUND_ALBEDO），反射后接着走。
统计：每次到达地面的光子权重 → 地面向下总通量（直射 + 漫射），除以大气顶水平通量 μ0·E0。
另外按到达方向分仰角统计漫射，看天光的角分布。
"""
import math, sys, pathlib
import numpy as np
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]/"scripts"/"Blender"))
import 火星大气 as AT


def sample_hg(g, u):
    s = (1 - g*g)/(1 - g + 2*g*u)
    return (1 + g*g - s*s)/(2*g)


def sample_rayleigh(u):
    # 反函数：c³ + 3c = 8u − 4 的实根
    q = 4*u - 2
    a = np.cbrt(-q + np.sqrt(q*q + 1)); b = np.cbrt(-q - np.sqrt(q*q + 1))
    return a + b


def rotate(mu, phi_dir_x, phi_dir_y, cth, rng):
    """方向 (sx, sy, mu) 按散射角余弦 cth、随机方位转。返回新的 (sx, sy, mu)。"""
    ph = 2*math.pi*rng.random(mu.shape)
    sth = np.sqrt(np.maximum(1 - cth*cth, 0))
    ux, uy, uz = phi_dir_x, phi_dir_y, mu
    den = np.sqrt(np.maximum(1 - uz*uz, 1e-12))
    nx = sth*(ux*uz*np.cos(ph) - uy*np.sin(ph))/den + ux*cth
    ny = sth*(uy*uz*np.cos(ph) + ux*np.sin(ph))/den + uy*cth
    nz = -sth*np.cos(ph)*den + uz*cth
    vert = den < 1e-6
    nx = np.where(vert, sth*np.cos(ph), nx); ny = np.where(vert, sth*np.sin(ph), ny); nz = np.where(vert, cth*np.sign(uz), nz)
    n = np.sqrt(nx*nx + ny*ny + nz*nz)
    return nx/n, ny/n, nz/n


def run(tau_r, tau_m, ssa, alb, mu0, n=1_000_000, seed=1, max_ev=400):
    """返回（向下总通量 / μ0E0，其中直射部分，漫射按到达仰角的直方图）。"""
    rng = np.random.default_rng(seed)
    tt = tau_r + tau_m
    z = np.zeros(n)                       # 光学深度（0 = 顶，tt = 地面）
    dx = np.full(n, math.sqrt(1 - mu0*mu0)); dy = np.zeros(n); dz = np.full(n, -mu0)   # dz < 0 向下
    w = np.ones(n); scat = np.zeros(n, bool); alive = np.ones(n, bool)
    E = 0.0; Edir = 0.0; hist = np.zeros(18)
    for ev in range(max_ev):
        idx = np.nonzero(alive)[0]
        if idx.size == 0: break
        l = -np.log(rng.random(idx.size))
        zn = z[idx] - l*dz[idx]           # 往下走 dz<0 → 光学深度增加
        hit = zn >= tt; out = zn <= 0
        # 到地面
        hi = idx[hit]
        if hi.size:
            E += w[hi].sum(); Edir += w[hi][~scat[hi]].sum()
            el = np.degrees(np.arcsin(np.clip(-dz[hi], 0, 1)))
            m = scat[hi]
            hist += np.histogram(el[m], bins=18, range=(0, 90), weights=w[hi][m])[0]
            # 朗伯反射
            w[hi] *= alb; z[hi] = tt
            u = rng.random(hi.size); dz[hi] = np.sqrt(u); ph = 2*math.pi*rng.random(hi.size)
            s = np.sqrt(1 - u); dx[hi] = s*np.cos(ph); dy[hi] = s*np.sin(ph); scat[hi] = True
            alive[hi[w[hi] < 1e-4]] = False
        alive[idx[out]] = False
        sc = idx[~hit & ~out]
        if sc.size == 0: continue
        z[sc] = zn[~hit & ~out]
        isd = rng.random(sc.size) < tau_m/tt
        w[sc] *= np.where(isd, ssa, 1.0)
        u = rng.random(sc.size)
        lobe = rng.random(sc.size) < AT.W_FWD
        cd = np.where(lobe, sample_hg(AT.G_FWD, u), sample_hg(AT.G_BACK, u))
        cr = sample_rayleigh(u)
        cth = np.clip(np.where(isd, cd, cr), -1, 1)
        dx[sc], dy[sc], dz[sc] = rotate(dz[sc], dx[sc], dy[sc], cth, rng) if False else rotate_full(dx[sc], dy[sc], dz[sc], cth, rng)
        scat[sc] = True
        alive[sc[w[sc] < 1e-4]] = False
    return E/n, Edir/n, hist/n


def rotate_full(ux, uy, uz, cth, rng):
    ph = 2*math.pi*rng.random(ux.shape)
    sth = np.sqrt(np.maximum(1 - cth*cth, 0))
    den = np.sqrt(np.maximum(1 - uz*uz, 1e-12))
    nx = sth*(ux*uz*np.cos(ph) - uy*np.sin(ph))/den + ux*cth
    ny = sth*(uy*uz*np.cos(ph) + ux*np.sin(ph))/den + uy*cth
    nz = -sth*np.cos(ph)*den + uz*cth
    vert = den < 1e-6
    nx = np.where(vert, sth*np.cos(ph), nx); ny = np.where(vert, sth*np.sin(ph), ny); nz = np.where(vert, cth*np.sign(uz), nz)
    nn = np.sqrt(nx*nx + ny*ny + nz*nz)
    return nx/nn, ny/nn, nz/nn


def site_taus(tau):
    """今天(tau) 的站点（−2.52 km）瑞利与尘埃光学厚度（三通道）。"""
    AT.今天(tau=tau)
    f = math.exp(2.52/AT.HR)
    return AT.TAU_R*f, np.asarray(AT.TAU_M)*f, AT.SSA_M.copy()


if __name__ == "__main__":
    mu0 = float(sys.argv[1]) if len(sys.argv) > 1 else 0.7006
    taus = [float(x) for x in sys.argv[2:]] or [0.3, 0.67, 1.5, 3, 5]
    for tau in taus:
        tr, tm, ssa = site_taus(tau)
        row = []
        for c in range(3):
            E, Ed, h = run(tr[c], tm[c], ssa[c], AT.GROUND_ALBEDO[c], mu0, n=400_000, seed=c + 1)
            row.append((E, Ed))
        print(f"τ {tau:4}: 总 {[round(r[0], 4) for r in row]}  直射 {[round(r[1], 4) for r in row]}  漫射 {[round(r[0] - r[1], 4) for r in row]}", flush=True)
