"""Works out the robe's new pieces and writes them, with their textures, for robe_blender.py to bring into Blender.

Pieces are in the body's bind pose, where -y is up, +x is the front and z runs across the body. Each vertex lists
the joints it follows. Run it with the folder to write to.
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image

import white_gold_robe as robe

PLATE = robe.SLATE
NAVY = np.array([40, 52, 78])
GOLD = robe.GOLD
METAL_TEXTURE = 'tim     em_p0000'
PANEL_TEXTURE = 'tim     em_t0000'

CHEST = 28
SPINE, FRONT_TOP, FRONT_TAIL = 27, 21, 22
SEGMENTS = 36
# the cloth over the shoulders, from the neck out: (y, radius front to back, radius across)
MANTLE = [(-1.760, 0.090, 0.100), (-1.730, 0.120, 0.150), (-1.700, 0.145, 0.195), (-1.670, 0.160, 0.235),
          (-1.635, 0.168, 0.275), (-1.595, 0.172, 0.305)]
FIT_OFFSET = 0.012     # how far the cloth lies above the coat: robe_blender.py moves it onto the coat
MANTLE_OPEN = math.radians(40)    # half the gap left at the front, so the chest shows


def metal(path):
    """The top half is the coat's slate cloth with a gold band at the edge, the bottom half plain gold."""
    v = np.linspace(0, 1, 512)[:, None]
    u = np.linspace(0, 1, 512)[None, :]
    cloth = PLATE * (0.86 + 0.10 * np.cos(u * math.pi * 40))[..., None] * np.ones((512, 512, 1))
    cloth = np.where((((v > 0.44) & (v < 0.482)) | (u < 0.018) | (u > 0.982))[..., None], GOLD * 0.95, cloth)
    gold = GOLD * (1.1 - 0.3 * (v - 0.5) * 2)[..., None] * np.ones((512, 512, 1))
    image = np.where(v[..., None] < 0.5, cloth, gold)
    Image.fromarray(np.clip(image, 0, 255).astype(np.uint8)).save(path)


def panel(path):
    """Navy cloth with a gold border and a gold point at the foot."""
    v = np.linspace(0, 1, 256)[:, None]
    u = np.linspace(0, 1, 256)[None, :]
    across = np.abs(u - 0.5) * 2
    cloth = NAVY * (0.9 + 0.12 * np.cos(u * math.pi * 10))[..., None] * np.ones((256, 256, 1))
    border = (across > 0.8) | (v > 0.92) | (across + (1 - v) * 3 < 0.45) & (v > 0.7)
    gold = GOLD * (0.85 + 0.25 * np.cos(v * math.pi * 4))[..., None]
    image = np.where(border[..., None], gold, cloth)
    Image.fromarray(np.clip(image, 0, 255).astype(np.uint8)).save(path)


def piece(name, texture, verts, faces):
    return {'name': name, 'texture': texture, 'verts': verts, 'faces': faces}


def vertex(point, normal, joints):
    return {'co': [float(c) for c in point[:3]], 'no': [float(c) for c in normal[:3]],
            'joints': [[j, float(w)] for j, w in joints]}


def mantle():
    """A rough yoke over the shoulders, open at the front. Blender lays it on the coat and copies the coat's weights."""
    verts, faces = [], []
    rows = len(MANTLE)
    start = math.pi / 2 + MANTLE_OPEN
    sweep = 2 * math.pi - 2 * MANTLE_OPEN
    for row, (y, radius_x, radius_z) in enumerate(MANTLE):
        for seg in range(SEGMENTS + 1):
            angle = start + sweep * seg / SEGMENTS
            across, front = math.cos(angle), math.sin(angle)
            point = (0.012 + radius_x * front, y, radius_z * across)
            normal = np.array([front / radius_x, -8, across / radius_z])
            normal = normal / np.linalg.norm(normal)
            verts.append(vertex(point, normal, [(CHEST, 1)]))
    for row in range(rows - 1):
        for seg in range(SEGMENTS):
            a, b = row * (SEGMENTS + 1) + seg, row * (SEGMENTS + 1) + seg + 1
            c, d = a + SEGMENTS + 1, b + SEGMENTS + 1
            u0, u1 = seg / SEGMENTS, (seg + 1) / SEGMENTS
            v0, v1 = row / (rows - 1) / 2, (row + 1) / (rows - 1) / 2
            faces.append([[a, u0, v0], [c, u0, v1], [d, u1, v1], [b, u1, v0]])
    return {**piece('hh_p', METAL_TEXTURE, verts, faces), 'fit': FIT_OFFSET}


def tabard():
    """A long panel down the front, on the coat's front tail bones so it swings with the coat."""
    rows = [(-1.235, 0.165, 0.105), (-1.10, 0.200, 0.110), (-0.95, 0.225, 0.115), (-0.75, 0.250, 0.120),
            (-0.55, 0.270, 0.122), (-0.34, 0.285, 0.070), (-0.28, 0.290, 0.004)]
    verts, faces = [], []
    for row, (y, x, half) in enumerate(rows):
        follow = min(1, max(0, (y + 1.235) / 0.2))
        joints = [(SPINE, 1 - follow), (FRONT_TAIL, follow)] if 0 < follow else [(SPINE, 1)]
        for edge in (-1, 1):
            verts.append(vertex((x, y, edge * half), (1, 0.02, 0), joints))
    for row in range(len(rows) - 1):
        a = row * 2
        v0, v1 = row / (len(rows) - 1), (row + 1) / (len(rows) - 1)
        faces.append([[a, 0, v0], [a + 2, 0, v1], [a + 3, 1, v1], [a + 1, 1, v0]])
    return piece('hh_t', PANEL_TEXTURE, verts, faces)


def ring():
    """The gold ring at the waist, standing on the front of the belt."""
    center = np.array([0.205, -1.205, 0])
    major, minor, rounds, around = 0.062, 0.016, 28, 10
    verts, faces = [], []
    for i in range(rounds):
        a = 2 * math.pi * i / rounds
        for j in range(around):
            b = 2 * math.pi * j / around
            spoke = np.array([0, math.cos(a), math.sin(a)])
            normal = spoke * math.cos(b) + np.array([1, 0, 0]) * math.sin(b)
            verts.append(vertex(center + spoke * major + normal * minor, normal, [(SPINE, 1)]))
    for i in range(rounds):
        for j in range(around):
            n = (i + 1) % rounds
            m = (j + 1) % around
            quad = [i * around + j, n * around + j, n * around + m, i * around + m]
            faces.append([[index, 0.5, 0.7] for index in quad])
    return piece('hh_r', METAL_TEXTURE, verts, faces)


def main():
    folder = sys.argv[1]
    os.makedirs(folder, exist_ok=True)
    metal(os.path.join(folder, METAL_TEXTURE + '.png'))
    panel(os.path.join(folder, PANEL_TEXTURE + '.png'))
    pieces = [mantle(), tabard(), ring()]
    with open(os.path.join(folder, 'parts.json'), 'w') as f:
        json.dump(pieces, f)
    print('Wrote', len(pieces), 'pieces,', sum(len(p['faces']) for p in pieces), 'faces')


if __name__ == '__main__':
    main()
