import type { PlacerState } from '@/placer/PlacerHud';

/**
 * The placer's strip against made-up state, for the dev server (/?placer). The console's own mock is
 * admin/mock.ts.
 */

const post = (action: string, data: unknown) => window.postMessage({ action, data }, '*');

const KEYS: PlacerState['keys'] = {
  cursor: 'G',
  move: 'W',
  rotate: 'R',
  axes: 'Q',
  snap: 'X',
  stick: 'T',
  surface: 'Alt',
  undo: 'Z',
  confirm: 'Enter',
  cancel: 'Backspace',
};

/**
 * `/?placer` a pegboard slid along a wall, flush and green, the move arrow dragged now and again;
 * `/?placer&floor` an oak floor rack lifted off the floor and over another rack, red.
 */
export function openMockPlacer(floor: boolean): void {
  const began = performance.now();

  window.setInterval(() => {
    const t = (performance.now() - began) / 1000;
    const dragging = !floor && t % 6 > 3;

    const state: PlacerState = floor
      ? {
          active: true,
          label: 'Oak Floor Rack',
          mount: 'floor',
          x: -1183.42,
          y: -1512.06,
          z: 4.79 + Math.abs(Math.sin(t)) * 0.2,
          heading: 124.5,
          space: 'world',
          snap: false,
          stick: false,
          cursor: true,
          mode: 'move',
          valid: false,
          warnings: [
            { key: 'floating', text: 'Floating 0.31 m off the floor: Alt puts it down.' },
            { key: 'overlap', text: 'Overlaps another rack.' },
          ],
          snapMove: 0.05,
          snapTurn: 15,
          keys: KEYS,
        }
      : {
          active: true,
          label: 'Tactical Pegboard',
          mount: 'wall',
          x: 452.18 + Math.sin(t / 2) * 0.4,
          y: -980.55,
          z: 31.12,
          heading: 270,
          space: 'world',
          snap: true,
          stick: true,
          cursor: true,
          mode: 'move',
          handle: dragging ? 'move' : null,
          dragging,
          readout: dragging ? `${Math.abs(Math.sin(t / 2) * 0.4).toFixed(2)} m` : null,
          valid: true,
          warnings: [],
          snapMove: 0.05,
          snapTurn: 15,
          keys: KEYS,
        };

    post('sd-gunracks:placer:hud', state);
  }, 100);
}
