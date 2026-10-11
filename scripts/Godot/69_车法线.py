"""毅力号：给没有法线贴图的车身图集（mars_2020_03、mars_2020_04）从基色图生成法线贴图（实景地形系统.md §17.1）。
glb（NASA 25042）只给 01、02、05、06 四张图集配了法线图；03、04 是车身两侧和后部的面板（螺钉孔、面板缝、开孔、格栅），
渲染里这些地方是平的。做法（「基色 → 高度」的老办法，CrazyBump / Substance 的 bake from albedo 同理）：
  高度 = ±(亮度 − 高斯模糊(亮度))：只留细节（缝、孔、螺钉），大块明暗（烘进图里的阴影）不当成起伏；
  正负号按 NASA 自带的法线图核对：01、02 上取「暗 = 凹」时和 01_n、02_n 的 x、y 分量都正相关（+0.12…+0.28；
  取反则都负相关，两个分量同号说明约定一致），即暗处（缝、孔、螺钉窝）是凹的；
  法线 = (−k·∂h/∂u, +k·∂h/∂行, 1) 归一化：OpenGL 约定（绿 = 图上方），和 glTF / Godot 一致。
定标：同样的做法用在有法线图的 01、02 上，和 NASA 自带的 01_n、02_n 比相关系数（核对正负号）和斜率标准差（定 k）。
标识保护：03 上的 NASA、JPL 格栅字样、04 上的名字芯片铭牌，矩形内法线置平（字样保持贴图原样，不压成凹凸）。
输出：godot/数据/sol0530/rover_n_03.png、rover_n_04.png（RGB8，1024²）。材质表「生成法线」指过去。
运行：.venv/bin/python scripts/Godot/69_车法线.py"""
import io, json, pathlib, struct
import numpy as np
from PIL import Image, ImageFilter

ROOT = pathlib.Path(__file__).resolve().parents[2]
D = ROOT/"godot"/"数据"/"sol0530"
SIGN = 1.0                                     # 高度 = +高通亮度：暗 = 凹（见上）
SIGMA = 3.0                                    # 高通的高斯半径（纹素）：缝和螺钉 1–4 纹素宽
PROTECT = {"mars_2020_03": [(180, 885, 290, 945), (388, 832, 475, 893)],   # NASA、JPL 格栅字样（x0, y0, x1, y1）
           "mars_2020_04": [(490, 62, 768, 178)]}                          # 名字芯片铭牌


def glb_images(path):
    b = path.read_bytes(); n = struct.unpack("<I", b[12:16])[0]; j = json.loads(b[20:20 + n]); b0 = 20 + n + 8
    out = {}
    for im in j["images"]:
        bv = j["bufferViews"][im["bufferView"]]; o = b0 + bv.get("byteOffset", 0)
        out[im["name"]] = Image.open(io.BytesIO(b[o:o + bv["byteLength"]])).convert("RGB")
    return out


def height(img):
    L = np.asarray(img.convert("L"), np.float32)/255.0
    blur = np.asarray(Image.fromarray((L*255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(SIGMA)), np.float32)/255.0
    return SIGN*(L - blur)


def grad(h):
    gx = (np.roll(h, -1, 1) - np.roll(h, 1, 1))*0.5
    gr = (np.roll(h, -1, 0) - np.roll(h, 1, 0))*0.5
    return gx, gr


def normal(h, k):
    gx, gr = grad(h)
    n = np.stack([-k*gx, k*gr, np.ones_like(h)], -1)
    return n/np.linalg.norm(n, axis=-1, keepdims=True)


def main():
    ims = glb_images(D/"rover.glb")
    # 定标：01、02 上和 NASA 自带法线图比
    ks = []
    for a, nn in [("mars_2020_01", "mars_2020_01_n"), ("mars_2020_02", "mars_2020_02_n")]:
        h = height(ims[a]); ref = np.asarray(ims[nn], np.float32)/127.5 - 1.0
        n1 = normal(h, 1.0)
        cx = np.corrcoef(n1[..., 0].ravel(), ref[..., 0].ravel())[0, 1]; cy = np.corrcoef(n1[..., 1].ravel(), ref[..., 1].ravel())[0, 1]
        sx = ref[..., 0].std()/max(n1[..., 0].std(), 1e-6); ks.append(sx)
        print(f"定标 {a}：相关 x {cx:+.2f}、y {cy:+.2f}；斜率标准差 NASA {ref[..., 0].std():.3f} / 本法(k=1) {n1[..., 0].std():.3f} → k {sx:.1f}")
    k = float(np.median(ks))
    for a in ["mars_2020_03", "mars_2020_04"]:
        n = normal(height(ims[a]), k)
        for x0, y0, x1, y1 in PROTECT.get(a, []): n[y0:y1, x0:x1] = (0.0, 0.0, 1.0)
        out = D/f"rover_n_{a[-2:]}.png"
        Image.fromarray((n*127.5 + 127.5).clip(0, 255).astype(np.uint8), "RGB").save(out)
        print(f"写出 {out.name}：k {k:.1f}，斜率标准差 {n[..., 0].std():.3f}")


main()
