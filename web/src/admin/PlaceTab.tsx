import { useEffect, useRef, useState } from 'react';
import { Gift, Lock, MousePointer2, ShieldCheck, Warehouse } from 'lucide-react';
import { fetchNui } from '@/nui/bridge';
import type { PlayerRow, RackAccess } from '@/types';
import { AccessEditor, cleanAccess } from './AccessEditor';
import { GiveForm } from './GiveForm';
import { Card, Chip, Empty, MOUNT_WORD, failureOf, isRefused, pictureOf, playersOf } from './shared';
import type { TabProps } from './shared';

const NOBODY: RackAccess = { jobs: [], gangs: [] };

/** How a model's slots read on its card: '8 long guns', '2 long guns · 6 handguns'. */
const slotsText = (kinds: { label: string; count: number }[]): string =>
  kinds.map(k => `${k.count} ${k.label.toLowerCase()}${k.count === 1 ? '' : 's'}`).join(' · ');

export const PlaceTab = ({ catalog, refreshToken, showToast }: TabProps) => {
  const [model, setModel] = useState('');
  const [access, setAccess] = useState<RackAccess>(NOBODY);
  const [locked, setLocked] = useState(true);
  const [busy, setBusy] = useState(false);
  const [players, setPlayers] = useState<PlayerRow[] | null>(null);

  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  useEffect(() => {
    if (!model && catalog.models.length > 0) setModel(catalog.models[0].model);
  }, [catalog.models, model]);

  // Who is on, for the give form.
  useEffect(() => {
    void fetchNui('admin:getPlayers').then(resp => {
      if (!alive.current) return;
      setPlayers(isRefused(resp) ? [] : playersOf(resp.list));
    });
  }, [refreshToken]);

  const picked = catalog.models.find(m => m.model === model);

  const place = async () => {
    if (!picked) return;

    setBusy(true);
    const resp = await fetchNui('admin:place', { model: picked.model, access: cleanAccess(access), locked });

    if (!alive.current) return;

    setBusy(false);

    const failure = failureOf(resp);

    if (failure) return showToast(failure, 'error');

    showToast(`Placing ${picked.label}: the console steps aside until it is down.`, 'info');
  };

  if (catalog.models.length === 0) {
    return (
      <Empty
        title="No rack models came back"
        sub="The catalog is read when the console opens: refresh to try again."
      />
    );
  }

  const listed = cleanAccess(access);
  const onList = listed.jobs.length + listed.gangs.length;

  return (
    <div className="ga-fade-in gr-place">
      <div className="gr-place-models">
        <Card
          title="Rack"
          icon={<Warehouse size={12} />}
          note="A staff rack belongs to nobody and takes no item. It never counts against anybody's limit."
          actions={<Chip tone="gray">{catalog.models.length} models</Chip>}
        >
          <div className="gr-models">
            {catalog.models.map(m => (
              <button
                key={m.model}
                type="button"
                className={`gr-model${m.model === model ? ' on' : ''}`}
                onClick={() => setModel(m.model)}
              >
                <img src={pictureOf(m.item)} alt="" />
                <span className="gr-model-name">{m.label}</span>
                <span className="gr-model-meta">
                  {MOUNT_WORD[m.mount]} · {slotsText(m.kinds) || `${m.slots} slots`}
                </span>
              </button>
            ))}
          </div>
        </Card>
      </div>

      <div className="gr-place-side">
        <Card
          title="Who may open it"
          icon={<ShieldCheck size={12} />}
          note="Besides staff. Leave both lists empty for a rack only staff open while it is locked; an armoury takes a job from a grade up."
        >
          <AccessEditor value={access} onChange={setAccess} disabled={busy} />
          <label className="ga-check">
            <input type="checkbox" checked={locked} onChange={e => setLocked(e.target.checked)} />
            <span className="ga-check-box" />
            <span>
              Locked
              <span className="ga-check-note">Unlocked, anyone standing at it may use it whatever the lists say.</span>
            </span>
          </label>
        </Card>

        <Card title="Put it down" icon={<MousePointer2 size={12} />}>
          <p className="gr-place-blurb">
            The console steps aside and a see-through {picked?.label ?? 'rack'} starts where you look
            {picked?.mount === 'wall' ? ', flat against the wall' : ', on the ground'}. Move it with the gizmo, Alt
            puts it back {picked?.mount === 'wall' ? 'flat on the wall' : 'on the floor'}, Enter places it and
            Backspace puts it away. The console comes back either way.
          </p>
          <div className="gr-place-go">
            <span className="gr-place-what">
              {picked ? (
                <>
                  <b>{picked.label}</b> · {locked ? <Lock size={11} /> : null} {locked ? 'locked' : 'open'} ·{' '}
                  {onList > 0 ? `${onList} on its list` : 'staff only'}
                </>
              ) : (
                'Pick a rack'
              )}
            </span>
            <button
              type="button"
              className="ga-btn green"
              onClick={() => void place()}
              disabled={!picked || busy}
            >
              <MousePointer2 size={13} />
              Place it
            </button>
          </div>
        </Card>

        <Card
          title="Give a rack item"
          icon={<Gift size={12} />}
          note="The item a player uses to put a rack down themselves. Theirs once it is down, and it counts against their limit."
        >
          <GiveForm catalog={catalog} players={players} showToast={showToast} />
        </Card>
      </div>
    </div>
  );
};
