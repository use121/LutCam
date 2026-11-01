#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成内置胶片预设 LUT（标准 .cube，33³）。

设计原则：
- 每个预设由一组「色彩参数」描述：对比、饱和、分离色调、提亮/压暗、通道 gamma 等；
- 在 sRGB gamma 空间里运算 —— 这正是 .cube 的通用约定，和视频调色软件一致；
- 输出严格按 .cube 规范：R 变化最快，B 最慢。

用法：
    python scripts/make_presets.py            # 生成到 Sources/Resources/Presets
    python scripts/make_presets.py --sheet    # 额外输出一张对比图用于检查
"""

import math
import os
import sys

SIZE = 25
OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "Sources", "Resources", "Presets")


def clamp(x, lo=0.0, hi=1.0):
    return lo if x < lo else (hi if x > hi else x)


def luma(r, g, b):
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


class Look:
    """一组色彩参数。默认值是「什么都不做」。"""

    def __init__(
        self,
        name,
        exposure=0.0,
        contrast=1.0,
        pivot=0.5,
        saturation=1.0,
        vibrance=0.0,
        fade=0.0,                 # 提亮黑位（哑光感），0~0.15
        gamma=(1.0, 1.0, 1.0),
        gain=(1.0, 1.0, 1.0),
        shadow_tint=(0.0, 0.0, 0.0),
        highlight_tint=(0.0, 0.0, 0.0),
        split=0.0,                # 分离色调强度
        hue_shift=(0.0, 0.0, 0.0),  # 通道串扰，制造胶片式偏色
        mono=False,
    ):
        self.name = name
        self.exposure = exposure
        self.contrast = contrast
        self.pivot = pivot
        self.saturation = saturation
        self.vibrance = vibrance
        self.fade = fade
        self.gamma = gamma
        self.gain = gain
        self.shadow_tint = shadow_tint
        self.highlight_tint = highlight_tint
        self.split = split
        self.hue_shift = hue_shift
        self.mono = mono

    def apply(self, r, g, b):
        # 1. 曝光
        r += self.exposure
        g += self.exposure
        b += self.exposure

        # 2. 哑光黑位：把黑提起来，同时保留白点
        if self.fade > 0:
            f = self.fade
            r = r * (1.0 - f) + f
            g = g * (1.0 - f) + f
            b = b * (1.0 - f) + f

        # 3. 对比（绕 pivot 做 S 形）
        if abs(self.contrast - 1.0) > 1e-6:
            c = self.contrast
            p = self.pivot
            r = (r - p) * c + p
            g = (g - p) * c + p
            b = (b - p) * c + p

        # 4. 通道 gamma（胶片肩部/趾部的差异）
        if self.gamma != (1.0, 1.0, 1.0):
            r = clamp(r) ** (1.0 / self.gamma[0])
            g = clamp(g) ** (1.0 / self.gamma[1])
            b = clamp(b) ** (1.0 / self.gamma[2])

        # 5. 通道增益
        r *= self.gain[0]
        g *= self.gain[1]
        b *= self.gain[2]

        # 6. 通道串扰：胶片染料层会互相污染，这是"胶片味"的主要来源
        if self.hue_shift != (0.0, 0.0, 0.0):
            hr, hg, hb = self.hue_shift
            r2 = r + g * hr
            g2 = g + b * hg
            b2 = b + r * hb
            r, g, b = r2, g2, b2

        r = clamp(r)
        g = clamp(g)
        b = clamp(b)

        # 7. 分离色调：暗部染一个色，亮部染另一个色
        if self.split > 0:
            y = clamp(luma(r, g, b))
            shadow_w = (1.0 - y) ** 2
            high_w = y ** 2
            sr, sg, sb = self.shadow_tint
            hr2, hg2, hb2 = self.highlight_tint
            r += (sr * shadow_w + hr2 * high_w) * self.split
            g += (sg * shadow_w + hg2 * high_w) * self.split
            b += (sb * shadow_w + hb2 * high_w) * self.split

        # 8. 饱和 / 自然饱和度
        if abs(self.saturation - 1.0) > 1e-6 or self.vibrance > 0:
            y = luma(r, g, b)
            sat = self.saturation
            if self.vibrance > 0:
                mx = max(r, g, b)
                mn = min(r, g, b)
                current = (mx - mn)  # 粗略的"已有饱和度"
                boost = 1.0 + self.vibrance * (1.0 - clamp(current))
                sat *= boost
            r = y + (r - y) * sat
            g = y + (g - y) * sat
            b = y + (b - y) * sat

        # 9. 黑白
        if self.mono:
            y = luma(clamp(r), clamp(g), clamp(b))
            # 给一点点暖灰，避免死板
            r, g, b = y * 1.01, y, y * 0.99

        return clamp(r), clamp(g), clamp(b)


# 文件名前缀决定在滤镜条里的顺序
PRESETS = [
    # ---------- 日系 / 正片 ----------
    Look(
        name="理光 正片",
        contrast=1.18,
        saturation=1.06,
        vibrance=0.10,
        gamma=(1.02, 1.00, 0.97),
        shadow_tint=(-0.012, 0.010, 0.030),
        highlight_tint=(0.022, 0.014, -0.008),
        split=1.0,
        hue_shift=(0.012, 0.0, 0.0),
    ),
    Look(
        name="富士 经典正片",
        contrast=1.10,
        saturation=0.84,
        fade=0.012,
        gamma=(1.00, 1.02, 1.04),
        shadow_tint=(-0.010, 0.014, 0.028),
        highlight_tint=(0.014, 0.012, 0.004),
        split=1.0,
        hue_shift=(0.020, 0.008, 0.0),
    ),
    Look(
        name="富士 经典负片",
        contrast=1.22,
        pivot=0.46,
        saturation=0.90,
        fade=0.020,
        gamma=(0.98, 1.00, 1.03),
        shadow_tint=(0.030, -0.004, 0.022),
        highlight_tint=(0.026, 0.018, -0.006),
        split=1.0,
        hue_shift=(0.026, 0.006, 0.010),
    ),
    # ---------- 柯达 ----------
    Look(
        name="柯达 波特拉",
        exposure=0.010,
        contrast=0.94,
        pivot=0.52,
        saturation=0.96,
        vibrance=0.12,
        fade=0.014,
        gamma=(1.02, 1.00, 0.99),
        shadow_tint=(0.018, 0.006, 0.014),
        highlight_tint=(0.022, 0.012, -0.010),
        split=1.0,
        hue_shift=(0.014, 0.0, 0.004),
    ),
    Look(
        name="柯达 金",
        exposure=0.014,
        contrast=1.06,
        saturation=1.12,
        vibrance=0.14,
        gamma=(1.03, 1.00, 0.94),
        shadow_tint=(0.012, 0.010, 0.018),
        highlight_tint=(0.030, 0.020, -0.014),
        split=1.0,
        hue_shift=(0.016, 0.004, 0.0),
    ),
    # ---------- 清新 ----------
    Look(
        name="日系 清新",
        exposure=0.055,
        contrast=0.88,
        pivot=0.54,
        saturation=0.92,
        fade=0.030,
        gamma=(1.00, 1.01, 1.02),
        shadow_tint=(-0.006, 0.016, 0.024),
        highlight_tint=(0.010, 0.014, 0.010),
        split=1.0,
    ),
    Look(
        name="森系 绿调",
        exposure=0.020,
        contrast=0.96,
        saturation=0.90,
        vibrance=0.10,
        fade=0.018,
        gamma=(0.99, 1.03, 1.00),
        shadow_tint=(-0.010, 0.028, 0.006),
        highlight_tint=(0.008, 0.020, 0.004),
        split=1.0,
        hue_shift=(0.010, 0.016, 0.0),
    ),
    # ---------- 复古 ----------
    Look(
        name="复古 褪色",
        exposure=0.018,
        contrast=0.90,
        saturation=0.80,
        fade=0.055,
        gamma=(1.03, 1.00, 0.96),
        shadow_tint=(0.030, 0.018, 0.008),
        highlight_tint=(0.028, 0.020, 0.004),
        split=1.0,
        hue_shift=(0.018, 0.010, 0.006),
    ),
    Look(
        name="港风 胶片",
        contrast=1.24,
        pivot=0.47,
        saturation=1.08,
        fade=0.022,
        gamma=(1.04, 1.00, 0.92),
        shadow_tint=(-0.008, 0.026, 0.010),
        highlight_tint=(0.036, 0.022, -0.012),
        split=1.0,
        hue_shift=(0.020, 0.014, 0.0),
    ),
    # ---------- 电影感 ----------
    Look(
        name="电影 青橙",
        contrast=1.14,
        pivot=0.48,
        saturation=1.04,
        gamma=(1.00, 1.00, 1.02),
        shadow_tint=(-0.040, 0.010, 0.046),
        highlight_tint=(0.048, 0.020, -0.030),
        split=1.0,
        hue_shift=(0.016, 0.0, 0.008),
    ),
    Look(
        name="冷调 夜行",
        exposure=-0.012,
        contrast=1.16,
        pivot=0.44,
        saturation=0.86,
        gamma=(0.98, 1.00, 1.06),
        shadow_tint=(-0.020, 0.004, 0.042),
        highlight_tint=(-0.010, 0.006, 0.026),
        split=1.0,
        hue_shift=(0.006, 0.0, 0.014),
    ),
    # ---------- 黑白 ----------
    Look(
        name="黑白",
        contrast=1.08,
        saturation=0.0,
        mono=True,
    ),
    Look(
        name="黑白 高反差",
        contrast=1.34,
        pivot=0.48,
        saturation=0.0,
        gamma=(0.96, 0.96, 0.96),
        mono=True,
    ),
]


def write_cube(look, path, size=SIZE):
    n = size
    denom = float(n - 1)
    lines = [
        '# 由 LutCam 内置生成器生成',
        'TITLE "%s"' % look.name,
        'LUT_3D_SIZE %d' % n,
        'DOMAIN_MIN 0.0 0.0 0.0',
        'DOMAIN_MAX 1.0 1.0 1.0',
        '',
    ]
    for bi in range(n):
        b = bi / denom
        for gi in range(n):
            g = gi / denom
            for ri in range(n):
                r = ri / denom
                rr, gg, bb = look.apply(r, g, b)
                lines.append("%.5f %.5f %.5f" % (rr, gg, bb))
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return len(lines)


def main():
    out = os.path.abspath(OUT_DIR)
    os.makedirs(out, exist_ok=True)

    # 清掉旧文件，避免改名后残留
    for name in os.listdir(out):
        if name.endswith(".cube"):
            os.remove(os.path.join(out, name))

    total = 0
    for index, look in enumerate(PRESETS, start=1):
        slug = "preset%02d.cube" % index
        path = os.path.join(out, slug)
        rows = write_cube(look, path)
        size_kb = os.path.getsize(path) / 1024
        total += size_kb
        print("  %-16s -> %s  (%.0f KB, %d 行)" % (look.name, slug, size_kb, rows))

    print("\n共 %d 个预设，合计 %.1f MB" % (len(PRESETS), total / 1024))

    if "--sheet" in sys.argv:
        render_sheet(out)


# ---------------- 对比图（仅用于人工检查） ----------------

def _sample_lut(path, size):
    """把 .cube 读回来，做三线性插值取样。"""
    dim = None
    vals = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("LUT_3D_SIZE"):
                dim = int(line.split()[1])
                continue
            if line.startswith("TITLE") or line.startswith("DOMAIN"):
                continue
            parts = line.split()
            if len(parts) == 3:
                vals.append((float(parts[0]), float(parts[1]), float(parts[2])))
    assert dim and len(vals) == dim ** 3, (path, dim, len(vals))

    def lookup(r, g, b):
        fr = clamp(r) * (dim - 1)
        fg = clamp(g) * (dim - 1)
        fb = clamp(b) * (dim - 1)
        r0, g0, b0 = int(fr), int(fg), int(fb)
        r1, g1, b1 = min(r0 + 1, dim - 1), min(g0 + 1, dim - 1), min(b0 + 1, dim - 1)
        dr, dg, db = fr - r0, fg - g0, fb - b0

        def at(ri, gi, bi):
            return vals[bi * dim * dim + gi * dim + ri]

        out = [0.0, 0.0, 0.0]
        for c in range(3):
            c00 = at(r0, g0, b0)[c] * (1 - dr) + at(r1, g0, b0)[c] * dr
            c10 = at(r0, g1, b0)[c] * (1 - dr) + at(r1, g1, b0)[c] * dr
            c01 = at(r0, g0, b1)[c] * (1 - dr) + at(r1, g0, b1)[c] * dr
            c11 = at(r0, g1, b1)[c] * (1 - dr) + at(r1, g1, b1)[c] * dr
            c0 = c00 * (1 - dg) + c10 * dg
            c1 = c01 * (1 - dg) + c11 * dg
            out[c] = c0 * (1 - db) + c1 * db
        return out

    return lookup


def render_sheet(preset_dir):
    """用一组色块（肤色/天空/植被/中性灰）拼一张对比图。"""
    import struct
    import zlib

    swatch_rows = [
        # (R, G, B) 近似真实场景的关键色
        (0.88, 0.72, 0.62), (0.78, 0.58, 0.48), (0.55, 0.36, 0.28),  # 肤色三档
        (0.35, 0.52, 0.72), (0.55, 0.72, 0.86), (0.72, 0.86, 0.95),  # 天空三档
        (0.20, 0.34, 0.18), (0.38, 0.52, 0.24), (0.62, 0.68, 0.34),  # 植被三档
        (0.08, 0.08, 0.08), (0.22, 0.22, 0.22), (0.45, 0.45, 0.45),  # 暗部
        (0.62, 0.62, 0.62), (0.80, 0.80, 0.80), (0.95, 0.95, 0.95),  # 亮部
        (0.85, 0.25, 0.22), (0.90, 0.62, 0.18), (0.30, 0.28, 0.62),  # 饱和色
    ]

    cell = 26
    cols = 6
    rows = 3
    tile_w = cols * cell
    tile_h = rows * cell
    pad = 6
    label_h = 0

    tiles = [("原图", None)]
    for index in range(1, len(PRESETS) + 1):
        tiles.append((PRESETS[index - 1].name, os.path.join(preset_dir, "preset%02d.cube" % index)))

    per_row = 4
    grid_cols = per_row
    grid_rows = (len(tiles) + per_row - 1) // per_row
    W = grid_cols * (tile_w + pad) + pad
    H = grid_rows * (tile_h + pad) + pad

    canvas = [[(0, 0, 0)] * W for _ in range(H)]

    def put(x, y, rgb):
        if 0 <= x < W and 0 <= y < H:
            canvas[y][x] = tuple(int(clamp(c) * 255) for c in rgb)

    for ti, (name, path) in enumerate(tiles):
        lookup = _sample_lut(path, SIZE) if path else (lambda r, g, b: [r, g, b])
        ox = pad + (ti % grid_cols) * (tile_w + pad)
        oy = pad + (ti // grid_cols) * (tile_h + pad)
        for si, base in enumerate(swatch_rows):
            sx = ox + (si % cols) * cell
            sy = oy + (si // cols) * cell
            out = lookup(*base)
            for yy in range(sy, sy + cell - 1):
                for xx in range(sx, sx + cell - 1):
                    put(xx, yy, out)
        print("  tile %d: %s" % (ti, name))

    # 写 PNG（RGB8）
    raw = bytearray()
    for row in canvas:
        raw.append(0)
        for r, g, b in row:
            raw.extend((r, g, b))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")

    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "_presets_sheet.png")
    with open(out_path, "wb") as f:
        f.write(png)
    print("\n对比图: %s" % os.path.abspath(out_path))


if __name__ == "__main__":
    main()
