#!/usr/bin/env python3
"""做「缺数据」提示页用的字体：Noto Sans SC 可变字体定在字重 400，只留 ASCII 和 GB2312（6763 个汉字加符号），放进 PCK。
没有数据包时 data/界面/素材 里的 17 MB 字体读不到，提示页靠这个。用法：工具/做缺数据字体.py（需要 fontTools，.venv 里有）。
输出 godot/界面/缺数据/NotoSansSC-400-GB2312.ttf（OFL，许可文本 NotoSansSC_OFL.txt 在 godot/界面/素材/）。"""
import pathlib, sys
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer
from fontTools import subset

R = pathlib.Path(__file__).resolve().parents[1]
src = R / "godot/界面/素材/NotoSansSC-VF.ttf"
out = R / "godot/界面/缺数据/NotoSansSC-400-GB2312.ttf"
chars = {chr(c) for c in range(0x20, 0x7F)}
for hi in range(0xA1, 0xF8):
    for lo in range(0xA1, 0xFF):
        try: chars.add(bytes([hi, lo]).decode("gb2312"))
        except UnicodeDecodeError: pass
chars |= set("·—…“”‘’、。，；：！？（）《》【】×°±≥≤→←↑↓")
f = TTFont(src)
f = instancer.instantiateVariableFont(f, {"wght": 400})
o = subset.Options(); o.layout_features = ["kern", "liga", "ccmp", "locl", "mark", "mkmk"]; o.notdef_outline = True; o.name_IDs = [0, 1, 2, 3, 4, 5, 6]
s = subset.Subsetter(o); s.populate(text="".join(sorted(chars))); s.subset(f)
out.parent.mkdir(parents=True, exist_ok=True); f.save(out)
print(f"{len(chars)} 个字符 → {out}（{out.stat().st_size/1e6:.2f} MB）")
