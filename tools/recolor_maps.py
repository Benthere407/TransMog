"""Writes the maps TransMog's Colors page recolors a gear mod with, from the mod as built in its default colors.

Run it with the mod's folder, after the mod is built and before its colors are changed in game. Every texture of the
mod's DATs that is mostly made of the palette's colors gets a map: each pixel is one of the palette's colors times a
brightness, or kept as it is. TransMog paints a map with new colors into an uncompressed texture of the same name.

A map file is bottom row first, as the texture is stored, with 6 bytes a pixel: class (0 kept, 1 main, 2 dark, 3 trim),
brightness in hundredths, alpha, then the kept pixel's blue, green and red.
"""
import json
import os
import struct
import sys

import numpy as np

import white_gold_robe as robe

PALETTE = {'main': robe.SLATE, 'dark': robe.SLATE_DARK, 'trim': robe.GOLD}
CLASSES = ['main', 'dark', 'trim']
MATCH = 0.985           # how close in hue a pixel must be to a palette color to follow it
NEAR_BLACK = 12         # darker than this follows the dark color, whatever its hue
UNCOMPRESSED = 0x91
HEADER = 57             # an uncompressed texture's own header: flag, name and a 40 byte bitmap header
MIN_SHARE = 0.4         # a texture with less of the palette than this is left alone


def pixels(data, offset, size):
    """A texture's RGB and alpha (0 to 128, as the game keeps it), bottom row first."""
    payload = data[offset + 16:offset + size]
    width, height = struct.unpack_from('<II', payload, 21)
    if payload[0] == UNCOMPRESSED:
        bgra = np.frombuffer(payload[HEADER:HEADER + 4 * width * height], np.uint8).reshape(height, width, 4)
        return bgra[..., [2, 1, 0]].astype(float), bgra[..., 3].astype(np.uint8), width, height
    blocks = payload[robe.TEXTURE_HEADER - 16:robe.TEXTURE_HEADER - 16 + width * height]
    rgb = robe.decode(blocks, width, height)[::-1].astype(float)
    raw = np.frombuffer(blocks, np.uint8).reshape(-1, 16)[:, :8]
    nibbles = np.stack([raw & 15, raw >> 4], -1).reshape(-1, 16).astype(np.uint16)
    alpha = nibbles.reshape(height // 4, width // 4, 4, 4).transpose(0, 2, 1, 3).reshape(height, width)
    return rgb, ((alpha * 17 * 128 + 127) // 255)[::-1].astype(np.uint8), width, height


def classify(rgb):
    length = np.linalg.norm(rgb, axis=2)
    classes = np.zeros(rgb.shape[:2], np.uint8)
    best = np.zeros(rgb.shape[:2])
    scale = np.zeros(rgb.shape[:2])
    for number, name in enumerate(CLASSES, 1):
        color = PALETTE[name].astype(float)
        match = (rgb @ color) / np.maximum(length * np.linalg.norm(color), 1e-6)
        better = (match > best) & (match > MATCH)
        classes[better] = number
        best[better] = match[better]
        scale[better] = (length / np.linalg.norm(color))[better]
    black = length < NEAR_BLACK
    classes[black] = 2
    scale[black] = (length / np.linalg.norm(PALETTE['dark']))[black]
    return classes, np.clip(np.round(scale * 100), 0, 255).astype(np.uint8)


def main():
    mod = sys.argv[1]
    os.makedirs(os.path.join(mod, 'recolor'), exist_ok=True)
    files = {}
    for root, _, names in os.walk(os.path.join(mod, 'ROM')):
        for name in names:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, mod)
            data = open(path, 'rb').read()
            for kind, offset, size in robe.chunks(data):
                if kind != 0x20:
                    continue
                rgb, alpha, width, height = pixels(data, offset, size)
                classes, scale = classify(rgb)
                share = (classes > 0).mean()
                texture = data[offset + 17:offset + 33]
                if share < MIN_SHARE:
                    print('skipped', texture, 'only %.0f%% palette' % (share * 100))
                    continue
                kept = rgb[..., [2, 1, 0]].astype(np.uint8)
                table = np.concatenate([classes[..., None], scale[..., None], alpha[..., None], kept], 2)
                map_name = '%s-%s.bin' % (rel.replace(os.sep, '_').replace('.DAT', ''), texture[8:].decode().strip())
                with open(os.path.join(mod, 'recolor', map_name), 'wb') as f:
                    f.write(table.tobytes())
                files.setdefault(rel, []).append({'texture': texture.decode('latin-1'), 'width': width, 'height': height,
                                                  'map': 'recolor/' + map_name})
                print(rel, texture, '%dx%d' % (width, height), '%.0f%% palette' % (share * 100))
    template = bytearray(UNCOMPRESSED.to_bytes(1, 'little') + bytes(16) + struct.pack('<IiiHHIIiiII', 40, 0, 0, 2, 32, 0, 0, 0, 0, 0, 32))
    info = {'palette': {name: [int(c) for c in color] for name, color in PALETTE.items()}, 'files': files,
            'header': template.hex()}
    with open(os.path.join(mod, 'recolor.json'), 'w') as f:
        json.dump(info, f, indent=1)


if __name__ == '__main__':
    main()
