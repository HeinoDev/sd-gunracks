"""jsonfmt.py -- data/racks.json written the one way: indented, but number lists kept on one line."""
import json
import re


def compact(obj):
    text = json.dumps(obj, indent=1)
    return re.sub(r'\[\s+(-?[0-9.e-]+(?:,\s+-?[0-9.e-]+)*)\s+\]',
                  lambda m: '[' + ', '.join(v.strip() for v in m.group(1).split(',')) + ']', text)


def write(path, obj):
    with open(path, 'w', newline='\n', encoding='utf-8') as f:
        f.write(compact(obj) + '\n')
