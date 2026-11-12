import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ArrowRightLeft, Crosshair, History, Lock, Navigation, Save, Search, ShieldCheck, Trash2, Undo2, Unlock,
  Warehouse, X,
} from 'lucide-react';
import { fetchNui } from '@/nui/bridge';
import { listOf, mapOf, numOf, strOrNull } from '@/nui/wire';
import type { LogRow, RackAccess, RackDetail, RackRow, RackSlot } from '@/types';
import { AccessEditor, cleanAccess, sameAccess } from './AccessEditor';
import { Dropdown } from './Dropdown';
import {
  Card,
  Chip,
  Empty,
  Loading,
  MOUNT_WORD,
  Stale,
  StatTile,
  Tip,
  failureOf,
  formatAgo,
  formatDate,
  formatNumber,
  hasAccess,
  isRefused,
  ownerWord,
  pictureOf,
  rackName,
  rackOf,
  toneOfKind,
  whereOf,
} from './shared';
import type { TabProps } from './shared';

const DEFAULT_POLL_MS = 6000;

type Filter = 'all' | 'player' | 'staff' | 'locked' | 'open' | 'guns' | 'restricted';

const FILTERS: [Filter, string][] = [
  ['all', 'All'],
  ['player', "Players'"],
  ['staff', 'Staff'],
  ['locked', 'Locked'],
  ['open', 'Open'],
  ['guns', 'With guns'],
  ['restricted', 'Job / gang'],
];

const passes = (r: RackRow, f: Filter): boolean => {
  switch (f) {
    case 'player':
      return !!r.owner;
    case 'staff':
      return !r.owner;
    case 'locked':
      return r.locked;
    case 'open':
      return !r.locked;
    case 'guns':
      return r.stored > 0;
    case 'restricted':
      return hasAccess(r.access);
    default:
      return true;
  }
};

// ---------------------------------------------------------------------------------------------
// Off the wire, rebuilt rather than trusted: an empty slot has no `gun`, a gun no serial.
// ---------------------------------------------------------------------------------------------

const slotOf = (raw: unknown): RackSlot | null => {
  const s = mapOf<unknown>(raw);
  const index = numOf(s.index, NaN);

  if (!Number.isFinite(index)) return null;

  const g = s.gun && typeof s.gun === 'object' ? mapOf<unknown>(s.gun) : null;

  return {
    index,
    kind: strOrNull(s.kind) ?? '',
    kindLabel: strOrNull(s.kindLabel) ?? strOrNull(s.kind) ?? '',
    busy: s.busy === true,
    gun: g
      ? {
          name: strOrNull(g.name) ?? '?',
          item: strOrNull(g.item) ?? strOrNull(g.name) ?? '?',
          label: strOrNull(g.label) ?? strOrNull(g.name) ?? '?',
          serial: strOrNull(g.serial) ?? undefined,
          ammo: numOf(g.ammo),
          durability: typeof g.durability === 'number' ? g.durability : undefined,
          attachments: listOf<unknown>(g.attachments).filter((a): a is string => typeof a === 'string'),
          tint: numOf(g.tint),
          by: strOrNull(g.by) ?? undefined,
          byName: strOrNull(g.byName) ?? undefined,
          at: numOf(g.at),
        }
      : undefined,
  };
};

const detailOf = (raw: unknown): RackDetail | null => {
  const d = mapOf<unknown>(raw);
  const rack = rackOf(d.rack);

  if (!rack) return null;

  const slots = listOf<unknown>(d.slots).flatMap(s => {
    const slot = slotOf(s);
    return slot ? [slot] : [];
  });

  return { rack, slots };
};

/** A rack's fill, as a short bar and a count: what the list shows in its Guns column. */
const Fill = ({ stored, slots }: { stored: number; slots: number }) => (
  <span className="gr-fill">
    <span className="gr-fill-track">
      <span
        className={`gr-fill-bar${stored >= slots && slots > 0 ? ' full' : ''}`}
        style={{ width: `${slots > 0 ? Math.min(100, (stored / slots) * 100) : 0}%` }}
      />
    </span>
    <span className="num">
      {formatNumber(stored)}/{formatNumber(slots)}
    </span>
  </span>
);

export const RacksTab = ({
  racks,
  racksReady,
  catalog,
  perms,
  pollMs,
  refreshToken,
  showToast,
  requestConfirm,
  reloadRacks,
  focusRack,
  clearFocus,
  setLeaveGuard,
}: TabProps) => {
  const period = pollMs.racks ?? DEFAULT_POLL_MS;

  const [query, setQuery] = useState('');
  const [filter, setFilter] = useState<Filter>('all');
  const [model, setModel] = useState('');
  const [picked, setPicked] = useState<number | null>(null);

  // Another tab pointed at a rack: open it here, once.
  useEffect(() => {
    if (focusRack === null) return;
    setPicked(focusRack);
    setFilter('all');
    setQuery('');
    setModel('');
    clearFocus();
  }, [focusRack, clearFocus]);

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    return racks
      .filter(r => passes(r, filter) && (!model || r.model === model))
      .filter(
        r =>
          !q ||
          String(r.id) === q.replace(/^#/, '') ||
          r.label.toLowerCase().includes(q) ||
          (r.ownerName ?? '').toLowerCase().includes(q) ||
          (r.owner ?? '').toLowerCase().includes(q) ||
          (r.street ?? '').toLowerCase().includes(q) ||
          (r.zone ?? '').toLowerCase().includes(q),
      )
      .sort((a, b) => a.id - b.id);
  }, [racks, query, filter, model]);

  const goTo = useCallback(
    async (r: RackRow) => {
      const resp = await fetchNui('admin:teleport', { rackId: r.id });
      const failure = failureOf(resp);

      if (failure) return showToast(failure, 'error');

      if (resp && resp.sameBucket === false) {
        const bucket = resp.bucket ?? r.bucket;
        showToast(`Gone to ${rackName(r)}. It is in routing bucket ${bucket}, not yours: you will not see it.`, 'info');
      } else {
        showToast(`Gone to ${rackName(r)}.`, 'success');
      }
    },
    [showToast],
  );

  if (!racksReady) return <Loading label="Reading the racks…" />;

  const locked = racks.filter(r => r.locked).length;
  const staff = racks.filter(r => !r.owner).length;
  const row = picked !== null ? racks.find(r => r.id === picked) ?? null : null;

  return (
    <div className={`ga-hu-root${picked !== null ? ' picked' : ''}`}>
      <div className="ga-toolbar">
        <div className="ga-search">
          <Search size={13} />
          <input
            value={query}
            onChange={e => setQuery(e.target.value)}
            placeholder="Search #id, model, owner, street…"
            spellCheck={false}
          />
          {query && (
            <button type="button" className="ga-search-clear" onClick={() => setQuery('')}>
              <X size={12} />
            </button>
          )}
        </div>

        {FILTERS.map(([id, label]) => (
          <button
            key={id}
            type="button"
            className={`ga-filter-pill${filter === id ? ' active' : ''}`}
            onClick={() => setFilter(id)}
          >
            {label}
          </button>
        ))}

        <div className="ga-toolbar-spacer" />

        <Dropdown
          ariaLabel="Rack model"
          className="gr-model-pick"
          value={model}
          onChange={setModel}
          options={[
            { value: '', label: 'Every model' },
            ...catalog.models.map(m => ({
              value: m.model,
              label: m.label,
              meta: MOUNT_WORD[m.mount].toLowerCase(),
            })),
          ]}
        />
        <span className="ga-toolbar-hint">refreshes every {Math.round(period / 1000)}s</span>
      </div>

      <div className="ga-hu-body">
        <div className="ga-hu-list ga-scroll">
          <Card
            title="Racks"
            icon={<Warehouse size={12} />}
            actions={
              <div className="ga-hu-counts">
                <Chip tone="gray">{shown.length} shown</Chip>
                <Chip tone={locked > 0 ? 'amber' : 'gray'}>{locked} locked</Chip>
                <Chip tone={staff > 0 ? 'blue' : 'gray'}>{staff} staff</Chip>
              </div>
            }
            flush
          >
            {shown.length === 0 ? (
              <Empty
                compact
                icon={<Warehouse size={22} />}
                title={racks.length === 0 ? 'No racks yet' : 'Nothing matches'}
                sub={
                  racks.length === 0
                    ? 'Nobody has put a rack down. Place one from the Place tab.'
                    : 'Clear the search, the model or the filter to see every rack.'
                }
              />
            ) : (
              <table className="ga-table ga-hu-table">
                <thead>
                  <tr>
                    <th>Rack</th>
                    <th>Owner</th>
                    <th className="ga-hu-wide">Where</th>
                    <th className="ga-hu-wide">Bucket</th>
                    <th className="ga-hu-wide">Lock</th>
                    <th>Guns</th>
                    <th />
                  </tr>
                </thead>
                <tbody>
                  {shown.map(r => (
                    <tr
                      key={r.id}
                      className={picked === r.id ? 'picked' : undefined}
                      tabIndex={0}
                      onClick={() => setPicked(picked === r.id ? null : r.id)}
                      onKeyDown={e => {
                        if (e.key === 'Enter') setPicked(r.id);
                      }}
                    >
                      <td>
                        <span className="ga-hu-name">
                          <span className="ga-truncate">{r.label}</span>
                          <span className="ga-hu-src">#{r.id}</span>
                        </span>
                      </td>
                      <td>
                        {r.owner ? (
                          <span className="gr-owner">
                            <span className={`ga-hu-dot${r.ownerOnline ? ' online' : ''}`} />
                            <span className="ga-truncate">{r.ownerName ?? r.owner}</span>
                          </span>
                        ) : (
                          <Chip tone="blue">staff</Chip>
                        )}
                      </td>
                      <td className="ga-hu-wide gr-where">
                        <span className="ga-truncate">{whereOf(r)}</span>
                      </td>
                      <td className="ga-hu-wide num">{r.bucket}</td>
                      <td className="ga-hu-wide">
                        <Chip tone={r.locked ? 'amber' : 'green'}>{r.locked ? 'locked' : 'open'}</Chip>
                      </td>
                      <td>
                        <Fill stored={r.stored} slots={r.slots} />
                      </td>
                      <td className="ga-hu-act" onClick={e => e.stopPropagation()}>
                        <Tip text="Go to it">
                          <button type="button" className="ga-btn sm" onClick={() => void goTo(r)}>
                            <Navigation size={12} />
                          </button>
                        </Tip>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </Card>
        </div>

        {picked !== null && (
          <div className="ga-hu-detail ga-scroll">
            <RackPanel
              key={picked}
              id={picked}
              row={row}
              item={catalog.models.find(m => m.model === row?.model)?.item}
              period={period}
              refreshToken={refreshToken}
              canDelete={perms.delete !== false}
              showToast={showToast}
              requestConfirm={requestConfirm}
              reloadRacks={reloadRacks}
              setLeaveGuard={setLeaveGuard}
              onGo={goTo}
              onClose={() => setPicked(null)}
            />
          </div>
        )}
      </div>
    </div>
  );
};

interface PanelProps {
  id: number;
  row: RackRow | null;
  /** The rack item of its model: what its picture is named. */
  item?: string;
  period: number;
  refreshToken: number;
  canDelete: boolean;
  showToast: TabProps['showToast'];
  requestConfirm: TabProps['requestConfirm'];
  reloadRacks: () => void;
  setLeaveGuard: TabProps['setLeaveGuard'];
  onGo: (r: RackRow) => Promise<void>;
  onClose: () => void;
}

/**
 * One rack, all of it: whose it is and where, its slots and the guns in them, who may open it, and
 * what has happened to it.
 */
function RackPanel({
  id,
  row,
  item,
  period,
  refreshToken,
  canDelete,
  showToast,
  requestConfirm,
  reloadRacks,
  setLeaveGuard,
  onGo,
  onClose,
}: PanelProps) {
  const [detail, setDetail] = useState<RackDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [history, setHistory] = useState<LogRow[] | null>(null);
  /** The action under way right now ('lock', 'take:3', 'delete', ...), so its button waits. */
  const [busy, setBusy] = useState<string | null>(null);

  const [draft, setDraft] = useState<RackAccess | null>(null);
  const [target, setTarget] = useState('');

  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  const load = useCallback(async () => {
    const resp = await fetchNui('admin:getRack', { id });

    if (!alive.current) return;

    if (isRefused(resp)) {
      setError(failureOf(resp) ?? 'The server sent nothing back.');
      return;
    }

    const d = detailOf(resp);

    if (!d) return setError('The server sent a rack this page cannot read.');

    setError(null);
    setDetail(d);
  }, [id]);

  const loadHistory = useCallback(async () => {
    const resp = await fetchNui('admin:getLogs', { page: 1, size: 12, rack: id });

    if (!alive.current || isRefused(resp)) return;

    setHistory(listOf<LogRow>(resp.list));
  }, [id]);

  useEffect(() => {
    void load();
    void loadHistory();

    const timer = window.setInterval(() => {
      void load();
      void loadHistory();
    }, period);

    return () => window.clearInterval(timer);
  }, [load, loadHistory, period, refreshToken]);

  const rack = detail?.rack ?? row;
  const saved = rack?.access ?? { jobs: [], gangs: [] };
  const editing = draft ?? saved;
  const dirty = draft !== null && !sameAccess(draft, saved);

  // Unsaved access edits hold the panel: switching tab or closing asks first.
  useEffect(() => {
    const what = rack ? rackName(rack) : 'this rack';
    setLeaveGuard(dirty ? () => `The access list of ${what} has changes that are not saved.` : null);

    return () => setLeaveGuard(null);
  }, [dirty, rack, setLeaveGuard]);

  /** After an action: this rack, its history, and the list everybody reads. */
  const after = useCallback(() => {
    void load();
    void loadHistory();
    reloadRacks();
  }, [load, loadHistory, reloadRacks]);

  const run = useCallback(
    async <T,>(key: string, call: () => Promise<T>, ok: (resp: T) => string | null) => {
      setBusy(key);
      const resp = await call();

      if (!alive.current) return;

      setBusy(null);

      const failure = failureOf(resp);

      if (failure) {
        showToast(failure, 'error');
        after();
        return;
      }

      const message = ok(resp);
      if (message) showToast(message, 'success');
      after();
    },
    [showToast, after],
  );

  if (!rack) {
    return error ? (
      <div className="ga-hu-missing">
        <Empty compact title="That rack could not be read" sub={error} error />
        <button type="button" className="ga-btn" onClick={onClose}>
          <X size={12} />
          Close
        </button>
      </div>
    ) : (
      <Loading label={`Reading rack #${id}…`} />
    );
  }

  const name = rackName(rack);
  const slots = detail?.slots ?? [];

  const setLocked = () =>
    void run(
      'lock',
      () => fetchNui('admin:setLocked', { rackId: rack.id, locked: !rack.locked }),
      () => (rack.locked ? `${name} unlocked: anyone at it may use it now.` : `${name} locked.`),
    );

  const takeGun = (s: RackSlot) => {
    const gun = `${s.gun?.label ?? 'The gun'}${s.gun?.serial ? ` (serial ${s.gun.serial})` : ''}`;

    requestConfirm({
      title: 'Take the gun',
      message: `${gun} comes off slot ${s.index} of ${name} and into your own inventory, with everything on it.`,
      confirmLabel: 'Take it',
      onConfirm: () =>
        void run(
          `take:${s.index}`,
          () => fetchNui('admin:takeGun', { rackId: rack.id, slot: s.index }),
          resp => `${resp && 'label' in resp && resp.label ? resp.label : 'The gun'} is in your inventory.`,
        ),
    });
  };

  const remove = () =>
    requestConfirm({
      title: `Delete ${name}`,
      message:
        rack.stored > 0
          ? `Every gun on it (${rack.stored}) goes into your inventory first. If they do not all fit, the rack is kept with the rest on it, so no gun is ever lost.`
          : 'It has no guns on it. It is gone for good, and nobody gets the rack item back.',
      confirmLabel: 'Delete it',
      danger: true,
      onConfirm: () =>
        void (async () => {
          setBusy('delete');
          const resp = await fetchNui('admin:deleteRack', { rackId: rack.id });

          if (!alive.current) return;

          setBusy(null);

          const failure = failureOf(resp);
          reloadRacks();

          if (failure) {
            showToast(failure, 'error');
            void load();
            return;
          }

          const given = resp?.given ? `, ${resp.given} gun${resp.given === 1 ? '' : 's'} in your inventory` : '';
          showToast(`${name} deleted${given}.`, 'success');
          onClose();
        })(),
    });

  const saveAccess = () => {
    if (!draft) return;

    const access = cleanAccess(draft);

    void run(
      'access',
      () => fetchNui('admin:setAccess', { rackId: rack.id, access }),
      () => {
        setDraft(null);
        return `Access to ${name} saved.`;
      },
    );
  };

  const transfer = () => {
    const to = target.trim();

    if (!to) return;

    const whose = /^\d+$/.test(to) ? `player ${to}'s` : `${to}'s`;
    const before = rack.owner ? `${ownerWord(rack)} no longer can` : 'it stops being a staff rack';

    requestConfirm({
      title: `Give ${name} away`,
      message: `${name} and the guns on it become ${whose}. They can lock, unlock and pick it up; ${before}.`,
      confirmLabel: 'Transfer it',
      onConfirm: () =>
        void run(
          'transfer',
          () => fetchNui('admin:transfer', { rackId: rack.id, target: to }),
          resp => {
            setTarget('');
            return `${name} now belongs to ${(resp && 'ownerName' in resp && resp.ownerName) || to}.`;
          },
        ),
    });
  };

  return (
    <>
      <div className="ga-hu-head">
        {item ? <img className="gr-pic" src={pictureOf(item)} alt="" /> : <span className="gr-pic" />}
        <div className="ga-hu-head-main">
          <div className="ga-detail-title">
            <h2>{name}</h2>
            <Chip tone={rack.locked ? 'amber' : 'green'}>{rack.locked ? 'locked' : 'open'}</Chip>
            {!rack.owner && <Chip tone="blue">staff rack</Chip>}
            {hasAccess(rack.access) && <Chip tone="purple">job / gang</Chip>}
            {rack.busy && <Chip tone="red">in use</Chip>}
          </div>
          <div className="ga-detail-sub">
            {rack.owner ? (
              <>
                {ownerWord(rack)} <span className="ga-mono ga-selectable">{rack.owner}</span>
                {rack.ownerOnline ? ' · on now' : ''}
              </>
            ) : (
              'Belongs to nobody'
            )}
            {' · '}
            {whereOf(rack)} · bucket {rack.bucket}
          </div>
        </div>
        <button type="button" className="ga-icon-btn" onClick={onClose} title="Close this rack">
          <X size={14} />
        </button>
      </div>

      <div className="ga-hu-commit gr-commit">
        <Tip text="Stand in front of it">
          <button type="button" className="ga-btn" onClick={() => void onGo(rack)}>
            <Navigation size={13} />
            Go to it
          </button>
        </Tip>
        <Tip text={rack.locked ? 'Anyone standing at it may use it' : 'Only its owner, staff and its access list'}>
          <button type="button" className="ga-btn" onClick={setLocked} disabled={busy === 'lock'}>
            {rack.locked ? <Unlock size={13} /> : <Lock size={13} />}
            {rack.locked ? 'Unlock' : 'Lock'}
          </button>
        </Tip>
        {canDelete && (
          <Tip text="Its guns go into your inventory first">
            <button type="button" className="ga-btn red" onClick={remove} disabled={busy === 'delete'}>
              <Trash2 size={13} />
              Delete
            </button>
          </Tip>
        )}
      </div>

      {error && <Stale>Last refresh failed — {error} Showing the rack as it last came back.</Stale>}

      <div className="ga-stat-grid">
        <StatTile
          icon={<Crosshair size={11} />}
          label="Guns"
          value={`${formatNumber(rack.stored)}/${formatNumber(rack.slots)}`}
          sub="on it now"
        />
        <StatTile icon={<Warehouse size={11} />} label="Mount" value={MOUNT_WORD[rack.mount]} sub={rack.label} />
        <StatTile
          icon={<History size={11} />}
          label="Placed"
          value={formatAgo(rack.createdAt)}
          sub={formatDate(rack.createdAt)}
        />
        <StatTile
          icon={<Navigation size={11} />}
          label="At"
          value={`${Math.round(rack.x)}, ${Math.round(rack.y)}`}
          sub={`z ${rack.z.toFixed(1)} · heading ${Math.round(rack.h)}°`}
        />
      </div>

      <Card
        title="Slots"
        icon={<Crosshair size={12} />}
        note="Every slot and the gun in it. Take moves that one gun, with everything on it, into your own inventory."
        actions={<Chip tone="gray">{formatNumber(rack.stored)} stored</Chip>}
        flush
      >
        {!detail ? (
          <Loading label="Reading its slots…" />
        ) : (
          <table className="ga-table gr-slots">
            <thead>
              <tr>
                <th>#</th>
                <th>Takes</th>
                <th>Gun</th>
                <th>Serial</th>
                <th>Ammo</th>
                <th>Attachments</th>
                <th>Racked by</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {slots.map(s => (
                <tr key={s.index} className={s.gun ? undefined : 'ga-hu-none'}>
                  <td className="num">{s.index}</td>
                  <td>{s.kindLabel}</td>
                  {s.gun ? (
                    <>
                      <td className="strong">
                        <Tip text={s.gun.name}>
                          <span>{s.gun.label}</span>
                        </Tip>
                      </td>
                      <td className="ga-mono ga-selectable">
                        {s.gun.serial ?? <span className="ga-hu-nil">—</span>}
                      </td>
                      <td className="num">{formatNumber(s.gun.ammo)}</td>
                      <td className="gr-attach">
                        {s.gun.attachments.length > 0
                          ? s.gun.attachments.join(', ')
                          : <span className="ga-hu-nil">—</span>}
                      </td>
                      <td className="ga-hu-when">
                        <Tip text={formatDate(s.gun.at)}>
                          <span>
                            {s.gun.byName ?? s.gun.by ?? 'unknown'} · {formatAgo(s.gun.at)}
                          </span>
                        </Tip>
                      </td>
                      <td className="ga-hu-act">
                        <button
                          type="button"
                          className="ga-btn sm"
                          onClick={() => takeGun(s)}
                          disabled={s.busy || busy === `take:${s.index}`}
                        >
                          Take
                        </button>
                      </td>
                    </>
                  ) : (
                    <td colSpan={6} className="gr-empty-slot">
                      {s.busy ? 'something is being put on it right now' : 'empty'}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Card>

      <Card
        title="Access"
        icon={<ShieldCheck size={12} />}
        note="Who besides its owner and staff may open it while it is locked: jobs and gangs, each from a lowest grade up. An unlocked rack is open to anyone standing at it."
        actions={
          dirty ? (
            <div className="ga-hu-counts">
              <button
                type="button"
                className="ga-btn sm"
                onClick={() => setDraft(null)}
                disabled={busy === 'access'}
              >
                <Undo2 size={12} />
                Revert
              </button>
              <button
                type="button"
                className="ga-btn green sm"
                onClick={saveAccess}
                disabled={busy === 'access'}
              >
                <Save size={12} />
                Save
              </button>
            </div>
          ) : (
            <Chip tone={hasAccess(saved) ? 'purple' : 'gray'}>
              {saved.jobs.length + saved.gangs.length} on the list
            </Chip>
          )
        }
      >
        <AccessEditor value={editing} onChange={setDraft} disabled={busy === 'access'} />
      </Card>

      <Card
        title="Owner"
        icon={<ArrowRightLeft size={12} />}
        note="Give it to a player: their server id while they are on, or their citizen id whether they are on or not. The guns on it stay where they are."
      >
        <div className="gr-inline">
          <input
            className="ga-input"
            value={target}
            maxLength={64}
            spellCheck={false}
            placeholder="Server id or citizen id"
            onChange={e => setTarget(e.target.value)}
            onKeyDown={e => {
              if (e.key === 'Enter') transfer();
            }}
          />
          <button
            type="button"
            className="ga-btn green"
            onClick={transfer}
            disabled={!target.trim() || busy === 'transfer'}
          >
            <ArrowRightLeft size={13} />
            Transfer
          </button>
        </div>
      </Card>

      <Card
        title="History"
        icon={<History size={12} />}
        note="The last things done at this rack, newest first. The Logs tab has the rest."
        actions={<Chip tone="gray">{history?.length ?? 0}</Chip>}
        flush
      >
        {history === null ? (
          <Loading label="Reading its history…" />
        ) : history.length === 0 ? (
          <Empty compact icon={<History size={22} />} title="Nothing logged at it yet" />
        ) : (
          <table className="ga-table ga-lg-table">
            <tbody>
              {history.map(h => (
                <tr key={h.id}>
                  <td className="ga-lg-when">
                    <Tip text={formatDate(h.at)}>
                      <span>{formatAgo(h.at)}</span>
                    </Tip>
                  </td>
                  <td className="ga-lg-who">{h.actor ?? <span className="ga-lg-system">system</span>}</td>
                  <td className="ga-lg-kind">
                    <Chip tone={toneOfKind(h.kind)}>{h.kind}</Chip>
                  </td>
                  <td className="ga-lg-detail ga-selectable">{h.detail}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </Card>
    </>
  );
}
