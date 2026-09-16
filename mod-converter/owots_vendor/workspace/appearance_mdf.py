"""OWOTS MDF texture reference remapping using the existing format reader/writer."""
import ctypes
import io
import json
from .appearance_project import _logical_path
from ..mdf.file_re_mdf import MDFFile


def parse_mdf(payload):
    file=MDFFile()
    file.fileVersion=51
    file.read(io.BytesIO(payload),51)
    if not file.isOnimushaVariant:
        raise ValueError('Expected OWOTS MDF 51 layout')
    return file


def texture_dependencies(payload):
    file=parse_mdf(payload)
    paths={}
    for material in file.materialList:
        for texture in material.textureList:
            if texture.texturePath:
                path=_logical_path(texture.texturePath)
                paths.setdefault(path.casefold(),path)
    return tuple(paths[key] for key in sorted(paths))


def texture_bindings(payload):
    """Identify bindings by material and slot, never incidental list ordering."""
    result={}
    for material in parse_mdf(payload).materialList:
        for texture in material.textureList:
            key=(material.materialName,texture.textureType)
            if key in result:
                raise ValueError('Ambiguous duplicate MDF material/texture slot')
            result[key]=_logical_path(texture.texturePath) if texture.texturePath else ''
    return result


def _semantic(value):
    if isinstance(value,(str,int,float,bool,type(None))):
        return value
    if isinstance(value,(ctypes.Union,ctypes.Structure)):
        return bytes(value).hex()
    if isinstance(value,(list,tuple)):
        return [_semantic(item) for item in value]
    # These are serialization offsets, never authored values. Keep unknown
    # flags, material uints, properties, buffer names/data and shader paths.
    return {key:_semantic(item) for key,item in vars(value).items()
            if not key.lower().endswith('offset') and key not in ('offsetList','stringList','sizeData')}


def rewrite_textures(payload, remap):
    file=parse_mdf(payload)
    mapping={}
    for source,target in remap.items():
        source=_logical_path(source)
        target=_logical_path(target)
        if not source.lower().endswith('.tex') or not target.lower().endswith('.tex') or '@' in source+target:
            raise ValueError('MDF remapping accepts logical texture paths only')
        if source.casefold() in mapping:
            raise ValueError('Duplicate texture remap source')
        mapping[source.casefold()]=target
    seen=set()
    for material in file.materialList:
        for texture in material.textureList:
            key=texture.texturePath.casefold()
            if key in mapping:
                texture.texturePath=mapping[key]
                seen.add(key)
    if seen != set(mapping):
        raise ValueError('MDF remap source was not found')
    expected=json.dumps(_semantic(file),sort_keys=True)
    output=io.BytesIO()
    file.write(output,51)
    payload=output.getvalue()
    if json.dumps(_semantic(parse_mdf(payload)),sort_keys=True) != expected:
        raise ValueError('MDF readback changed material semantics')
    return payload
