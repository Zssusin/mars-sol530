# 界面 v3「丙」对比图：读 godot/界面/截图/、godot/玩法/截图/ 下的自测截图（界面/测试.sh、玩法/测试.sh 产出，不进 git），
#   拼成 docs/界面/图/丙_*.jpg（1600 宽，q80）。每格左下角写标签（中文字体用 godot/界面/素材 的 Noto）。
#   用法：.venv/bin/python 工具/界面对比图.py   （先跑：丙 / --界面=旧 各 2560x1440 两套自测，丙 1920x1080 一套）
import os
from PIL import Image, ImageDraw, ImageFont
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
G = R + "/godot"; OUT = R + "/docs/界面/图"; os.makedirs(OUT, exist_ok=True)
F = ImageFont.truetype(G + "/界面/素材/NotoSansSC-VF.ttf", 18)
UI, UIo, PL, PLo = G + "/界面/截图/2560x1440", G + "/界面/截图/2560x1440_旧", G + "/玩法/截图/2560x1440", G + "/玩法/截图/2560x1440_旧"
UI1, PL1 = G + "/界面/截图/1920x1080", G + "/玩法/截图/1920x1080"


def sheet(name, rows, w=1600):
    cw = w // 2; ch = cw * 9 // 16
    S = Image.new("RGB", (w, ch * len(rows)), (16, 16, 16)); d = ImageDraw.Draw(S)
    for r, row in enumerate(rows):
        for c, (path, lab) in enumerate(row):
            if path is None or not os.path.exists(path): continue
            im = Image.open(path).convert("RGB").resize((cw, ch), Image.LANCZOS); S.paste(im, (c * cw, r * ch))
            tw = d.textlength(lab, font=F); y0 = r * ch + ch - 26; d.rectangle([c * cw, y0, c * cw + tw + 14, y0 + 26], fill=(0, 0, 0)); d.text((c * cw + 7, y0 + 2), lab, font=F, fill=(255, 255, 255))
        d.line([(cw, r * ch), (cw, r * ch + ch)], fill=(16, 16, 16), width=3)
    S.save(f"{OUT}/{name}.jpg", quality=80, optimize=True); print(name, S.size, os.path.getsize(f"{OUT}/{name}.jpg") // 1024, "KB")


P = lambda d, n: f"{d}/{n}.png"
sheet("丙_跟车", [[(P(UIo, n), f"v2 仪表式 · {t}"), (P(UI, n), f"丙 · {t}")] for n, t in [("1_直行", "跟车直行"), ("2_阿克曼左弧", "阿克曼左弧"), ("4_斜坡倾角", "斜坡告警")]])
sheet("丙_桅杆俯视", [[(P(UIo, "5_桅杆_右弧"), "v2 · 桅杆"), (P(UI, "5_桅杆_右弧"), "丙 · 桅杆（地平线方位字、两侧水平标）")],
                    [(P(UIo, "7_俯视_远图_上午"), "v2 · 俯视"), (P(UI, "7_俯视_远图_上午"), "丙 · 俯视")],
                    [(P(UI, "8_完整档"), "丙 · 完整档（读数牌、倾角弧常驻）"), (P(UI, "9_兴趣点"), "丙 · 兴趣点小标（20–100 m）")]])
sheet("丙_玩法", [[(P(PLo, n), f"v2 · {t}"), (P(PL, n), f"丙 · {t}")] for n, t in [("兴趣点_2_导览卡", "导览卡"), ("B_5_执行_HUD", "B 执行（跟车）"), ("B_6_执行_桅杆", "B 执行（桅杆）")]])
sheet("丙_B页面", [[(P(PL, "B_1_下行卡"), "丙 · 下行卡（小图：稀疏风险标记）"), (P(PL, "B_3_规划图_预演"), "丙 · 规划图（小三角＝高风险、小叉＝不可通行）")], [(P(PL, "B_7_报告卡"), "丙 · 报告卡"), (P(PL, "B_8_报告_倾角"), "丙 · 报告卡（倾角超限）")]])
sheet("丙_细节", [[(P(UI, "10_石块挡环"), "丙 · 罗盘环被石块挡住（石块第 19 层）"), (P(UI, "10b_石块挡环_旧"), "之前 · 环投到石块上")],
                  [(P(PL, "兴趣点_1_出发_导览卡"), "丙 · 导览卡避开车身"), (P(PL, "兴趣点_4_远点导览卡"), "丙 · 远点导览卡（小标不在画面里，放左侧）")]])
sheet("丙_1080p", [[(P(UI1, "1_直行"), "1080p · 跟车"), (P(UI1, "5_桅杆_右弧"), "1080p · 桅杆")],
                   [(P(PL1, "兴趣点_2_导览卡"), "1080p · 导览卡"), (P(PL1, "B_6_执行_桅杆"), "1080p · B 执行（桅杆）")],
                   [(P(PL1, "B_1_下行卡"), "1080p · 下行卡"), (P(PL1, "B_3_规划图_预演"), "1080p · 规划图")]])
