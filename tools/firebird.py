"""Builds the mount-rooster mod: the Tulfaire, a true mount, repainted as an original firebird.

The chocobo version in rooster.py draws well, but the rider ends up on the ground, because a ride
file doesn't seat a rider on a mount slot. Run it with no arguments. Pass a folder to also save the
textures there as PNGs. It reads the game's DAT and never changes it.
"""
import json
import os
import struct
import sys

import numpy as np

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rainbow_unicorn as ru
import unicorn_deluxe as ud
import white_gold_robe as wg

MOD = r'C:\catseyexi\catseyexi-client\Ashita\polplugins\DATs\TransMog\mount-rooster'
SOURCE = r'ROM\353\64.DAT'

RED = np.array((225, 35, 30.))
BEAK = np.array((250, 195, 55.))
COPPER = np.array((230, 120, 40.))
HACKLE = np.array((250, 175, 60.))
CHESTNUT = np.array((150, 62, 30.))
GREEN = np.array((25, 115, 80.))
INK = np.array((18, 30, 45.))
LEGS = np.array((235, 180, 60.))

COMB_FROM = 1.72      # heights on the model
HEAD_FROM = 1.45
NECK_FROM = 0.95
LEGS_BELOW = 0.28
TAIL_BEHIND = -0.55   # along the model, head toward +x
WING_OUT = 0.42       # out to the side
WING_TIP = 2.3
EYE_BOX = (0, 0, 26, 26)    # left, top, right, bottom on the first texture
LIGHT_BASE = 82.0
BLEED = 3


def fill(texture_size, triangles):
    width, height = texture_size
    where = np.full((height, width, 3), np.nan)
    for points, uv, _ in triangles:
        u, v = np.array(uv[0::2]) * width, np.array(uv[1::2]) * height
        area = (v[1] - v[2]) * (u[0] - u[2]) + (u[2] - u[1]) * (v[0] - v[2])
        if abs(area) < 1e-9:
            continue
        left, right = int(max(u.min() - 1, 0)), int(min(u.max() + 2, width))
        top, bottom = int(max(v.min() - 1, 0)), int(min(v.max() + 2, height))
        xs, ys = np.meshgrid(np.arange(left, right) + .5, np.arange(top, bottom) + .5)
        a = ((v[1] - v[2]) * (xs - u[2]) + (u[2] - u[1]) * (ys - v[2])) / area
        b = ((v[2] - v[0]) * (xs - u[2]) + (u[0] - u[2]) * (ys - v[2])) / area
        c = 1 - a - b
        hit = np.minimum(np.minimum(a, b), c) >= -0.02
        at = a[..., None] * points[0] + b[..., None] * points[1] + c[..., None] * points[2]
        where[top:bottom, left:right][hit] = at[hit]
    return where


def blend(a, b, t):
    t = np.clip(t, 0, 1)[..., None]
    return a * (1 - t) + b * t


def paint(pixels, where, first):
    light = pixels.mean(-1, keepdims=False) * 0 + (pixels * (0.30, 0.59, 0.11)).sum(-1)
    x, y, side = where[..., 0], where[..., 1], np.abs(where[..., 2])
    body = blend(np.broadcast_to(CHESTNUT, pixels.shape).copy(), CHESTNUT * 0.7, (NECK_FROM - y) / 0.6)

    wings = side > WING_OUT
    body[wings] = blend(np.broadcast_to(CHESTNUT, pixels.shape), GREEN * 0.8, (side - 1.0) / (WING_TIP - 1.0))[wings]
    tail = x < TAIL_BEHIND
    body[tail] = blend(np.broadcast_to(GREEN, pixels.shape), INK, (TAIL_BEHIND - x) / 1.1)[tail]
    neck = (y >= NECK_FROM) & ~wings & ~tail
    body[neck] = blend(np.broadcast_to(HACKLE, pixels.shape), COPPER, (y - NECK_FROM) / (HEAD_FROM - NECK_FROM))[neck]
    head = (y >= HEAD_FROM) & ~wings & ~tail
    body[head] = np.broadcast_to(COPPER, pixels.shape)[head]
    comb = (y >= COMB_FROM) & ~wings & ~tail
    body[comb] = np.broadcast_to(RED, pixels.shape)[comb]
    legs = (y < LEGS_BELOW) & ~tail & ~wings
    body[legs] = np.broadcast_to(LEGS, pixels.shape)[legs]

    # the beak is the only brown on the head of this magenta bird
    brown = (pixels[..., 1] > pixels[..., 2] * 1.05) & head
    body[brown] = np.broadcast_to(BEAK, pixels.shape)[brown]

    out = np.clip(body * np.clip(light / LIGHT_BASE, 0.35, 1.45)[..., None], 0, 255)
    known = ~np.isnan(x)
    result = pixels.astype(float)
    result[known] = out[known]
    if first:
        left, top, right, bottom = EYE_BOX
        result[top:bottom, left:right] = pixels[top:bottom, left:right]
    for _ in range(BLEED):
        grown = known.copy()
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            near = np.roll(known, (dy, dx), (0, 1)) & ~grown
            result[near] = np.roll(result, (dy, dx), (0, 1))[near]
            grown |= near
        known = grown
    return np.clip(result, 0, 255)


def main():
    with open(os.path.join(ru.GAME, SOURCE), 'rb') as f:
        data = bytearray(f.read())
    bones = next(ud.skeleton(data[o + 16:o + s]) for k, o, s in ru.chunks(data) if k == 0x29)
    triangles = ud.body_triangles(data, bones)
    textures = []
    for kind, offset, size in ru.chunks(data):
        if kind == 0x20:
            width, height = struct.unpack_from('<II', data, offset + 16 + 21)
            textures.append((offset + ru.TEXTURE_HEADER, width, height))

    for index, (start, width, height) in enumerate(textures[:2]):
        blocks = bytes(data[start:start + width * height])
        pixels = wg.decode(blocks, width, height)
        where = fill((width, height), [t for t in triangles if t[2] == index])
        painted = paint(pixels, where, index == 0)
        data[start:start + width * height] = wg.encode(painted, blocks)
        if len(sys.argv) > 1:
            from PIL import Image
            Image.fromarray(painted.astype(np.uint8)).save(os.path.join(sys.argv[1], 'tim_____tex0%d.png' % index))

    path = os.path.join(MOD, SOURCE)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
    with open(os.path.join(MOD, 'transmog.json'), 'w') as f:
        json.dump({'title': 'Tulfaire as Firebird', 'category': 'mount', 'look': 'Firebird'}, f)
    print('Wrote', MOD)
    ru.refresh_swaps(data, 'Firebird', MOD)


if __name__ == '__main__':
    main()
