"""Decode verified PlayerPartsList records; never infer IDs from filenames."""
from dataclasses import dataclass
import json
from .appearance_project import PARTS, _logical_path, _digest


@dataclass(frozen=True)
class NativePart:
    part: str
    native_id: int
    prefab: str
    catalog: str
    catalog_sha256: str


def related_body_templates(body_id, quality, records, rules):
    """Resolve observed fixed IDs only; missing IDs never become default parts."""
    matches=[rule for rule in rules if rule['BodyID']==body_id]
    if len(matches)>1:raise ValueError('Duplicate native body rule')
    if not matches:return None,()
    rule=matches[0]
    related=[]
    for part,field in (('HAIR','FixHairID'),('GAUNTLET','FixGauntletID'),('BOW','FixBowID')):
        candidates=[i for i,row in enumerate(records) if row['part']==part
                    and row['native_id']==rule[field] and row['variant']==quality]
        # Multiple catalogs with distinct prefabs are ambiguous, even if their
        # filenames look similar. Preserve candidates for author selection.
        related.append({'part':part,'nativeId':rule[field],'templates':tuple(candidates)})
    return rule,tuple(related)


def read_parts_catalog(report, part, catalog):
    """Follow the root DataList references, excluding orphan RSZ instances.

    report is the appearance-rsz inspect result. Caller supplies the verified
    catalog's part role (normal/HQ and episode remain separate catalogs).
    """
    if part not in {p for group in PARTS.values() for p in group}:
        raise ValueError("Unknown player part")
    catalog = _logical_path(catalog)
    if not catalog.lower().endswith('.user'):
        raise ValueError("Expected logical Catalog USER path")
    if report.get('SchemaVersion') != 1 or report.get('Operation') != 'inspect':
        raise ValueError("Expected an inspection report")
    digest = _digest(report['SourceSha256'])
    instances = {}
    for item in report['Instances']:
        index = item['Index']
        if type(index) is not int or index < 0 or index in instances:
            raise ValueError("Invalid or duplicate instance index")
        instances[index] = item
    roots = [item for item in instances.values() if item['Type'] == 'app.user_data.PlayerPartsList']
    if len(roots) != 1:
        raise ValueError("Expected one PlayerPartsList root")

    def fields(item):
        result = {}
        for field in item['Fields']:
            if field['Name'] in result:
                raise ValueError("Duplicate RSZ field")
            result[field['Name']] = field['Value']
        return result

    def reference(value, expected):
        if not isinstance(value, dict) or set(value) != {'Reference'} or type(value['Reference']) is not int:
            raise ValueError("Invalid object reference")
        item = instances.get(value['Reference'])
        if item is None or item['Type'] != expected:
            raise ValueError("Missing or wrong-type catalog reference")
        return item

    rows = fields(roots[0])['_DataList']
    if not isinstance(rows, list):
        raise ValueError("Invalid catalog DataList")
    result, ids = [], set()
    for row in rows:
        values = fields(reference(row, 'app.user_data.PlayerPartsList.cData'))
        number = values['_ID']
        if not isinstance(number, dict) or number.get('Type') != 'System.Int32':
            raise ValueError("Expected signed native ID")
        identity = json.loads(number['Data'])
        if type(identity) is not int or not -(2**31) <= identity < 2**31 or identity in ids:
            raise ValueError("Invalid or duplicate native ID")
        ids.add(identity)
        prefab = fields(reference(values['_PartsPrefab'], 'via.Prefab'))['Path']
        prefab = _logical_path(prefab)
        if not prefab.lower().endswith('.pfb') or '@' in prefab:
            raise ValueError("Invalid prefab path")
        result.append(NativePart(part, identity, prefab, catalog, digest))
    return tuple(result)
