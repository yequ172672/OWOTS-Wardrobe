"""Content-based registration planning; source files and native targets stay intact.

Only stock PFB wrappers may collapse normal/HQ contexts. Their complete opaque
field payload and object/type tables must match an original template first.
Custom wrappers use a stricter fingerprint, retaining every non-path field.
"""
from dataclasses import dataclass, field
from pathlib import PurePosixPath
import hashlib
import json
import re
import struct

import rsz_paths
from mod_converter import ConversionError


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=True).encode()).hexdigest()


def prefab_signature(data, resolve):
    """Read PFB18 tables, excluding only serialization offsets and path strings.

    This representation is for comparison only, never for writing a resource.
    Opaque RSZ fields, CRCs, object ordering and reference indices remain exact.
    """
    spans = rsz_paths.inventory(data)
    magic, objects, resources, refs, users, rt, pt, ut, rsz = struct.unpack_from('<IiiiQQQQQ', data)
    if magic != 0x424650:
        raise ValueError('Expected PFB18')
    signature, version, ro, ri, ru, reserved, io, do, uo = struct.unpack_from('<6I3Q', data, rsz)
    by_offset = {span.offset: span for span in spans}
    def reference(offset):
        if offset in by_offset:
            return resolve(by_offset[offset].path)
        if data[offset:offset+2] == b'\0\0':
            return ''
        raise ValueError('Unrecognized table string')
    # Include nonzero bytes outside the recognized tables/strings as well.
    # Alignment padding alone may change when a copied path is longer.
    regions = [(0, 56), (56, 56+objects*12), (rt, rt+refs*16),
               (pt, pt+resources*8), (ut, ut+users*16), (rsz, rsz+48),
               (rsz+48, rsz+48+ro*4), (rsz+io, rsz+io+ri*8),
               (rsz+uo, rsz+uo+ru*16), (rsz+do, len(data))]
    regions.extend((s.offset, s.offset+len(s.path.encode('utf-16le'))+2)
                   for s in spans if s.kind != 'inline-path')
    cursor, unknown = 0, []
    for begin, end in sorted((a, b) for a, b in regions if b > a):
        if begin > cursor and any(data[cursor:begin]):
            gap = data[cursor:begin]
            try:
                strings = gap.decode('utf-16le').split('\0')
                orphan_paths = all(not value or rsz_paths.TABLE_PATH.fullmatch(value) for value in strings)
            except UnicodeDecodeError:
                orphan_paths = False
            # Editors can leave the old, now unreferenced string in the table
            # pool after moving a pointer. No field can address this pool except
            # the already inventoried tables; opaque non-string gaps stay exact.
            if not orphan_paths:
                unknown.append(gap.hex())
        cursor = max(cursor, end)
    chunks = []
    start = rsz + do
    for span in (s for s in spans if s.kind == 'inline-path'):
        end = span.offset + len(span.path.encode('utf-16le')) + 2
        padded = (end + 3) & ~3
        if padded <= len(data) and not any(data[end:padded]):
            end = padded
        chunks.extend((data[start:span.offset-4].hex(), resolve(span.path)))
        start = end
    chunks.append(data[start:].hex())
    return digest([
        objects, refs, resources, users,
        data[56:56+objects*12].hex(), data[rt:rt+refs*16].hex(),
        [reference(struct.unpack_from('<Q', data, pt+i*8)[0]) for i in range(resources)],
        [(data[ut+i*16:ut+i*16+8].hex(), reference(struct.unpack_from('<Q', data, ut+i*16+8)[0])) for i in range(users)],
        signature, version, ro, ri, ru, reserved,
        data[rsz+48:rsz+48+ro*4].hex(), data[rsz+io:rsz+io+ri*8].hex(),
        [(data[rsz+uo+i*16:rsz+uo+i*16+8].hex(), reference(rsz+struct.unpack_from('<Q', data, rsz+uo+i*16+8)[0])) for i in range(ru)],
        chunks, unknown,
    ])


def shape(data):
    return prefab_signature(data, lambda path: PurePosixPath(path).suffix.casefold())


def render_bindings(data, spans):
    """Resource slots follow table pointers, not string-pool storage order."""
    count = struct.unpack_from('<i', data, 8)[0]
    table = struct.unpack_from('<Q', data, 32)[0]
    by_offset = {s.offset: s for s in spans}
    result = []
    for index in range(count):
        offset = struct.unpack_from('<Q', data, table+index*8)[0]
        if offset in by_offset:
            s = by_offset[offset]
            result.append(rsz_paths.Span(s.offset, s.path, 'resource'))
        elif data[offset:offset+2] != b'\0\0':
            raise ValueError('Unknown resource slot')
    result.extend(s for s in spans if s.kind == 'inline-path')
    return result


@dataclass
class AppearancePlan:
    group: list
    covered_targets: list[dict] = field(default_factory=list)
    duplicate_assets: set[str] = field(default_factory=set)
    fingerprint: str = ''
    merge_evidence: list[dict] = field(default_factory=list)

    def entry(self, category):
        return {'category': category, 'targets': [c.record for c in self.group],
                'coveredTargets': self.covered_targets}


class AppearanceFingerprints:
    def __init__(self, source, game, records, dependencies, check_cancel, hidden_assets, hidden_mesh=lambda key: False):
        self.source, self.game = source, game
        self.dependencies, self.check_cancel = dependencies, check_cancel
        self.hidden_assets = hidden_assets
        self.hidden_mesh = hidden_mesh
        self.cache, self.file_cache = {}, {}
        self.templates = {}
        originals = {}
        for record in records:
            self.check_cancel()
            try:
                asset = game.find(record['prefab'])
                if asset:
                    payload = asset.path.read_bytes()
                    originals[record['prefab'].casefold()] = (shape(payload), payload)
            except (ValueError, OSError, struct.error, ConversionError):
                continue
        for record in records:
            key = record['prefab'].casefold()
            if key not in originals:
                continue
            own_shape, payload = originals[key]
            normal_key = key[:-7] + '.pfb' if key.endswith('_hq.pfb') else key
            normal_shape = originals.get(normal_key, (own_shape,))[0]
            self.templates.setdefault((record['part'], own_shape), []).append((normal_shape, payload))

    def file_token(self, asset):
        key = str(asset.path)
        if key not in self.file_cache:
            checksum = hashlib.sha256()
            with asset.path.open('rb') as stream:
                while block := stream.read(1024*1024):
                    self.check_cancel()
                    checksum.update(block)
            self.file_cache[key] = (asset.extension, asset.version, checksum.hexdigest())
        return self.file_cache[key]

    def asset(self, logical, active=frozenset()):
        key = logical.lstrip('@').casefold()
        if key in active:
            raise ValueError('Cyclic comparison graph')
        if key in self.cache:
            return self.cache[key]
        self.check_cancel()
        base, stream = self.source.get(key), self.source.get(key, True)
        extension = PurePosixPath(key).suffix
        # Unmodified leaves keep their exact stock identity. Never assume that
        # two stock meshes are equal because they share a modified texture.
        if base is None and stream is None and extension not in ('.mdf2', '.user', '.pfb', '.mmi', '.mpi'):
            return ('original', key)
        original = base is None
        base = base or self.game.find(key)
        if base is None:
            raise ValueError('Missing comparison resource: ' + key)
        active = active | {key}
        if extension == '.mdf2':
            from owots_vendor.workspace.appearance_mdf import parse_mdf, _semantic
            material = parse_mdf(base.path.read_bytes())
            for item in material.materialList:
                for texture in item.textureList:
                    if texture.texturePath:
                        texture.texturePath = digest(self.asset(texture.texturePath, active))
            token = (extension, base.version, digest(_semantic(material)))
        elif extension == '.pfb':
            token = (extension, base.version, prefab_signature(base.path.read_bytes(), lambda p: self.asset(p, active)))
        elif extension in ('.user', '.mmi', '.mpi'):
            # Exact wrapper bytes plus effective descendants. Unknown userdata
            # layouts cannot erase a material/texture override downstream.
            token = (self.file_token(base), tuple((p.casefold(), self.asset(p, active))
                     for p in self.dependencies(key, self.source)))
        else:
            # A MOD base never inherits a stock streaming tail (publisher rule).
            token = (self.file_token(base), self.file_token(stream) if stream else
                     ('original-stream', key) if original else None)
        self.cache[key] = token
        return token

    def candidate(self, candidate):
        logical = candidate.record['prefab'].casefold()
        asset = self.source.get(logical) or self.game.find(logical)
        if asset is None:
            raise ValueError('Missing prefab')
        payload = asset.path.read_bytes()
        spans = rsz_paths.inventory(payload)
        templates = self.templates.get((candidate.record['part'], shape(payload)), [])

        def users(data):
            result = []
            for span in rsz_paths.inventory(data):
                if span.kind != 'userdata':
                    continue
                key = span.path.lstrip('@').casefold()
                # Stock gameplay skill rows vary with the replaced native ID;
                # they do not define the wardrobe appearance. Authored rows stay.
                if '/equipskilldata/' not in key or self.source.get(key) is not None:
                    result.append(key)
            return result

        matches = {normal for normal, template in templates if users(template) == users(payload)}
        if len(matches) != 1:
            return ('custom-prefab', self.asset(logical))
        # Stock normal/HQ wrappers differ in context-only userdata. Preserve
        # resource slot order, duplicated bindings, effective materials and all
        # authored descendants. Only geometry-proven hidden part assets vanish.
        ignored = set(self.hidden_assets)
        render_spans = render_bindings(payload, spans)
        for kind in ('resource', 'inline-path'):
            refs = [s.path.lstrip('@').casefold() for s in render_spans if s.kind == kind]
            pairs = [(a, b) for a, b in zip(refs, refs[1:]) if a.endswith('.mesh') and b.endswith('.mdf2')]
            visible_materials = {mdf for mesh, mdf in pairs if not self.hidden_mesh(mesh)}
            for mesh, mdf in pairs:
                if mdf not in visible_materials and self.hidden_mesh(mesh):
                    ignored.update((mesh, mdf))
        bindings = [(s.kind, self.asset(s.path)) for s in render_spans
                    if s.kind in ('resource', 'inline-path')
                    and PurePosixPath(s.path).suffix.casefold() != '.user'
                    and s.path.lstrip('@').casefold() not in ignored]
        edits = sorted({digest(self.asset(key)) for key in candidate.changed
                        if key != logical and key not in ignored})
        return ('stock-context', next(iter(matches)), bindings, edits)

    def unchanged_context(self, group):
        """Same authored override of a stock target's normal/AC/HQ contexts.

        A stock event material alone is not another authored outfit. This rule
        never crosses native families or discards an additional authored file.
        Any authored PFB requires the full content comparison instead.
        """
        values = []
        for candidate in group:
            if self.source.get(candidate.record['prefab']):
                return None
            stem = PurePosixPath(candidate.record['prefab']).stem.casefold()
            stem = re.sub(r'_ac$', '', re.sub(r'_hq$', '', stem))
            values.append((candidate.record['part'], stem, sorted(candidate.changed)))
        return values


def deduplicate_groups(groups, fingerprints, hidden, body_rules, category_for, companions):
    """Collapse accessories first, then bodies with the same resulting equip rules."""
    def category(plan):
        return category_for[plan.group[0].record['part']]

    plans = [AppearancePlan(group, [t for c in group for t in c.covered_targets]) for group in groups]
    plans.sort(key=lambda p: (p.group[0].record['variant'] != 'normal',
                             '_ac' in p.group[0].record['prefab'].casefold(),
                             '/_dlc/' in p.group[0].record['prefab'].casefold(),
                             p.group[0].record['prefab'].casefold()))
    base = {}
    for plan in plans:
        try:
            base[id(plan)] = [(c.record['part'], fingerprints.candidate(c)) for c in plan.group]
        except (ValueError, OSError, struct.error, ConversionError) as error:
            if getattr(error, 'code', None) == 'CANCELLED':
                raise
            # Comparison uncertainty preserves the entry; conversion still
            # performs its ordinary independent validation.
            base[id(plan)] = ('unproven', [c.record for c in plan.group])

    retained = []
    for body_phase in (False, True):
        by_signature = {}
        by_context = {}
        for plan in plans:
            if (category(plan) == 'body') != body_phase:
                continue
            parts = {c.record['part'] for c in plan.group}
            hides, equipment = set(), {}
            if 'BODY' in parts:
                hides = {part for variant, part in hidden if variant == plan.group[0].record['variant']}
                body_id = next(c.record['native_id'] for c in plan.group if c.record['part'] == 'BODY')
                rule = next((r for r in body_rules if r['BodyID'] == body_id), {})
                if rule.get('IsVisibleCloak') is False: hides.add('CLOAK')
                if rule.get('IsInvisibleHead') is True: hides.add('HEAD')
                hides -= parts
                for accessory in ('cloak', 'gauntlet'):
                    options = companions(plan.entry('body'), [p.entry(category(p)) for p in retained], accessory)
                    equipment[accessory] = sorted(digest(o) for o in options)
                    if len(options) == 1:
                        hides = {p for p in hides if category_for[p] != accessory}
            signature = digest((category(plan), base[id(plan)], sorted(hides), equipment))
            plan.fingerprint = signature
            owner = by_signature.get(signature)
            method = 'same-appearance-content'
            context = None if base[id(plan)][0] == 'unproven' else fingerprints.unchanged_context(plan.group)
            context_key = digest(([(p, stem) for p, stem, _ in context], sorted(hides), equipment)) if context is not None else None
            if owner is None and context_key in by_context:
                for previous, previous_context in by_context[context_key]:
                    if all(set(current[2]) <= set(old[2]) for current, old in zip(context, previous_context)):
                        owner = previous
                        method = 'same-authored-override-stock-contexts'
                        break
            if owner:
                targets = [c.record for c in plan.group] + plan.covered_targets
                owner.covered_targets.extend(targets)
                owner.merge_evidence.append({'method': method, 'targets': targets})
                owner.duplicate_assets.update(set().union(*(c.changed for c in plan.group)))
                owner.duplicate_assets.update(plan.duplicate_assets)
            else:
                retained.append(plan)
            by_signature[signature] = owner or plan
            if context_key is not None:
                by_context.setdefault(context_key, []).append((owner or plan, context))
    return sorted(retained, key=lambda p: plans.index(p))
