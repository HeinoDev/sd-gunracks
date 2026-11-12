import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Crosshair, Gift, Navigation, Search, Users, Warehouse, X } from 'lucide-react';
import { fetchNui } from '@/nui/bridge';
import type { PlayerRow, RackRow } from '@/types';
import { GiveForm } from './GiveForm';
import {
  Avatar,
  Card,
  Chip,
  Empty,
  Loading,
  Stale,
  StatTile,
  Tip,
  failureOf,
  formatNumber,
  isRefused,
  playersOf,
  rackName,
  whereOf,
} from './shared';
import type { TabProps } from './shared';

const DEFAULT_POLL_MS = 8000;

/** A job or gang with its grade, as a few words: 'police 2'. */
const groupText = (name: string | undefined, grade: number) => (name ? `${name} ${grade}` : null);

export const PlayersTab = ({ catalog, pollMs, refreshToken, showToast, openRack }: TabProps) => {
  const period = pollMs.players ?? DEFAULT_POLL_MS;

  const [rows, setRows] = useState<PlayerRow[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [picked, setPicked] = useState<number | null>(null);

  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  const load = useCallback(async () => {
    const resp = await fetchNui('admin:getPlayers');

    if (!alive.current) return;

    if (isRefused(resp)) {
      setError(failureOf(resp) ?? 'The server sent nothing back.');
      return;
    }

    setError(null);
    setRows(playersOf(resp.list));
  }, []);

  useEffect(() => {
    void load();
    const timer = window.setInterval(() => void load(), period);

    return () => window.clearInterval(timer);
  }, [load, period, refreshToken]);

  const list = useMemo(() => rows ?? [], [rows]);

  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();

    if (!q) return list;

    return list.filter(
      p =>
        p.name.toLowerCase().includes(q) ||
        p.username.toLowerCase().includes(q) ||
        (p.cid ?? '').toLowerCase().includes(q) ||
        String(p.src) === q.replace(/^#/, ''),
    );
  }, [list, query]);

  const goTo = useCallback(
    async (r: RackRow) => {
      const resp = await fetchNui('admin:teleport', { rackId: r.id });
      const failure = failureOf(resp);

      if (failure) return showToast(failure, 'error');

      showToast(`Gone to ${rackName(r)}.`, 'success');
    },
    [showToast],
  );

  if (error && rows === null) {
    return <Empty title="The players could not be read" sub={error} error />;
  }

  if (rows === null) return <Loading label="Reading who is on…" />;

  const owning = list.filter(p => p.racks.length > 0).length;
  const player = picked !== null ? list.find(p => p.src === picked) ?? null : null;

  return (
    <div className={`ga-hu-root${player ? ' picked' : ''}`}>
      <div className="ga-toolbar">
        <div className="ga-search">
          <Search size={14} />
          <input
            value={query}
            onChange={e => setQuery(e.target.value)}
            placeholder="Search name, #id or citizen id…"
            spellCheck={false}
          />
          {query && (
            <button type="button" className="ga-search-clear" onClick={() => setQuery('')}>
              <X size={13} />
            </button>
          )}
        </div>
        <div className="ga-toolbar-spacer" />
        <span className="ga-toolbar-hint">refreshes every {Math.round(period / 1000)}s</span>
      </div>

      {error && <Stale>Last refresh failed — {error} Showing the last list that came back.</Stale>}

      <div className="ga-hu-body">
        <div className="ga-hu-list ga-scroll">
          <Card
            title="On the server"
            icon={<Users size={12} />}
            actions={
              <div className="ga-hu-counts">
                <Chip tone={list.length > 0 ? 'green' : 'gray'}>{list.length} on</Chip>
                <Chip tone={owning > 0 ? 'blue' : 'gray'}>{owning} own racks</Chip>
              </div>
            }
            flush
          >
            {shown.length === 0 ? (
              <Empty
                compact
                icon={<Users size={22} />}
                title={list.length === 0 ? 'Nobody is on' : 'Nothing matches'}
                sub={
                  list.length === 0
                    ? 'Players show up here while they are on the server.'
                    : 'Clear the search to see everybody.'
                }
              />
            ) : (
              <table className="ga-table ga-hu-table">
                <thead>
                  <tr>
                    <th>Player</th>
                    <th className="ga-hu-wide">Citizen id</th>
                    <th className="ga-hu-wide">Job</th>
                    <th className="ga-hu-wide">Gang</th>
                    <th>Racks</th>
                    <th>Guns</th>
                  </tr>
                </thead>
                <tbody>
                  {shown.map(p => (
                    <tr
                      key={p.src}
                      className={picked === p.src ? 'picked' : undefined}
                      tabIndex={0}
                      onClick={() => setPicked(picked === p.src ? null : p.src)}
                      onKeyDown={e => {
                        if (e.key === 'Enter') setPicked(p.src);
                      }}
                    >
                      <td>
                        <span className="ga-hu-name">
                          <span className="ga-hu-dot online" />
                          <span className="ga-truncate">{p.name}</span>
                          <span className="ga-hu-src">#{p.src}</span>
                        </span>
                      </td>
                      <td className="ga-hu-wide ga-hu-cid ga-selectable">
                        {p.cid ?? <span className="ga-hu-nil">—</span>}
                      </td>
                      <td className="ga-hu-wide">
                        {groupText(p.job, p.jobGrade) ?? <span className="ga-hu-nil">—</span>}
                      </td>
                      <td className="ga-hu-wide">
                        {groupText(p.gang, p.gangGrade) ?? <span className="ga-hu-nil">—</span>}
                      </td>
                      <td className="num">
                        {p.racks.length > 0 ? formatNumber(p.racks.length) : <span className="ga-hu-nil">—</span>}
                      </td>
                      <td className="num">{p.guns > 0 ? formatNumber(p.guns) : <span className="ga-hu-nil">—</span>}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            )}
          </Card>
        </div>

        {player && (
          <div className="ga-hu-detail ga-scroll">
            <div className="ga-hu-head">
              <Avatar name={player.name} online large />
              <div className="ga-hu-head-main">
                <div className="ga-detail-title">
                  <h2>{player.name}</h2>
                  <Chip tone="green">on · #{player.src}</Chip>
                  {player.job && <Chip tone="gray">{groupText(player.job, player.jobGrade)}</Chip>}
                  {player.gang && <Chip tone="purple">{groupText(player.gang, player.gangGrade)}</Chip>}
                </div>
                <div className="ga-detail-sub">
                  {player.username}
                  {player.cid && (
                    <>
                      {' · '}
                      <span className="ga-mono ga-selectable">{player.cid}</span>
                    </>
                  )}
                </div>
              </div>
              <button
                type="button"
                className="ga-icon-btn"
                onClick={() => setPicked(null)}
                title="Close this player"
              >
                <X size={14} />
              </button>
            </div>

            <div className="ga-stat-grid gr-stats-3">
              <StatTile
                icon={<Warehouse size={11} />}
                label="Racks"
                value={formatNumber(player.racks.length)}
                sub="theirs, all buckets"
              />
              <StatTile icon={<Crosshair size={11} />} label="Guns" value={formatNumber(player.guns)} sub="on their racks" />
              <StatTile
                icon={<Crosshair size={11} />}
                label="Free slots"
                value={formatNumber(player.racks.reduce((sum, r) => sum + Math.max(0, r.slots - r.stored), 0))}
                sub="across their racks"
              />
            </div>

            <Card
              title="Their racks"
              icon={<Warehouse size={12} />}
              note="Click one to open it in the Racks tab."
              actions={<Chip tone="gray">{player.racks.length}</Chip>}
              flush
            >
              {player.racks.length === 0 ? (
                <Empty compact icon={<Warehouse size={22} />} title="No racks" sub="They have not put a rack down." />
              ) : (
                <table className="ga-table ga-hu-table">
                  <thead>
                    <tr>
                      <th>Rack</th>
                      <th>Where</th>
                      <th>Lock</th>
                      <th>Guns</th>
                      <th />
                    </tr>
                  </thead>
                  <tbody>
                    {player.racks.map(r => (
                      <tr key={r.id} tabIndex={0} onClick={() => openRack(r.id)}>
                        <td>
                          <span className="ga-hu-name">
                            <span className="ga-truncate">{r.label}</span>
                            <span className="ga-hu-src">#{r.id}</span>
                          </span>
                        </td>
                        <td className="gr-where">
                          <span className="ga-truncate">{whereOf(r)}</span>
                        </td>
                        <td>
                          <Chip tone={r.locked ? 'amber' : 'green'}>{r.locked ? 'locked' : 'open'}</Chip>
                        </td>
                        <td className="num">
                          {formatNumber(r.stored)}/{formatNumber(r.slots)}
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

            <Card
              title="Give a rack item"
              icon={<Gift size={12} />}
              note="Straight into their inventory. They place it themselves, and it counts against their limit."
            >
              <GiveForm catalog={catalog} to={player} showToast={showToast} />
            </Card>
          </div>
        )}
      </div>
    </div>
  );
};
