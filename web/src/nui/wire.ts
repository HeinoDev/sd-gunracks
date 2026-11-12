/**
 * Reading what Lua sends.
 *
 * Lua has one table type, so an EMPTY list leaves the server as `{}` rather than `[]`, and a nil
 * field is simply absent rather than null. Anything that .map()s a list off the wire has to go
 * through these first, or the first empty rack crashes the page that draws it.
 */

/** The value if it is a real array, otherwise an empty one. */
export const listOf = <T>(value: unknown): T[] => (Array.isArray(value) ? (value as T[]) : []);

/** A plain object keyed by string, or an empty one. An empty Lua table can arrive as `[]`. */
export const mapOf = <T>(value: unknown): Record<string, T> =>
  value && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, T>) : {};

/** A finite number, or the fallback for absent / null / NaN / anything else. */
export const numOf = (value: unknown, fallback = 0): number =>
  typeof value === 'number' && Number.isFinite(value) ? value : fallback;

/** A string, or null for absent / null / anything else. Empty strings count as absent. */
export const strOrNull = (value: unknown): string | null =>
  typeof value === 'string' && value !== '' ? value : null;

/** The same refusal every page checks for: `{ ok: false, err }` from the relay or the server. */
export const refusalOf = (resp: unknown): string | null => {
  if (resp && typeof resp === 'object' && (resp as { ok?: unknown }).ok === false) {
    const err = (resp as { err?: unknown }).err;
    return typeof err === 'string' && err ? err : 'the server refused that';
  }
  return null;
};
