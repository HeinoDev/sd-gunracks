"""zones.py -- every slot's interaction box, written into data/racks.json (slots[i].zone).

    python tools/props/zones.py          (build.py also runs it before it writes racks.json)

ox_target (and qb-target) show a zone's options when the player's aim ray ENDS inside the zone. A stored gun has no
collision, and the space a slot's gun stands in is open air, so the ray goes through the gun and ends on whatever is
behind it: the rack's rest, its back board, the wall, the floor. A small sphere where the gun sits is therefore only
reachable with the camera in the slot. Each slot gets a box instead that covers its whole column: from in front of the
gun back through whatever the ray will land on, from below the gun to above it, as wide as the slot is from its
neighbours (so two slots never share a point, and one prompt shows at a time).

A zone is { c = [x, y, z], s = [sx, sy, sz], yaw } in the rack's space: the box's centre, its size along its own axes,
and its turn about Z (the slot's yaw: the box's axes are the slot frame's).
"""
import json
import math
import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
RESOURCE = os.path.dirname(os.path.dirname(HERE))
RACKS = os.path.join(RESOURCE, 'data', 'racks.json')


def rz(deg):
    a = math.radians(deg)
    return np.array([[math.cos(a), -math.sin(a), 0], [math.sin(a), math.cos(a), 0], [0, 0, 1.0]])


def to_slot(s, p):
    """A rack-space point in slot s's frame."""
    return rz(-s['yaw']) @ (np.array(p) - np.array(s['pos']))


def half_gap(rack, s, axis, same_level=None, default=0.10, cap=0.10):
    """Half the distance to the nearest other slot along this slot's own `axis` (0 = x, 2 = z), counting only slots
    roughly level with it on the other axis (same_level metres), less 2 mm."""
    best = None
    for o in rack['slots']:
        if o is s:
            continue
        d = to_slot(s, o['pos'])
        other = 2 if axis == 0 else 0
        if same_level is not None and abs(d[other]) > same_level:
            continue
        if abs(d[axis]) < 1e-4:
            continue
        g = abs(d[axis])
        best = g if best is None else min(best, g)
    return min(cap, (best / 2 - 0.002) if best is not None else default)


def zone_for(rack, s, kind):
    t = kind['type']
    fb = kind.get('fallback', {})
    two_sided = any(abs(((o['yaw'] - s['yaw']) + 180) % 360 - 180) > 90 for o in rack['slots'])
    if t == 'upright':
        hw = half_gap(rack, s, 0, same_level=0.3, cap=0.09)
        front = -fb.get('notch_len', 0.19) / 2 - 0.22
        if two_sided:
            back = fb.get('rest_y', 0.15) + 0.015                       # up to the spine, not into the other side
        elif rack.get('corner'):
            back = math.hypot(s['pos'][0], s['pos'][1]) - 0.06          # up to the corner post
        elif rack['mount'] == 'wall':
            back = -s['pos'][1] + 0.04                                  # into the wall a little
        else:
            back = fb.get('rest_y', 0.15) + 0.70                        # the floor (and a wall) behind the rack
        z0, z1 = -s['pos'][2] - 0.03, 1.30
        lo, hi = [-hw, front, z0], [hw, back, z1]
    elif t == 'horizontal':
        hooks = fb.get('hooks', [-0.21, 0.21])
        reach = (hooks[1] - hooks[0]) / 2 + 0.36
        dn = half_gap(rack, s, 2, same_level=0.6, default=0.17, cap=0.17)
        lo, hi = [-reach, -0.22, -dn], [reach, 0.04, dn]
    elif t == 'peg':
        hw = half_gap(rack, s, 0, same_level=0.08, cap=0.09)
        lo, hi = [-hw, -0.32, -0.16], [hw, 0.04, 0.10]
    elif t == 'flat':
        hw = half_gap(rack, s, 0, same_level=0.08, cap=0.20)
        dn = half_gap(rack, s, 2, same_level=0.08, default=0.11, cap=0.11)
        lo, hi = [-hw, -0.10, -dn], [hw, 0.04, dn]
    elif t == 'post':
        hw = half_gap(rack, s, 0, same_level=0.05, cap=0.05)
        lo, hi = [-hw, -0.20, -0.04], [hw, 0.12, 0.42]
    else:
        return None
    lo, hi = np.array(lo), np.array(hi)
    c_slot = (lo + hi) / 2
    c = np.array(s['pos']) + rz(s['yaw']) @ c_slot
    r = lambda v: [round(float(x), 4) + 0.0 for x in v]  # noqa: E731
    return {'c': r(c), 's': r(hi - lo), 'yaw': round(float(s['yaw']), 2)}


def add(data):
    """Give every slot of every rack in a racks.json dict its zone (in place)."""
    for rack in data['racks'].values():
        for s in rack['slots']:
            z = zone_for(rack, s, rack['kinds'][s['kind']])
            if z:
                s['zone'] = z
    return data


def main():
    import jsonfmt
    data = json.load(open(RACKS, encoding='utf-8'))
    add(data)
    jsonfmt.write(RACKS, data)
    for name, rack in data['racks'].items():
        s = rack['slots'][0]
        print(f"{name:22s} slot 1 zone size {s['zone']['s']}")


if __name__ == '__main__':
    main()
