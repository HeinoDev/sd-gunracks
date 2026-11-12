"""metas.py -- every firearm in GTA V, from the game's own weapon metas.

    python tools/props/weapons/metas.py <folder of extracted metas>

The metas are extracted from the game's archives with CodeWalker: weapons*.meta / weapon_*.meta (CWeaponInfo),
weaponarchetypes.meta and weaponcomponents.meta. Writes
tools/props/cache/weapons.json:

    { WEAPON_X = { model, group, pack, components = [{ name, model, bone, attach }] } }

`components` are the DEFAULT ones only (what CreateWeaponObject puts on a bare gun: its magazine, a sniper's scope):
the rack's fits are made against the gun as the game draws it. `bone` is where the component goes on the gun
(WAPClip, WAPScop ...), `attach` the component model's own bone that goes onto it (AAPClip ...).

A later file overrides an earlier one (common.rpf, then update.rpf, then the DLC packs): files are read sorted so that
holds. Only firearms are kept (the groups in GROUPS): no melee, throwables, launchers or vehicle weapons.
"""
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / 'cache' / 'weapons.json'

GROUPS = {'GROUP_PISTOL', 'GROUP_STUNGUN', 'GROUP_SMG', 'GROUP_RIFLE', 'GROUP_MG', 'GROUP_SHOTGUN', 'GROUP_SNIPER'}


def rank(name):
    """Read order: base game, then the update, then DLC packs (a patch of a pack after the pack)."""
    if name.startswith('common.rpf'):
        return (0, name)
    if name.startswith('update_update.rpf_common'):
        return (1, name)
    return (2, name)


def pack_of(name):
    m = re.search(r'dlcpacks_([a-z0-9_]+?)_dlc\.rpf', name) or re.search(r'dlc_patch_([a-z0-9_]+?)_common', name)
    return m.group(1) if m else 'base'


def text(node, tag):
    el = node.find(tag)
    return el.text.strip() if el is not None and el.text else None


def parse(folder):
    files = sorted((p for p in Path(folder).iterdir() if p.suffix == '.meta'), key=lambda p: rank(p.name))
    comps, weapons = {}, {}
    for p in files:
        try:
            root = ET.fromstring(p.read_bytes())
        except ET.ParseError as err:
            print(f'skip {p.name}: {err}')
            continue
        for item in root.iter('Item'):
            kind = item.get('type') or ''
            name = text(item, 'Name')
            if not name:
                continue
            if kind.startswith('CWeaponComponent') and name.startswith('COMPONENT_'):
                comps[name] = dict(model=(text(item, 'Model') or '').lower(), attach=text(item, 'AttachBone'))
            elif kind == 'CWeaponInfo' and name.startswith('WEAPON_'):
                group = text(item, 'Group')
                model = (text(item, 'Model') or '').lower()
                if group not in GROUPS or not model:
                    continue
                defaults = []
                aps = item.find('AttachPoints')
                for ap in (aps if aps is not None else []):
                    bone = text(ap, 'AttachBone')
                    for c in ap.iter('Item'):
                        d = c.find('Default')
                        if d is not None and d.get('value') == 'true':
                            defaults.append(dict(name=text(c, 'Name'), bone=bone))
                weapons[name] = dict(model=model, group=group, pack=pack_of(p.name), components=defaults)
    for w in weapons.values():
        for c in w['components']:
            info = comps.get(c['name'], {})
            c['model'] = info.get('model') or None
            c['attach'] = info.get('attach')
        w['components'] = [c for c in w['components'] if c['model']]
    return weapons


def main():
    weapons = parse(sys.argv[1])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(dict(sorted(weapons.items())), indent=1), encoding='utf-8')
    by = {}
    for w in weapons.values():
        by[w['group']] = by.get(w['group'], 0) + 1
    print(f'{len(weapons)} firearms -> {OUT}  {by}')


if __name__ == '__main__':
    main()
