import '@fontsource/inter/400.css';
import '@fontsource/inter/500.css';
import '@fontsource/inter/600.css';
import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { Crosshair, LayoutDashboard, PlusSquare, RefreshCw, ScrollText, Users, Warehouse, X } from 'lucide-react';
import { fetchNui } from '@/nui/bridge';
import { mapOf } from '@/nui/wire';
import { useNuiEvent } from '@/hooks/useNuiEvent';
import type { AdminOpenPayload, AdminPerms, AdminPollMs, Catalog, ConfirmSpec, RackRow, ToastType } from '@/types';
import { ConfirmDialog, EMPTY_CATALOG, catalogOf, isRefused, racksOf } from './shared';
import type { TabProps } from './shared';
import { ErrorBoundary } from './ErrorBoundary';
import { OverviewTab } from './OverviewTab';
import { RacksTab } from './RacksTab';
import { WeaponsTab } from './WeaponsTab';
import { PlaceTab } from './PlaceTab';
import { PlayersTab } from './PlayersTab';
import { LogsTab } from './LogsTab';
import './admin.css';
import './gunracks.css';

type TabId = 'overview' | 'racks' | 'weapons' | 'place' | 'players' | 'logs';

interface TabDef {
  id: TabId;
  label: string;
  icon: ReactNode;
  Component: (props: TabProps) => ReactNode;
}

const TABS: TabDef[] = [
  { id: 'overview', label: 'Overview', icon: <LayoutDashboard size={15} />, Component: OverviewTab },
  { id: 'racks', label: 'Racks', icon: <Warehouse size={15} />, Component: RacksTab },
  { id: 'weapons', label: 'Weapons', icon: <Crosshair size={15} />, Component: WeaponsTab },
  { id: 'place', label: 'Place', icon: <PlusSquare size={15} />, Component: PlaceTab },
  { id: 'players', label: 'Players', icon: <Users size={15} />, Component: PlayersTab },
  { id: 'logs', label: 'Logs', icon: <ScrollText size={15} />, Component: LogsTab },
];

/** How often the rack list is read while the console is open, when the server names no period. */
const DEFAULT_RACKS_POLL_MS = 6000;

interface Toast {
  id: number;
  message: string;
  type: ToastType;
}

const Console = () => {
  const [visible, setVisible] = useState(false);
  const [activeTab, setActiveTab] = useState<TabId>('overview');

  const [perms, setPerms] = useState<AdminPerms>({});
  const [pollMs, setPollMs] = useState<AdminPollMs>({});

  const [racks, setRacks] = useState<RackRow[]>([]);
  const [racksReady, setRacksReady] = useState(false);
  const [catalog, setCatalog] = useState<Catalog>(EMPTY_CATALOG);
  const [focusRack, setFocusRack] = useState<number | null>(null);

  // Counts opens, so the catalog is re-read once per open even when an open arrives on top of a
  // panel that never closed.
  const [opened, setOpened] = useState(0);

  const [confirm, setConfirm] = useState<ConfirmSpec | null>(null);
  const [toasts, setToasts] = useState<Toast[]>([]);
  const toastId = useRef(0);

  const [refreshToken, setRefreshToken] = useState(0);

  // Bumped by a tab after it changed a rack, so the list is read again straight away rather than at
  // the next poll.
  const [racksToken, setRacksToken] = useState(0);
  const reloadRacks = useCallback(() => setRacksToken(n => n + 1), []);

  const showToast = useCallback((message: string, type: ToastType = 'info') => {
    const id = ++toastId.current;
    setToasts(prev => [...prev, { id, message, type }]);
    setTimeout(() => setToasts(prev => prev.filter(t => t.id !== id)), 3000);
  }, []);

  const close = useCallback(() => {
    setVisible(false);
    setConfirm(null);
    void fetchNui('admin:close');
  }, []);

  // A tab with unsaved edits answers this before the panel lets it unmount. A ref, not state:
  // registering must not re-render the whole console on every keystroke.
  const leaveGuard = useRef<(() => string | null) | null>(null);
  const setLeaveGuard = useCallback((guard: (() => string | null) | null) => {
    leaveGuard.current = guard;
  }, []);

  const guarded = useCallback((go: () => void, what: string) => {
    const why = leaveGuard.current?.();
    if (!why) {
      go();
      return;
    }
    setConfirm({
      title: 'Unsaved changes',
      message: why,
      confirmLabel: what,
      danger: true,
      onConfirm: () => {
        leaveGuard.current = null;
        go();
      },
    });
  }, []);

  const switchTab = useCallback(
    (id: TabId) => {
      if (id === activeTab) return;
      guarded(() => setActiveTab(id), 'Leave anyway');
    },
    [activeTab, guarded],
  );

  // The Overview, Weapons and Players tabs name racks; clicking one opens it in the Racks tab.
  const openRack = useCallback(
    (id: number) => {
      guarded(() => {
        setFocusRack(id);
        setActiveTab('racks');
      }, 'Leave anyway');
    },
    [guarded],
  );

  const clearFocus = useCallback(() => setFocusRack(null), []);

  const requestClose = useCallback(() => guarded(close, 'Close anyway'), [guarded, close]);

  useNuiEvent<AdminOpenPayload>('sd-gunracks:admin:open', data => {
    // An empty Lua table can arrive as `[]`; mapOf turns that back into "no permissions listed".
    setPerms(mapOf<boolean>(data?.perms));
    setPollMs(mapOf<number>(data?.pollMs));
    setConfirm(null);
    setOpened(n => n + 1);
    setVisible(true);
  });

  useNuiEvent('sd-gunracks:admin:close', () => {
    setVisible(false);
    setConfirm(null);
  });

  // The rack list: every tab reads from it, so the console keeps it, and keeps it fresh.
  const racksPeriod = pollMs.racks ?? DEFAULT_RACKS_POLL_MS;
  useEffect(() => {
    if (!visible) return;

    let cancelled = false;

    const load = () =>
      void fetchNui('admin:getRacks').then(resp => {
        if (cancelled) return;
        if (!isRefused(resp)) setRacks(racksOf(resp.list));
        setRacksReady(true);
      });

    load();
    const timer = window.setInterval(load, racksPeriod);

    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [visible, refreshToken, racksToken, racksPeriod]);

  useEffect(() => {
    if (!visible) return;

    let cancelled = false;

    void fetchNui('admin:getCatalog').then(resp => {
      if (cancelled || isRefused(resp)) return;
      setCatalog(catalogOf(resp));
    });

    return () => {
      cancelled = true;
    };
  }, [visible, opened]);

  useEffect(() => {
    if (!visible) return;

    const onKeyDown = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;

      if (confirm) {
        setConfirm(null);
        return;
      }
      requestClose();
    };

    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [visible, confirm, requestClose]);

  // The line under the open tab: where that tab is, measured, so that it slides from one to the next.
  const tabRefs = useRef<Partial<Record<TabId, HTMLButtonElement | null>>>({});
  const [underline, setUnderline] = useState<{ left: number; width: number } | null>(null);
  useLayoutEffect(() => {
    const el = tabRefs.current[activeTab];

    if (!visible || !el) return;

    setUnderline({ left: el.offsetLeft + 10, width: Math.max(0, el.offsetWidth - 20) });
  }, [activeTab, visible, racks.length]);

  // A number opens the tab that is that many along - unless something is being typed into.
  useEffect(() => {
    if (!visible) return;

    const onKey = (e: KeyboardEvent) => {
      if (e.ctrlKey || e.altKey || e.metaKey) return;

      const at = e.target as HTMLElement | null;

      if (at && (at.tagName === 'INPUT' || at.tagName === 'TEXTAREA' || at.isContentEditable)) return;

      const n = Number(e.key);
      if (Number.isInteger(n) && n >= 1 && n <= TABS.length) switchTab(TABS[n - 1].id);
    };

    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [visible, switchTab]);

  if (!visible) return null;

  const active = TABS.find(t => t.id === activeTab) ?? TABS[0];
  const ActiveTab = active.Component;

  const tabProps: TabProps = {
    racks,
    racksReady,
    catalog,
    perms,
    pollMs,
    refreshToken,
    showToast,
    requestConfirm: setConfirm,
    reloadRacks,
    setLeaveGuard,
    openRack,
    focusRack,
    clearFocus,
  };

  const guns = racks.reduce((sum, r) => sum + r.stored, 0);
  const locked = racks.filter(r => r.locked).length;

  return (
    <div className="ga-root">
      <div className="ga-panel">
        {confirm && <ConfirmDialog spec={confirm} onClose={() => setConfirm(null)} />}

        <div className="ga-header">
          <div className="ga-brand">
            <h1>Gun Racks</h1>
            <span className="ga-brand-sub">Every rack, the guns on them, who owns what and who did what</span>
          </div>

          <div className="ga-header-actions">
            <button
              type="button"
              className="ga-icon-btn"
              onClick={() => setRefreshToken(n => n + 1)}
              title="Refresh"
            >
              <RefreshCw size={14} />
            </button>
            <button type="button" className="ga-icon-btn" onClick={requestClose} title="Close (ESC)">
              <X size={16} />
            </button>
          </div>
        </div>

        {/* The tabs: words in a row, the open one underlined. */}
        <div className="ga-tabs">
          {TABS.map((tab, i) => (
            <button
              key={tab.id}
              type="button"
              ref={el => {
                tabRefs.current[tab.id] = el;
              }}
              className="ga-tab"
              data-on={activeTab === tab.id}
              title={`${i + 1}`}
              onClick={() => switchTab(tab.id)}
            >
              {tab.label}
              {tab.id === 'racks' && racks.length > 0 && <span className="ga-tab-count">{racks.length}</span>}
              {tab.id === 'weapons' && guns > 0 && <span className="ga-tab-count">{guns}</span>}
            </button>
          ))}
          {underline && (
            <span className="ga-tab-underline" style={{ left: underline.left, width: underline.width }} />
          )}
          <span className="ga-tabs-hint">
            {racks.length} racks · {guns} guns · {locked} locked
          </span>
        </div>

        <div className="ga-body">
          <div className="ga-content" key={activeTab}>
            <ActiveTab {...tabProps} />
          </div>
        </div>

        <div className="ga-toasts">
          {toasts.map(toast => (
            <div key={toast.id} className={`ga-toast ${toast.type}`}>
              {toast.message}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};

/**
 * The staff console: one window, its tabs in a row. Mounted once for the life of the page and drawn
 * only between `sd-gunracks:admin:open` and a close, so it costs nothing while the placer's strip
 * has the screen.
 */
export function AdminConsole() {
  return (
    <ErrorBoundary>
      <Console />
    </ErrorBoundary>
  );
}
