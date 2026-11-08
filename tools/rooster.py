"""Builds the mount-chocobo-rooster mod: the ridden chocobo, repainted as an original rooster.

Run it with no arguments. It reads the game's chocobo DAT, never changes it, and writes the mod's
files to DATs\\TransMog. Pass a folder to also save the texture there as a PNG.
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

MOD = r'C:\catseyexi\catseyexi-client\Ashita\polplugins\DATs\TransMog\mount-chocobo-rooster'
TARGET = r'ROM\90\56.DAT'
SEAT_FROM = r'ROM\351\101.DAT'
SEATS = range(48, 56)    # one for each race and sex, it seems
SEAT_BONE = 3
SADDLE_FORWARD = 0.2
HANDLE_BONE, SADDLE_BONE = 18, 52    # the handle hangs off the neck; the rest of the saddle rides on 52
# the rider keeps the Raptor's straddle pose, so each race's hands land at its own reach: these move each
# seat along and up so the hands meet the saddle's handle (Hume, Elvaan, Tarutaru, Mithra, Galka), tuned in game
REACH = {48: (0.08, -0.02), 49: (0.08, -0.02), 50: (0.06, -0.04), 51: (0.06, -0.04), 52: (0.14, 0.0), 53: (0.14, 0.0),
         54: (0.1, 0.0), 55: (0.04, -0.05)}
RIDE = None

RED = (205, 25, 25)
LEGS = (205, 145, 62)
BEAK = (215, 170, 80)
COPPER = (185, 72, 25)
HACKLE = (200, 85, 30)
CHESTNUT = (115, 32, 18)
WING = (85, 25, 16)
TAIL_TOP = (18, 60, 52)
TAIL_END = (12, 18, 26)

# left, top, right, bottom in texels: the saddle, straps and bags stay as they are
GEAR = [(128, 0, 240, 62), (170, 45, 210, 78), (112, 95, 128, 140)]
EYE = (25, 25, 50, 42)
BODY_MIDDLE = 1.15     # heights on the model, head toward +x
TAIL_FROM = -0.62
NECK_FROM, NECK_BOTTOM = 0.3, 1.25
HEAD_FROM, HEAD_BOTTOM = 0.55, 1.62
COMB_FROM = 2.0
WATTLE_FROM, WATTLE_BELOW = 0.72, 1.74
BEAK_FROM = 0.98
LEGS_BELOW = 0.82
WING_OUT = 0.36
LIGHT_BASE = 128.0


def inside(x, y, box):
    return box[0] <= x < box[2] and box[1] <= y < box[3]


def mix(a, b, t):
    t = min(1, max(0, t))
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def lit(color, p, base=150):
    return ru.shade(color, min(1.35, max(0.4, ru.luma(p) / base)))


def is_feather_area(x, y):
    return x >= 205 and y >= 80 or x >= 135 and y >= 178


def paint_body(pixels, where):
    """Everything but the saddle, by where each texel sits on the model."""
    light = (pixels * (0.30, 0.59, 0.11)).sum(-1)
    x, y, side = where[..., 0], where[..., 1], np.abs(where[..., 2])
    full = pixels.shape
    known = ~np.isnan(x)
    color = np.broadcast_to(np.array(CHESTNUT, float), full).copy()

    def put(mask, value):
        color[mask] = np.broadcast_to(np.array(value, float), full)[mask]

    put(known, fb.blend(color, np.array(WING, float), (BODY_MIDDLE - y) / 0.5))
    wing = side > WING_OUT
    put(wing, fb.blend(np.broadcast_to(np.array(WING, float), full), np.array(TAIL_END, float), (side - WING_OUT) / 0.5))
    tail = x < TAIL_FROM
    put(tail, fb.blend(np.broadcast_to(np.array(TAIL_TOP, float), full), np.array(TAIL_END, float), (TAIL_FROM - x) / 0.45))
    neck = (x >= NECK_FROM) & (y >= NECK_BOTTOM) & ~wing
    towards = np.clip((y - NECK_BOTTOM) / 0.3, 0, 1)
    put(neck, fb.blend(np.array(CHESTNUT, float) * np.ones(full), np.array(HACKLE, float), towards))
    head = (x >= HEAD_FROM) & (y >= HEAD_BOTTOM) & ~wing
    put(head, COPPER)
    put(head & (y >= COMB_FROM), RED)
    put(head & (x >= WATTLE_FROM) & (y < WATTLE_BELOW), RED)
    put((x >= BEAK_FROM) & (y >= HEAD_BOTTOM) & ~wing, BEAK)
    put((y < LEGS_BELOW) & ~wing & ~tail, LEGS)

    out = np.clip(color * np.clip(light / LIGHT_BASE, 0.4, 1.35)[..., None], 0, 255)
    result = pixels.astype(float)
    result[known] = out[known]
    rows, columns = np.indices(pixels.shape[:2])
    for box in GEAR + [EYE]:
        keep = (columns >= box[0]) & (columns < box[2]) & (rows >= box[1]) & (rows < box[3])
        result[keep] = pixels[keep]
    return result


def attachment_table(data):
    """Where a skeleton's attachment points start in the file, and the skeleton's bones."""
    offset = next(o for k, o, _ in ru.chunks(data) if k == 0x29)
    body = offset + 16
    count = struct.unpack_from('<H', data, body + 2)[0]
    size = next(s for k, _, s in ru.chunks(data) if k == 0x29)
    return body + 4 + count * 30 + 4, ud.skeleton(bytes(data[body:offset + size]))


def back_height(points, x):
    """The top of a model's back near a point along it, with height up."""
    near = points[(abs(points[:, 0] - x) < 0.16) & (abs(points[:, 2]) < 0.22)]
    return near[:, 1].max()


def mesh_points(data, name, bones):
    chunk = next((o, s) for k, o, s in ru.chunks(data) if k == 0x2A and data[o:o + 4] == name)
    triangles = ud.read_mesh(bytes(data[chunk[0] + 16:chunk[0] + chunk[1]]), bones)
    return np.concatenate([t[0] for t in triangles])


def add_seats(data, raptor):
    """A mount keeps a rider's seat in attachment points 48 to 55; a chocobo's are empty."""
    table, bones = attachment_table(data)
    raptor_table, raptor_bones = attachment_table(raptor)
    ours, theirs = mesh_points(data, b'hh_c', bones), mesh_points(raptor, b'hh_m', raptor_bones)
    rotation, move = bones[SEAT_BONE]
    middle = move[0] + SADDLE_FORWARD
    top = back_height(ours, middle)
    for point in SEATS:
        at = raptor_table + point * 26
        bone = struct.unpack_from('<H', raptor, at)[0]
        offset = np.array(struct.unpack_from('<3f', raptor, at + 14))
        r, m = raptor_bones[bone]
        seat = offset @ r + m
        lift = -seat[1] - back_height(theirs, seat[0])
        forward, up = REACH[point]
        target = np.array((middle + forward, -(top + lift + up), 0.0))
        local = (target - move) @ rotation.T
        here = table + point * 26
        struct.pack_into('<H', data, here, SEAT_BONE)
        struct.pack_into('<3f', data, here + 14, *local)
        print('seat', point, 'lift', round(float(lift), 3), 'local', np.round(local, 3))


def as_mount(data):
    """A ride file lacks a mount's sequence for seating a rider, so it takes the Raptor's."""
    with open(os.path.join(ru.GAME, SEAT_FROM), 'rb') as f:
        raptor = f.read()
    borrowed = {}
    for kind, offset, size in ru.chunks(raptor):
        name = raptor[offset:offset + 4]
        if (kind == 0x07 and name in (b'cdam', b'vdam', b'coff')) or (kind == 0x3D and name.startswith(b'dam')) \
                or (kind == 0x45 and name == b'moun'):
            borrowed[name] = raptor[offset:offset + size]
    pieces = []
    for kind, offset, size in ru.chunks(data):
        name = bytes(data[offset:offset + 4])
        chunk = bytes(data[offset:offset + size])
        if kind == 0x07 and name in borrowed:
            chunk = borrowed[name]
        pieces.append(chunk)
        if kind == 0x45 and name == b'info':
            pieces += [borrowed[key] for key in (b'vdam', b'dam1', b'dam2', b'dam3', b'dam4', b'moun')]
    out = bytearray(b''.join(pieces))
    out[0:4] = b'moun'
    if RIDE is not None:        # the moun chunk's 16 bytes: per race and sex, 8 signed numbers then 8 riding styles
        at = next(o for k, o, _ in ru.chunks(out) if k == 0x45 and out[o:o + 4] == b'moun')
        assert len(RIDE) == 16, 'the moun chunk holds 16 bytes'
        out[at + 16:at + 32] = RIDE
    add_seats(out, raptor)
    return out



def pin_handle(data):
    """The saddle's handle hangs on a neck bone, so it swings away from the rider's hands as the bird runs. It
    moves onto the saddle's own bone, re-expressed in that bone's frame so it rests exactly where it was."""
    bones = attachment_table(data)[1]
    offset = next(o for k, o, _ in ru.chunks(data) if k == 0x2A and data[o:o + 4] == b'hh_k')
    c = offset + 16
    head = struct.unpack_from('<23H', data, c)
    table = struct.unpack_from('<%dH' % head[8], data, c + head[6] * 2)
    neck, saddle = table.index(HANDLE_BONE), table.index(SADDLE_BONE)
    one = struct.unpack_from('<H', data, c + head[9] * 2)[0]
    (r1, m1), (r2, m2) = bones[HANDLE_BONE], bones[SADDLE_BONE]
    moved = 0
    for i in range(one):
        at = c + head[12] * 2 + i * 4
        pair = struct.unpack_from('<H', data, at)[0]
        if pair & 0x7f != neck:
            continue
        v = c + head[15] * 2 + i * 24
        point, normal = np.array(struct.unpack_from('<3f', data, v)), np.array(struct.unpack_from('<3f', data, v + 12))
        struct.pack_into('<3f', data, v, *((point @ r1 + m1 - m2) @ r2.T))
        struct.pack_into('<3f', data, v + 12, *((normal @ r1) @ r2.T))
        struct.pack_into('<H', data, at, (pair & ~0x3fff) | saddle << 7 | saddle)   # its mirror is the same bone
        moved += 1
    return moved


def main():
    with open(os.path.join(ru.GAME, TARGET), 'rb') as f:
        data = bytearray(f.read())
    textures = [offset + ru.TEXTURE_HEADER for kind, offset, _ in ru.chunks(data) if kind == 0x20]
    start = textures[0]
    blocks = bytes(data[start:start + ru.SIZE * ru.SIZE])
    pixels = wg.decode(blocks, ru.SIZE, ru.SIZE)
    bones = attachment_table(data)[1]
    triangles = []
    for kind, offset, size in ru.chunks(data):
        if kind == 0x2A:
            triangles += ud.read_mesh(bytes(data[offset + 16:offset + size]), bones)
    painted = paint_body(pixels, fb.fill((ru.SIZE, ru.SIZE), triangles))
    data[start:start + ru.SIZE * ru.SIZE] = wg.encode(painted, blocks)
    if len(sys.argv) > 1:
        from PIL import Image
        Image.fromarray(painted.astype(np.uint8)).save(os.path.join(sys.argv[1], 'tim_____choc_tx.png'))

    data = as_mount(data)
    print('Moved %d handle points onto the saddle' % pin_handle(data))
    path = os.path.join(MOD, TARGET)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
    with open(os.path.join(MOD, 'transmog.json'), 'w') as f:
        json.dump({'title': 'Chocobo as Red Rooster', 'category': 'mount', 'look': 'Red Rooster'}, f)
    print('Wrote', MOD)
    ru.refresh_swaps(data, 'Red Rooster', MOD)


if __name__ == '__main__':
    main()
