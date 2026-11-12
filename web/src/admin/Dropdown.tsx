import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState } from 'react';
import type { ReactNode } from 'react';
import { Check, ChevronDown } from 'lucide-react';

/**
 * The panel's dropdown.
 *
 * A native <select> renders as whatever chrome the game's browser feels like drawing, and its
 * option list cannot be styled at all — so every picker in the panel is this instead.
 */

export interface DropdownOption {
  value: string;
  label: string;

  /** Leading mark, such as a lucide icon. */
  icon?: ReactNode;
  /** Quiet right-aligned detail, e.g. '8 slots'. */
  meta?: string;
  disabled?: boolean;
}

interface DropdownProps {
  value: string;
  options: DropdownOption[];
  onChange: (value: string) => void;

  /** Shown when `value` matches nothing — the "— pick one —" line a <select> would carry. */
  placeholder?: string;
  disabled?: boolean;
  className?: string;
  /** Names the control for screen readers when the visible <label> is not tied to it. */
  ariaLabel?: string;
}

export const Dropdown = ({
  value,
  options,
  onChange,
  placeholder = 'Select…',
  disabled,
  className,
  ariaLabel,
}: DropdownProps) => {
  const [open, setOpen] = useState(false);

  // Which row the keyboard is on. Separate from `value`: moving through the list must not commit
  // anything until Enter, or arrowing past a row would fire an action on the way past.
  const [active, setActive] = useState(-1);

  const triggerRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const listId = useId();

  const selected = options.find(o => o.value === value);
  const pickable = (i: number) => i >= 0 && i < options.length && !options[i].disabled;

  const close = useCallback((focusTrigger: boolean) => {
    setOpen(false);
    setActive(-1);
    if (focusTrigger) triggerRef.current?.focus();
  }, []);

  const commit = (i: number) => {
    if (!pickable(i)) return;
    onChange(options[i].value);
    close(true);
  };

  // Open onto the current choice rather than the top, so the first arrow press moves from where the
  // reader already is.
  useEffect(() => {
    if (!open) return;

    const at = options.findIndex(o => o.value === value);
    setActive(at >= 0 ? at : options.findIndex(o => !o.disabled));
  }, [open, options, value]);

  // Open upwards when the list would run off the bottom of whatever scrolls it (a picker on a table's
  // last row), and there is more room above. Measured before the list is painted, so it never jumps.
  const [up, setUp] = useState(false);
  useLayoutEffect(() => {
    const trigger = triggerRef.current;
    const menu = menuRef.current;

    if (!open || !trigger || !menu) return;

    let box = trigger.parentElement;
    while (box && box !== document.body) {
      const overflow = getComputedStyle(box).overflowY;
      if (overflow === 'auto' || overflow === 'scroll') break;
      box = box.parentElement;
    }

    const bound = box && box !== document.body
      ? box.getBoundingClientRect()
      : { top: 0, bottom: window.innerHeight };
    const at = trigger.getBoundingClientRect();
    const below = Math.min(bound.bottom, window.innerHeight) - at.bottom;
    const above = at.top - Math.max(bound.top, 0);
    setUp(below < menu.offsetHeight + 6 && above > below);
  }, [open]);

  // Keep the highlighted row on screen in a list long enough to scroll.
  useEffect(() => {
    if (!open || active < 0) return;

    const node = menuRef.current?.querySelector<HTMLElement>(`[data-i="${active}"]`);
    node?.scrollIntoView({ block: 'nearest' });
  }, [open, active]);

  const step = (from: number, dir: 1 | -1) => {
    for (let i = from + dir; i >= 0 && i < options.length; i += dir) {
      if (!options[i].disabled) return i;
    }
    return from;
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (disabled) return;

    if (!open) {
      if (e.key === 'Enter' || e.key === ' ' || e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        setOpen(true);
      }
      return;
    }

    switch (e.key) {
      case 'Escape':
        // The panel closes on ESC from a window listener. Stopped here so the first press only
        // shuts the list, the way it would on a native select.
        e.preventDefault();
        e.stopPropagation();
        close(true);
        break;
      case 'ArrowDown':
        e.preventDefault();
        setActive(a => step(a, 1));
        break;
      case 'ArrowUp':
        e.preventDefault();
        setActive(a => step(a, -1));
        break;
      case 'Home':
        e.preventDefault();
        setActive(step(-1, 1));
        break;
      case 'End':
        e.preventDefault();
        setActive(step(options.length, -1));
        break;
      case 'Enter':
      case ' ':
        e.preventDefault();
        commit(active);
        break;
      case 'Tab':
        close(false);
        break;
      default:
        break;
    }
  };

  return (
    <div className={className ? `ga-dropdown ${className}` : 'ga-dropdown'}>
      <button
        ref={triggerRef}
        type="button"
        className="ga-dropdown-trigger"
        disabled={disabled}
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? listId : undefined}
        aria-label={ariaLabel}
        onClick={() => setOpen(o => !o)}
        onKeyDown={onKeyDown}
      >
        <span className="ga-dropdown-value">
          {selected?.icon}
          <span className={selected ? 'ga-truncate' : 'ga-truncate ga-dropdown-placeholder'}>
            {selected ? selected.label : placeholder}
          </span>
        </span>
        <ChevronDown size={13} className={open ? 'ga-dropdown-caret open' : 'ga-dropdown-caret'} />
      </button>

      {open && (
        <>
          <div className="ga-dropdown-backdrop" onClick={() => close(false)} />
          <div
            ref={menuRef}
            id={listId}
            role="listbox"
            className={up ? 'ga-dropdown-menu ga-scroll up' : 'ga-dropdown-menu ga-scroll'}
            aria-label={ariaLabel}
          >
            {options.length === 0 && <div className="ga-dropdown-empty">Nothing to choose from</div>}

            {options.map((o, i) => (
              <button
                key={o.value}
                type="button"
                role="option"
                data-i={i}
                aria-selected={o.value === value}
                disabled={o.disabled}
                className={
                  'ga-dropdown-item'
                  + (o.value === value ? ' selected' : '')
                  + (i === active ? ' active' : '')
                }
                onMouseEnter={() => setActive(i)}
                onClick={() => commit(i)}
              >
                {o.icon}
                <span className="ga-truncate">{o.label}</span>
                {o.meta && <span className="ga-dropdown-meta">{o.meta}</span>}
                {o.value === value && <Check size={12} />}
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
};
