import { useId } from 'react';
import { Plus, Trash2 } from 'lucide-react';
import type { AccessEntry, RackAccess } from '@/types';

/** Names are the framework's job and gang names: short, no spaces at either end (the server trims them too). */
const NAME_MAX = 50;

type Side = 'jobs' | 'gangs';

const SIDES: { side: Side; title: string; add: string; placeholder: string }[] = [
  { side: 'jobs', title: 'Jobs', add: 'Add a job', placeholder: 'police' },
  { side: 'gangs', title: 'Gangs', add: 'Add a gang', placeholder: 'ballas' },
];

/** The list as the server will keep it: blank names gone, names trimmed, grades whole and not below 0. */
export const cleanAccess = (a: RackAccess): RackAccess => {
  const clean = (list: AccessEntry[]) =>
    list
      .map(e => ({ name: e.name.trim(), grade: Math.max(0, Math.floor(Number(e.grade) || 0)) }))
      .filter(e => e.name !== '');
  return { jobs: clean(a.jobs), gangs: clean(a.gangs) };
};

/** Whether two lists say the same thing once both are cleaned (order kept: it is the order staff wrote them in). */
export const sameAccess = (a: RackAccess, b: RackAccess): boolean =>
  JSON.stringify(cleanAccess(a)) === JSON.stringify(cleanAccess(b));

/**
 * Who besides the owner and staff may open a rack while it is locked: jobs and gangs, each from a
 * lowest grade up. Edited here as rows of a name and a grade; what is sent is cleanAccess of them.
 */
export const AccessEditor = ({
  value,
  onChange,
  disabled = false,
}: {
  value: RackAccess;
  onChange: (next: RackAccess) => void;
  disabled?: boolean;
}) => {
  const id = useId();
  const set = (side: Side, list: AccessEntry[]) => onChange({ ...value, [side]: list });

  const update = (side: Side, i: number, patch: Partial<AccessEntry>) =>
    set(side, value[side].map((x, j) => (j === i ? { ...x, ...patch } : x)));

  return (
    <div className="gr-access">
      {SIDES.map(({ side, title, add, placeholder }) => (
        <div key={side} className="gr-access-side">
          <div className="gr-access-head">
            <span className="ga-field-label" id={`${id}-${side}-heading`}>{title}</span>
            <button
              type="button"
              className="ga-btn sm"
              disabled={disabled}
              onClick={() => set(side, [...value[side], { name: '', grade: 0 }])}
            >
              <Plus size={12} />
              {add}
            </button>
          </div>

          {value[side].length === 0 ? (
            <div className="gr-access-none">None</div>
          ) : (
            value[side].map((entry, i) => (
              <div key={i} className="gr-access-row">
                <input
                  className="ga-input"
                  value={entry.name}
                  id={`${id}-${side}-name-${i}`}
                  maxLength={NAME_MAX}
                  spellCheck={false}
                  placeholder={placeholder}
                  disabled={disabled}
                  aria-label={i === 0 ? undefined : `${title} name`}
                  aria-labelledby={i === 0 ? `${id}-${side}-heading` : undefined}
                  onChange={e => update(side, i, { name: e.target.value })}
                />
                <span className="gr-access-from">from grade</span>
                <input
                  className="ga-input ga-mono gr-access-grade"
                  type="number"
                  min={0}
                  value={entry.grade}
                  disabled={disabled}
                  aria-label={`${title} lowest grade`}
                  onChange={e => update(side, i, { grade: Math.max(0, Math.floor(Number(e.target.value) || 0)) })}
                />
                <button
                  type="button"
                  className="ga-btn red sm"
                  disabled={disabled}
                  aria-label={`Remove ${entry.name || 'this line'}`}
                  onClick={() => set(side, value[side].filter((_, j) => j !== i))}
                >
                  <Trash2 size={12} />
                </button>
              </div>
            ))
          )}
        </div>
      ))}
    </div>
  );
};
