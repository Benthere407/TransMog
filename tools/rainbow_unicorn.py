"""Builds the mount-raptor-rainbow-unicorn mod: the Alicorn model, repainted, in the Raptor's place.

Run it with no arguments. It reads the game's Alicorn DAT, never changes it, and writes the mod's
files to DATs\\TransMog. Pass a folder to also save the two textures there as PNGs.
"""
import json
import math
import os
import struct
import sys
import zlib

GAME = r'C:\catseyexi\catseyexi-client\Game\FINAL FANTASY XI'
MOD = r'C:\catseyexi\catseyexi-client\Ashita\polplugins\DATs\TransMog\mount-raptor-rainbow-unicorn'
SOURCE = r'ROM\384\108.DAT'
TARGETS = [r'ROM\351\100.DAT', r'ROM\351\101.DAT', r'ROM\351\104.DAT']

TEXTURE_HEADER = 16 + 69    # chunk header, then the texture's own, up to the DXT3 blocks
SIZE = 256

# root to tip, as in the reference picture
MANE_COLORS = [(170, 50, 235), (235, 50, 200), (120, 70, 245), (40, 130, 255), (30, 215, 225), (60, 225, 110),
               (240, 235, 60), (255, 165, 40), (255, 90, 150)]
TAIL_COLORS = [(235, 50, 200), (120, 70, 245), (40, 130, 255), (30, 215, 225), (60, 225, 110), (240, 235, 60),
               (255, 165, 40), (255, 80, 110), (200, 60, 235)]
HORN_COLORS = [(255, 255, 255), (255, 240, 120), (255, 165, 40), (255, 80, 130), (190, 60, 235), (50, 130, 255),
               (40, 220, 200)]
PINK = (255, 170, 215)
LAVENDER = (190, 160, 255)
GOLD = (255, 200, 70)

# outlines in texels, one list per texture
MANE = [(0, 0), (140, 0), (145, 60), (158, 65), (160, 125), (183, 133), (250, 128), (256, 160),
        (150, 157), (100, 152), (72, 158), (64, 190), (72, 225), (75, 256), (0, 256)]
TAIL = [(120, 20), (140, 0), (215, 0), (256, 45), (256, 192), (232, 190), (222, 130), (205, 100),
        (160, 92), (130, 60)]
HORN = [(93, 3), (115, 30), (130, 65), (146, 100), (148, 135), (165, 160), (165, 205), (150, 205), (118, 150),
        (113, 128), (125, 100), (112, 60), (100, 30)]
EYE = (212, 60)
EYE_RADIUS = (15, 12)


def chunks(data):
    offset = 0
    while offset + 16 <= len(data):
        value = struct.unpack_from('<I', data, offset + 4)[0]
        size = (value >> 7 & 0x7ffff) * 16
        if size < 16:
            break
        yield value & 0x7f, offset, size
        offset += size


def refresh_swaps(data, look, own):
    """TransMog dresses another mount in a look by copying the file when the swap is made: a folder with
    no look of its own, titled '<mount> as <look>'. A rebuilt look goes into those copies too."""
    root = os.path.dirname(own)
    for folder in sorted(os.listdir(root)):
        path = os.path.join(root, folder)
        manifest = os.path.join(path, 'transmog.json')
        if os.path.normcase(path) == os.path.normcase(own) or not os.path.isfile(manifest):
            continue
        with open(manifest) as f:
            info = json.load(f)
        if 'look' in info or not info.get('title', '').endswith(' as ' + look):
            continue
        for parent, _, names in os.walk(path):
            for name in names:
                if name.upper().endswith('.DAT'):
                    with open(os.path.join(parent, name), 'wb') as f:
                        f.write(data)
                    print('Refreshed', os.path.join(parent, name))


def from_565(c):
    return (c >> 11 & 31) * 255 // 31, (c >> 5 & 63) * 255 // 63, (c & 31) * 255 // 31


def to_565(c):
    return (min(255, c[0]) * 31 // 255) << 11 | (min(255, c[1]) * 63 // 255) << 5 | min(255, c[2]) * 31 // 255


def palette(c0, c1):
    a, b = from_565(c0), from_565(c1)
    return [a, b, tuple((2 * a[i] + b[i]) // 3 for i in range(3)), tuple((a[i] + 2 * b[i]) // 3 for i in range(3))]


def decode(blocks):
    pixels = [[(0, 0, 0)] * SIZE for _ in range(SIZE)]
    offset = 0
    for y in range(0, SIZE, 4):
        for x in range(0, SIZE, 4):
            c0, c1, bits = struct.unpack_from('<HHI', blocks, offset + 8)
            colors = palette(c0, c1)
            for j in range(4):
                for i in range(4):
                    pixels[y + j][x + i] = colors[bits >> (2 * (j * 4 + i)) & 3]
            offset += 16
    return pixels


def distance(a, b):
    return (a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2


def encode_block(block):
    best = (-1, block[0], block[0])
    for i in range(16):
        for j in range(i + 1, 16):
            d = distance(block[i], block[j])
            if d > best[0]:
                best = (d, block[i], block[j])
    c0, c1 = to_565(best[1]), to_565(best[2])
    if c0 < c1:
        c0, c1 = c1, c0
    colors = palette(c0, c1)
    bits = 0
    for i, pixel in enumerate(block):
        index = min(range(4), key=lambda k: distance(pixel, colors[k]))
        bits |= index << (2 * i)
    return struct.pack('<HHI', c0, c1, bits)


def encode(pixels, blocks):
    """The new colors, each block keeping its alpha."""
    out = bytearray(blocks)
    offset = 0
    for y in range(0, SIZE, 4):
        for x in range(0, SIZE, 4):
            block = [pixels[y + j][x + i] for j in range(4) for i in range(4)]
            out[offset + 8:offset + 16] = encode_block(block)
            offset += 16
    return bytes(out)


def inside(x, y, outline):
    hit = False
    for i in range(len(outline)):
        x0, y0 = outline[i]
        x1, y1 = outline[i - 1]
        if (y0 > y) != (y1 > y) and x < (x1 - x0) * (y - y0) / (y1 - y0) + x0:
            hit = not hit
    return hit


def gradient(colors, u):
    u = min(0.999, max(0, u)) * (len(colors) - 1)
    i = int(u)
    a, b = colors[i], colors[i + 1]
    return tuple(a[k] + (b[k] - a[k]) * (u - i) for k in range(3))


def hair(color, p):
    """The color lit by the old hair's light and dark, its highlights going toward white."""
    light = luma(p) / 190
    if light <= 1:
        return shade(color, 0.45 + 0.55 * light)
    return tuple(int(min(255, c + (255 - c) * (light - 1) * 1.3)) for c in color)


def shade(color, light):
    return tuple(int(min(255, c * light)) for c in color)


def luma(p):
    return (p[0] * 30 + p[1] * 59 + p[2] * 11) / 100


def is_purple(p):
    return p[2] > p[1] + 12 and p[0] > p[1] - 4


def background(pixels):
    counts = {}
    for row in pixels:
        for p in row:
            counts[p] = counts.get(p, 0) + 1
    return max(counts, key=counts.get)


def body_color(p):
    light = luma(p)
    if light < 72:
        return shade(GOLD, 0.45 + light / 70)
    return shade(LAVENDER if is_purple(p) else PINK, 0.55 + light / 300)


def paint_mane(pixels, back):
    for y in range(SIZE):
        for x in range(SIZE):
            p = pixels[y][x]
            if inside(x, y, MANE):
                if distance(p, back) >= 40:
                    u = y / 175 + 0.05 * math.sin(x / 11 + y / 30) + (luma(p) - 170) / 1400
                    pixels[y][x] = hair(gradient(MANE_COLORS, u), p)
            elif distance(p, back) >= 300:
                pixels[y][x] = body_color(p)


def paint_eye(pixels):
    cx, cy = EYE
    rx, ry = EYE_RADIUS
    for y in range(cy - ry, cy + ry + 1):
        for x in range(cx - rx, cx + rx + 1):
            d = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2
            if d > 1:
                continue
            iris = ((x - cx) / (rx * 0.62)) ** 2 + ((y - cy) / (ry * 0.8)) ** 2
            pupil = ((x - cx) / (rx * 0.32)) ** 2 + ((y - cy) / (ry * 0.42)) ** 2
            shine = ((x - cx + 3) / 3) ** 2 + ((y - cy + 3) / 3) ** 2
            if d > 0.82:
                color = (35, 15, 45)
            elif shine < 1:
                color = (255, 255, 255)
            elif pupil < 1:
                color = (20, 15, 40)
            elif iris < 1:
                color = (70, 110 + (y - cy) * 6, 245)
            else:
                color = (255, 255, 255)
            pixels[y][x] = color


def paint_tail(pixels, back):
    for y in range(SIZE):
        for x in range(SIZE):
            p = pixels[y][x]
            if inside(x, y, HORN):
                if distance(p, back) >= 40:
                    pixels[y][x] = shade(gradient(HORN_COLORS, (y - 3) / 202), 0.85 + luma(p) / 900)
            elif inside(x, y, TAIL):
                if distance(p, back) >= 40:
                    u = math.hypot(x - 175, y - 85) / 125 + (luma(p) - 170) / 1000
                    pixels[y][x] = hair(gradient(TAIL_COLORS, u + 0.06 * math.sin(math.atan2(y - 85, x - 175) * 5)), p)
            elif distance(p, back) >= 300:
                pixels[y][x] = body_color(p)


def save_png(path, pixels):
    raw = b''.join(b'\0' + bytes(c for p in row for c in p) for row in pixels)

    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))

    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', SIZE, SIZE, 8, 2, 0, 0, 0))
                + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def main():
    with open(os.path.join(GAME, SOURCE), 'rb') as f:
        data = bytearray(f.read())
    textures = [offset + TEXTURE_HEADER for kind, offset, _ in chunks(data) if kind == 0x20]
    if len(textures) != 2:
        sys.exit('Expected two textures in ' + SOURCE)

    for index, start in enumerate(textures):
        blocks = bytes(data[start:start + SIZE * SIZE])
        pixels = decode(blocks)
        back = background(pixels)
        if index == 0:
            paint_mane(pixels, back)
            paint_eye(pixels)
        else:
            paint_tail(pixels, back)
        data[start:start + SIZE * SIZE] = encode(pixels, blocks)
        if len(sys.argv) > 1:
            save_png(os.path.join(sys.argv[1], 'rainbow%d.png' % index), decode(data[start:start + SIZE * SIZE]))

    for target in TARGETS:
        path = os.path.join(MOD, target)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as f:
            f.write(data)
    with open(os.path.join(MOD, 'transmog.json'), 'w') as f:
        json.dump({'title': 'Raptor as Rainbow Unicorn', 'category': 'mount', 'look': 'Rainbow Unicorn'}, f)
    refresh_swaps(data, 'Rainbow Unicorn', MOD)
    print('Wrote', MOD)


if __name__ == '__main__':
    main()
