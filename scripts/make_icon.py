#!/usr/bin/env python3
"""生成 LutCam 的 App 图标。

设计：深空底 + 光圈虹膜（六边形开口）+ 一圈色谱环。
含义：相机光圈（拍） + 色谱（LUT 调色）。

纯数学绘制，2 倍超采样抗锯齿，不依赖任何图像库。
"""

import math
import struct
import zlib
import os

SIZE = 1024
SS = 2                      # 超采样倍数
W = SIZE * SS
CX = CY = W / 2.0
R = W / 2.0

# 配色
BG_CENTER = (0.098, 0.132, 0.222)   # 中心深蓝
BG_EDGE = (0.016, 0.022, 0.043)     # 边缘近黑
GOLD = (0.914, 0.753, 0.486)        # e9c07c
GOLD_HOT = (1.0, 0.960, 0.870)      # 开口高光
BLADE = (0.072, 0.092, 0.150)       # 叶片暗部

RING_IN = 0.800
RING_OUT = 0.860
HEX_R = 0.340                        # 六边形外接圆半径（相对 R）


def smoothstep(e0, e1, x):
    if e1 <= e0:
        return 0.0 if x < e0 else 1.0
    t = (x - e0) / (e1 - e0)
    t = 0.0 if t < 0 else (1.0 if t > 1 else t)
    return t * t * (3 - 2 * t)


def hue_rgb(h):
    """h in [0,1) -> rgb"""
    h = h % 1.0
    i = int(h * 6)
    f = h * 6 - i
    q = 1 - f
    t = f
    if i == 0:   r, g, b = 1, t, 0
    elif i == 1: r, g, b = q, 1, 0
    elif i == 2: r, g, b = 0, 1, t
    elif i == 3: r, g, b = 0, q, 1
    elif i == 4: r, g, b = t, 0, 1
    else:        r, g, b = 1, 0, q
    return r, g, b


def hex_boundary(theta):
    """正六边形在给定角度上的边界半径（相对 HEX_R）"""
    seg = math.pi / 3.0
    a = theta % seg
    return math.cos(math.pi / 6.0) / math.cos(a - math.pi / 6.0)


def pixel(x, y):
    dx = x - CX
    dy = y - CY
    r = math.hypot(dx, dy) / R

    # --- 背景：径向渐变 ---
    k = smoothstep(0.0, 1.15, r)
    cr = BG_CENTER[0] + (BG_EDGE[0] - BG_CENTER[0]) * k
    cg = BG_CENTER[1] + (BG_EDGE[1] - BG_CENTER[1]) * k
    cb = BG_CENTER[2] + (BG_EDGE[2] - BG_CENTER[2]) * k

    theta = math.atan2(dy, dx)

    # --- 外圈色谱环 ---
    ring_a = smoothstep(RING_IN - 0.012, RING_IN + 0.006, r) * \
             (1.0 - smoothstep(RING_OUT - 0.006, RING_OUT + 0.012, r))
    if ring_a > 0:
        hue = (theta / (2 * math.pi)) + 0.08
        sr, sg, sb = hue_rgb(hue)
        # 大幅去饱和，只留一点色相流动，避免变成彩虹环
        lum = 0.299 * sr + 0.587 * sg + 0.114 * sb
        desat = 0.82
        sr = sr * (1 - desat) + lum * desat
        sg = sg * (1 - desat) + lum * desat
        sb = sb * (1 - desat) + lum * desat
        # 再统一往金色拉
        mix = 0.72
        sr = sr * (1 - mix) + GOLD[0] * mix
        sg = sg * (1 - mix) + GOLD[1] * mix
        sb = sb * (1 - mix) + GOLD[2] * mix
        # 环的亮度做一点角度变化，像反光
        shine = 0.72 + 0.28 * math.cos(theta - math.pi * 0.75)
        sr, sg, sb = sr * shine, sg * shine, sb * shine
        cr = cr * (1 - ring_a) + sr * ring_a
        cg = cg * (1 - ring_a) + sg * ring_a
        cb = cb * (1 - ring_a) + sb * ring_a

    # --- 虹膜叶片区（环内侧到开口之间） ---
    hb = HEX_R * hex_boundary(theta)
    if r < RING_IN and r > hb:
        # 叶片基色：越靠内越暗，形成纵深
        t = smoothstep(hb, RING_IN, r)
        br = BLADE[0] * (0.55 + 0.75 * t)
        bg = BLADE[1] * (0.55 + 0.75 * t)
        bb = BLADE[2] * (0.55 + 0.75 * t)

        # 叶片接缝：六条从顶点向外的暗线
        seg = math.pi / 3.0
        local = ((theta % seg) - seg / 2.0)
        seam = 1.0 - smoothstep(0.0, 0.055, abs(local))
        seam *= smoothstep(hb, hb + 0.05, r)
        if seam > 0:
            br *= (1 - 0.55 * seam)
            bg *= (1 - 0.55 * seam)
            bb *= (1 - 0.55 * seam)

        # 叶片靠近开口的一圈亮边（金属反光）
        edge = 1.0 - smoothstep(0.0, 0.018, r - hb)
        if edge > 0:
            br = br * (1 - edge) + GOLD[0] * 0.85 * edge
            bg = bg * (1 - edge) + GOLD[1] * 0.85 * edge
            bb = bb * (1 - edge) + GOLD[2] * 0.85 * edge

        # 与外环之间做柔和过渡
        blend = smoothstep(RING_IN - 0.05, RING_IN, r)
        cr = cr * blend + br * (1 - blend)
        cg = cg * blend + bg * (1 - blend)
        cb = cb * blend + bb * (1 - blend)

    # --- 开口：透进来的光 ---
    if r < hb:
        t = 1.0 - (r / max(hb, 1e-6))          # 1 = 中心
        glow = t * t
        gr = GOLD[0] * (0.62 + 0.38 * glow)
        gg = GOLD[1] * (0.62 + 0.38 * glow)
        gb = GOLD[2] * (0.62 + 0.38 * glow)
        # 中心偏白，像光源
        hot = smoothstep(0.35, 1.0, glow)
        gr = gr * (1 - hot) + GOLD_HOT[0] * hot
        gg = gg * (1 - hot) + GOLD_HOT[1] * hot
        gb = gb * (1 - hot) + GOLD_HOT[2] * hot

        # 开口边缘暗一点，增加层次
        rim = 1.0 - smoothstep(0.0, 0.06, hb - r)
        gr *= (1 - 0.45 * rim)
        gg *= (1 - 0.45 * rim)
        gb *= (1 - 0.45 * rim)

        cr, cg, cb = gr, gg, gb

    # --- 整体暗角 ---
    vig = 1.0 - 0.35 * smoothstep(0.72, 1.05, r)
    cr *= vig
    cg *= vig
    cb *= vig

    return cr, cg, cb


def build():
    hi = bytearray(W * W * 3)
    for y in range(W):
        row = y * W * 3
        for x in range(W):
            r, g, b = pixel(x + 0.5, y + 0.5)
            i = row + x * 3
            hi[i] = max(0, min(255, int(r * 255 + 0.5)))
            hi[i + 1] = max(0, min(255, int(g * 255 + 0.5)))
            hi[i + 2] = max(0, min(255, int(b * 255 + 0.5)))

    # 2x2 下采样
    out = bytearray(SIZE * SIZE * 3)
    for y in range(SIZE):
        for x in range(SIZE):
            r = g = b = 0
            for dy in (0, 1):
                for dx in (0, 1):
                    i = ((y * SS + dy) * W + (x * SS + dx)) * 3
                    r += hi[i]; g += hi[i + 1]; b += hi[i + 2]
            o = (y * SIZE + x) * 3
            out[o] = r >> 2
            out[o + 1] = g >> 2
            out[o + 2] = b >> 2
    return out


def write_png(path, rgb):
    raw = bytearray()
    stride = SIZE * 3
    for y in range(SIZE):
        raw.append(0)                       # filter: none
        raw.extend(rgb[y * stride:(y + 1) * stride])

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", ihdr)
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")

    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    base = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(base, "..", "Sources", "Resources", "Assets.xcassets", "AppIcon.appiconset")
    os.makedirs(out_dir, exist_ok=True)
    target = os.path.join(out_dir, "icon-1024.png")
    write_png(target, build())
    print("已生成:", target, os.path.getsize(target), "字节")
