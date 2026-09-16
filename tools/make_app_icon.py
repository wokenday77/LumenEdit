#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 AppIcon1024.png —— 纯标准库实现，不依赖 Pillow。
用法： python tools/make_app_icon.py
输出： LumenEdit/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon1024.png

只做一次即可；想换配色改下面几个常量再跑一遍。
"""

import math
import os
import struct
import zlib

SIZE = 1024
CX = CY = SIZE / 2.0

# 配色
BG_TOP = (0x1B, 0x1F, 0x27)
BG_BOTTOM = (0x0A, 0x0C, 0x10)

RING_OUTER = 322.0
RING_INNER = 246.0
RING_DARK = (0xC8, 0x86, 0x1E)   # 环的暗侧（也可以理解成背光面）
RING_LIGHT = (0xFF, 0xD9, 0x8A)  # 环的高光侧
RING_MID = (0xF2, 0xAF, 0x3C)    # 环的主色

DOT_RADIUS = 96.0
DOT_COLOR = (0xE9, 0xEE, 0xF5)

# 光照方向（左上），与圆环高光角度 -135° 保持一致，否则两处明暗会打架
LIGHT_X = -0.7071
LIGHT_Y = -0.7071

OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "LumenEdit", "Resources", "Assets.xcassets", "AppIcon.appiconset", "AppIcon1024.png",
)


def clamp01(v):
    if v < 0.0:
        return 0.0
    if v > 1.0:
        return 1.0
    return v


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c1, c2, t):
    return tuple(lerp(c1[i], c2[i], t) for i in range(3))


def render():
    rows = []
    # 高光中心角度：左上方向（-135°）
    hi_angle = math.radians(-135.0)
    for y in range(SIZE):
        row = bytearray()
        # 背景竖直渐变
        bg_t = y / float(SIZE - 1)
        bg = mix(BG_TOP, BG_BOTTOM, bg_t)
        py = y + 0.5 - CY
        for x in range(SIZE):
            px = x + 0.5 - CX
            d = math.hypot(px, py)

            r, g, b = bg

            # 外圈：环形遮罩（用距离做解析抗锯齿，比超采样快很多）
            outer_cov = clamp01(0.5 + (RING_OUTER - d))
            inner_cov = clamp01(0.5 + (d - RING_INNER))
            ring_cov = outer_cov * inner_cov

            if ring_cov > 0.0:
                # 沿圆周做角度高光，形成金属感
                ang = math.atan2(py, px)
                cos_delta = math.cos(ang - hi_angle)
                t = clamp01((cos_delta + 1.0) * 0.5)  # 0..1
                if t < 0.5:
                    ring_col = mix(RING_DARK, RING_MID, t * 2.0)
                else:
                    ring_col = mix(RING_MID, RING_LIGHT, (t - 0.5) * 2.0)
                r = lerp(r, ring_col[0], ring_cov)
                g = lerp(g, ring_col[1], ring_cov)
                b = lerp(b, ring_col[2], ring_cov)

            # 中心实心圆（镜头）
            dot_cov = clamp01(0.5 + (DOT_RADIUS - d))
            if dot_cov > 0.0:
                # 用线性方向光，不用 atan2 —— 角度插值在圆心处有奇点，会出现"锥形"artifact
                u = (px * LIGHT_X + py * LIGHT_Y) / DOT_RADIUS  # 归一化到 [-1, 1]
                shade = 0.84 + 0.16 * clamp01(u * 0.5 + 0.5)
                dot_col = tuple(c * shade for c in DOT_COLOR)
                r = lerp(r, dot_col[0], dot_cov)
                g = lerp(g, dot_col[1], dot_cov)
                b = lerp(b, dot_col[2], dot_cov)

            row.append(int(clamp01(r / 255.0) * 255.0 + 0.5))
            row.append(int(clamp01(g / 255.0) * 255.0 + 0.5))
            row.append(int(clamp01(b / 255.0) * 255.0 + 0.5))
        rows.append(bytes(row))
    return rows


def write_png(path, width, height, rows):
    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + r for r in rows)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)
    return len(png)


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    rows = render()
    size = write_png(OUT, SIZE, SIZE, rows)
    print("written: %s (%d bytes)" % (OUT, size))


if __name__ == "__main__":
    main()
