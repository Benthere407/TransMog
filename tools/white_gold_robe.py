"""Builds the gear-white-gold-robe mod: Royal Redingote in slate and gold, with Royal Cloak's hood and new
pauldrons, over Vanya Slops and Clogs, for Elvaan male only.

Run it with no arguments. It reads ffxi-hd's DATs, never changes them, and writes the mod's files to
DATs\\TransMog. Pass a folder to also save the textures there as PNGs.

A file id is the race's first id for that slot plus the model, from the table at FFXiMain+0x35D380.
"""
import json
import math
import os
import struct
import sys

import numpy as np
from PIL import Image

DATS = r'C:\catseyexi\catseyexi-client\Ashita\polplugins\DATs'
SOURCE = os.path.join(DATS, 'ffxi-hd')
GAME = r'C:\catseyexi\catseyexi-client\Game\FINAL FANTASY XI'
MOD = os.path.join(DATS, 'TransMog', 'gear-white-gold-robe')
REDINGOTE = r'ROM\221\52.DAT' # file 13958, body model 238
CLOAK = r'ROM\93\79.DAT'     # file 13767, body model 47, for its hood
SKELETON = r'ROM\37\31.DAT'  # file 13424
SLOPS = r'ROM\329\103.DAT'  # file 75162
CLOGS = r'ROM\329\110.DAT'  # file 75418

# The robe goes on model 443, which no item uses and which has its own three files, so the pieces it was built
# from stay as they are. Most models no item uses all share one placeholder file, so they won't do.
ROBE_MODEL = 443
ROBE_FILES = {REDINGOTE: r'ROM\383\34.DAT', SLOPS: r'ROM\383\36.DAT', CLOGS: r'ROM\383\37.DAT'}
ELVAAN_MALE = 3
LOOKS = [{'slot': 'body', 'model': ROBE_MODEL, 'race': ELVAAN_MALE, 'name': 'White and gold robe', 'icon': 11315,
          'hides': ['head']},    # the hood covers the head slot: a worn hat would poke through
         {'slot': 'legs', 'model': ROBE_MODEL, 'race': ELVAAN_MALE, 'name': 'White and gold robe (legs)', 'icon': 27288},
         {'slot': 'feet', 'model': ROBE_MODEL, 'race': ELVAAN_MALE, 'name': 'White and gold robe (feet)', 'icon': 27463}]

TEXTURE_HEADER = 16 + 69    # chunk header, then the texture's own, up to the DXT3 blocks

SLATE = np.array([84, 98, 120])
SLATE_DARK = np.array([40, 48, 62])
WHITE = np.array([238, 238, 242])
GOLD = np.array([232, 188, 92])

# the palette of each texture: what red, near-black, grey and green parts become
HOOD = {'red': SLATE, 'dark': SLATE_DARK, 'grey': SLATE, 'green': GOLD, 'floor': 0.75}
PANTS = {'red': SLATE, 'dark': SLATE_DARK, 'grey': SLATE, 'green': GOLD}
PAINTS = {b'em_m84_6': HOOD, b'em_lem24': PANTS, b'em_fom14': PANTS}
COAT_TEXTURE = b'elm_01  '

# pauldrons are a mesh of their own, on the upper arm bone: 59 draws one side, its mirror 45 the other.
# In that bone's space +x runs down the arm and the origin is the shoulder joint.
ARM_BONES = (59, 45)
MIRROR_Z = 3                # flag on a vertex: the mirror side negates z
TEXTURE_NAME = b'tim     em_p0000'
MESH_HEADER = 64            # bytes, up to the draw list
MATERIAL = 46               # bytes of the draw list's material block
BATCH = 128                 # triangles in one list
SEGMENTS = 18
# (x, radius) down the bell from its top to its rim, with a step at each overlapping plate
BELL = [(-0.110, 0.010), (-0.104, 0.050), (-0.085, 0.078), (-0.050, 0.094), (-0.015, 0.100), (-0.013, 0.112),
        (0.025, 0.118), (0.027, 0.128), (0.060, 0.132), (0.068, 0.140)]
PLATE_LIGHT = np.array([158, 176, 198])

# wings stand behind the shoulders on the collarbone, so they stay upright as the arms swing. They are built in the
# body's bind pose, where -y is up, +x is the front and z runs across the body, then moved into the bone's space.
WING_BONES = (57, 43)
WING_PLATES = 7
WING_BASE = (-0.095, -1.60, 0.285)     # x, y, z of the middle of the wing's foot
WING_RISE = (-0.075, -0.56, 0.055)     # how far its tip is from there
WING_WIDTH = 0.095                     # half its width, front to back
WING_FLARE = 0.016                     # how far each plate's foot stands out over the plate below

def chunks(data):
    offset = 0
    while offset + 16 <= len(data):
        value = struct.unpack_from('<I', data, offset + 4)[0]
        size = (value >> 7 & 0x7ffff) * 16
        if size < 16:
            break
        yield value & 0x7f, offset, size
        offset += size


def from_565(c):
    return np.stack([(c >> 11 & 31) * 255 // 31, (c >> 5 & 63) * 255 // 63, (c & 31) * 255 // 31], -1)


def to_565(c):
    c = np.clip(c, 0, 255).astype(np.uint32)
    return (c[..., 0] * 31 // 255) << 11 | (c[..., 1] * 63 // 255) << 5 | c[..., 2] * 31 // 255


def block_palettes(c0, c1):
    a, b = from_565(c0).astype(np.int32), from_565(c1).astype(np.int32)
    return np.stack([a, b, (2 * a + b) // 3, (a + 2 * b) // 3], 1)


def decode(blocks, width, height):
    data = np.frombuffer(blocks, dtype=np.uint8).reshape(-1, 16)
    ends = data[:, 8:12].copy().view(np.uint16).reshape(-1, 2).astype(np.int32)
    bits = data[:, 12:16].copy().view(np.uint32).reshape(-1)
    palettes = block_palettes(ends[:, 0], ends[:, 1])
    picks = np.stack([bits >> (2 * i) & 3 for i in range(16)], 1).astype(np.int32)
    texels = palettes[np.arange(len(data))[:, None], picks].reshape(-1, 4, 4, 3)
    rows = texels.reshape(height // 4, width // 4, 4, 4, 3).transpose(0, 2, 1, 3, 4)
    return rows.reshape(height, width, 3)


def encode(pixels, blocks):
    """Refits each block's colors along its widest axis and keeps its alpha."""
    height, width = pixels.shape[:2]
    texels = pixels.reshape(height // 4, 4, width // 4, 4, 3).transpose(0, 2, 1, 3, 4).reshape(-1, 16, 3).astype(float)
    centers = texels.mean(1, keepdims=True)
    spread = texels - centers
    axes = np.array([np.linalg.svd(block, full_matrices=False)[2][0] for block in spread])
    along = (spread * axes[:, None]).sum(2)
    low, high = along.min(1), along.max(1)
    c0 = to_565(centers[:, 0] + axes * high[:, None])
    c1 = to_565(centers[:, 0] + axes * low[:, None])
    palettes = block_palettes(c0, c1).astype(float)
    distances = ((texels[:, :, None] - palettes[:, None]) ** 2).sum(3)
    picks = distances.argmin(2).astype(np.uint32)
    bits = np.zeros(len(texels), dtype=np.uint32)
    for i in range(16):
        bits |= picks[:, i] << (2 * i)
    out = np.frombuffer(blocks, dtype=np.uint8).reshape(-1, 16).copy()
    out[:, 8:10] = c0.astype(np.uint16)[:, None].view(np.uint8).reshape(-1, 2)
    out[:, 10:12] = c1.astype(np.uint16)[:, None].view(np.uint8).reshape(-1, 2)
    out[:, 12:16] = bits[:, None].view(np.uint8).reshape(-1, 4)
    return out.tobytes()


def repaint(pixels, paint):
    rgb = pixels.astype(float)
    top, bottom = rgb.max(2), rgb.min(2)
    chroma = top - bottom
    saturation = chroma / np.maximum(top, 1)
    light = rgb @ np.array([0.30, 0.59, 0.11])
    red, green, blue = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    hue = np.degrees(np.arctan2(np.sqrt(3) * (green - blue), 2 * red - green - blue)) % 360

    is_grey = saturation < 0.16
    is_green = (hue > 70) & (hue < 200) & ~is_grey
    is_gold = (hue >= 27) & (hue <= 70) & (saturation > 0.35) & (top > 120)
    is_dark = top < 62
    is_red = ~is_grey & ~is_green & ~is_gold & ~is_dark

    def tint(color, base, gain, floor=0.55):
        return color * np.clip(floor + (light[..., None] - base) * gain, 0.3, 1.5)

    out = np.array(pixels, dtype=float)
    out[is_grey] = tint(paint['grey'], 150, 0.006)[is_grey]
    out[is_dark] = tint(paint['dark'], 20, 0.012)[is_dark]
    out[is_red] = tint(paint['red'], 60, 0.007, paint.get('floor', 0.55))[is_red]
    out[is_green] = tint(paint['green'], 70, 0.008)[is_green]
    out[is_gold] = tint(GOLD, 120, 0.006)[is_gold]
    return np.clip(out, 0, 255).astype(np.int32)


def coat(pixels):
    """Redingote's cream, purple and wine go slate by brightness alone, and its brown and gold trim goes gold."""
    rgb = pixels.astype(float)
    top, bottom = rgb.max(2), rgb.min(2)
    saturation = (top - bottom) / np.maximum(top, 1)
    light = rgb @ np.array([0.30, 0.59, 0.11])
    red, green, blue = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    hue = np.degrees(np.arctan2(np.sqrt(3) * (green - blue), 2 * red - green - blue)) % 360
    trim = (hue >= 15) & (hue <= 60) & ((saturation > 0.5) & (top > 45) | (saturation > 0.27) & (light > 45) & (light < 115))
    cloth = SLATE * np.clip(0.75 + (light[..., None] - 150) * 0.0035, 0.3, 1.15)
    gold = GOLD * np.clip(0.6 + (light[..., None] - 70) * 0.008, 0.45, 1.15)
    return np.clip(np.where(trim[..., None], gold, cloth), 0, 255).astype(np.int32)


def metal():
    """The top half is blue-grey plate with gold at each step, the bottom half a gold wing plate."""
    v = np.linspace(0, 1, 256)[:, None]
    u = np.linspace(0, 1, 256)[None, :]
    bands = (v * 2 * (len(BELL) - 1)) % 1
    plate = PLATE_LIGHT * (0.92 + 0.10 * np.cos(u * math.pi * 6))[..., None] * np.ones((256, 256, 1))
    plate = np.where((bands > 0.62)[..., None], GOLD * (0.85 + 0.35 * (bands - 0.62))[..., None], plate)
    across = np.abs(u - 0.5) * 2
    down = (v - 0.5) * 2
    wing = GOLD * (1.12 - 0.40 * down - 0.22 * across ** 2)[..., None]
    wing = np.where((across < 0.05)[..., None], GOLD * 0.6, wing)
    wing = np.where((down > 0.86)[..., None], GOLD * 0.42, wing)
    return np.clip(np.where(v[..., None] < 0.5, plate, wing), 0, 255).astype(np.int32)


def lathe():
    """The bell turned around x: its vertices (position, normal) and triangles (three corners of index, u, v)."""
    verts, tris = [], []
    rows = len(BELL)
    for row, (x, radius) in enumerate(BELL):
        before = BELL[max(row - 1, 0)]
        after = BELL[min(row + 1, rows - 1)]
        slope = math.atan2(after[1] - before[1], after[0] - before[0])
        for seg in range(SEGMENTS):
            angle = seg * 2 * math.pi / SEGMENTS
            ny, nz = math.cos(angle), math.sin(angle)
            verts.append((x, radius * ny, radius * nz, -math.sin(slope), math.cos(slope) * ny, math.cos(slope) * nz))
    for row in range(rows - 1):
        for seg in range(SEGMENTS):
            a, b = row * SEGMENTS + seg, row * SEGMENTS + (seg + 1) % SEGMENTS
            c, d = a + SEGMENTS, b + SEGMENTS
            u0, u1 = seg / SEGMENTS, (seg + 1) / SEGMENTS
            v0, v1 = row / (rows - 1) / 2, (row + 1) / (rows - 1) / 2
            tris.append(((a, u0, v0), (c, u0, v1), (b, u1, v0)))
            tris.append(((b, u1, v0), (c, u0, v1), (d, u1, v1)))
    return verts, tris


def inverse_bones():
    """The inverse of each bone's bind pose. A point p in the body is p @ matrix in that bone's space."""
    with open(os.path.join(GAME, SKELETON), 'rb') as f:
        data = f.read()
    offset = next(o for kind, o, _ in chunks(data) if kind == 0x29) + 16
    world = []
    for index in range(struct.unpack_from('<H', data, offset + 2)[0]):
        parent, _, x, y, z, w, *move = struct.unpack_from('<bb7f', data, offset + 4 + index * 30)
        matrix = np.array([[1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0],
                           [2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0],
                           [2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0],
                           [*move, 1]])
        world.append(matrix if index == 0 else matrix @ world[parent])
    return [np.linalg.inv(m) for m in world]


def wing():
    """Overlapping plates climbing to a point, each a quad on both faces, in the collarbone's space."""
    to_bone = inverse_bones()[WING_BONES[0]]
    verts, tris = [], []
    base, rise = np.array(WING_BASE), np.array(WING_RISE)

    def corner(t, edge, flare):
        half = WING_WIDTH * min(1, 0.55 + 2.0 * t) * (1 - t ** 4)
        middle = base + rise * t + np.array([0, 0, 0.05 * math.sin(math.pi * t) + flare])
        return middle + np.array([edge * half, 0, 0])

    def add(a, b, c, d, facing):
        """A quad of feet a, b and heads c, d. Facing is the side of z it looks to."""
        normal = np.array([0, 0, facing, 0.0]) @ to_bone
        first = len(verts)
        for point in (a, b, c, d):
            moved = np.array([*point, 1]) @ to_bone
            verts.append((*moved[:3], *normal[:3]))
        corners = ((first, 0, 1), (first + 1, 1, 1), (first + 2, 0, 0.5)), ((first + 1, 1, 1), (first + 3, 1, 0.5), (first + 2, 0, 0.5))
        for tri in corners:
            pa, pb, pc = (np.array((a, b, c, d)[i - first]) for i, _, _ in tri)
            clockwise = np.dot(np.cross(pb - pa, pc - pa), (0, 0, facing)) <= 0
            tris.append(tri if clockwise else tri[::-1])

    for plate in range(WING_PLATES):
        foot, head = plate / WING_PLATES, (plate + 1.35) / WING_PLATES
        head = min(head, 0.995)
        a, b = corner(foot, -1, WING_FLARE), corner(foot, 1, WING_FLARE)
        c, d = corner(head, -1, 0), corner(head, 1, 0)
        add(a, b, c, d, 1)
        add(a, b, c, d, -1)
    return verts, tris


def chunk_bytes(name, kind, body):
    body += bytes(-(16 + len(body)) % 16)
    size = 16 + len(body)
    return name + struct.pack('<I', kind | (size // 16) << 7) + bytes(8) + body


def mesh_chunk(name, template, texture, table, verts, tris, pairs_of_vertices):
    """A mesh of all one-bone or all two-bone vertices, with its header and material copied from a small mesh."""
    draw = bytearray(template[MESH_HEADER:MESH_HEADER + MATERIAL])
    draw += struct.pack('<H', 0x8000) + texture
    for start in range(0, len(tris), BATCH):
        batch = tris[start:start + BATCH]
        draw += struct.pack('<HH', 0x54, len(batch))
        for (a, ua, va), (b, ub, vb), (c, uc, vc) in batch:
            draw += struct.pack('<3H6f', a, b, c, ua, va, ub, vb, uc, vc)
    draw += struct.pack('<H', 0xffff)
    draw += bytes(len(draw) % 2)

    words = MESH_HEADER // 2
    bones = words + len(draw) // 2
    counts = bones + len(table)
    pairs = counts + 2
    positions = pairs + 2 * len(verts)
    vertex_words = 2 * len(verts[0])
    end = positions + vertex_words * len(verts)
    header = bytearray(template[:MESH_HEADER])
    for index, value in ((5, len(draw) // 2), (6, bones), (8, len(table)), (9, counts), (12, pairs),
                         (14, 2 * len(verts)), (15, positions), (17, vertex_words * len(verts)), (18, end), (23, end)):
        struct.pack_into('<H', header, index * 2, value)

    split = (len(verts), 0) if vertex_words == 12 else (0, len(verts))
    body = bytes(header) + bytes(draw) + struct.pack(f'<{len(table)}H', *table) + struct.pack('<2H', *split)
    body += b''.join(struct.pack('<HH', *pair) for pair in pairs_of_vertices)
    return chunk_bytes(name, 0x2a, body + b''.join(struct.pack(f'<{len(v)}f', *v) for v in verts))


def texture_chunk(name, pixels):
    """The legs' 256x256 texture chunk, which has the same header a new one needs, with pixels in it."""
    with open(os.path.join(SOURCE, SLOPS), 'rb') as f:
        source = f.read()
    offset, size = next((o, s) for kind, o, s in chunks(source) if kind == 0x20)
    chunk = bytearray(source[offset:offset + size])
    chunk[:4] = name[8:12]
    chunk[17:33] = name
    blocks = (bytes([255]) * 8 + bytes(8)) * (256 * 256 // 16)
    chunk[TEXTURE_HEADER:TEXTURE_HEADER + 256 * 256] = encode(pixels, blocks)
    return bytes(chunk)


def part(data, name):
    """A chunk of a DAT by its four letter name."""
    offset, size = next((o, size) for _, o, size in chunks(data) if data[o:o + 4] == name)
    return bytes(data[offset:offset + size])


def add_parts(robe, cloak):
    """Royal Cloak's hood and the new pauldrons added to the coat, each keeping its own texture."""
    meshes = [(o, s) for kind, o, s in chunks(robe) if kind == 0x2a]
    after = sum(meshes[-1])
    template = part(cloak, b'hh_1')[16:]
    textures = part(cloak, b'em_m') + texture_chunk(TEXTURE_NAME, metal())
    verts, tris = lathe()
    new = part(cloak, b'hh_m') + mesh_chunk(b'hh_p', template, TEXTURE_NAME, ARM_BONES, verts, tris,
                                            [(0 | 1 << 7 | MIRROR_Z << 14, 0)] * len(verts))
    verts, tris = wing()
    new += mesh_chunk(b'hh_w', template, TEXTURE_NAME, WING_BONES, verts, tris,
                      [(0 | 1 << 7 | MIRROR_Z << 14, 0)] * len(verts))
    return robe[:meshes[0][0]] + textures + robe[meshes[0][0]:after] + new + robe[after:]


def painted(path, png_folder):
    with open(os.path.join(SOURCE, path), 'rb') as f:
        data = bytearray(f.read())
    for kind, offset, _ in chunks(data):
        if kind != 0x20:
            continue
        width, height = struct.unpack_from('<II', data, offset + 16 + 21)
        name = bytes(data[offset + 16 + 9:offset + 16 + 17])
        if name != COAT_TEXTURE and name not in PAINTS:
            continue
        start, size = offset + TEXTURE_HEADER, width * height
        blocks = bytes(data[start:start + size])
        pixels = decode(blocks, width, height)
        data[start:start + size] = encode(coat(pixels) if name == COAT_TEXTURE else repaint(pixels, PAINTS[name]), blocks)
        if png_folder:
            image = decode(bytes(data[start:start + size]), width, height).astype(np.uint8)
            Image.fromarray(image).save(os.path.join(png_folder, name.decode().strip() + '.png'))
    return data


def write(path, data):
    target = os.path.join(MOD, ROBE_FILES[path])
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, 'wb') as f:
        f.write(data)


def main():
    folder = sys.argv[1] if len(sys.argv) > 1 else None
    write(REDINGOTE, add_parts(painted(REDINGOTE, folder), painted(CLOAK, folder)))
    write(SLOPS, painted(SLOPS, folder))
    write(CLOGS, painted(CLOGS, folder))
    with open(os.path.join(MOD, 'transmog.json'), 'w') as f:
        json.dump({'title': 'White and gold robe (Elvaan male)', 'category': 'gear', 'looks': LOOKS}, f)
    print('Wrote', MOD)


if __name__ == '__main__':
    main()
