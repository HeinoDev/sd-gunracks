import '@fontsource/inter/500.css';
import '@fontsource/inter/600.css';
import { useState } from 'react';
import type { ReactNode } from 'react';
import { AlertTriangle } from 'lucide-react';
import { useNuiEvent } from '@/hooks/useNuiEvent';
import './placer.css';

export interface PlacerWarning {
  key: string;
  /** What is wrong, in the locale's words (client/racks/placement.lua reads locales/). */
  text?: string;
}

/** The key names the strip shows, from configs/client/controls.lua (a server that moves a key moves its name too). */
export interface PlacerKeys {
  cursor?: string;
  move?: string;
  rotate?: string;
  axes?: string;
  snap?: string;
  stick?: string;
  surface?: string;
  undo?: string;
  confirm?: string;
  cancel?: string;
}

/** What client/racks/placement.lua sends twenty times a second while a rack is being placed. */
export interface PlacerState {
  active: boolean;
  label?: string;
  /** Wall racks keep flat to a wall, the rest sit on a floor or a table-top. */
  mount?: 'floor' | 'wall' | 'surface';
  x?: number;
  y?: number;
  z?: number;
  heading?: number;
  space?: 'local' | 'world';
  snap?: boolean;
  stick?: boolean;
  cursor?: boolean;
  mode?: 'move' | 'rotate';
  handle?: 'move' | 'rotate' | null;
  dragging?: boolean;
  readout?: string | null;
  /** Whether it may go down here: the outline is green when it may and red when not. */
  valid?: boolean;
  warnings?: PlacerWarning[];
  snapMove?: number;
  snapTurn?: number;
  keys?: PlacerKeys;
}

const HANDLES: Record<string, string> = { move: 'Move', rotate: 'Rotate' };

const Kbd = ({ children, strong = false }: { children: string; strong?: boolean }) => (
  <span className={`pl-kbd${strong ? ' strong' : ''}`}>{children}</span>
);

const Hint = ({ keys, label, on }: { keys: string[]; label: string; on?: boolean }) => (
  <div className="pl-hint">
    <span className={on ? 'on' : undefined}>
      {label}
      {on && <span className="pl-dot" />}
    </span>
    <span className="pl-keys">
      {keys.map(k => (
        <Kbd key={k}>{k}</Kbd>
      ))}
    </span>
  </div>
);

const Mode = ({ label, on }: { label: string; on: boolean }) => (
  <span className={`pl-mode${on ? ' on' : ''}`}>
    <span className="pl-mode-dot" />
    {label}
  </span>
);

const Axis = ({ name, value, colour }: { name: string; value?: number; colour: string }) => (
  <span className="pl-axis">
    <span className="pl-axis-name" style={{ color: colour }}>
      {name}
    </span>
    <span className="pl-mono">{(value ?? 0).toFixed(2)}</span>
  </span>
);

const Group = ({ title, children }: { title: string; children: ReactNode }) => (
  <>
    <div className="pl-label">{title}</div>
    {children}
  </>
);

/**
 * The placer's strip: the keys down the left, where the rack is and what is switched on along the
 * bottom, what is wrong with where it is above that, and while the gizmo is dragged, how far it has
 * gone at the top. It takes no focus: the mouse is the gizmo's.
 */
export function PlacerHud() {
  const [hud, setHud] = useState<PlacerState>({ active: false });

  useNuiEvent<PlacerState>('sd-gunracks:placer:hud', data => setHud(data && data.active ? data : { active: false }));

  if (!hud.active) return null;

  const k = hud.keys ?? {};
  const wall = hud.mount === 'wall';
  const handleName = hud.handle ? HANDLES[hud.handle] : null;
  const warnings = hud.warnings ?? [];
  const valid = hud.valid !== false;
  const snapLabel = hud.snap ? `Snap ${hud.snapMove ?? 0.05} m · ${hud.snapTurn ?? 15}°` : 'Snap';

  return (
    <div className="pl-root">
      {hud.dragging && hud.readout && (
        <div className="pl-readout-wrap">
          <div className="pl-readout">
            <span className="pl-readout-handle">{handleName}</span>
            <span className="pl-mono pl-readout-value">{hud.readout}</span>
          </div>
        </div>
      )}

      <div className="pl-keys-card">
        <Group title="Gizmo">
          <Hint keys={[k.cursor ?? 'G']} label="Cursor on / off" on={hud.cursor} />
          <Hint keys={['RMB']} label="Hold to look around" />
          <Hint keys={['LMB']} label="Grab arrow or ring" />
          <Hint keys={[k.move ?? 'W']} label="Move mode" on={hud.mode !== 'rotate'} />
          <Hint keys={[k.rotate ?? 'R']} label="Rotate mode" on={hud.mode === 'rotate'} />
          <Hint keys={[k.axes ?? 'Q']} label={hud.space === 'world' ? 'World axes' : 'Local axes'} />
        </Group>
        <div className="pl-gap" />
        <Group title="Adjust">
          <Hint keys={['Wheel']} label="Turn" />
          <Hint keys={['↑', '↓', '←', '→']} label={wall ? 'Along the wall' : 'Nudge'} />
          <Hint keys={['PgUp', 'PgDn']} label="Height" />
        </Group>
        <div className="pl-gap" />
        <Group title="Edit">
          <Hint keys={[k.snap ?? 'X']} label="Snap" on={hud.snap} />
          <Hint keys={[k.stick ?? 'T']} label={wall ? 'Stick to wall' : 'Stick to ground'} on={hud.stick} />
          <Hint keys={[k.surface ?? 'Alt']} label={wall ? 'Flat to the wall' : 'Down to the floor'} />
          <Hint keys={['Ctrl', k.undo ?? 'Z']} label="Undo" />
        </Group>
      </div>

      <div className="pl-bottom">
        <div className="pl-bottom-inner">
          {warnings.map(w => (
            <div key={w.key} className="pl-warning">
              <AlertTriangle size={13} />
              {w.text ?? w.key}
            </div>
          ))}
          <div className="pl-bar">
            <div className="pl-bar-top">
              <span className="pl-title">{`Placing ${hud.label ?? ''}`}</span>
              {handleName && <span className="pl-handle">{handleName}</span>}
              <span className="pl-axes">
                <Axis name="X" value={hud.x} colour="#ef5b5b" />
                <Axis name="Y" value={hud.y} colour="#48d680" />
                <Axis name="Z" value={hud.z} colour="#609cff" />
                <span className="pl-axis">
                  <span className="pl-axis-name" style={{ color: '#eeb848' }}>
                    H
                  </span>
                  <span className="pl-mono">{`${(hud.heading ?? 0).toFixed(1)}°`}</span>
                </span>
              </span>
            </div>
            <div className="pl-bar-bottom">
              <Mode label={snapLabel} on={!!hud.snap} />
              <Mode label={hud.mode === 'rotate' ? 'Rotate' : 'Move'} on />
              <Mode label="Cursor" on={!!hud.cursor} />
              <Mode label={wall ? 'Stick to wall' : 'Stick to ground'} on={!!hud.stick} />
              <Mode label={hud.space === 'world' ? 'World axes' : 'Local axes'} on={hud.space === 'world'} />
              <span className="pl-actions">
                <span className="pl-cancel">
                  <Kbd>{k.cancel ?? 'Backspace'}</Kbd>
                  Cancel
                </span>
                <span className={`pl-confirm${valid ? '' : ' off'}`}>
                  <Kbd strong={valid}>{k.confirm ?? 'Enter'}</Kbd>
                  Place
                </span>
              </span>
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
