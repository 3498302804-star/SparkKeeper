"""生成 SparkKeeper AppIcon（1024x1024 PNG），纯 Pillow 绘制火焰图标。"""
import math
from PIL import Image, ImageDraw, ImageFilter

S = 1024
img = Image.new("RGB", (S, S), (18, 18, 22))
d = ImageDraw.Draw(img)

# 背景径向渐变（深紫 -> 橙黑）
for r in range(S, 0, -2):
    t = r / S
    rr = int(24 + 42 * (1 - t))
    gg = int(14 + 26 * (1 - t))
    bb = int(36 + 30 * (1 - t))
    d.ellipse([S / 2 - r, S / 2 - r, S / 2 + r, S / 2 + r], fill=(rr, gg, bb))

glow = Image.new("RGB", (S, S), (0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse([150, 250, 880, 900], fill=(255, 96, 20))
glow = glow.filter(ImageFilter.GaussianBlur(160))
img = Image.blend(img, Image.composite(glow, img, glow.convert("L")), 0.55)
d = ImageDraw.Draw(img)


def bezier(points, steps=160):
    out = []
    n = len(points) - 1
    for i in range(steps + 1):
        t = i / steps
        x = y = 0.0
        for k, (px, py) in enumerate(points):
            c = math.comb(n, k) * (t ** k) * ((1 - t) ** (n - k))
            x += c * px
            y += c * py
        out.append((x, y))
    return out


def flame(draw, scale, color, dy=0.0, top=0.0):
    cx = S / 2
    pts = [
        (cx, 200 + top + dy),
        (cx + 210 * scale, 430 + dy),
        (cx + 250 * scale, 600 + dy),
        (cx + 120 * scale, 800 + dy),
        (cx - 40 * scale, 860 + dy),
        (cx - 240 * scale, 720 + dy),
        (cx - 205 * scale, 520 + dy),
        (cx - 90 * scale, 590 + dy),
        (cx - 60 * scale, 430 + dy),
    ]
    draw.polygon(bezier(pts), fill=color)


# 外焰
flame(d, 1.00, (255, 92, 20))
# 中焰
flame(d, 0.74, (255, 158, 40), dy=45, top=40)
# 内焰
flame(d, 0.46, (255, 226, 130), dy=105, top=60)

# 底部圆角遮罩
mask = Image.new("L", (S, S), 0)
md = ImageDraw.Draw(mask)
md.rounded_rectangle([0, 0, S, S], radius=0, fill=255)
img = Image.composite(img, Image.new("RGB", (S, S), (0, 0, 0)), mask)

img = img.filter(ImageFilter.SMOOTH)
img.save(r"D:\DeepSeek Harness工作\SparkKeeper\SparkKeeper\Assets.xcassets\AppIcon.appiconset\AppIcon-1024.png", "PNG")

# 顺带生成 README 用的小尺寸预览
img.resize((256, 256), Image.LANCZOS).save(
    r"D:\DeepSeek Harness工作\SparkKeeper\docs\icon-preview.png", "PNG"
)
print("icon ok", img.size)
