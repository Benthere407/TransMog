"""Builds the mount-raptor-unicorn-deluxe mod: an original rainbow unicorn painted by 3D position.

rainbow_unicorn.py paints the flat texture, so colors break where it folds around the model. This
works out where each texel sits on the model, using the mesh and skeleton in the DAT, so color
runs along the real mane and tail and only the lower legs turn gold. Run it with no arguments.
Pass a folder to also save the two textures there as PNGs. Texels the body mesh doesn't use, such
as the horn's piece, are painted by outline as before.
"""
import json
import math
import os
import struct
import sys

import numpy as np

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rainbow_unicorn as ru
import red_rooster as rr

MOD = r'C:\catseyexi\catseyexi-client\Ashita\polplugins\DATs\TransMog\mount-raptor-unicorn-deluxe'

MANE_COLORS = [(200, 70, 240), (240, 70, 200), (130, 90, 250), (60, 145, 255), (45, 220, 225), (80, 230, 125),
               (245, 235, 85), (255, 175, 60), (255, 110, 165)]
TAIL_COLORS = [(240, 70, 200), (130, 90, 250), (60, 145, 255), (45, 220, 225), (80, 230, 125), (245, 235, 85),
               (255, 175, 60), (255, 100, 125), (205, 80, 240)]
PINK = (255, 190, 225)
LAVENDER = (205, 180, 255)
GOLD = (255, 205, 85)

MANE_TOP, MANE_BOTTOM = 2.4, 0.95      # heights on the model
TAIL_ROOT, TAIL_END = -0.7, -2.57      # along the model, head toward +x
LEG_FADE_TOP, LEG_FADE_BOTTOM = 1.25, 0.75
GOLD_TOP, GOLD_BOTTOM = 0.75, 0.55
EYE = (86, 190)                        # the real eye, the bright spot on the first texture
EYE_RADIUS = (16, 13)
BLEED = 3                              # texels
DETAIL_RADIUS = 4                      # texels of blur taken away to leave the fine detail
FUR_DETAIL, FUR_STRANDS = 0.16, 0.07
HAIR_DETAIL, HAIR_STRANDS = 0.3, 0.2
HORN_BLEED = 4                         # texels
HORN_SAME = 0.008                      # yalms: a body point this close to a horn point is the copy
HORN_SKIN_FROM = 0.72                  # how far down the horn the head's color starts
TAIL_ROOT_AT = (-0.62, 1.6)            # along and up the model: what the tail tilts around
TAIL_SHIFT = 0.2                       # how far back the whole tail goes
TAIL_FULL = 1.0                        # above 1 the back of the curve bulges out further
TAIL_TILT = 0.0                        # degrees; above 0 the front of the tail lifts and goes back
TAIL_BEHIND = 0.1                      # along the model: the front of the body never moves
LEGS_TOP, LEGS_BACK = 1.05, -1.0       # height and place below which a point is a leg, not tail
FEET_TOP = 0.45                        # height: the back feet reach as far back as the tail
ROOT_HOLD, ROOT_FREE = 0.05, 0.55      # distance from the root: inside the first the tail stays, past the second it all moves
TAIL_NEAR = 0.05                       # a vertex this close to the tail's texels is part of the tail


def quaternion_matrix(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w)],
                     [2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w)],
                     [2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y)]])


def skeleton(body):
    bones = []
    for i in range(struct.unpack_from('<H', body, 2)[0]):
        at = 4 + i * 30
        parent = body[at]
        rotation = quaternion_matrix(struct.unpack_from('<4f', body, at + 2))
        move = np.array(struct.unpack_from('<3f', body, at + 18))
        if i == 0 or parent >= i:
            bones.append((rotation, move))
        else:
            up_rotation, up_move = bones[parent]
            bones.append((rotation @ up_rotation, up_move + move @ up_rotation))
    return bones


def body_triangles(data, bones):
    """The hh_b mesh as (positions, uvs, texture index) with height pointing up."""
    for kind, offset, size in ru.chunks(data):
        if kind == 0x2A and data[offset:offset + 4] == b'hh_b':
            return read_mesh(data[offset + 16:offset + size], bones)
    sys.exit('No body mesh found.')


def read_mesh(c, bones):
    head = struct.unpack_from('<23H', c, 0)
    draw, draw_size, counts, pairs_at, verts_at = head[3], head[5], head[9], head[12], head[15]
    one, two = struct.unpack_from('<2H', c, counts * 2)
    pairs = [struct.unpack_from('<2H', c, pairs_at * 2 + i * 4) for i in range(one + two)]
    if head[1] & 0x80:      # this mesh's bone ids index its own bone table, as the horn's do
        table = struct.unpack_from('<%dH' % head[8], c, head[6] * 2)
        pairs = [(table[a & 0x7f], table[b & 0x7f] if b else 0) for a, b in pairs]
    at = verts_at * 2
    points = []
    for i in range(one):
        v = struct.unpack_from('<6f', c, at)
        at += 24
        rotation, move = bones[pairs[i][0] & 0x7f]
        points.append(np.array(v[:3]) @ rotation + move)
    for i in range(one, one + two):
        v = struct.unpack_from('<14f', c, at)
        at += 56
        r1, m1 = bones[pairs[i][0] & 0x7f]
        r2, m2 = bones[pairs[i][1] & 0x7f]
        points.append(np.array(v[0:6:2]) @ r1 + m1 * v[6] + np.array(v[1:6:2]) @ r2 + m2 * v[7])
    points = np.array(points) * (1, -1, 1)

    triangles = []
    stream = c[draw * 2:(draw + draw_size) * 2]
    at, texture = 0, 0

    def add(indices, uvs):
        triangles.append((points[list(indices)], uvs, texture))

    while at + 2 <= len(stream):
        op = struct.unpack_from('<H', stream, at)[0]
        if op == 0x8010:
            at += 46
        elif op == 0x8000:
            texture = 0 if stream[at + 2:at + 18].rstrip().endswith(b'1') else 1
            at += 18
        elif op == 0x0054:
            count = struct.unpack_from('<H', stream, at + 2)[0]
            at += 4
            for _ in range(count):
                t = struct.unpack_from('<3H6f', stream, at)
                at += 30
                add(t[:3], t[3:])
        elif op == 0x5453:
            count = struct.unpack_from('<H', stream, at + 2)[0]
            t = struct.unpack_from('<3H6f', stream, at + 4)
            at += 34
            a, b, c3 = t[:3]
            ua, ub, uc = t[3:5], t[5:7], t[7:9]
            add((a, b, c3), ua + ub + uc)
            flip = True
            for _ in range(count - 1):
                index, u, v = struct.unpack_from('<H2f', stream, at)
                at += 10
                a, ua, b, ub, c3, uc = b, ub, c3, uc, index, (u, v)
                add((b, a, c3), ub + ua + uc) if flip else add((a, b, c3), ua + ub + uc)
                flip = not flip
        else:
            break
    return triangles


def position_maps(triangles):
    size = ru.SIZE
    where = [np.full((size, size, 3), np.nan), np.full((size, size, 3), np.nan)]
    facing = [np.zeros((size, size, 3)), np.zeros((size, size, 3))]
    for points, uv, texture in triangles:
        normal = np.cross(points[1] - points[0], points[2] - points[0])
        length = np.linalg.norm(normal)
        if length < 1e-9:
            continue
        normal /= length
        u, v = np.array(uv[0::2]) * size, np.array(uv[1::2]) * size
        area = (v[1] - v[2]) * (u[0] - u[2]) + (u[2] - u[1]) * (v[0] - v[2])
        if abs(area) < 1e-9:
            continue
        left, right = int(max(u.min() - 1, 0)), int(min(u.max() + 2, size))
        top, bottom = int(max(v.min() - 1, 0)), int(min(v.max() + 2, size))
        for y in range(top, bottom):
            for x in range(left, right):
                a = ((v[1] - v[2]) * (x + .5 - u[2]) + (u[2] - u[1]) * (y + .5 - v[2])) / area
                b = ((v[2] - v[0]) * (x + .5 - u[2]) + (u[0] - u[2]) * (y + .5 - v[2])) / area
                c = 1 - a - b
                if min(a, b, c) >= -0.02:
                    where[texture][y, x] = a * points[0] + b * points[1] + c * points[2]
                    facing[texture][y, x] = normal
    return where, facing


def gradient(colors, u):
    u = min(0.999, max(0, u)) * (len(colors) - 1)
    i = int(u)
    a, b = colors[i], colors[i + 1]
    return tuple(a[k] + (b[k] - a[k]) * (u - i) for k in range(3))


def mix(a, b, t):
    t = min(1, max(0, t))
    return tuple(a[k] + (b[k] - a[k]) * t for k in range(3))


def hair(color, p, light):
    shade = (0.55 + ru.luma(p) / 400) * light
    if shade <= 1:
        return ru.shade(color, shade)
    return tuple(int(min(255, c + (255 - c) * (shade - 1) * 1.2)) for c in color)


def body(p, at, normal):
    height = at[1]
    color = mix(PINK, LAVENDER, (LEG_FADE_TOP - height) / (LEG_FADE_TOP - LEG_FADE_BOTTOM))
    color = mix(color, GOLD, (GOLD_TOP - height) / (GOLD_TOP - GOLD_BOTTOM))
    sky = 0.86 + 0.14 * abs(normal[1]) if normal[1] > 0 else 0.86 + 0.08 * normal[1]
    return ru.shade(color, sky * (0.72 + ru.luma(p) / 480))


def paint_first(pixels, where, facing, old):
    for y in range(ru.SIZE):
        for x in range(ru.SIZE):
            at = where[y, x]
            if np.isnan(at[0]):
                continue
            p = pixels[y][x]
            if ru.inside(x, y, ru.MANE):
                u = (MANE_TOP - at[1]) / (MANE_TOP - MANE_BOTTOM)
                u += 0.05 * math.sin(at[0] * 9 + at[1] * 4) + (ru.luma(p) - 170) / 1500
                old[y][x] = hair(gradient(MANE_COLORS, u), p, 0.92 + 0.12 * max(0, facing[y, x][1]))
            else:
                old[y][x] = body(p, at, facing[y, x])


def paint_second(pixels, where, facing, old):
    for y in range(ru.SIZE):
        for x in range(ru.SIZE):
            at = where[y, x]
            if np.isnan(at[0]):
                continue
            p = pixels[y][x]
            if ru.inside(x, y, ru.TAIL):
                u = (TAIL_ROOT - at[0]) / (TAIL_ROOT - TAIL_END)
                u += 0.07 * math.sin(at[1] * 11) + (ru.luma(p) - 170) / 1200
                old[y][x] = hair(gradient(TAIL_COLORS, u), p, 1)
            else:
                old[y][x] = body(p, at, facing[y, x])


def bleed(where, painted, skip):
    """Spreads the paint a few texels past each mapped edge, so old colors can't show along seams."""
    known = ~np.isnan(where[..., 0])
    for _ in range(BLEED):
        grown = known.copy()
        for y in range(ru.SIZE):
            for x in range(ru.SIZE):
                if known[y, x] or skip(x, y):
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < ru.SIZE and 0 <= ny < ru.SIZE and known[ny, nx]:
                        painted[y][x] = painted[ny][nx]
                        grown[y, x] = True
                        break
        known = grown


def paint_eye(pixels):
    cx, cy = EYE
    rx, ry = EYE_RADIUS
    for y in range(cy - ry, cy + ry + 1):
        for x in range(cx - rx, cx + rx + 1):
            d = ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2
            if d > 1:
                continue
            iris = ((x - cx) / (rx * 0.66)) ** 2 + ((y - cy) / (ry * 0.84)) ** 2
            pupil = ((x - cx) / (rx * 0.34)) ** 2 + ((y - cy) / (ry * 0.44)) ** 2
            shine = ((x - cx + 4) / 3.2) ** 2 + ((y - cy + 3) / 3.2) ** 2
            if d > 0.8:
                color = (45, 20, 60)
            elif shine < 1:
                color = (255, 255, 255)
            elif pupil < 1:
                color = (20, 15, 45)
            elif iris < 1:
                color = (90, 70 + (y - cy) * 5, 245)
            else:
                color = (255, 250, 250)
            pixels[y][x] = color


def blur(values, radius):
    out = values.astype(float)
    for axis in (0, 1):
        total = np.zeros_like(out)
        for step in range(-radius, radius + 1):
            total += np.roll(out, step, axis)
        out = total / (2 * radius + 1)
    return out


def strands(across, along):
    """Thin streaks that change quickly across the hair and slowly along it."""
    return (0.5 * np.sin(across * 41 + 3 * np.sin(along * 5))
            + 0.3 * np.sin(across * 83 + 2 * np.sin(along * 3 + 1))
            + 0.2 * np.sin(across * 137 + along * 2))


def add_hair(painted, source, where, hair_outline, index):
    """Brings out the original painted fur, and lays strands along the way the hair runs."""
    colors = np.array(painted, dtype=float)
    luma = (np.array(source, dtype=float) * (0.30, 0.59, 0.11)).sum(-1)
    detail = np.clip(luma - blur(luma, DETAIL_RADIUS), -40, 40) / 40
    known = ~np.isnan(where[..., 0])
    x, y, z = [np.nan_to_num(where[..., axis]) for axis in range(3)]
    hair = np.zeros(known.shape, dtype=bool)
    for row in range(ru.SIZE):
        for column in range(ru.SIZE):
            hair[row, column] = known[row, column] and ru.inside(column, row, hair_outline)

    fur = strands(y + 0.6 * z, x)
    if index == 0:
        flow = strands(x + 0.8 * z, y)      # the mane falls down the neck
    else:
        flow = strands(y + 0.8 * z, x)      # the tail runs along its length
    factor = np.ones(known.shape)
    body = known & ~hair
    factor[body] = 1 + FUR_DETAIL * detail[body] + FUR_STRANDS * fur[body]
    factor[hair] = 1 + HAIR_DETAIL * detail[hair] + HAIR_STRANDS * flow[hair]
    colors = np.clip(colors * factor[..., None], 0, 255)
    return [[tuple(int(c) for c in pixel) for pixel in row] for row in colors]


def paint_horn(painted, source, data, bones):
    """The horn's own piece, by how far along its real length each texel sits."""
    chunk = next((o, s) for k, o, s in ru.chunks(data) if k == 0x2A and data[o:o + 4] == b'hh_t')
    triangles = read_mesh(bytes(data[chunk[0] + 16:chunk[0] + chunk[1]]), bones)
    where = position_maps(triangles)[0][1]
    known = ~np.isnan(where[..., 0])
    points = where[known]
    base = points[np.argmin(points[:, 1])]
    tip = points[np.argmax(((points - base) ** 2).sum(1))]
    axis = tip - base
    along = np.nan_to_num(1 - ((where - base) @ axis) / (axis @ axis))     # 1 at the base, 0 at the tip
    for _ in range(HORN_BLEED):
        grown = known.copy()
        for shift in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            fresh = np.roll(known, shift, (0, 1)) & ~grown
            along[fresh] = np.roll(along, shift, (0, 1))[fresh]
            grown |= fresh
        known = grown
    luma = (np.array(source, dtype=float) * (0.30, 0.59, 0.11)).sum(-1)
    soft = blur(luma, 2)
    for row, column in zip(*np.nonzero(known)):
        light = 0.82 + soft[row, column] / 700
        color = gradient(ru.HORN_COLORS, along[row, column])
        # the horn's base runs into the head and fights it for the same pixels, so it takes the head's color
        color = mix(color, PINK, (along[row, column] - HORN_SKIN_FROM) / (1 - HORN_SKIN_FROM))
        painted[row][column] = ru.shade(color, light)
    return painted


def smooth(edge0, edge1, x):
    t = min(1.0, max(0.0, (x - edge0) / (edge1 - edge0)))
    return t * t * (3 - 2 * t)


def horn_points(data, bones):
    """The horn's vertices on the model, with height up. Its bone ids index the mesh's own bone table."""
    offset = next(o for k, o, _ in ru.chunks(data) if k == 0x2A and data[o:o + 4] == b'hh_t')
    c = data[offset + 16:]
    head = struct.unpack_from('<23H', c, 0)
    table = struct.unpack_from('<%dH' % head[8], c, head[6] * 2)
    one = struct.unpack_from('<H', c, head[9] * 2)[0]
    points = []
    for i in range(one):
        pair = struct.unpack_from('<H', c, head[12] * 2 + i * 4)[0]
        rotation, move = bones[table[pair & 0x7f]]
        point = np.array(struct.unpack_from('<3f', c, head[15] * 2 + i * 24)) @ rotation + move
        points.append(point * (1, -1, 1))
    return np.array(points)


def hide_horn_copy(data, bones):
    """The body has its own copy of the horn's surface in the same place, which flickers against the horn.
    Those triangles get all three corners on one vertex, so they draw nothing and no vertex moves."""
    horn = horn_points(data, bones)
    body = next(o for k, o, _ in ru.chunks(data) if k == 0x2A and data[o:o + 4] == b'hh_b')
    c = data[body + 16:]
    head = struct.unpack_from('<23H', c, 0)
    points = [p for triangle in read_mesh(c, bones) for p in triangle[0]]
    copy = [np.min(((horn - p) ** 2).sum(1)) < HORN_SAME ** 2 for p in points]
    at, end, number, hidden = head[3] * 2, (head[3] + head[5]) * 2, 0, 0
    while at + 2 <= end:
        op = struct.unpack_from('<H', c, at)[0]
        if op == 0x8010:
            at += 46
        elif op == 0x8000:
            at += 18
        elif op == 0x0054:
            count = struct.unpack_from('<H', c, at + 2)[0]
            at += 4
            for _ in range(count):
                if all(copy[number * 3:number * 3 + 3]):
                    first = struct.unpack_from('<H', c, at)[0]
                    struct.pack_into('<3H', data, body + 16 + at, first, first, first)
                    hidden += 1
                at += 30
                number += 1
        elif op == 0x5453:
            count = struct.unpack_from('<H', c, at + 2)[0]
            at += 34 + 10 * (count - 1)
            number += count
        else:
            break
    return hidden


def reshape_with(tail):
    """How the Alicorn changes, with height up: the tail slides back whole, keeping its shape."""
    turn = np.radians(TAIL_TILT)
    cos, sin = np.cos(turn), np.sin(turn)

    def reshape(p):
        x, y, z = p
        legs = (y < LEGS_TOP and x > LEGS_BACK) or y < FEET_TOP
        if legs or x > TAIL_BEHIND or np.min(((tail - p) ** 2).sum(1)) > TAIL_NEAR ** 2:
            return np.array((x, y, z))
        out_x, out_y = x - TAIL_ROOT_AT[0], y - TAIL_ROOT_AT[1]
        if out_x < 0:
            out_x *= TAIL_FULL           # the part behind the root swells out, for a rounder curve
        tilted_x, tilted_y = out_x * cos - out_y * sin, out_x * sin + out_y * cos
        # all of the tail moves as one, so its curve keeps the original shape; only the root stays on the rump
        amount = smooth(ROOT_HOLD, ROOT_FREE, np.hypot(out_x, out_y))
        new_x = TAIL_ROOT_AT[0] + tilted_x - TAIL_SHIFT
        new_y = TAIL_ROOT_AT[1] + tilted_y
        return np.array((x + (new_x - x) * amount, y + (new_y - y) * amount, z))

    return reshape


def main(mod=None):
    mod = mod or MOD
    with open(os.path.join(ru.GAME, ru.SOURCE), 'rb') as f:
        data = bytearray(f.read())
    with open(os.path.join(ru.MOD, ru.TARGETS[1]), 'rb') as f:
        current = f.read()
    bones = next(skeleton(data[offset + 16:offset + size]) for kind, offset, size in ru.chunks(data) if kind == 0x29)
    where, facing = position_maps(body_triangles(data, bones))

    starts = [offset + ru.TEXTURE_HEADER for kind, offset, _ in ru.chunks(data) if kind == 0x20]
    area = ru.SIZE * ru.SIZE
    for index, start in enumerate(starts):
        blocks = bytes(data[start:start + area])
        source = ru.decode(blocks)
        painted = ru.decode(current[start:start + area])    # the outline paint keeps the unmapped texels
        if index == 0:
            paint_first(source, where[0], facing[0], painted)
            bleed(where[0], painted, lambda x, y: False)
            painted = add_hair(painted, source, where[0], ru.MANE, 0)
            paint_eye(painted)
        else:
            paint_second(source, where[1], facing[1], painted)
            bleed(where[1], painted, lambda x, y: ru.inside(x, y, ru.HORN))
            painted = add_hair(painted, source, where[1], ru.TAIL, 1)
            painted = paint_horn(painted, source, data, bones)
        data[start:start + area] = ru.encode(painted, blocks)
        if len(sys.argv) > 1:
            ru.save_png(os.path.join(sys.argv[1], 'deluxe%d.png' % index), ru.decode(data[start:start + area]))

    body = next(o for k, o, _ in ru.chunks(data) if k == 0x2A and data[o:o + 4] == b'hh_b')
    rows, columns = np.nonzero(~np.isnan(where[1][..., 0]))
    tail = np.array([where[1][r, c] for r, c in zip(rows, columns) if ru.inside(c, r, ru.TAIL)])
    rr.deform(data, body, bones, reshape_with(tail))
    print('Hid %d triangles that copy the horn' % hide_horn_copy(data, bones))

    for target in ru.TARGETS:
        path = os.path.join(mod, target)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, 'wb') as f:
            f.write(data)
    with open(os.path.join(mod, 'transmog.json'), 'w') as f:
        json.dump({'title': 'Raptor as Deluxe Unicorn', 'category': 'mount', 'look': 'Deluxe Unicorn'}, f)
    print('Wrote', mod)
    if mod == MOD:      # a test build elsewhere leaves the swaps alone
        ru.refresh_swaps(data, 'Deluxe Unicorn', MOD)


if __name__ == '__main__':
    main()
