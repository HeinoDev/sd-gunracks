import { useEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { AlertTriangle, Inbox, Loader2 } from 'lucide-react';
import { listOf, mapOf, numOf, refusalOf, strOrNull } from '@/nui/wire';
import type {
  AccessEntry,
  AdminPerms,
  AdminPollMs,
  Catalog,
  ConfirmSpec,
  Mount,
  PlayerRow,
  RackAccess,
  RackModel,
  RackRow,
  Refusal,
  ToastType,
} from '@/types';

export interface TabProps {
  /** Every rack on the server, as the console last read it (see AdminConsole). */
  racks: RackRow[];

  /** False until the first rack list has come back, so an empty list can be told from a slow one. */
  racksReady: boolean;

  catalog: Catalog;
  perms: AdminPerms;
  pollMs: AdminPollMs;

  /** Bumped by the header's refresh button. A tab re-reads whatever it shows when it changes. */
  refreshToken: number;

  showToast: (message: string, type?: ToastType) => void;
  requestConfirm: (spec: ConfirmSpec) => void;

  /** Read the rack list again now: after anything a tab did changes a rack. */
  reloadRacks: () => void;

  /** Open the Racks tab with this rack picked: how the other tabs point at one. */
  openRack: (id: number) => void;

  /** The rack the Racks tab should open on, once; it calls back with null when it has. */
  focusRack: number | null;
  clearFocus: () => void;

  /**
   * A tab holding unsaved edits registers a check here. The panel asks it before switching tab or
   * closing; a string back is the reason to stop and confirm, null means leave freely. Pass null to
   * unregister — a tab must do so when it unmounts.
   */
  setLeaveGuard: (guard: (() => string | null) | null) => void;
}

// ---------------------------------------------------------------------------------------------
// Reading answers
// ---------------------------------------------------------------------------------------------

/** No answer at all, or `{ ok: false }`. Narrows a `Thing | Refusal | null` down to the Thing. */
export const isRefused = (resp: unknown): resp is Refusal | null | undefined =>
  resp === null || resp === undefined || refusalOf(resp) !== null;

/** Why a call failed, in words fit for a toast, or null if it did not. */
export const failureOf = (resp: unknown): string | null => {
  if (resp === null || resp === undefined) return 'The callback never came back.';
  return refusalOf(resp);
};

export const MOUNTS: Mount[] = ['floor', 'wall', 'surface'];

export const MOUNT_WORD: Record<Mount, string> = {
  floor: 'Floor',
  wall: 'Wall',
  surface: 'Table-top',
};

/**
 * The rack's picture: the inventory icon in the resource's images/ folder (vite.config.ts says how
 * the dev server finds it).
 */
export const pictureOf = (item: string): string => `../../images/${item}.png`;

const entriesOf = (value: unknown): AccessEntry[] =>
  listOf<Record<string, unknown> | null>(value).flatMap(e => {
    const name = e && strOrNull(e.name);
    return e && name ? [{ name, grade: Math.max(0, Math.floor(numOf(e.grade))) }] : [];
  });

/** An access list off the wire: jobs and gangs as lists, never absent. */
export const accessOf = (value: unknown): RackAccess => {
  const a = mapOf<unknown>(value);
  return { jobs: entriesOf(a.jobs), gangs: entriesOf(a.gangs) };
};

/** Whether a rack has anybody on its access list. */
export const hasAccess = (a: RackAccess): boolean => a.jobs.length + a.gangs.length > 0;

/**
 * One rack off the wire. Every key is rebuilt rather than trusted: a staff rack has no `owner`, a
 * rack with nobody on its access list arrives with `access: {}` or none at all.
 */
export const rackOf = (raw: unknown): RackRow | null => {
  const r = mapOf<unknown>(raw);
  const id = numOf(r.id, NaN);

  if (!Number.isFinite(id)) return null;

  const model = strOrNull(r.model) ?? '';

  return {
    id,
    model,
    label: strOrNull(r.label) ?? model,
    mount: MOUNTS.includes(r.mount as Mount) ? (r.mount as Mount) : 'floor',
    owner: strOrNull(r.owner) ?? undefined,
    ownerName: strOrNull(r.ownerName) ?? undefined,
    ownerOnline: r.ownerOnline === true,
    bucket: numOf(r.bucket),
    x: numOf(r.x),
    y: numOf(r.y),
    z: numOf(r.z),
    h: numOf(r.h),
    street: strOrNull(r.street) ?? undefined,
    zone: strOrNull(r.zone) ?? undefined,
    locked: r.locked === true,
    access: accessOf(r.access),
    stored: numOf(r.stored),
    slots: numOf(r.slots),
    createdAt: numOf(r.createdAt),
    busy: r.busy === true,
  };
};

export const racksOf = (value: unknown): RackRow[] =>
  listOf<unknown>(value).flatMap(r => {
    const rack = rackOf(r);
    return rack ? [rack] : [];
  });

export const EMPTY_CATALOG: Catalog = { models: [], maxGive: 10 };

export const catalogOf = (value: unknown): Catalog => {
  const raw = mapOf<unknown>(value);
  const models = listOf<Record<string, unknown> | null>(raw.models).flatMap((m): RackModel[] => {
    const model = m && strOrNull(m.model);
    const item = m && strOrNull(m.item);

    if (!m || !model || !item) return [];

    return [
      {
        model,
        item,
        label: strOrNull(m.label) ?? model,
        mount: MOUNTS.includes(m.mount as Mount) ? (m.mount as Mount) : 'floor',
        slots: numOf(m.slots),
        kinds: listOf<Record<string, unknown> | null>(m.kinds).flatMap(k =>
          k && strOrNull(k.label) ? [{ label: strOrNull(k.label) as string, count: numOf(k.count) }] : [],
        ),
      },
    ];
  });
  return { models, maxGive: Math.max(1, numOf(raw.maxGive, EMPTY_CATALOG.maxGive)) };
};

/** The players on the server off the wire, each with their racks. */
export const playersOf = (value: unknown): PlayerRow[] =>
  listOf<Record<string, unknown> | null>(value).flatMap(p => {
    const src = p ? numOf(p.src, NaN) : NaN;

    if (!p || !Number.isFinite(src)) return [];

    const username = strOrNull(p.username) ?? `player ${src}`;

    return [
      {
        src,
        name: strOrNull(p.name) ?? username,
        username,
        cid: strOrNull(p.cid) ?? undefined,
        job: strOrNull(p.job) ?? undefined,
        jobGrade: numOf(p.jobGrade),
        gang: strOrNull(p.gang) ?? undefined,
        gangGrade: numOf(p.gangGrade),
        guns: numOf(p.guns),
        racks: racksOf(p.racks),
      },
    ];
  });

/** Where a rack stands, in words: its street and area when the client found them, else its coords. */
export const whereOf = (r: { street?: string; zone?: string; x: number; y: number }): string => {
  const parts = [r.street, r.zone].filter((s): s is string => !!s);
  return parts.length > 0 ? parts.join(', ') : `${Math.round(r.x)}, ${Math.round(r.y)}`;
};

/** A rack's name in one line: its model and its number. */
export const rackName = (r: { label: string; id: number }): string => `${r.label} #${r.id}`;

/** Who a rack belongs to, in words. */
export const ownerWord = (r: { owner?: string; ownerName?: string }): string =>
  r.owner ? r.ownerName ?? r.owner : 'Staff rack';

// ---------------------------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------------------------

export const formatNumber = (value: number | undefined | null): string =>
  (value ?? 0).toLocaleString();

export const formatDate = (unixSeconds: number | undefined | null): string => {
  if (!unixSeconds) return '—';
  return new Date(unixSeconds * 1000).toLocaleString(undefined, {
    day: '2-digit',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  });
};

export const formatAgo = (unixSeconds: number | undefined | null): string => {
  if (!unixSeconds) return '—';
  const secs = Math.max(0, Math.floor(Date.now() / 1000 - unixSeconds));
  if (secs < 60) return `${secs}s ago`;
  if (secs < 3600) return `${Math.floor(secs / 60)}m ago`;
  if (secs < 86400) return `${Math.floor(secs / 3600)}h ago`;
  return `${Math.floor(secs / 86400)}d ago`;
};

export const initials = (name: string): string => (name || '??').slice(0, 2).toUpperCase();

/**
 * Unix seconds on the viewer's clock, ticking once a second: what the Overview's "Updated 4s ago"
 * counts against.
 */
export const useNow = (): number => {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));

  useEffect(() => {
    const tick = window.setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => window.clearInterval(tick);
  }, []);

  return now;
};

// ---------------------------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------------------------

export type ChipTone = 'green' | 'red' | 'amber' | 'blue' | 'purple' | 'gray';

/**
 * Log kinds are the server's to name, so the colour is read off the verb inside one rather than
 * off a fixed list that would go grey the day a kind is added.
 */
export const toneOfKind = (kind: string): ChipTone => {
  const k = (kind || '').toLowerCase();
  if (/(delete|remove|reset|wipe|clear|cancel|lapse|suspect|seize|force)/.test(k)) return 'red';
  if (/(create|start|add|new|place|store|give)/.test(k)) return 'green';
  if (/(save|edit|set|update|override|lock|access|transfer)/.test(k)) return 'amber';
  if (/(end|finish|take|pickup|export)/.test(k)) return 'purple';
  if (/(teleport|debug|open|view)/.test(k)) return 'blue';
  return 'gray';
};

export const Chip = ({
  tone = 'gray',
  icon,
  children,
}: {
  tone?: ChipTone;
  icon?: ReactNode;
  children: ReactNode;
}) => (
  <span className={`ga-chip ${tone}`}>
    {icon}
    {children}
  </span>
);

export const Avatar = ({
  name,
  online = false,
  large = false,
}: {
  name: string;
  online?: boolean;
  large?: boolean;
}) => (
  <div className="ga-avatar">
    <div className={`ga-avatar-circle${large ? ' lg' : ''}${online ? ' online' : ''}`}>
      {initials(name)}
    </div>
    <div className={`ga-avatar-dot${online ? ' online' : ''}`} />
  </div>
);

export const Loading = ({ label = 'Loading…' }: { label?: string }) => (
  <div className="ga-loading">
    <Loader2 size={18} className="ga-spin" />
    <span>{label}</span>
  </div>
);

export const Empty = ({
  icon,
  title,
  sub,
  error = false,
  compact = false,
}: {
  icon?: ReactNode;
  title: string;
  sub?: string;
  error?: boolean;
  compact?: boolean;
}) => (
  <div className={`ga-empty${error ? ' error' : ''}${compact ? ' compact' : ''}`}>
    <div className="ga-empty-icon">
      {icon ?? (error ? <AlertTriangle size={26} /> : <Inbox size={26} />)}
    </div>
    <div className="ga-empty-title">{title}</div>
    {sub && <div className="ga-empty-sub">{sub}</div>}
  </div>
);

export const Card = ({
  title,
  icon,
  actions,
  note,
  flush = false,
  className,
  children,
}: {
  title?: ReactNode;
  icon?: ReactNode;
  actions?: ReactNode;
  note?: string;
  flush?: boolean;
  className?: string;
  children: ReactNode;
}) => (
  <div className={className ? `ga-card ${className}` : 'ga-card'}>
    {(title || actions) && (
      <div className="ga-card-header">
        <div className="ga-card-header-title">
          {icon}
          {title}
        </div>
        {actions}
      </div>
    )}
    {note && <div className="ga-card-note">{note}</div>}
    <div className={`ga-card-body${flush ? ' flush' : ''}`}>{children}</div>
  </div>
);

export const StatTile = ({
  label,
  value,
  sub,
  icon,
}: {
  label: string;
  value: ReactNode;
  sub?: ReactNode;
  icon?: ReactNode;
}) => (
  <div className="ga-stat-tile">
    <div className="ga-stat-tile-label">
      {icon}
      {label}
    </div>
    <div className="ga-stat-tile-value">{value}</div>
    {sub && <div className="ga-stat-tile-sub">{sub}</div>}
  </div>
);

/** The amber strip a polled tab shows when its last read failed and it is drawing an old one. */
export const Stale = ({ children }: { children: ReactNode }) => (
  <div className="ga-stale">{children}</div>
);

export const Tip = ({ text, children }: { text: string; children: ReactNode }) => {
  const ref = useRef<HTMLSpanElement>(null);
  const [pos, setPos] = useState<{ left: number; top: number } | null>(null);

  const show = () => {
    const el = ref.current;

    if (!el) return;

    const r = el.getBoundingClientRect();
    setPos({ left: r.left + r.width / 2, top: r.top - 8 });
  };

  return (
    <span
      ref={ref}
      className="ga-tipw"
      onMouseEnter={show}
      onMouseLeave={() => setPos(null)}
      onMouseDown={() => setPos(null)}
    >
      {children}
      {pos &&
        createPortal(
          <div className="ga-tip-pop" style={{ left: pos.left, top: pos.top }}>
            {text}
          </div>,
          document.body,
        )}
    </span>
  );
};

export const ConfirmDialog = ({ spec, onClose }: { spec: ConfirmSpec; onClose: () => void }) => {
  const [closing, setClosing] = useState(false);

  const close = () => {
    setClosing(true);
    setTimeout(onClose, 160);
  };

  return (
    <div className={`ga-modal-backdrop${closing ? ' closing' : ''}`} onClick={close}>
      <div className="ga-modal" onClick={e => e.stopPropagation()}>
        {spec.title && <p className="ga-modal-title">{spec.title}</p>}
        <p>{spec.message}</p>
        <div className="ga-modal-actions">
          <button type="button" className="ga-btn" onClick={close}>
            Cancel
          </button>
          <button
            type="button"
            className={`ga-btn ${spec.danger ? 'red' : 'green'}`}
            onClick={() => {
              spec.onConfirm();
              close();
            }}
          >
            {spec.confirmLabel ?? 'Confirm'}
          </button>
        </div>
      </div>
    </div>
  );
};
