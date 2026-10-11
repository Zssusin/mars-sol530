"""独立实现 BHMIE（Bohren & Huffman 1983 附录 A 的算法）核对 miepython；再核对瑞利极限。"""
import numpy as np, math, miepython as mp
def bhmie(x, m, mu):
    nstop = int(x + 4*x**(1/3) + 2); y = m*x
    nmx = int(max(nstop, abs(y)) + 15)
    D = np.zeros(nmx + 1, complex)
    for n in range(nmx, 0, -1): D[n-1] = n/y - 1/(D[n] + n/y)
    S1 = np.zeros(len(mu), complex); S2 = np.zeros(len(mu), complex)
    pim1 = np.zeros(len(mu)); pin = np.ones(len(mu))
    psi0 = math.cos(x); psi1 = math.sin(x); chi0 = math.sin(x); chi1 = -math.cos(x)
    xi1 = complex(psi1, -chi1); qext = qsca = 0.0
    for n in range(1, nstop + 1):
        if n > 1: pim1, pin = pin, ((2*n - 1)/(n - 1))*mu*pin - (n/(n - 1))*pim1
        tau = n*mu*pin - (n + 1)*pim1
        fn = (2*n + 1)/(n*(n + 1))
        psi = (2*n - 1)*psi1/x - psi0; chi = (2*n - 1)*chi1/x - chi0; xi = complex(psi, -chi)
        an = ((D[n]/m + n/x)*psi - psi1)/((D[n]/m + n/x)*xi - xi1)
        bn = ((m*D[n] + n/x)*psi - psi1)/((m*D[n] + n/x)*xi - xi1)
        S1 += fn*(an*pin + bn*tau); S2 += fn*(an*tau + bn*pin)
        qsca += (2*n + 1)*(abs(an)**2 + abs(bn)**2); qext += (2*n + 1)*(an + bn).real
        psi0, psi1 = psi1, psi; chi0, chi1 = chi1, chi; xi1 = complex(psi1, -chi1)
    return S1, S2, 2/x**2*qext, 2/x**2*qsca
mu = np.cos(np.radians(np.array([0., 0.5, 2, 10, 45, 90, 135, 180])))
for m, x in [(1.50 - 0.005j, 17.1), (1.5 - 0.0013j, 8.5), (1.55 + 0j, 5.213), (1.5 - 0.0077j, 21.4)]:
    S1, S2, qe, qs = bhmie(x, m, mu)
    T1, T2 = mp.S1_S2(m, x, mu, norm='bohren')
    qe2, qs2, _, g2 = mp.efficiencies_mx(m, x)
    print(f"m={m} x={x}: max|ΔS|/|S|={max(np.max(abs(S1-T1)/abs(T1)), np.max(abs(S2-T2)/abs(T2))):.2e}  Qext {qe:.6f} vs {qe2:.6f}  Qsca {qs:.6f} vs {qs2:.6f}")
x = 0.01; m = 1.5 - 0.0j
qs = mp.efficiencies_mx(m, x)[1]; ray = 8/3*x**4*abs((m*m - 1)/(m*m + 2))**2
print("瑞利极限 Qsca", qs, "解析", ray, "比", qs/ray)
