"""Builds the mount-red-rooster mod: an original realistic red rooster on the Raptor, a true mount.

The Raptor seats a rider properly, so it's reshaped rather than replaced. Each vertex moves in place,
which keeps the mesh's size and layout: a round body and chest, a short beak, a thicker neck, and the
long tail pulled in and curled up. It's then painted by 3D position, measured on the original shape.
Run it with no arguments. Pass a folder to also save the texture there as a PNG.
"""
import json
import os
import struct
import sys

import numpy as np

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import firebird as fb
import rainbow_unicorn as ru
import unicorn_deluxe as ud
import white_gold_robe as wg

MOD = r'C:\catseyexi\catseyexi-client\Ashita\polplugins\DATs\TransMog\mount-red-rooster'
SOURCE = r'ROM\351\101.DAT'
SIZE = 256

MAHOGANY = np.array((125, 32, 18.))
DEEP = np.array((62, 18, 14.))
HACKLE = np.array((205, 82, 28.))
COMB = np.array((215, 24, 26.))
BEAK = np.array((222, 180, 95.))
LEGS = np.array((214, 150, 62.))
TAIL = np.array((14, 20, 26.))
SHEEN = np.array((16, 64, 56.))

# the original Raptor, head toward +x, height up, half the body on +z
BODY_FRONT, BODY_BACK = 0.75, -0.6
BODY_HEIGHT = 1.25
BODY_X = 0.08
PLUMP_SIDE, PLUMP_UNDER, PLUMP_LONG = 1.6, 1.45, 0.92
NECK_FROM, NECK_THICK = 0.72, 1.45
BEAK_FROM, BEAK_KEEP = 1.40, 0.42
TAIL_FROM, TAIL_END = -0.6, -2.5
TAIL_KEEP, TAIL_RISE, TAIL_DEEP = 0.34, 0.62, 2.6
LEGS_BELOW = 0.85

HEAD_FROM = 1.15
COMB_FROM, CREST_FROM = 1.95, 0.85
WATTLE_BELOW = 1.86
NECK_BOTTOM = 1.1
FADE = 0.22
EYE, EYE_RADIUS = (201, 22), (9, 8)
SOFTEN, DETAIL = 7, 0.3
FEATHER = 0.13          # how strongly the painted feather rows show


def smooth(edge0, edge1, x):
    t = np.clip((x - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)


def reshape(p):
    """Where a point of the original Raptor goes, in model space with height up."""
    x, y, z = p
    tail = smooth(TAIL_FROM + 0.25, TAIL_FROM - 0.2, x)
    body = smooth(BODY_BACK - 0.25, BODY_BACK + 0.1, x) * smooth(BODY_FRONT + 0.25, BODY_FRONT - 0.1, x)
    body *= smooth(LEGS_BELOW - 0.1, LEGS_BELOW + 0.15, y)

    new_x, new_y, new_z = x, y, z
    side = 1 + (PLUMP_SIDE - 1) * body
    new_z = z * side
    below = min(0, y - BODY_HEIGHT)
    new_y = y + below * (PLUMP_UNDER - 1) * body
    new_x = BODY_X + (x - BODY_X) * (1 + (PLUMP_LONG - 1) * body)

    neck = smooth(NECK_FROM - 0.1, NECK_FROM + 0.15, x) * smooth(NECK_BOTTOM - 0.1, NECK_BOTTOM + 0.1, y)
    if neck > 0:
        new_z *= 1 + (NECK_THICK - 1) * neck * (1 - smooth(HEAD_FROM, HEAD_FROM + 0.2, x))
    if x > BEAK_FROM:
        new_x = BEAK_FROM + (x - BEAK_FROM) * BEAK_KEEP

    if tail > 0:
        along = max(0.0, TAIL_FROM - x)
        new_x = x + (TAIL_FROM - along * TAIL_KEEP - x) * tail
        new_y = y + along * TAIL_RISE * tail + (y - 1.55) * (TAIL_DEEP - 1) * tail * (1 - along / (TAIL_FROM - TAIL_END))
    return np.array((new_x, new_y, new_z))


def deform(data, offset, bones, reshape=reshape):
    """Moves the vertices of one mesh chunk in place."""
    c = offset + 16
    head = struct.unpack_from('<23H', data, c)
    one, two = struct.unpack_from('<2H', data, c + head[9] * 2)
    pairs = [struct.unpack_from('<2H', data, c + head[12] * 2 + i * 4) for i in range(one + two)]
    at = c + head[15] * 2
    flip = np.array((1, -1, 1))
    for i in range(one):
        v = struct.unpack_from('<6f', data, at)
        rotation, move = bones[pairs[i][0] & 0x7f]
        point = np.array(v[:3]) @ rotation + move
        target = reshape(point * flip) * flip
        struct.pack_into('<3f', data, at, *((target - move) @ rotation.T))
        at += 24
    for i in range(one, one + two):
        v = list(struct.unpack_from('<14f', data, at))
        r1, m1 = bones[pairs[i][0] & 0x7f]
        r2, m2 = bones[pairs[i][1] & 0x7f]
        point = np.array(v[0:6:2]) @ r1 + m1 * v[6] + np.array(v[1:6:2]) @ r2 + m2 * v[7]
        delta = reshape(point * flip) * flip - point
        d1, d2 = (delta * v[6]) @ r1.T, (delta * v[7]) @ r2.T
        for k in range(3):
            v[k * 2] += d1[k]
            v[k * 2 + 1] += d2[k]
        struct.pack_into('<14f', data, at, *v)
        at += 56


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
    known = ~np.isnan(x)
    color = np.broadcast_to(MAHOGANY, full).copy()

    def put(mask, value):
        color[mask] = np.broadcast_to(value, full)[mask]

    put(known, fb.blend(np.broadcast_to(MAHOGANY, full), DEEP, (BODY_HEIGHT - y) / 0.5))
    tail_color = fb.blend(np.broadcast_to(TAIL, full), SHEEN, 0.5 + 0.5 * np.sin(y * 9 + x * 4))
    put(known, fb.blend(color, tail_color, (TAIL_FROM + FADE - x) / (2 * FADE)))
    towards_neck = (np.clip((x - NECK_FROM + FADE) / (2 * FADE), 0, 1)
                    * np.clip((y - NECK_BOTTOM + FADE) / (2 * FADE), 0, 1))
    put(known, fb.blend(color, HACKLE, towards_neck))
    head = (x >= HEAD_FROM) & (y >= NECK_BOTTOM)
    put(head, HACKLE * 1.05)
    put(head & (y < WATTLE_BELOW) & (x < BEAK_FROM), COMB)
    put((x >= CREST_FROM) & (y >= COMB_FROM), COMB)
    put(x >= BEAK_FROM, BEAK)
    put((y < LEGS_BELOW) & (x >= TAIL_FROM), LEGS)

    rows, columns = np.indices(pixels.shape[:2])
    feathers = 1 + FEATHER * np.sin(columns * 1.1) * np.sin(rows * 1.1 + np.sin(columns * 0.55) * 1.4)
    shade = np.clip(light / 118.0, 0.5, 1.3) * feathers
    out = np.clip(color * shade[..., None], 0, 255)
    eye = ((columns - EYE[0]) / EYE_RADIUS[0]) ** 2 + ((rows - EYE[1]) / EYE_RADIUS[1]) ** 2 <= 1
    out[eye] = pixels[eye]
    out[empty] = pixels[empty]
    return out


def main():
    with open(os.path.join(ru.GAME, SOURCE), 'rb') as f:
        data = bytearray(f.read())
    bones = next(ud.skeleton(data[o + 16:o + s]) for k, o, s in ru.chunks(data) if k == 0x29)
    body = next((o, s) for k, o, s in ru.chunks(data) if k == 0x2A and data[o:o + 4] == b'hh_m')
    triangles = ud.read_mesh(data[body[0] + 16:body[0] + body[1]], bones)

    start = next(o + ru.TEXTURE_HEADER for k, o, s in ru.chunks(data) if k == 0x20)
    blocks = bytes(data[start:start + SIZE * SIZE])
    pixels = wg.decode(blocks, SIZE, SIZE)
    painted = paint(pixels, fb.fill((SIZE, SIZE), triangles))
    data[start:start + SIZE * SIZE] = wg.encode(painted, blocks)
    deform(data, body[0], bones)
    if len(sys.argv) > 1:
        from PIL import Image
        Image.fromarray(painted.astype(np.uint8)).save(os.path.join(sys.argv[1], 'tim_____wy.png'))

    path = os.path.join(MOD, SOURCE)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
    with open(os.path.join(MOD, 'transmog.json'), 'w') as f:
        json.dump({'title': 'Raptor as Plump Rooster', 'category': 'mount'}, f)
    print('Wrote', MOD)


if __name__ == '__main__':
    main()
