"""Puts the recolored HD textures on XimTool's robe DAT and writes it into the mod as the robe's body.

Run it with the path of the DAT XimTool wrote. XimTool works from the game's own textures, so the coat and hood
are swapped for white_gold_robe.py's slate and gold HD ones here. A texture chunk stands alone, so its size can change.
"""
import os
import sys

import white_gold_robe as robe


def main():
    with open(sys.argv[1], 'rb') as f:
        data = f.read()
    replacements = {b'tim     elm_01  ': robe.part(robe.painted(robe.REDINGOTE, None), b'elm_'),
                    b'tim     em_m84_6': robe.part(robe.painted(robe.CLOAK, None), b'em_m')}
    out = bytearray()
    done = set()
    for kind, offset, size in robe.chunks(data):
        name = data[offset + 17:offset + 33]
        if kind == 0x20 and name in replacements:
            out += replacements[name]
            done.add(name)
        else:
            out += data[offset:offset + size]
    assert done == set(replacements), done
    robe.write(robe.REDINGOTE, out)
    print('Wrote', len(out), 'bytes,', [(bytes(out[o:o + 4]), hex(k)) for k, o, _ in robe.chunks(out) if k in (0x20, 0x2a)])


if __name__ == '__main__':
    main()
