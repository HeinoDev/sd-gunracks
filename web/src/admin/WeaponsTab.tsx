import { useCallback, useEffect, useRef, useState } from 'react';
import { Crosshair, RefreshCw, Search, X } from 'lucide-react';
import { fetchNui } from '@/nui/bridge';
import { listOf, mapOf, numOf, strOrNull } from '@/nui/wire';
import type { WeaponField, WeaponHit } from '@/types';
import { Dropdown } from './Dropdown';
import {
  Card,
  Chip,
  Empty,
  Loading,
  Stale,
  Tip,
  failureOf,
  formatAgo,
  formatDate,
  formatNumber,
  isRefused,
  whereOf,
} from './shared';
import type { TabProps } from './shared';

/** How long typing has to pause before the search is sent: one search per word, not per key. */
const TYPE_PAUSE_MS = 300;

const FIELDS: { value: WeaponField; label: string }[] = [
  { value: 'any', label: 'Anything' },
  { value: 'weapon', label: 'Weapon' },
  { value: 'serial', label: 'Serial' },
  { value: 'owner', label: 'Rack owner' },
  { value: 'by', label: 'Racked by' },
];

const hitOf = (raw: unknown): WeaponHit | null => {
  const h = mapOf<unknown>(raw);
  const rackId = numOf(h.rackId, NaN);

  if (!Number.isFinite(rackId)) return null;

  const name = strOrNull(h.name) ?? '?';

  return {
    rackId,
    rackLabel: strOrNull(h.rackLabel) ?? `Rack #${rackId}`,
    model: strOrNull(h.model) ?? '',
    slot: numOf(h.slot),
    name,
    label: strOrNull(h.label) ?? name,
    serial: strOrNull(h.serial) ?? undefined,
    ammo: numOf(h.ammo),
    owner: strOrNull(h.owner) ?? undefined,
    ownerName: strOrNull(h.ownerName) ?? undefined,
    by: strOrNull(h.by) ?? undefined,
    byName: strOrNull(h.byName) ?? undefined,
    at: numOf(h.at),
    bucket: numOf(h.bucket),
    x: numOf(h.x),
    y: numOf(h.y),
    z: numOf(h.z),
    street: strOrNull(h.street) ?? undefined,
    zone: strOrNull(h.zone) ?? undefined,
  };
};

export const WeaponsTab = ({ refreshToken, racks, showToast, openRack }: TabProps) => {
  const [query, setQuery] = useState('');
  const [field, setField] = useState<WeaponField>('any');
  // What was last sent: the box is debounced, the field dropdown is not.
  const [sent, setSent] = useState('');

  const [hits, setHits] = useState<WeaponHit[] | null>(null);
  const [total, setTotal] = useState(0);
  const [capped, setCapped] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => setSent(query.trim()), TYPE_PAUSE_MS);
    return () => window.clearTimeout(timer);
  }, [query]);

  const load = useCallback(
    async (manual = false) => {
      if (manual) setRefreshing(true);

      const resp = await fetchNui('admin:searchWeapons', { q: sent, field });

      if (!alive.current) return;

      if (manual) setRefreshing(false);

      if (isRefused(resp)) {
        const message = failureOf(resp) ?? 'The server sent nothing back.';
        setError(message);
        if (manual) showToast(message, 'error');
        return;
      }

      setError(null);
      setHits(
        listOf<unknown>(resp.list).flatMap(h => {
          const hit = hitOf(h);
          return hit ? [hit] : [];
        }),
      );
      setTotal(numOf(resp.total));
      setCapped(resp.capped === true);
    },
    [sent, field, showToast],
  );

  // Read again whenever the racks move (a gun racked or taken changes the answer), and on Refresh.
  const stored = racks.reduce((sum, r) => sum + r.stored, 0);
  useEffect(() => {
    void load();
  }, [load, refreshToken, stored]);

  if (error && hits === null) return <Empty title="The stored guns could not be read" sub={error} error />;

  return (
    <div className="ga-fade-in">
      <div className="ga-toolbar">
        <div className="ga-search ga-lg-search">
          <Search size={14} />
          <input
            value={query}
            onChange={e => setQuery(e.target.value)}
            placeholder="Search a weapon, a serial, an owner or who racked it…"
            spellCheck={false}
          />
          {query && (
            <button type="button" className="ga-search-clear" onClick={() => setQuery('')}>
              <X size={13} />
            </button>
          )}
        </div>
        <Dropdown
          ariaLabel="Search in"
          className="gr-field-pick"
          value={field}
          onChange={value => setField(value as WeaponField)}
          options={FIELDS}
        />

        <div className="ga-toolbar-spacer" />

        <span className="ga-toolbar-hint">
          {sent
            ? `${formatNumber(total)} match${total === 1 ? '' : 'es'}`
            : `${formatNumber(total)} stored on the server`}
        </span>
        <button type="button" className="ga-btn" onClick={() => void load(true)} disabled={refreshing}>
          <RefreshCw size={11} className={refreshing ? 'ga-spin' : undefined} />
          Refresh
        </button>
      </div>

      {error && <Stale>Last search failed — {error} Showing the last answer that came back.</Stale>}

      {hits === null ? (
        <Loading label="Reading the stored guns…" />
      ) : (
        <Card
          title="Stored guns"
          icon={<Crosshair size={12} />}
          note={
            capped
              ? `The first ${hits.length} of ${total}, newest racked first. Narrow the search to see the rest.`
              : 'Newest racked first. Click one to open its rack.'
          }
          actions={<Chip tone="gray">{hits.length} shown</Chip>}
          flush
        >
          {hits.length === 0 ? (
            <Empty
              compact
              icon={<Crosshair size={22} />}
              title={sent ? 'Nothing matches that search' : 'No guns on any rack'}
              sub={
                sent
                  ? 'Try another word, or search in Anything.'
                  : 'Guns show up here as soon as somebody racks one.'
              }
            />
          ) : (
            <table className="ga-table ga-hu-table">
              <thead>
                <tr>
                  <th>Weapon</th>
                  <th>Serial</th>
                  <th>Ammo</th>
                  <th>Rack</th>
                  <th>Owner</th>
                  <th>Racked by</th>
                  <th>When</th>
                </tr>
              </thead>
              <tbody>
                {hits.map(h => (
                  <tr key={`${h.rackId}:${h.slot}`} tabIndex={0} onClick={() => openRack(h.rackId)}>
                    <td className="strong">
                      <Tip text={h.name}>
                        <span>{h.label}</span>
                      </Tip>
                    </td>
                    <td className="ga-mono ga-selectable">{h.serial ?? <span className="ga-hu-nil">—</span>}</td>
                    <td className="num">{formatNumber(h.ammo)}</td>
                    <td>
                      <Tip text={`${whereOf(h)} · bucket ${h.bucket} · slot ${h.slot}`}>
                        <span className="ga-hu-name">
                          <span className="ga-truncate">{h.rackLabel}</span>
                          <span className="ga-hu-src">#{h.rackId}</span>
                        </span>
                      </Tip>
                    </td>
                    <td>{h.owner ? h.ownerName ?? h.owner : <Chip tone="blue">staff</Chip>}</td>
                    <td>{h.byName ?? h.by ?? <span className="ga-hu-nil">—</span>}</td>
                    <td className="ga-hu-when">
                      <Tip text={formatDate(h.at)}>
                        <span>{formatAgo(h.at)}</span>
                      </Tip>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Card>
      )}
    </div>
  );
};
