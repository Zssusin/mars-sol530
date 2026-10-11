# cmp.py <out.jpg> <A.png> <B.png> [标题A] [标题B] [放大倍数]：上排 A、B，下排 |A−B|×k 热图 和 A/B 局部放大（右下 1/4 区的中心 400×225）
import sys, numpy as np
from PIL import Image, ImageDraw, ImageFont
out, fa, fb = sys.argv[1:4]; ta = sys.argv[4] if len(sys.argv) > 4 else "A"; tb = sys.argv[5] if len(sys.argv) > 5 else "B"; k = float(sys.argv[6]) if len(sys.argv) > 6 else 8
A = Image.open(fa).convert("RGB"); B = Image.open(fb).convert("RGB")
a = np.asarray(A).astype(float); b = np.asarray(B).astype(float)
d = np.abs(a - b).max(-1)
H, W = d.shape
heat = np.clip(d*k, 0, 255).astype(np.uint8)
hm = Image.fromarray(np.stack([heat, heat//3, 255 - heat], -1))
w2 = 800; h2 = int(H*w2/W)
cy, cx = int(H*float(sys.argv[7]) if len(sys.argv) > 7 else H*0.62), int(W*float(sys.argv[8]) if len(sys.argv) > 8 else W*0.5)
cw = W//5; ch = int(cw*h2/(w2/2))
box = (cx - cw//2, cy - ch//2, cx + cw//2, cy + ch//2)
ca = A.crop(box).resize((w2//2, h2), Image.LANCZOS); cb = B.crop(box).resize((w2//2, h2), Image.LANCZOS)
S = Image.new("RGB", (2*w2, 2*h2), (0, 0, 0))
S.paste(A.resize((w2, h2)), (0, 0)); S.paste(B.resize((w2, h2)), (w2, 0)); S.paste(hm.resize((w2, h2)), (0, h2))
crop = Image.new("RGB", (w2, h2)); crop.paste(ca, (0, 0)); crop.paste(cb, (w2//2, 0)); S.paste(crop, (w2, h2))
dr = ImageDraw.Draw(S)
try: font = ImageFont.truetype("/usr/share/fonts/google-noto-sans-mono-cjk-vf-fonts/NotoSansMonoCJK-VF.ttc", 22)
except Exception: font = ImageFont.load_default()
for (x, y, t) in [(8, 6, ta), (w2 + 8, 6, tb), (8, h2 + 6, "|差| × %g（平均 %.2f DN，>2 DN %.1f%%，>8 DN %.2f%%）" % (k, np.abs(a - b).mean(), (d > 2).mean()*100, (d > 8).mean()*100)), (w2 + 8, h2 + 6, "局部放大：左 " + ta + "，右 " + tb)]:
    dr.text((x + 1, y + 1), t, fill=(0, 0, 0), font=font); dr.text((x, y), t, fill=(255, 255, 255), font=font)
S.save(out, quality=80)
print(out, "平均 %.3f DN  >2DN %.2f%%  >8DN %.3f%%" % (np.abs(a - b).mean(), (d > 2).mean()*100, (d > 8).mean()*100))
