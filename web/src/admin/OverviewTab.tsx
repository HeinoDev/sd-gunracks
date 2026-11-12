import { useEffect, useState } from 'react';
import { Boxes, Crosshair, Lock, ScrollText, Shield, User, Warehouse, WifiOff } from 'lucide-react';
import { fetchNui } from '@/nui/bridge';
import { listOf, numOf } from '@/nui/wire';
import type { LogRow, Overview } from '@/types';
import {
  Card,
  Chip,
  Empty,
  Loading,
  StatTile,
  failureOf,
  formatAgo,
  formatNumber,
  isRefused,
  toneOfKind,
  useNow,
} from './shared';
import type { TabProps } from './shared';

const DEFAULT_POLL_MS = 10_000;

const share = (part: number, whole: number): number =>
  whole > 0 ? Math.round((part / whole) * 100) : 0;

const overviewOf = (raw: Overview): Overview => ({
  racks: numOf(raw.racks),
  guns: numOf(raw.guns),
  slots: numOf(raw.slots),
  locked: numOf(raw.locked),
  open: numOf(raw.open),
  staff: numOf(raw.staff),
  restricted: numOf(raw.restricted),
  owners: numOf(raw.owners),
  buckets: numOf(raw.buckets),
  online: numOf(raw.online),
  byModel: listOf<Overview['byModel'][number]>(raw.byModel).map(m => ({
    ...m,
    count: numOf(m.count),
    guns: numOf(m.guns),
    slots: numOf(m.slots),
  })),
  recent: listOf<LogRow>(raw.recent),
});

export const OverviewTab = ({ pollMs, refreshToken, openRack }: TabProps) => {
  const period = pollMs.overview ?? DEFAULT_POLL_MS;

  const [overview, setOverview] = useState<Overview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [fetchedAt, setFetchedAt] = useState(0);
  const now = useNow();

  useEffect(() => {
    let cancelled = false;

    const load = async () => {
      const resp = await fetchNui('admin:getOverview');
      if (cancelled) return;

      if (isRefused(resp)) {
        setError(failureOf(resp) ?? 'The server sent nothing back.');
        return;
      }

      setOverview(overviewOf(resp));
      setFetchedAt(Math.floor(Date.now() / 1000));
      setError(null);
    };

    void load();
    const poll = window.setInterval(() => void load(), period);

    return () => {
      cancelled = true;
      window.clearInterval(poll);
    };
  }, [period, refreshToken]);

  if (!overview) {
    if (error) return <Empty error title="Couldn't read the racks" sub={error} />;
    return <Loading label="Reading the racks…" />;
  }

  const age = Math.max(0, now - fetchedAt);
  const modelMax = Math.max(1, ...overview.byModel.map(m => m.count));
  const players = overview.racks - overview.staff;
  const buckets = overview.buckets === 1 ? 'bucket' : 'buckets';

  return (
    <div className="ga-fade-in">
      <div className="ga-toolbar">
        <div className="ga-section-label ga-ov-heading">Right now</div>
        <div className="ga-toolbar-spacer" />
        <div className="ga-ov-poll-line">
          <span className={`ga-ov-dot${error ? ' stale' : ''}`} />
          {error ? 'Poll failed' : age < 2 ? 'Updated just now' : `Updated ${age}s ago`}
        </div>
        <span className="ga-toolbar-hint">every {Math.round(period / 1000)}s</span>
      </div>

      {error && (
        <div className="ga-ov-note bad">
          <WifiOff size={13} />
          <span>
            The last poll failed — {error} The figures below are {age}s old and will not move until
            a poll succeeds.
          </span>
        </div>
      )}

      <div className="ga-stat-grid cols-5">
        <StatTile
          icon={<Warehouse size={11} />}
          label="Racks"
          value={formatNumber(overview.racks)}
          sub={`${formatNumber(players)} players' · ${formatNumber(overview.staff)} staff`}
        />
        <StatTile
          icon={<Crosshair size={11} />}
          label="Guns stored"
          value={formatNumber(overview.guns)}
          sub={`of ${formatNumber(overview.slots)} slots · ${share(overview.guns, overview.slots)}% full`}
        />
        <StatTile
          icon={<Lock size={11} />}
          label="Locked"
          value={formatNumber(overview.locked)}
          sub={`${formatNumber(overview.open)} open to anyone at them`}
        />
        <StatTile
          icon={<Shield size={11} />}
          label="Staff racks"
          value={formatNumber(overview.staff)}
          sub={`${formatNumber(overview.restricted)} with job or gang access`}
        />
        <StatTile
          icon={<User size={11} />}
          label="Owners"
          value={formatNumber(overview.owners)}
          sub={`${formatNumber(overview.online)} on the server · ${formatNumber(overview.buckets)} ${buckets}`}
        />
      </div>

      <div className="ga-two-col">
        <Card
          title="Racks by model"
          icon={<Boxes size={12} />}
          note="How many of each rack stand, most first, and how full they are between them."
          actions={<Chip tone="gray">{formatNumber(overview.racks)} racks</Chip>}
        >
          {overview.byModel.length === 0 ? (
            <Empty
              compact
              icon={<Boxes size={22} />}
              title="No racks yet"
              sub="Nobody has put a rack down, and staff have placed none."
            />
          ) : (
            <div className="ga-ov-bars">
              {overview.byModel.map((m, i) => (
                <div key={m.model} className="ga-ov-bar-row">
                  <span className={`ga-ov-bar-rank${i === 0 ? ' lead' : ''}`}>#{i + 1}</span>
                  <div className="ga-ov-bar-name">{m.label || m.model}</div>
                  <div className="ga-ov-bar-track">
                    <div
                      className="ga-ov-bar-fill"
                      // A model with one rack still gets a sliver, or it reads as none at all.
                      style={{ width: `${m.count > 0 ? Math.max((m.count / modelMax) * 100, 2) : 0}%` }}
                    />
                  </div>
                  <div className="ga-ov-bar-value">
                    {formatNumber(m.count)}
                    <span className="share">{share(m.guns, m.slots)}% full</span>
                  </div>
                </div>
              ))}
            </div>
          )}
        </Card>

        <Card title="Recent activity" icon={<ScrollText size={12} />} flush>
          {overview.recent.length === 0 ? (
            <Empty
              compact
              icon={<ScrollText size={22} />}
              title="Nothing logged yet"
              sub="Racks placed, guns racked and taken, locks forced and staff actions show up here as they happen."
            />
          ) : (
            <div className="ga-ov-recent">
              {overview.recent.map((row, index) => (
                <div
                  key={`${row.id}-${index}`}
                  className={`ga-ov-recent-row${row.rack ? ' gr-link' : ''}`}
                  onClick={row.rack ? () => openRack(row.rack as number) : undefined}
                >
                  <span className="ga-ov-recent-when">{formatAgo(row.at)}</span>
                  <Chip tone={toneOfKind(row.kind)}>{row.kind}</Chip>
                  <span className="ga-ov-recent-detail ga-selectable">
                    <b>{row.actor ?? 'system'}</b> {row.detail}
                  </span>
                </div>
              ))}
            </div>
          )}
        </Card>
      </div>
    </div>
  );
};
