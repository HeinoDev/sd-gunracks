/**
 * What crosses the wire between the page and client/racks/admin.lua (and, through its relay, the
 * server's console handlers in server/racks/admin.lua and server/racks/views.lua). Lua has one
 * table type, so every list here can arrive as `{}` and every optional field simply absent: the
 * tabs read them through nui/wire.ts and the readers in admin/shared.tsx, never straight.
 */

export type ToastType = 'info' | 'success' | 'error';

export interface ConfirmSpec {
  title?: string;
  message: string;
  confirmLabel?: string;
  danger?: boolean;
  onConfirm: () => void;
}

export interface Refusal {
  ok: false;
  err?: string;
}

/** Where a rack goes: on the floor, on a wall, or on the floor or any table-top. */
export type Mount = 'floor' | 'wall' | 'surface';

export interface AdminPerms {
  admin?: boolean;
  /** Whether a rack may be deleted from the console (configs/server/admin.lua AllowDelete). */
  delete?: boolean;
}

export type AdminPollKey = 'overview' | 'racks' | 'players' | 'logs';
export type AdminPollMs = Partial<Record<AdminPollKey, number>>;

export interface AdminOpenPayload {
  perms: AdminPerms;
  pollMs: AdminPollMs;
}

/** One job or gang on a rack's access list, and the lowest grade it opens to. */
export interface AccessEntry {
  name: string;
  grade: number;
}

export interface RackAccess {
  jobs: AccessEntry[];
  gangs: AccessEntry[];
}

/** One rack model as the Place tab offers it (data/racks.json + configs/shared/racks.lua). */
export interface RackModel {
  model: string;
  item: string;
  label: string;
  mount: Mount;
  slots: number;
  /** What its slots take: 'Long gun' x8, 'Handgun' x6 ... */
  kinds: { label: string; count: number }[];
}

export interface Catalog {
  models: RackModel[];
  /** The most rack items one give hands out (configs/server/admin.lua MaxGive). */
  maxGive: number;
}

/** A rack as the Racks tab lists it. */
export interface RackRow {
  id: number;
  model: string;
  label: string;
  mount: Mount;
  /** The owner's character id; absent for a staff rack, which belongs to nobody. */
  owner?: string;
  ownerName?: string;
  ownerOnline: boolean;
  bucket: number;
  x: number;
  y: number;
  z: number;
  h: number;
  /** Filled in by the client from the coords: the street and the area it stands in. */
  street?: string;
  zone?: string;
  locked: boolean;
  access: RackAccess;
  stored: number;
  slots: number;
  /** Unix seconds. */
  createdAt: number;
  /** A store, take or delete is in flight on it right now. */
  busy: boolean;
}

export interface StoredGun {
  name: string;
  item: string;
  label: string;
  serial?: string;
  ammo: number;
  /** 0..100, when the inventory keeps a condition. */
  durability?: number;
  attachments: string[];
  tint: number;
  /** Character id and name of whoever racked it, and when (unix seconds). */
  by?: string;
  byName?: string;
  at: number;
}

export interface RackSlot {
  index: number;
  kind: string;
  kindLabel: string;
  gun?: StoredGun;
  busy: boolean;
}

export interface RackDetail {
  rack: RackRow;
  slots: RackSlot[];
}

/** A stored gun found by the Weapons tab, with the rack it is on. */
export interface WeaponHit {
  rackId: number;
  rackLabel: string;
  model: string;
  slot: number;
  name: string;
  label: string;
  serial?: string;
  ammo: number;
  owner?: string;
  ownerName?: string;
  by?: string;
  byName?: string;
  at: number;
  bucket: number;
  x: number;
  y: number;
  z: number;
  street?: string;
  zone?: string;
}

export type WeaponField = 'any' | 'weapon' | 'serial' | 'owner' | 'by';

export interface PlayerRow {
  src: number;
  /** Character name. */
  name: string;
  /** Account name (GetPlayerName). */
  username: string;
  cid?: string;
  job?: string;
  jobGrade: number;
  gang?: string;
  gangGrade: number;
  guns: number;
  racks: RackRow[];
}

export interface LogRow {
  id: number;
  /** Unix seconds. */
  at: number;
  /** The audit event: place, store, take, admin.delete, suspect ... */
  kind: string;
  /** Who did it; absent for the resource itself or another resource (an export). */
  actor?: string;
  cid?: string;
  rack?: number;
  detail: string;
}

export interface LogPage {
  list: LogRow[];
  total: number;
  page: number;
  size: number;
  pages: number;
  /** Every kind on record (for the filter pills), with how many rows each has. */
  kinds: { kind: string; count: number }[];
}

export interface Overview {
  racks: number;
  guns: number;
  slots: number;
  locked: number;
  open: number;
  /** Racks placed by staff or an export: they belong to nobody. */
  staff: number;
  /** Racks with a job or gang access list. */
  restricted: number;
  owners: number;
  buckets: number;
  online: number;
  byModel: { model: string; label: string; count: number; guns: number; slots: number }[];
  recent: LogRow[];
}

export interface Callbacks {
  'admin:close': { req: Record<string, never>; res: { ok: boolean } };
  // Relayed straight to the server's twin (shared/admin_callbacks.lua).
  'admin:getOverview': { req: Record<string, never>; res: Overview | Refusal };
  'admin:getCatalog': { req: Record<string, never>; res: Catalog | Refusal };
  'admin:getRacks': { req: Record<string, never>; res: { list: RackRow[] } | Refusal };
  'admin:getRack': { req: { id: number }; res: RackDetail | Refusal };
  'admin:setLocked': {
    req: { rackId: number; locked: boolean };
    res: { ok: boolean; err?: string; locked?: boolean };
  };
  'admin:setAccess': {
    req: { rackId: number; access: RackAccess };
    res: { ok: boolean; err?: string; access?: RackAccess };
  };
  /** `target` is a server id or a citizen id. */
  'admin:transfer': {
    req: { rackId: number; target: string };
    res: { ok: boolean; err?: string; owner?: string; ownerName?: string };
  };
  /** One stored gun off a rack into the admin's own inventory. */
  'admin:takeGun': {
    req: { rackId: number; slot: number };
    res: { ok: boolean; err?: string; label?: string };
  };
  /** The guns go to the admin's inventory first; a rack whose guns did not all fit is kept with the rest. */
  'admin:deleteRack': {
    req: { rackId: number };
    res: { ok: boolean; err?: string; given?: number };
  };
  'admin:searchWeapons': {
    req: { q: string; field: WeaponField };
    res: { list: WeaponHit[]; total: number; capped: boolean } | Refusal;
  };
  'admin:getPlayers': { req: Record<string, never>; res: { list: PlayerRow[] } | Refusal };
  'admin:giveItem': {
    req: { target: number; item: string; count: number };
    res: { ok: boolean; err?: string; count?: number; label?: string; targetName?: string };
  };
  'admin:getLogs': {
    req: { page: number; size: number; kind?: string; q?: string; rack?: number };
    res: LogPage | Refusal;
  };
  // Answered by the client (after asking the server where the rack is, which logs it).
  'admin:teleport': {
    req: { rackId: number };
    res: { ok: boolean; err?: string; bucket?: number; sameBucket?: boolean };
  };
  /**
   * Step the console aside and start the placer for a staff rack; the console comes back when it is
   * placed or put away.
   */
  'admin:place': {
    req: { model: string; access: RackAccess; locked: boolean };
    res: { ok: boolean; err?: string };
  };
}

export type CallbackName = keyof Callbacks;
export type CallbackRequest<K extends CallbackName> = Callbacks[K]['req'];
export type CallbackResponse<K extends CallbackName> = Callbacks[K]['res'];
