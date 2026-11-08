"""Run inside Blender: blender --background --python robe_blender.py -- <coat.gltf> <hood.gltf> <parts folder> <out.gltf>

Takes XimTool's export of the coat, adds the hood mesh from XimTool's export of Royal Cloak and the pieces from
robe_parts.py, saves a .blend beside the output to open by hand, and writes the glTF XimTool imports.
"""
import json
import os
import sys

import bpy

GROUP = 'joint-%d'
EXTRAS = {'occludeType': '0', 'displayType': '0', 'ambientMultiplier': '1.0000', 'specularPower': '0.0000',
          'referenceOnly': 'false'}


def blender_point(co):
    """Game space to Blender's, the same turn the glTF importer makes."""
    return co[0], -co[2], co[1]


def armature():
    return next(o for o in bpy.context.scene.objects if o.type == 'ARMATURE')


def material(name, image_path):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    node = mat.node_tree.nodes.new('ShaderNodeTexImage')
    node.image = bpy.data.images.load(image_path)
    shader = mat.node_tree.nodes['Principled BSDF']
    mat.node_tree.links.new(node.outputs['Color'], shader.inputs['Base Color'])
    return mat


def add_piece(data, mat, rig):
    mesh = bpy.data.meshes.new(data['name'])
    corners = [[corner[0] for corner in face] for face in data['faces']]
    mesh.from_pydata([blender_point(v['co']) for v in data['verts']], [], corners)
    uv = mesh.uv_layers.new(name='UVMap')
    index = 0
    for face in data['faces']:
        for corner in face:
            uv.data[index].uv = (corner[1], 1 - corner[2])
            index += 1
    mesh.materials.append(mat)
    mesh.update()
    obj = bpy.data.objects.new(data['name'], mesh)
    bpy.context.scene.collection.objects.link(obj)
    obj.parent = rig
    obj.modifiers.new('Armature', 'ARMATURE').object = rig
    for i, v in enumerate(data['verts']):
        for joint, weight in v['joints']:
            if weight > 0:
                name = GROUP % joint
                group = obj.vertex_groups.get(name) or obj.vertex_groups.new(name=name)
                group.add([i], weight, 'REPLACE')
    obj['datId'] = data['name']
    obj['textureName'] = mat.name
    for key, value in EXTRAS.items():
        obj[key] = value
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.shade_smooth()
    obj.select_set(False)
    return obj


def fit_to_coat(obj, coat, offset):
    """Lays a piece on the coat's surface and gives each vertex the weights of the coat beneath it."""
    to_coat = coat.matrix_world.inverted() @ obj.matrix_world
    from_coat = to_coat.inverted()
    names = {group.index: group.name for group in coat.vertex_groups}
    for vertex in obj.data.vertices:
        hit, location, normal, face = coat.closest_point_on_mesh(to_coat @ vertex.co)
        weights = {}
        for index in coat.data.polygons[face].vertices:
            for entry in coat.data.vertices[index].groups:
                name = names[entry.group]
                weights[name] = weights.get(name, 0) + entry.weight
        vertex.co = from_coat @ (location + normal * offset)
        top = sorted(weights.items(), key=lambda item: -item[1])[:2]
        total = sum(weight for _, weight in top)
        for group in obj.vertex_groups:
            group.remove([vertex.index])
        for name, weight in top:
            group = obj.vertex_groups.get(name) or obj.vertex_groups.new(name=name)
            group.add([vertex.index], weight / total, 'REPLACE')
    obj.data.update()


def add_hood(path, rig):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = set(bpy.data.objects) - before
    for obj in new:
        if obj.type == 'MESH' and obj.get('datId') == 'hh_m':
            obj.parent = rig
            obj.matrix_parent_inverse.identity()
            for modifier in obj.modifiers:
                if modifier.type == 'ARMATURE':
                    modifier.object = rig
    for obj in new:
        if not (obj.type == 'MESH' and obj.get('datId') == 'hh_m'):
            bpy.data.objects.remove(obj, do_unlink=True)


def coat_mesh():
    return next(o for o in bpy.context.scene.objects if o.type == 'MESH' and o.get('datId') == 'hh_1')


def main():
    coat, hood, parts, out = sys.argv[sys.argv.index('--') + 1:]
    bpy.ops.object.select_all(action='SELECT')
    bpy.ops.object.delete()
    bpy.ops.import_scene.gltf(filepath=coat)
    rig = armature()
    add_hood(hood, rig)
    with open(os.path.join(parts, 'parts.json')) as f:
        pieces = json.load(f)
    materials = {}
    for data in pieces:
        name = data['texture']
        if name not in materials:
            materials[name] = material(name, os.path.join(parts, name + '.png'))
        obj = add_piece(data, materials[name], rig)
        if 'fit' in data:
            fit_to_coat(obj, coat_mesh(), data['fit'])
    bpy.ops.wm.save_as_mainfile(filepath=out.replace('.gltf', '.blend'))
    bpy.ops.export_scene.gltf(filepath=out, export_extras=True, export_format='GLTF_SEPARATE', export_animations=False,
                              export_influence_nb=2)


if __name__ == '__main__':
    main()
