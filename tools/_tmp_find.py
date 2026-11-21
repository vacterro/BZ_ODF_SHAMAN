import json, pathlib
p = pathlib.Path(r'V:\___VAC\__K\__CODE\_MISC\_BZ_ODF_SHAMAN\data\odf_schema.json')
d = json.loads(p.read_text(encoding='utf-8'))
hits = []
for cls, info in d.get('classes', {}).items():
    for name, prop in info.get('properties', {}).items():
        desc = str(prop.get('description', ''))
        if 'not odf inherited' in desc.lower() or 'not inherited' in desc.lower():
            hits.append((cls, name, desc[:180]))
for cls, name, desc in hits:
    print(f'{cls}|{name}|{desc}')
print('TOTAL', len(hits))
sr = d.get('classes', {}).get('OrdnanceClass', {}).get('properties', {}).get('shotRadius')
print('SR', json.dumps(sr))
