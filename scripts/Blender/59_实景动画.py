"""
实景动画（Blender，Cycles）：打开 58 存的 实景_sol0530.blend，相机绕毅力号转 120°，同时太阳按延时从早走到晚——
  「任意角度、任意太阳下都成立」正是真三维模型和 55 投影版（一张图）的区别，这段动画就演这个。
  每帧更新：太阳灯（方向、强度、颜色＝大气直射透过率）、天空图（火星大气.py 今天()；地面空气透视也读同一张图）、
  相机、像素角（微观细节按像素足迹淡出）。天空图每 KEY 帧算一张，中间线性插值（天空变化慢）。
  开 persistent data：几何与 BVH 只建一次，之后每帧只改灯、图、相机。
运行：blender -b -P scripts/Blender/59_实景动画.py -- [帧数 192] [宽 1280] [采样 32] [时刻 10:30 15:30] [预览]
     预览＝只渲首、中、尾 3 帧（640 宽）看构图与曝光。
产出：产出/Blender/实景/动画/帧/0001.png … → 产出/Blender/实景/动画/sol0530_环绕.mp4（ffmpeg）
数据：NASA/JPL-Caltech/ASU/MSSS/University of Arizona/USGS。
"""
import importlib.util, math, pathlib, subprocess, sys, time
import numpy as np
import bpy
from mathutils import Matrix, Vector

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
_spec = importlib.util.spec_from_file_location("场景58", HERE/"58_实景场景.py")
S58 = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(S58)   # 借 58 的 sun_dir、常数、路径
AT = S58.AT

BLEND = S58.SITE/"重建"/"实景_sol0530.blend"
OUT = S58.MAP/"产出"/"Blender"/"实景"/"动画"
KEY = 8                                                                  # 天空图每 8 帧算一张
RADIUS, FOV = 10.0, 55                                                   # 环绕半径（m，离车体中心）、水平视场（°）


def log(*a): print("[59]", *a, flush=True)


def hm(t):
    h, m = (int(x) for x in t.split(":")); return h + m/60


def ltst(x):
    h = int(x); m = int(round((x - h)*60)); return f"{h:02d}:{m:02d}"


def smooth(t): return t*t*(3 - 2*t)


def up2(a):
    """(h, w, c) → (2h, 2w, c) 双线性放大：天空图半分辨率算（1024×512 要 16 s，512×256 只要 2.5 s），天空很平滑看不出差别。"""
    for ax in (0, 1):
        n = a.shape[ax]; x = np.clip((np.arange(2*n) + 0.5)/2 - 0.5, 0, n - 1); i0 = np.floor(x).astype(int)
        f = (x - i0).reshape([-1 if k == ax else 1 for k in range(3)])
        a = np.take(a, i0, ax)*(1 - f) + np.take(a, np.minimum(i0 + 1, n - 1), ax)*f
    return a


def rover_center():
    """毅力号所有网格世界包围盒的中心（不含桅杆以上）。"""
    lo, hi = np.full(3, 1e9), np.full(3, -1e9)
    for o in bpy.data.collections["毅力号"].all_objects:
        if o.type != "MESH": continue
        P = np.array([tuple(o.matrix_world @ Vector(c)) for c in o.bound_box]); lo = np.minimum(lo, P.min(0)); hi = np.maximum(hi, P.max(0))
    c = (lo + hi)/2; c[2] = lo[2] + 0.9                                    # 高度取车体甲板附近
    return c


def main(opts):
    nf = int(opts[opts.index("帧数") + 1]) if "帧数" in opts else 192
    W = int(opts[opts.index("宽") + 1]) if "宽" in opts else 1280
    spp = int(opts[opts.index("采样") + 1]) if "采样" in opts else 32
    t0_, t1_ = (opts[opts.index("时刻") + 1], opts[opts.index("时刻") + 2]) if "时刻" in opts else ("10:30", "15:30")
    preview = "预览" in opts
    if preview and "宽" not in opts: W = 640
    H = W*9//16
    bpy.ops.wm.open_mainfile(filepath=str(BLEND))
    sc = bpy.context.scene
    sun = bpy.data.objects["太阳"]; sky = bpy.data.images["火星天空_今天"]
    mat = bpy.data.materials["火星表土"]

    # 相机路径：从车尾斜后方经侧面转到车头斜前方，取朝太阳的那一侧（顺光，车身和石块的影子都看得见）
    c = rover_center()
    az = math.radians(S58.ROVER_YPR[0] % 360); hd = np.array([math.sin(az), math.cos(az), 0])
    s_mid = S58.sun_dir(ltst((hm(t0_) + hm(t1_))/2))
    rot = lambda v, a: np.array([v[0]*math.cos(a) - v[1]*math.sin(a), v[0]*math.sin(a) + v[1]*math.cos(a), 0])
    side = 1 if np.dot(rot(-hd, math.radians(90)), s_mid) > 0 else -1
    bpy.context.view_layer.update(); dg = bpy.context.evaluated_depsgraph_get()
    def ground_z(x, y):
        hit, p, *_ = sc.ray_cast(dg, Vector((x, y, 500)), Vector((0, 0, -1)))
        return p.z if hit else 0.0
    cam = bpy.data.cameras.new("动画"); ob = bpy.data.objects.new("动画", cam); sc.collection.objects.link(ob)
    cam.sensor_fit = "HORIZONTAL"; cam.sensor_width = 36; cam.angle = math.radians(FOV); cam.clip_start = 0.02; cam.clip_end = 200000
    sc.camera = ob
    for o in bpy.data.objects: o.visible_camera = True                     # 58 的对照机位藏过桅杆，这里全显示

    sc.render.engine = "CYCLES"; sc.cycles.samples = spp; sc.cycles.use_denoising = True
    prefs = bpy.context.preferences.addons["cycles"].preferences
    for t in ("OPTIX", "CUDA"):
        try: prefs.compute_device_type = t; prefs.get_devices(); break
        except TypeError: continue
    for d in prefs.devices: d.use = d.type != "CPU"
    sc.cycles.device = "GPU" if any(d.type != "CPU" for d in prefs.devices) else "CPU"
    sc.render.use_persistent_data = True
    sc.render.resolution_x, sc.render.resolution_y, sc.render.resolution_percentage = W, H, 100
    sc.render.image_settings.file_format = "PNG"
    sc.render.use_stamp = True                                             # 左下角时刻条
    for k in ("date", "time", "render_time", "frame", "frame_range", "memory", "hostname", "camera", "lens", "scene",
              "marker", "filename", "sequencer_strip"):
        if hasattr(sc.render, f"use_stamp_{k}"): setattr(sc.render, f"use_stamp_{k}", False)
    sc.render.use_stamp_note = True; sc.render.stamp_font_size = max(12, W//64)
    sc.render.stamp_background = (0, 0, 0, 0.45)
    mat.node_tree.nodes["像素角"].outputs[0].default_value = cam.angle_x/W

    AT.今天(); atm = AT.Atmosphere()
    o_ = np.array([0, 0, AT.R - 2.52]); cache = {}
    def sky_at(x):
        if x not in cache:
            L, *_ = AT.env_map(atm, o_, S58.sun_dir(ltst(x)), w=sky.size[0]//2, h=sky.size[1]//2, ground_albedo=0.22); L = up2(L)
            rgba = np.ones((L.shape[0], L.shape[1], 4), np.float32); rgba[..., :3] = L; cache[x] = rgba
        return cache[x]

    frames = [0, nf//2, nf - 1] if preview else range(nf)
    fd = OUT/("预览" if preview else "帧"); fd.mkdir(parents=True, exist_ok=True)
    T0 = time.time()
    for i in frames:
        u = i/(nf - 1); e = smooth(u)
        x = hm(t0_) + (hm(t1_) - hm(t0_))*u                                 # 太阳匀速走（延时），相机缓入缓出
        s = S58.sun_dir(ltst(x))
        T = atm.transmittance(np.array([-2.52]), np.array([s[2]]))[0]; Tm = float(np.mean(T))
        sun.data.energy = S58.E_TOP*Tm; sun.data.color = tuple((T/Tm).tolist())
        sun.rotation_euler = Vector((-s).tolist()).to_track_quat("-Z", "Y").to_euler()
        k0 = (i//KEY)*KEY; k1 = min(k0 + KEY, nf - 1); w = 0 if k1 == k0 else (i - k0)/(k1 - k0)
        xa, xb = (hm(t0_) + (hm(t1_) - hm(t0_))*k/(nf - 1) for k in (k0, k1))
        sky.pixels.foreach_set(((1 - w)*sky_at(round(xa, 4)) + w*sky_at(round(xb, 4))).ravel()); sky.update(); sky.update_tag()
        if len(cache) > 4: cache.pop(next(iter(cache)))
        phi = math.radians(30 + 120*e)*side
        p = c + RADIUS*rot(-hd, phi); p[2] = ground_z(p[0], p[1]) + 1.6 + 1.2*math.sin(math.pi*e)   # 中段抬到 2.8 m 看甲板
        tgt = c + np.array([0, 0, 0.3])
        f = Vector((tgt - p).tolist()).normalized(); r = f.cross(Vector((0, 0, 1))).normalized(); up = r.cross(f)
        M = Matrix((r, up, -f)).transposed().to_4x4(); M.translation = Vector(p.tolist()); ob.matrix_world = M
        sc.render.stamp_note_text = f"Perseverance  sol 530  Jezero  LTST {ltst(x)}   sun el {math.degrees(math.asin(s[2])):.0f}°"
        sc.render.filepath = str(fd/f"{i + 1:04d}.png")
        bpy.ops.render.render(write_still=True)
        log(f"帧 {i + 1}/{nf}  {ltst(x)}  （累计 {time.time() - T0:.0f} s）")
    if preview: return
    mp4 = OUT/"sol0530_环绕.mp4"
    for enc in (["-c:v", "h264_nvenc", "-cq", "18", "-preset", "p7"], ["-c:v", "libopenh264", "-b:v", "12M"]):
        r = subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "24", "-i", str(fd/"%04d.png"), *enc,
                            "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(mp4)])
        if r.returncode == 0: log(f"→ {mp4}"); break


if __name__ == "__main__":
    main(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
