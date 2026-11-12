"""fitcheck.py -- runs the resource's own shared/fit.lua (stock Lua 5.4, a few stubs) against data/racks.json and
compares it with Python:

  1. measured fits: fit.place must give exactly the slot frame times the racks.json row (same offset, same rotation);
  2. the addon-gun fallback: every vanilla gun is placed AGAIN as if it were an addon (no fit row, only its bounding
     box), and the distance between where the fallback puts the gun's bounding-box corners and where the measured fit
     puts them is reported per kind of slot (median and worst, in cm). That is how wrong an addon gun can look.

    python tools/props/fitcheck.py
"""
import json
import math
import os
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'weapons'))
import fits  # noqa: E402
import guns  # noqa: E402

RESOURCE = os.path.dirname(os.path.dirname(HERE))
TMP = os.path.join(HERE, 'cache', 'fitcheck')


def lua_literal(v):
    if isinstance(v, dict):
        return '{' + ','.join(f'[{json.dumps(k)}]={lua_literal(x)}' for k, x in v.items()) + '}'
    if isinstance(v, list):
        return '{' + ','.join(lua_literal(x) for x in v) + '}'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if v is None:
        return 'nil'
    if isinstance(v, str):
        return json.dumps(v)
    return repr(float(v)) if isinstance(v, float) else str(v)


DRIVER = r'''
package.path = RES .. '/?.lua;' .. RES .. '/?/init.lua;' .. package.path
vector3 = function(x, y, z) return { x = x, y = y, z = z } end
lib = { loadJson = function() return { racks = dofile(TMP .. '/racks.lua') } end }
package.loaded['configs.config'] = { Weapons = { Extra = EXTRA, Blacklist = {} } }
local fit = dofile(RES .. '/shared/fit.lua')
local out = {}
for _, q in ipairs(dofile(TMP .. '/queries.lua')) do
    local o, r = fit.place(q.model, q.slot, q.weapon, q.lo and vector3(q.lo[1], q.lo[2], q.lo[3]),
        q.hi and vector3(q.hi[1], q.hi[2], q.hi[3]))
    if o then
        out[#out + 1] = string.format('%s %d %s %.6f %.6f %.6f %.6f %.6f %.6f', q.model, q.slot, q.weapon, o.x, o.y, o.z, r.x, r.y, r.z)
    else
        out[#out + 1] = string.format('%s %d %s nil', q.model, q.slot, q.weapon)
    end
end
io.write(table.concat(out, '\n'))
'''


def matrix(pos, rot):
    R = fits.matrix_yxz(*rot)
    M = np.eye(4)
    M[:3, :3] = R
    M[:3, 3] = pos
    return M


def main():
    os.makedirs(TMP, exist_ok=True)
    racks = json.load(open(os.path.join(RESOURCE, 'data', 'racks.json'), encoding='utf-8'))['racks']
    with open(os.path.join(TMP, 'racks.lua'), 'w', encoding='utf-8') as f:
        f.write('return ' + lua_literal(racks))
    table = guns.table()
    queries, expect = [], []
    for model, rack in racks.items():
        for i, s in enumerate(rack['slots'], 1):
            for w, row in rack['fits'].get(s['kind'], {}).items():
                g = guns.load(w)
                lo, hi = g.bbox()
                queries.append(dict(model=model, slot=i, weapon=w))                       # measured
                queries.append(dict(model=model, slot=i, weapon='ADDON_' + w, lo=list(lo), hi=list(hi)))
                yaw = math.radians(s['yaw'])
                Rs = np.array([[math.cos(yaw), -math.sin(yaw), 0], [math.sin(yaw), math.cos(yaw), 0], [0, 0, 1]])
                pos = np.array(s['pos']) + Rs @ np.array(row[:3])
                expect.append((model, i, w, pos, (row[3], row[4], row[5] + s['yaw']), lo, hi, s['kind']))
            break                          # one slot of each rack is enough for the comparison (all slots alike)
    extra = {'ADDON_' + w: table[w]['group'] for w in table}
    with open(os.path.join(TMP, 'queries.lua'), 'w', encoding='utf-8') as f:
        f.write('return ' + lua_literal(queries))
    drv = f'RES = {json.dumps(RESOURCE.replace(os.sep, "/"))}\nTMP = {json.dumps(TMP.replace(os.sep, "/"))}\n' \
          f'EXTRA = {lua_literal(extra)}\n' + DRIVER
    with open(os.path.join(TMP, 'driver.lua'), 'w', encoding='utf-8') as f:
        f.write(drv)
    res = subprocess.run(['lua', os.path.join(TMP, 'driver.lua')], capture_output=True, text=True)
    if res.returncode:
        print(res.stderr)
        sys.exit(1)
    lines = res.stdout.split('\n')
    got = {}
    for ln in lines:
        p = ln.split()
        if len(p) < 4 or p[3] == 'nil':
            got[(p[0], int(p[1]), p[2])] = None
            continue
        got[(p[0], int(p[1]), p[2])] = (np.array([float(x) for x in p[3:6]]), tuple(float(x) for x in p[6:9]))
    bad, errs = 0, {}
    for model, i, w, pos, rot, lo, hi, kind in expect:
        m = got.get((model, i, w))
        corners = np.array([[x, y, z, 1] for x in (lo[0], hi[0]) for y in (lo[1], hi[1]) for z in (lo[2], hi[2])])
        want = (matrix(pos, rot) @ corners.T).T[:, :3]
        if m is None:
            bad += 1
            continue
        have = (matrix(m[0], m[1]) @ corners.T).T[:, :3]
        if np.abs(have - want).max() > 1e-4:
            bad += 1
            print('MISMATCH', model, i, w, np.abs(have - want).max())
        f = got.get((model, i, 'ADDON_' + w))
        if f is None:
            errs.setdefault((model, kind), []).append(float('nan'))
            continue
        fb = (matrix(f[0], f[1]) @ corners.T).T[:, :3]
        errs.setdefault((model, kind), []).append(float(np.linalg.norm(fb - want, axis=1).max()))
    print(f'measured fits: {len(expect) - bad}/{len(expect)} placed exactly as Python')
    for (model, kind), e in errs.items():
        e = np.array(e)
        print(f'  fallback {model:22s} {kind:7s} median {np.nanmedian(e) * 100:5.1f} cm  worst {np.nanmax(e) * 100:5.1f} cm  '
              f'({np.isnan(e).sum()} unplaced)')


if __name__ == '__main__':
    main()
