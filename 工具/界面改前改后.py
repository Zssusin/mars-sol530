#!/usr/bin/env python3
"""界面 5：「改前 | 改后」对照图。用法：改前改后.py <改前.png> <改后.png> <输出.jpg> [标题]
两张图并排（各缩到 1280 宽），顶上两个标签。"""
import sys
from PIL import Image, ImageDraw, ImageFont
a, b, out = sys.argv[1:4]
F = ImageFont.truetype("/home/user/Documents/mars-work/地图_界面3/godot/界面/素材/NotoSansSC-VF.ttf", 28)
A = Image.open(a).convert("RGB"); B = Image.open(b).convert("RGB")
w = 1280; h = int(A.height*w/A.width)
A = A.resize((w, h), Image.LANCZOS); B = B.resize((w, h), Image.LANCZOS)
im = Image.new("RGB", (w*2 + 8, h + 44), (16, 16, 16))
im.paste(A, (0, 44)); im.paste(B, (w + 8, 44))
d = ImageDraw.Draw(im)
d.text((12, 6), "改前", font=F, fill=(255, 255, 255)); d.text((w + 20, 6), "改后" + (" · " + sys.argv[4] if len(sys.argv) > 4 else ""), font=F, fill=(255, 255, 255))
im.save(out, quality=92)
