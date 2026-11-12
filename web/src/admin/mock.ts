import { registerMockNui } from '@/nui/bridge';
import type {
  AdminOpenPayload,
  Catalog,
  LogRow,
  Mount,
  Overview,
  PlayerRow,
  RackAccess,
  RackRow,
  RackSlot,
  StoredGun,
  WeaponHit,
} from '@/types';

/**
 * The console against made-up state, for the dev server (/?admin). The rack models are the resource's
 * own (data/racks.json, configs/shared/racks.lua); who owns what, the guns on them and the action log
 * are invented here.
 */

const NOW = Math.floor(Date.now() / 1000);
const MIN = 60;
const HOUR = 3600;
const DAY = 86400;

const post = (action: string, data: unknown) => window.postMessage({ action, data }, '*');

/** The ten racks, as data/racks.json describes them. */
const MODELS: { model: string; item: string; label: string; mount: Mount; kinds: [string, string, number][] }[] = [
  { model: 'sd_gunrack_oak', item: 'gunrack_oak', label: 'Oak Floor Rack', mount: 'floor', kinds: [['long', 'Long gun', 8]] },
  { model: 'sd_gunrack_panel', item: 'gunrack_panel', label: 'Steel Wall Panel', mount: 'wall', kinds: [['long', 'Long gun', 3]] },
  { model: 'sd_gunrack_walnut', item: 'gunrack_walnut', label: 'Walnut Wall Rack', mount: 'wall', kinds: [['long', 'Long gun', 6]] },
  { model: 'sd_gunrack_pegboard', item: 'gunrack_pegboard', label: 'Tactical Pegboard', mount: 'wall', kinds: [['long', 'Long gun', 2], ['pistol', 'Handgun', 6]] },
  { model: 'sd_gunrack_pistols', item: 'gunrack_pistols', label: 'Pistol Display Board', mount: 'wall', kinds: [['pistol', 'Handgun', 8]] },
  { model: 'sd_gunrack_armory', item: 'gunrack_armory', label: 'Armory A-Frame', mount: 'floor', kinds: [['long', 'Long gun', 12]] },
  { model: 'sd_gunrack_corner', item: 'gunrack_corner', label: 'Cherry Corner Rack', mount: 'floor', kinds: [['long', 'Long gun', 5]] },
  { model: 'sd_gunrack_stand', item: 'gunrack_stand', label: 'Pistol Stand', mount: 'surface', kinds: [['pistol', 'Handgun', 5]] },
  { model: 'sd_gunrack_pipe', item: 'gunrack_pipe', label: 'Industrial Pipe Rack', mount: 'wall', kinds: [['long', 'Long gun', 4]] },
  { model: 'sd_gunrack_heritage', item: 'gunrack_heritage', label: 'Heritage Display', mount: 'wall', kinds: [['long', 'Long gun', 1]] },
];

const CATALOG: Catalog = {
  models: MODELS.map(m => ({
    model: m.model,
    item: m.item,
    label: m.label,
    mount: m.mount,
    slots: m.kinds.reduce((sum, k) => sum + k[2], 0),
    kinds: m.kinds.map(([, label, count]) => ({ label, count })),
  })),
  maxGive: 10,
};

const LONG: [string, string, string[]][] = [
  ['WEAPON_CARBINERIFLE', 'Carbine Rifle', ['Flashlight', 'Medium Scope']],
  ['WEAPON_PUMPSHOTGUN', 'Pump Shotgun', ['Flashlight']],
  ['WEAPON_ASSAULTRIFLE', 'Assault Rifle', []],
  ['WEAPON_SNIPERRIFLE', 'Sniper Rifle', ['Large Scope']],
  ['WEAPON_SMG', 'SMG', ['Suppressor', 'Extended Clip']],
  ['WEAPON_MUSKET', 'Musket', []],
];
const SHORT: [string, string, string[]][] = [
  ['WEAPON_PISTOL', 'Pistol', ['Flashlight']],
  ['WEAPON_COMBATPISTOL', 'Combat Pistol', []],
  ['WEAPON_HEAVYPISTOL', 'Heavy Pistol', ['Suppressor']],
  ['WEAPON_REVOLVER', 'Heavy Revolver', []],
];

interface MockPlayer {
  src?: number;
  name: string;
  username: string;
  cid: string;
  job?: string;
  jobGrade: number;
  gang?: string;
  gangGrade: number;
}

const PEOPLE: MockPlayer[] = [
  { src: 3, name: 'Dana Whitlock', username: 'dana', cid: 'DWH51842', job: 'police', jobGrade: 4, gangGrade: 0 },
  { src: 7, name: 'June Abernathy', username: 'junebug', cid: 'JUN48213', job: 'unemployed', jobGrade: 0, gangGrade: 0 },
  { src: 12, name: 'Marcus Doyle', username: 'mdoyle', cid: 'MDO77120', job: 'mechanic', jobGrade: 1, gang: 'ballas', gangGrade: 2 },
  { src: 15, name: 'Rosa Delgado', username: 'rosa_d', cid: 'RDE20991', job: 'ammunation', jobGrade: 2, gangGrade: 0 },
  { src: 21, name: 'Tommy Kwan', username: 'tkwan', cid: 'TKW55031', job: 'taxi', jobGrade: 0, gang: 'vagos', gangGrade: 1 },
  { name: 'Walt Hendry', username: 'walt', cid: 'WHE99120', jobGrade: 0, gangGrade: 0 },
  { name: 'Ellie Marsh', username: 'ellie', cid: 'ELL55021', jobGrade: 0, gangGrade: 0 },
];

const WHERE: { street: string; zone: string; x: number; y: number; z: number }[] = [
  { street: 'Mirror Park Blvd', zone: 'Mirror Park', x: 1265.4, y: -579.1, z: 69.0 },
  { street: 'Grove St', zone: 'Davis', x: 102.7, y: -1938.2, z: 20.8 },
  { street: 'Mission Row', zone: 'Mission Row', x: 452.2, y: -980.6, z: 30.7 },
  { street: 'Procopio Dr', zone: 'Paleto Bay', x: -440.1, y: 6008.3, z: 31.7 },
  { street: 'Palomino Ave', zone: 'Little Seoul', x: -662.4, y: -935.1, z: 21.8 },
  { street: 'Vespucci Blvd', zone: 'Vespucci Canals', x: -1183.4, y: -1512.1, z: 4.4 },
  { street: 'Senora Rd', zone: 'Sandy Shores', x: 1693.2, y: 3760.6, z: 34.7 },
  { street: 'Hawick Ave', zone: 'Hawick', x: 252.3, y: -36.2, z: 69.9 },
];

interface MockRack {
  id: number;
  model: string;
  owner?: string;
  bucket: number;
  where: number;
  h: number;
  locked: boolean;
  access: RackAccess;
  createdAt: number;
  guns: Record<number, StoredGun>;
}

let serialNo = 40211;
const gun = (pick: [string, string, string[]], by: MockPlayer, ago: number): StoredGun => ({
  name: pick[0],
  item: pick[0],
  label: pick[1],
  serial: `${by.cid.slice(0, 3)}${serialNo++}`,
  ammo: [0, 6, 12, 30, 45, 60][serialNo % 6],
  durability: 62 + (serialNo % 38),
  attachments: pick[2],
  tint: serialNo % 4,
  by: by.cid,
  byName: by.name,
  at: NOW - ago,
});

const fill = (model: string, owner: MockPlayer, count: number, from: number): Record<number, StoredGun> => {
  const def = MODELS.find(m => m.model === model)!;
  const out: Record<number, StoredGun> = {};
  let slot = 1;

  for (const [kind, , n] of def.kinds) {
    for (let i = 0; i < n; i++, slot++) {
      if (Object.keys(out).length >= count) return out;
      if ((slot + from) % 3 === 0) continue;

      const pool = kind === 'pistol' ? SHORT : LONG;
      out[slot] = gun(pool[(slot + from) % pool.length], owner, (slot * 7 + from) * HOUR);
    }
  }

  return out;
};

const NOBODY: RackAccess = { jobs: [], gangs: [] };
const person = (cid: string) => PEOPLE.find(p => p.cid === cid)!;

let RACKS: MockRack[] = [
  { id: 3, model: 'sd_gunrack_armory', bucket: 0, where: 2, h: 90, locked: true, access: { jobs: [{ name: 'police', grade: 2 }, { name: 'sheriff', grade: 2 }], gangs: [] }, createdAt: NOW - 21 * DAY, guns: {} },
  { id: 4, model: 'sd_gunrack_pistols', bucket: 0, where: 2, h: 270, locked: true, access: { jobs: [{ name: 'police', grade: 0 }], gangs: [] }, createdAt: NOW - 21 * DAY, guns: {} },
  { id: 9, model: 'sd_gunrack_oak', owner: 'DWH51842', bucket: 0, where: 0, h: 182, locked: true, access: NOBODY, createdAt: NOW - 12 * DAY, guns: {} },
  { id: 11, model: 'sd_gunrack_pegboard', owner: 'MDO77120', bucket: 0, where: 1, h: 45, locked: true, access: NOBODY, createdAt: NOW - 9 * DAY, guns: {} },
  { id: 14, model: 'sd_gunrack_walnut', owner: 'JUN48213', bucket: 0, where: 4, h: 0, locked: false, access: NOBODY, createdAt: NOW - 6 * DAY, guns: {} },
  { id: 15, model: 'sd_gunrack_stand', owner: 'JUN48213', bucket: 0, where: 4, h: 12, locked: true, access: NOBODY, createdAt: NOW - 6 * DAY, guns: {} },
  { id: 18, model: 'sd_gunrack_heritage', owner: 'WHE99120', bucket: 0, where: 3, h: 300, locked: true, access: NOBODY, createdAt: NOW - 5 * DAY, guns: {} },
  { id: 21, model: 'sd_gunrack_corner', owner: 'RDE20991', bucket: 0, where: 5, h: 135, locked: true, access: NOBODY, createdAt: NOW - 4 * DAY, guns: {} },
  { id: 22, model: 'sd_gunrack_panel', owner: 'RDE20991', bucket: 0, where: 5, h: 225, locked: true, access: NOBODY, createdAt: NOW - 4 * DAY, guns: {} },
  { id: 25, model: 'sd_gunrack_pipe', bucket: 0, where: 1, h: 180, locked: true, access: { jobs: [], gangs: [{ name: 'ballas', grade: 1 }] }, createdAt: NOW - 3 * DAY, guns: {} },
  { id: 27, model: 'sd_gunrack_oak', owner: 'TKW55031', bucket: 4, where: 6, h: 64, locked: true, access: NOBODY, createdAt: NOW - 2 * DAY, guns: {} },
  { id: 30, model: 'sd_gunrack_pistols', owner: 'ELL55021', bucket: 0, where: 7, h: 90, locked: false, access: NOBODY, createdAt: NOW - DAY, guns: {} },
  { id: 31, model: 'sd_gunrack_armory', owner: 'DWH51842', bucket: 0, where: 0, h: 270, locked: true, access: NOBODY, createdAt: NOW - 7 * HOUR, guns: {} },
  { id: 33, model: 'sd_gunrack_walnut', owner: 'MDO77120', bucket: 0, where: 1, h: 315, locked: true, access: NOBODY, createdAt: NOW - 40 * MIN, guns: {} },
];

/** Per rack: who racked its guns, and how many. */
const COUNTS: Record<number, [string, number]> = {
  3: ['DWH51842', 9],
  4: ['DWH51842', 5],
  9: ['DWH51842', 6],
  11: ['MDO77120', 7],
  14: ['JUN48213', 2],
  15: ['JUN48213', 3],
  18: ['WHE99120', 1],
  21: ['RDE20991', 4],
  22: ['RDE20991', 3],
  25: ['MDO77120', 2],
  27: ['TKW55031', 5],
  30: ['ELL55021', 6],
  31: ['DWH51842', 4],
  33: ['MDO77120', 0],
};

for (const r of RACKS) {
  const [by, n] = COUNTS[r.id];
  r.guns = fill(r.model, person(by), n, r.id);
}

const defOf = (model: string) => MODELS.find(m => m.model === model)!;
const slotsOf = (model: string) => defOf(model).kinds.reduce((sum, k) => sum + k[2], 0);
const online = (cid?: string) => !!cid && PEOPLE.some(p => p.cid === cid && p.src !== undefined);

const rowOf = (r: MockRack): RackRow => {
  const w = WHERE[r.where];
  const owner = r.owner ? person(r.owner) : undefined;

  return {
    id: r.id,
    model: r.model,
    label: defOf(r.model).label,
    mount: defOf(r.model).mount,
    owner: r.owner,
    ownerName: owner?.name,
    ownerOnline: online(r.owner),
    bucket: r.bucket,
    x: w.x + (r.id % 5) * 0.8,
    y: w.y - (r.id % 3) * 0.6,
    z: w.z,
    h: r.h,
    street: w.street,
    zone: w.zone,
    locked: r.locked,
    access: r.access,
    stored: Object.keys(r.guns).length,
    slots: slotsOf(r.model),
    createdAt: r.createdAt,
    busy: false,
  };
};

/** The staff member looking at the console. */
const ME = 'Dana Whitlock (dana)';

let logId = 0;
const LOGS: LogRow[] = [];

const note = (kind: string, actor: string | undefined, detail: string, rack?: number, ago = 0) => {
  LOGS.unshift({ id: ++logId, at: Math.floor(Date.now() / 1000) - ago, kind, actor, cid: undefined, rack, detail });
};

// A history long enough to page through: oldest first, so the newest ends up on top.
(() => {
  const lines: [string, string | undefined, string, number | undefined][] = [];

  for (const r of [...RACKS].sort((a, b) => a.createdAt - b.createdAt)) {
    const owner = r.owner ? person(r.owner) : undefined;

    lines.push(
      owner
        ? ['place', `${owner.name} (${owner.username})`, `placed ${defOf(r.model).label} (rack ${r.id})`, r.id]
        : ['admin.place', ME, `placed staff rack ${r.id} (${r.model})`, r.id],
    );

    for (const [slot, g] of Object.entries(r.guns)) {
      const who = `${g.byName} (${person(g.by!).username})`;
      lines.push(['store', who, `stored ${g.name} (serial ${g.serial}) on rack ${r.id} slot ${slot}`, r.id]);
    }
  }

  lines.push(
    ['take', 'June Abernathy (junebug)', 'took WEAPON_PUMPSHOTGUN (serial JUN40190) from rack 14 slot 2', 14],
    ['force', 'Tommy Kwan (tkwan)', 'failed to force rack 21 (tool broke)', 21],
    ['suspect', 'Tommy Kwan (tkwan)', 'action requests faster than 600 ms', undefined],
    ['force', 'Tommy Kwan (tkwan)', 'forced the lock on rack 21 (owner Rosa Delgado)', 21],
    ['seize', ME, 'seized WEAPON_SMG (serial RDE40177) from rack 21 slot 3, owner Rosa Delgado', 21],
    ['lock', 'June Abernathy (junebug)', 'unlocked rack 14', 14],
    ['admin.give', ME, 'gave 2x gunrack_walnut to Marcus Doyle', undefined],
    ['export', undefined, 'my_housing created rack 33 (sd_gunrack_walnut)', 33],
    ['admin.access', ME, 'set the access list of rack 25: gangs ballas 1', 25],
    ['pickup', 'Ellie Marsh (ellie)', 'picked up Pistol Stand (rack 29)', undefined],
  );

  lines.forEach((l, i) => note(l[0], l[1], l[2], l[3], (lines.length - i) * 47 * MIN));
})();

const playerRows = (): PlayerRow[] =>
  PEOPLE.filter(p => p.src !== undefined).map(p => {
    const mine = RACKS.filter(r => r.owner === p.cid).map(rowOf);
    return {
      src: p.src as number,
      name: p.name,
      username: p.username,
      cid: p.cid,
      job: p.job,
      jobGrade: p.jobGrade,
      gang: p.gang,
      gangGrade: p.gangGrade,
      guns: mine.reduce((sum, r) => sum + r.stored, 0),
      racks: mine,
    };
  });

export function installAdminMocks(): void {
  const find = (id: number) => RACKS.find(r => r.id === id);

  registerMockNui('admin:close', () => ({ ok: true }));
  registerMockNui('admin:getCatalog', () => CATALOG);
  registerMockNui('admin:getRacks', () => ({ list: RACKS.map(rowOf) }));

  registerMockNui('admin:getOverview', (): Overview => {
    const rows = RACKS.map(rowOf);
    const byModel = MODELS.map(m => {
      const of = rows.filter(r => r.model === m.model);
      return {
        model: m.model,
        label: m.label,
        count: of.length,
        guns: of.reduce((sum, r) => sum + r.stored, 0),
        slots: of.reduce((sum, r) => sum + r.slots, 0),
      };
    })
      .filter(m => m.count > 0)
      .sort((a, b) => b.count - a.count || a.label.localeCompare(b.label));
    return {
      racks: rows.length,
      guns: rows.reduce((sum, r) => sum + r.stored, 0),
      slots: rows.reduce((sum, r) => sum + r.slots, 0),
      locked: rows.filter(r => r.locked).length,
      open: rows.filter(r => !r.locked).length,
      staff: rows.filter(r => !r.owner).length,
      restricted: rows.filter(r => r.access.jobs.length + r.access.gangs.length > 0).length,
      owners: new Set(rows.flatMap(r => (r.owner ? [r.owner] : []))).size,
      buckets: new Set(rows.map(r => r.bucket)).size,
      online: PEOPLE.filter(p => p.src !== undefined).length,
      byModel,
      recent: LOGS.slice(0, 8),
    };
  });

  registerMockNui('admin:getRack', ({ id }) => {
    const r = find(id);

    if (!r) return { ok: false, err: 'That rack is not here any more.' };

    const slots: RackSlot[] = [];
    let index = 1;

    for (const [kind, label, n] of defOf(r.model).kinds) {
      for (let i = 0; i < n; i++, index++) {
        slots.push({ index, kind, kindLabel: label, gun: r.guns[index], busy: false });
      }
    }

    return { rack: rowOf(r), slots };
  });

  registerMockNui('admin:setLocked', ({ rackId, locked }) => {
    const r = find(rackId);

    if (!r) return { ok: false, err: 'That rack is not here any more.' };

    r.locked = locked;
    note('admin.lock', ME, `${locked ? 'locked' : 'unlocked'} rack ${r.id}`, r.id);

    return { ok: true, locked };
  });

  registerMockNui('admin:setAccess', ({ rackId, access }) => {
    const r = find(rackId);

    if (!r) return { ok: false, err: 'That rack is not here any more.' };

    r.access = access;
    note('admin.access', ME, `set the access list of rack ${r.id}`, r.id);

    return { ok: true, access };
  });

  registerMockNui('admin:transfer', ({ rackId, target }) => {
    const r = find(rackId);

    if (!r) return { ok: false, err: 'That rack is not here any more.' };

    const to = PEOPLE.find(p => String(p.src) === target || p.cid.toLowerCase() === target.toLowerCase());

    if (!to) {
      return { ok: false, err: /^\d+$/.test(target) ? 'No player with that id.' : 'No character with that citizen id.' };
    }

    r.owner = to.cid;
    note('admin.transfer', ME, `gave rack ${r.id} to ${to.name}`, r.id);

    return { ok: true, owner: to.cid, ownerName: to.name };
  });

  registerMockNui('admin:takeGun', ({ rackId, slot }) => {
    const r = find(rackId);
    const g = r?.guns[slot];

    if (!r || !g) return { ok: false, err: 'There is no gun in that slot.' };

    delete r.guns[slot];
    note('admin.take', ME, `took ${g.name} (serial ${g.serial}) off rack ${r.id} slot ${slot}`, r.id);

    return { ok: true, label: g.label };
  });

  registerMockNui('admin:deleteRack', ({ rackId }) => {
    const r = find(rackId);

    if (!r) return { ok: false, err: 'That rack is not here any more.' };

    const given = Object.keys(r.guns).length;
    RACKS = RACKS.filter(x => x.id !== rackId);
    note('admin.delete', ME, `deleted rack ${rackId} (${r.model}), returned ${given} guns`, rackId);

    return { ok: true, given };
  });

  registerMockNui('admin:searchWeapons', ({ q, field }) => {
    const needle = q.trim().toLowerCase();
    const all: WeaponHit[] = [];

    for (const r of RACKS) {
      const row = rowOf(r);

      for (const [slot, g] of Object.entries(r.guns)) {
        all.push({
          rackId: r.id,
          rackLabel: row.label,
          model: r.model,
          slot: Number(slot),
          name: g.name,
          label: g.label,
          serial: g.serial,
          ammo: g.ammo,
          owner: row.owner,
          ownerName: row.ownerName,
          by: g.by,
          byName: g.byName,
          at: g.at,
          bucket: r.bucket,
          x: row.x,
          y: row.y,
          z: row.z,
          street: row.street,
          zone: row.zone,
        });
      }
    }

    const has = (...values: (string | undefined)[]) => values.some(v => (v ?? '').toLowerCase().includes(needle));
    const hits = all
      .filter(h => {
        if (!needle) return true;
        if (field === 'weapon') return has(h.name, h.label);
        if (field === 'serial') return has(h.serial);
        if (field === 'owner') return has(h.owner, h.ownerName);
        if (field === 'by') return has(h.by, h.byName);
        return has(h.name, h.label, h.serial, h.owner, h.ownerName, h.by, h.byName);
      })
      .sort((a, b) => b.at - a.at);

    return { list: hits.slice(0, 200), total: hits.length, capped: hits.length > 200 };
  });

  registerMockNui('admin:getPlayers', () => ({ list: playerRows() }));

  registerMockNui('admin:giveItem', ({ target, item, count }) => {
    const p = PEOPLE.find(x => x.src === target);

    if (!p) return { ok: false, err: 'No player with that id.' };

    const m = MODELS.find(x => x.item === item);
    const n = Math.min(CATALOG.maxGive, Math.max(1, count));
    note('admin.give', ME, `gave ${n}x ${item} to ${p.name}`);

    return { ok: true, count: n, label: m?.label ?? item, targetName: p.name };
  });

  registerMockNui('admin:getLogs', ({ page, size, kind, q, rack }) => {
    const needle = (q ?? '').toLowerCase();
    const scoped = LOGS.filter(l => rack === undefined || l.rack === rack);

    const matches = (l: LogRow) => {
      if (kind && l.kind !== kind) return false;
      if (!needle) return true;
      return (l.actor ?? '').toLowerCase().includes(needle) || l.detail.toLowerCase().includes(needle);
    };

    const rows = scoped.filter(matches);
    const counts = new Map<string, number>();

    for (const l of scoped) counts.set(l.kind, (counts.get(l.kind) ?? 0) + 1);

    const pages = Math.max(1, Math.ceil(rows.length / size));
    const at = Math.min(Math.max(1, page), pages);

    return {
      list: rows.slice((at - 1) * size, at * size),
      total: rows.length,
      page: at,
      size,
      pages,
      kinds: [...counts.entries()]
        .sort((a, b) => a[0].localeCompare(b[0]))
        .map(([k, count]) => ({ kind: k, count })),
    };
  });

  registerMockNui('admin:teleport', ({ rackId }) => {
    const r = find(rackId);

    if (!r) return { ok: false, err: 'That rack is not here any more.' };

    return { ok: true, bucket: r.bucket, sameBucket: r.bucket === 0 };
  });

  registerMockNui('admin:place', () => ({ ok: true }));
}

/** What the client script posts with `sd-gunracks:admin:open`. Every permission, sensible polls. */
export const MOCK_ADMIN_OPEN: AdminOpenPayload = {
  perms: { admin: true, delete: true },
  pollMs: { overview: 10_000, racks: 6_000, players: 8_000, logs: 15_000 },
};

/**
 * For looking at a tab without a mouse (a headless screenshot): `&tab=2` presses that tab's number key,
 * `&pick=9` then clicks the row of rack #9 (or of player #9 on the Players tab).
 */
const driveFromQuery = (): void => {
  const q = new URLSearchParams(window.location.search);
  const tab = q.get('tab');
  const pick = q.get('pick');

  if (tab) window.setTimeout(() => window.dispatchEvent(new KeyboardEvent('keydown', { key: tab })), 300);

  if (pick) {
    window.setTimeout(() => {
      const rows = Array.from(document.querySelectorAll<HTMLTableRowElement>('.ga-hu-table tbody tr'));
      rows.find(r => r.querySelector('.ga-hu-src')?.textContent === `#${pick}`)?.click();
    }, 900);
  }
};

export function openMockAdmin(): void {
  installAdminMocks();
  post('sd-gunracks:admin:open', MOCK_ADMIN_OPEN);
  driveFromQuery();
}
