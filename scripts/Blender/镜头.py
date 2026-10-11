"""
镜头表 + 坐标换算。50（venv）与 51（Blender）都读它，纯 Python + numpy。

场景坐标：以区域中心为原点的当地东-北-天坐标（x 东、y 北、z 天，单位 km），火星中心在 (0, 0, −R)。
坐标小，Cycles 的 float32 精度在 1 km 外也有厘米级。
太阳：正典 2100-03-15，Ls 17.9°，太阳赤纬 +7.5°；时刻用当地真太阳时（火星时，1/24 火星日）。
"""
import math
import numpy as np

R = 3396.2

REGIONS = {                                           # 数据区域：东经 lon0, lon1；纬度 lat0（北）, lat1（南）
    "梅拉斯": (283.0, 303.0, -3.0, -17.0),
}

SHOTS = {
    # 科普莱特斯水道中间、湖面上 800 m，顺峡谷往东看：北壁（左）背光，南壁（右）迎着东北来的晨光
    "科普莱特斯峡谷": dict(
        data="梅拉斯",
        cam=(295.3, -12.40, -3.0),                    # 东经、纬度、基准面以上高度（km）
        heading=100.0, pitch=3.0, fov=70.0,           # 航向（北起顺时针）、俯仰、水平视场（度）
        time=7.6, dec=7.5,                            # 当地真太阳时（火星时）、太阳赤纬
        title="科普莱特斯峡谷　2100 年 3 月 15 日 早晨",
    ),
    # 南岸山脊上空 2.5 km（山脊约 +4 km，比湖面高近 8 km）俯瞰科普莱特斯：脚下的坡一直落到湖，北壁在对面 40–110 km
    "科普莱特斯俯瞰": dict(
        data="梅拉斯",
        cam=(296.55, -13.40, None), agl=2.5,          # 高度给 None ＝ 按地面以上 agl km（51 查高程图）
        heading=350.0, pitch=-14.0, fov=70.0,
        time=9.8, dec=7.5,                            # 上午：太阳约 50°，北壁受光
        title="科普莱特斯峡谷南缘俯瞰　2100 年 3 月 15 日 上午",
    ),
    # 火星车视角：梅拉斯深谷南部，浅色层状沉积陡坎脚下的岩块坡，离地 1.6 m（桅杆相机高度），抬头朝北看陡坎
    # 近景用 HiRISE（52_近景数据），远景接 50 的 HRSC/CTX
    "梅拉斯层状沉积": dict(
        data="梅拉斯", near="Melas_2891E_131S",
        cam=(289.0892, -13.0297, None), agl=0.0016,   # 陡坎下半段的岩块坡（坡约 10°，往北 1.5 km 升 600 m）
        heading=5.0, pitch=16.0, fov=70.0,            # 抬头看坡上的陡坎；Navcam 45°、Mastcam-34 15°，这里取 70°
        time=9.5, dec=7.5,                            # 上午：太阳东北偏东约 48°，朝南的坎面受光
        title="梅拉斯深谷 浅色层状沉积　2100 年 3 月 15 日 上午",
    ),
}
PPD = 128                                            # 高程纹理分辨率（原始 463 m）
PPD_WATER = 64                                        # 水面网格


def unit_pf(lon, lat):
    """经纬度（度）→ 火星固连坐标单位向量。"""
    lo, la = np.radians(lon), np.radians(lat)
    return np.stack([np.cos(la)*np.cos(lo), np.cos(la)*np.sin(lo), np.sin(la)], -1)


class Frame:
    """区域中心（或指定中心，近景用相机处）的东-北-天坐标。"""
    def __init__(self, region, center=None):
        lon0, lon1, lat0, lat1 = region
        self.lonc, self.latc = center if center else ((lon0 + lon1)/2, (lat0 + lat1)/2)
        lo, la = math.radians(self.lonc), math.radians(self.latc)
        self.E = np.array([-math.sin(lo), math.cos(lo), 0.0])
        self.N = np.array([-math.sin(la)*math.cos(lo), -math.sin(la)*math.sin(lo), math.cos(la)])
        self.U = np.array([math.cos(la)*math.cos(lo), math.cos(la)*math.sin(lo), math.sin(la)])
        self.M = np.stack([self.E, self.N, self.U])                       # 固连 → 场景（旋转）
        self.C = np.array([0.0, 0.0, -R])                                 # 火星中心

    def dir(self, v_pf): return np.asarray(v_pf) @ self.M.T

    def pos(self, lon, lat, r):
        """经纬度 + 到火星中心的距离（km）→ 场景坐标。"""
        return self.dir(unit_pf(lon, lat)*np.asarray(r)[..., None]) + self.C

    def enu_at(self, lon, lat):
        """某点的当地 东、北、天 方向（场景坐标）。"""
        lo, la = math.radians(lon), math.radians(lat)
        e = np.array([-math.sin(lo), math.cos(lo), 0.0])
        n = np.array([-math.sin(la)*math.cos(lo), -math.sin(la)*math.sin(lo), math.cos(la)])
        u = np.array([math.cos(la)*math.cos(lo), math.cos(la)*math.sin(lo), math.sin(la)])
        return self.dir(e), self.dir(n), self.dir(u)


def camera(shot, F):
    """→ (位置, 前, 右, 上)，场景坐标。"""
    lon, lat, alt = shot["cam"]
    p = F.pos(lon, lat, R + alt)
    e, n, u = F.enu_at(lon, lat)
    h, pt = math.radians(shot["heading"]), math.radians(shot["pitch"])
    f = math.cos(pt)*(math.sin(h)*e + math.cos(h)*n) + math.sin(pt)*u
    right = np.cross(f, u); right /= np.linalg.norm(right)
    up = np.cross(right, f)
    return p, f, right, up


def sun_dir(shot, F):
    """太阳方向（场景坐标）：赤纬 dec，时角由相机所在经度的当地真太阳时给出。"""
    lon = shot["cam"][0]
    H = 15.0*(shot["time"] - 12.0)                    # 时角（上午为负）
    lon_ss = lon - H                                  # 东经：上午太阳下点在东边
    return F.dir(unit_pf(lon_ss, shot["dec"]))


def sun_altaz(shot, F):
    s = sun_dir(shot, F)
    e, n, u = F.enu_at(shot["cam"][0], shot["cam"][1])
    el = math.degrees(math.asin(s @ u))
    az = math.degrees(math.atan2(s @ e, s @ n)) % 360
    return el, az


if __name__ == "__main__":
    for k, s in SHOTS.items():
        F = Frame(REGIONS[s["data"]])
        el, az = sun_altaz(s, F)
        print(k, f"太阳高度 {el:.1f}°，方位 {az:.1f}°；相机航向 {s['heading']}°")
