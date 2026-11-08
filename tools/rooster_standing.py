"""Builds the mount-standing-rooster mod: the Raptor, a true mount, repainted as an original rooster.

It's painted by 3D position, as in unicorn_deluxe.py. The Raptor's dark stripes are mostly flattened
out, so they don't show through the new colors. Run it with no arguments. Pass a folder to also save
the texture there as a PNG. It reads the game's DAT and never changes it.
"""
import json
import os
import sys

import numpy as np

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firebird as fb
import rainbow_unicorn as ru
import unicorn_deluxe as ud
import white_gold_robe as wg

MOD = r'C:\catseyexi\catseyexi-client\Ashita\polplugins\DATs\TransMog\mount-standing-rooster'
SOURCE = r'ROM\351\101.DAT'
SIZE = 256

RED = np.array((225, 35, 30.))
BEAK = np.array((250, 195, 55.))
COPPER = np.array((225, 110, 40.))
HACKLE = np.array((250, 175, 65.))
CHESTNUT = np.array((160, 68, 32.))
GREEN = np.array((30, 120, 85.))
INK = np.array((18, 30, 45.))
LEGS = np.array((235, 180, 60.))

BEAK_FROM = 1.40      # along the model, head toward +x
HEAD_FROM = 1.15
NECK_FROM = 0.72
TAIL_BEHIND = -0.5
TAIL_END = -2.5
CREST_FROM = 0.85
FADE = 0.22           # yalms of blend either side of a color change
COMB_FROM = 1.95      # heights on the model
WATTLE_BELOW = 1.86
NECK_BOTTOM = 1.1
LEGS_BELOW = 0.85
EYE = (201, 22)                 # on the texture
EYE_RADIUS = (9, 8)
SOFTEN = 7                      # texels of blur that lose the stripes
DETAIL = 0.3                    # how much of the sharp texture stays


def soften(values):
    out = values.astype(float)
    for axis in (0, 1):
        total = np.zeros_like(out)
        for step in range(-SOFTEN, SOFTEN + 1):
            total += np.roll(out, step, axis)
        out = total / (2 * SOFTEN + 1)
    return out


def paint(pixels, where):
    luma = (pixels * (0.30, 0.59, 0.11)).sum(-1)
    empty = pixels.sum(-1) < 12
    light = soften(luma) * (1 - DETAIL) + luma * DETAIL
    x, y = where[..., 0], where[..., 1]
    full = pixels.shape

    color = np.broadcast_to(CHESTNUT, full).copy()
    unmapped = np.isnan(x)

    def put(mask, value):
        color[mask] = np.broadcast_to(value, full)[mask]

    known = ~unmapped
    tail_color = fb.blend(np.broadcast_to(GREEN, full), INK, (TAIL_BEHIND - x) / (TAIL_BEHIND - TAIL_END))
    put(known, fb.blend(color, tail_color, (TAIL_BEHIND + FADE - x) / (2 * FADE)))
    neck_color = fb.blend(np.broadcast_to(HACKLE, full), COPPER, (x - NECK_FROM) / (HEAD_FROM - NECK_FROM))
    towards_neck = np.clip((x - NECK_FROM + FADE) / (2 * FADE), 0, 1) * np.clip((y - NECK_BOTTOM + FADE) / (2 * FADE), 0, 1)
    put(known, fb.blend(color, neck_color, towards_neck))
    head = (x >= HEAD_FROM) & (y >= NECK_BOTTOM)
    put(head, COPPER)
    put(head & (y < WATTLE_BELOW) & (x < BEAK_FROM), RED)
    put((x >= CREST_FROM) & (y >= COMB_FROM), RED)
    put(x >= BEAK_FROM, BEAK)
    put((y < LEGS_BELOW) & (x >= TAIL_BEHIND), LEGS)

    out = np.clip(color * np.clip(light / 125.0, 0.45, 1.35)[..., None], 0, 255)
    rows, columns = np.indices(pixels.shape[:2])
    eye = ((columns - EYE[0]) / EYE_RADIUS[0]) ** 2 + ((rows - EYE[1]) / EYE_RADIUS[1]) ** 2 <= 1
    out[eye] = pixels[eye]
    out[empty] = pixels[empty]
    return out


def main():
    with open(os.path.join(ru.GAME, SOURCE), 'rb') as f:
        data = bytearray(f.read())
    bones = next(ud.skeleton(data[o + 16:o + s]) for k, o, s in ru.chunks(data) if k == 0x29)
    triangles = next(ud.read_mesh(data[o + 16:o + s], bones) for k, o, s in ru.chunks(data)
                     if k == 0x2A and data[o:o + 4] == b'hh_m')
    start = next(o + ru.TEXTURE_HEADER for k, o, s in ru.chunks(data) if k == 0x20)
    blocks = bytes(data[start:start + SIZE * SIZE])
    pixels = wg.decode(blocks, SIZE, SIZE)
    painted = paint(pixels, fb.fill((SIZE, SIZE), triangles))
    data[start:start + SIZE * SIZE] = wg.encode(painted, blocks)
    if len(sys.argv) > 1:
        from PIL import Image
        Image.fromarray(painted.astype(np.uint8)).save(os.path.join(sys.argv[1], 'tim_____wy.png'))

    path = os.path.join(MOD, SOURCE)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
    with open(os.path.join(MOD, 'transmog.json'), 'w') as f:
        json.dump({'title': 'Raptor as Rooster', 'category': 'mount', 'look': 'Rooster'}, f)
    print('Wrote', MOD)


if __name__ == '__main__':
    main()
