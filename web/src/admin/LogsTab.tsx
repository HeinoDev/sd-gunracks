import { useCallback, useEffect, useRef, useState } from 'react';
import { ChevronLeft, ChevronRight, RefreshCw, ScrollText, Search, X } from 'lucide-react';
import { fetchNui } from '@/nui/bridge';
import { listOf, numOf, strOrNull } from '@/nui/wire';
import type { LogPage, LogRow } from '@/types';
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
  toneOfKind,
} from './shared';
import type { TabProps } from './shared';

const DEFAULT_POLL_MS = 15_000;

/** Rows a page: the server takes 10 to 100. */
const PAGE_SIZE = 50;

/** How long typing has to pause before the search is sent. */
const TYPE_PAUSE_MS = 300;

const pageOf = (raw: LogPage): LogPage => ({
  list: listOf<LogRow>(raw.list).map(r => ({
    ...r,
    id: numOf(r.id),
    at: numOf(r.at),
    kind: strOrNull(r.kind) ?? '?',
    actor: strOrNull(r.actor) ?? undefined,
    rack: numOf(r.rack, 0) || undefined,
    detail: strOrNull(r.detail) ?? '',
  })),
  total: numOf(raw.total),
  page: Math.max(1, numOf(raw.page, 1)),
  size: Math.max(1, numOf(raw.size, PAGE_SIZE)),
  pages: Math.max(1, numOf(raw.pages, 1)),
  kinds: listOf<{ kind: string; count: number }>(raw.kinds)
    .filter(k => typeof k.kind === 'string')
    .map(k => ({ kind: k.kind, count: numOf(k.count) })),
});

/**
 * The Logs tab, paged on the server: the log is a table that grows with every rack used, so the
 * search, the kind and the page are the server's to apply, and only one page ever comes back.
 */
export const LogsTab = ({ pollMs, refreshToken, showToast, openRack }: TabProps) => {
  const period = pollMs.logs ?? DEFAULT_POLL_MS;

  const [data, setData] = useState<LogPage | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  const [kind, setKind] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const [sent, setSent] = useState('');
  const [page, setPage] = useState(1);

  // Nothing reads this. Bumping it on every poll re-renders the "4m ago" column even when the log
  // itself came back unchanged.
  const [, setTick] = useState(0);

  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  useEffect(() => {
    const timer = window.setTimeout(() => {
      setSent(query.trim());
      setPage(1);
    }, TYPE_PAUSE_MS);
    return () => window.clearTimeout(timer);
  }, [query]);

  const load = useCallback(
    async (manual = false) => {
      if (manual) setRefreshing(true);

      const resp = await fetchNui('admin:getLogs', {
        page,
        size: PAGE_SIZE,
        kind: kind ?? undefined,
        q: sent || undefined,
      });

      if (!alive.current) return;

      if (manual) setRefreshing(false);

      if (isRefused(resp)) {
        const message = failureOf(resp) ?? 'The server sent nothing back.';
        setError(message);
        if (manual) showToast(message, 'error');
        return;
      }

      setError(null);
      setData(pageOf(resp));
    },
    [page, kind, sent, showToast],
  );

  // Only the newest page moves by itself: an older one would shift under the reader as rows come in.
  useEffect(() => {
    void load();

    if (page !== 1) return;

    const timer = window.setInterval(() => {
      setTick(n => n + 1);
      void load();
    }, period);

    return () => window.clearInterval(timer);
  }, [load, period, refreshToken, page]);

  const pick = (next: string | null) => {
    setKind(next);
    setPage(1);
  };

  if (error && data === null) {
    return <Empty title="The action log could not be read" sub={error} error />;
  }

  if (data === null) return <Loading label="Reading the action log…" />;

  const all = data.kinds.reduce((sum, k) => sum + k.count, 0);
  const kinds = data.kinds.map(k => k.kind);

  // A filter with no rows left keeps its pill, or there would be no way to see which filter is
  // hiding everything.
  if (kind && !kinds.includes(kind)) kinds.push(kind);

  const first = data.total === 0 ? 0 : (data.page - 1) * data.size + 1;
  const last = Math.min(data.total, data.page * data.size);

  return (
    <div className="ga-fade-in">
      <div className="ga-toolbar">
        <div className="ga-search ga-lg-search">
          <Search size={14} />
          <input
            value={query}
            onChange={e => setQuery(e.target.value)}
            placeholder="Search who or what…"
            spellCheck={false}
          />
          {query && (
            <button type="button" className="ga-search-clear" onClick={() => setQuery('')}>
              <X size={13} />
            </button>
          )}
        </div>

        <div className="ga-toolbar-spacer" />

        <span className="ga-toolbar-hint">
          {page === 1 ? `refreshes every ${Math.round(period / 1000)}s` : 'paused on an older page'}
        </span>
        <button type="button" className="ga-btn" onClick={() => void load(true)} disabled={refreshing}>
          <RefreshCw size={11} className={refreshing ? 'ga-spin' : undefined} />
          Refresh
        </button>
      </div>

      <div className="ga-filter-row ga-lg-filters">
        <button
          type="button"
          className={`ga-filter-pill${kind === null ? ' active' : ''}`}
          onClick={() => pick(null)}
        >
          All {formatNumber(all)}
        </button>
        {kinds.map(name => (
          <button
            key={name}
            type="button"
            className={`ga-filter-pill${kind === name ? ' active' : ''}`}
            onClick={() => pick(name)}
          >
            {name} {formatNumber(data.kinds.find(k => k.kind === name)?.count ?? 0)}
          </button>
        ))}
      </div>

      {error && (
        <Stale>
          Last refresh failed — {error} Showing the last page that came back, which may be behind.
        </Stale>
      )}

      <Card
        title="Action log"
        icon={<ScrollText size={12} />}
        note="Newest first. A row with nobody against it was written by the resource itself or by another resource through an export."
        actions={<Chip tone="gray">{formatNumber(data.total)} rows</Chip>}
        flush
      >
        {data.list.length === 0 ? (
          <Empty
            compact
            icon={<ScrollText size={22} />}
            title={
              sent ? 'Nothing matches that search' : kind ? `No ${kind} rows on record` : 'Nothing has been logged yet'
            }
            sub={
              sent || kind
                ? 'Clear the search or pick another kind.'
                : 'Put a rack down, rack a gun or take one, and it will appear here.'
            }
          />
        ) : (
          <>
            <table className="ga-table ga-lg-table">
              <thead>
                <tr>
                  <th>When</th>
                  <th>Who</th>
                  <th>Kind</th>
                  <th>Rack</th>
                  <th>Detail</th>
                </tr>
              </thead>
              <tbody>
                {data.list.map((row, index) => (
                  <tr key={`${row.id}-${index}`}>
                    <td className="ga-lg-when">
                      <Tip text={formatDate(row.at)}>
                        <span>{formatAgo(row.at)}</span>
                      </Tip>
                    </td>
                    <td className="ga-lg-who ga-selectable">
                      {row.actor ?? <span className="ga-lg-system">system</span>}
                    </td>
                    <td className="ga-lg-kind">
                      <Chip tone={toneOfKind(row.kind)}>{row.kind}</Chip>
                    </td>
                    <td className="gr-log-rack">
                      {row.rack ? (
                        <button
                          type="button"
                          className="gr-rack-link"
                          onClick={() => openRack(row.rack as number)}
                        >
                          #{row.rack}
                        </button>
                      ) : (
                        <span className="ga-hu-nil">—</span>
                      )}
                    </td>
                    <td className="ga-lg-detail ga-selectable">{row.detail}</td>
                  </tr>
                ))}
              </tbody>
            </table>

            <div className="gr-pager">
              <span className="gr-pager-count">
                {formatNumber(first)}–{formatNumber(last)} of {formatNumber(data.total)}
              </span>
              <div className="ga-toolbar-spacer" />
              <span className="gr-pager-page">
                page {data.page} of {data.pages}
              </span>
              <button
                type="button"
                className="ga-btn sm"
                onClick={() => setPage(p => Math.max(1, p - 1))}
                disabled={data.page <= 1}
              >
                <ChevronLeft size={12} />
                Newer
              </button>
              <button
                type="button"
                className="ga-btn sm"
                onClick={() => setPage(p => Math.min(data.pages, p + 1))}
                disabled={data.page >= data.pages}
              >
                Older
                <ChevronRight size={12} />
              </button>
            </div>
          </>
        )}
      </Card>
    </div>
  );
};
