import { useEffect, useState } from 'react';
import { Gift, Minus, Plus } from 'lucide-react';
import { fetchNui } from '@/nui/bridge';
import type { Catalog, PlayerRow, ToastType } from '@/types';
import { Dropdown } from './Dropdown';
import { failureOf } from './shared';

/**
 * Hand a player rack items: which player (picked from who is on, or the one already open), which rack,
 * how many. The server caps the count (configs/server/admin.lua MaxGive) and checks they can carry it.
 */
export const GiveForm = ({
  catalog,
  players,
  to,
  showToast,
}: {
  catalog: Catalog;
  /** Who is on, to pick from. Left out when `to` names the player. */
  players?: PlayerRow[] | null;
  to?: PlayerRow;
  showToast: (message: string, type?: ToastType) => void;
}) => {
  const [target, setTarget] = useState(to ? String(to.src) : '');
  const [item, setItem] = useState('');
  const [count, setCount] = useState(1);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    if (to) setTarget(String(to.src));
  }, [to]);

  // The first rack in the list until staff pick one, once the catalog has come back.
  useEffect(() => {
    if (!item && catalog.models.length > 0) setItem(catalog.models[0].item);
  }, [catalog.models, item]);

  const most = catalog.maxGive;
  const clamp = (n: number) => setCount(Math.min(most, Math.max(1, Math.round(n) || 1)));

  const give = async () => {
    const src = Number(target);

    if (!Number.isInteger(src) || src <= 0 || !item) return;

    setBusy(true);
    const resp = await fetchNui('admin:giveItem', { target: src, item, count });
    setBusy(false);

    const failure = failureOf(resp);

    if (failure) return showToast(failure, 'error');

    const who = resp?.targetName ?? `player ${src}`;
    showToast(`Gave ${resp?.count ?? count}x ${resp?.label ?? item} to ${who}.`, 'success');
  };

  return (
    <div className="gr-give">
      {!to && (
        <div className="gr-give-who">
          <label className="ga-field-label">Player</label>
          <Dropdown
            ariaLabel="Player to give to"
            value={target}
            placeholder={players === null ? 'Reading who is on…' : 'Pick a player…'}
            disabled={!players || players.length === 0}
            onChange={setTarget}
            options={(players ?? []).map(p => ({ value: String(p.src), label: p.name, meta: `#${p.src}` }))}
          />
        </div>
      )}

      <div className="gr-give-what">
        <label className="ga-field-label">Rack</label>
        <Dropdown
          ariaLabel="Rack item to give"
          value={item}
          placeholder="Rack…"
          disabled={catalog.models.length === 0}
          onChange={setItem}
          options={catalog.models.map(m => ({ value: m.item, label: m.label, meta: `${m.slots} slots` }))}
        />
      </div>

      <div className="gr-give-count">
        <label className="ga-field-label">Amount</label>
        <div className="gr-stepper">
          <button
            type="button"
            className="ga-btn"
            onClick={() => clamp(count - 1)}
            disabled={count <= 1}
            aria-label="One fewer"
          >
            <Minus size={13} />
          </button>
          <input
            className="ga-input ga-mono"
            type="number"
            min={1}
            max={most}
            value={count}
            onChange={e => clamp(Number(e.target.value))}
          />
          <button
            type="button"
            className="ga-btn"
            onClick={() => clamp(count + 1)}
            disabled={count >= most}
            aria-label="One more"
          >
            <Plus size={13} />
          </button>
        </div>
      </div>

      <button
        type="button"
        className="ga-btn green gr-give-btn"
        onClick={() => void give()}
        disabled={busy || !target || !item}
      >
        <Gift size={13} />
        Give
      </button>
    </div>
  );
};
