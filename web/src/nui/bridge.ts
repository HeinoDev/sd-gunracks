import type { CallbackName, CallbackRequest, CallbackResponse } from '@/types';

declare global {
  interface Window {
    GetParentResourceName?: () => string;
  }
}

export const isEnvBrowser = (): boolean => typeof window.GetParentResourceName !== 'function';

const resourceName = (): string => window.GetParentResourceName?.() ?? 'sd-gunracks';

type MockHandler = (data: unknown) => unknown;

const mockHandlers = new Map<string, MockHandler>();

export function registerMockNui<K extends CallbackName>(
  callback: K,
  handler: (data: CallbackRequest<K>) => CallbackResponse<K>,
): void {
  mockHandlers.set(callback, handler as MockHandler);
}

export async function fetchNui<K extends CallbackName>(
  callback: K,
  data?: CallbackRequest<K>,
): Promise<CallbackResponse<K> | null> {
  if (isEnvBrowser()) {
    const handler = mockHandlers.get(callback);
    return handler ? ((handler(data) ?? null) as CallbackResponse<K> | null) : null;
  }

  try {
    const resp = await fetch(`https://${resourceName()}/${callback}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data ?? {}),
    });
    return (await resp.json()) as CallbackResponse<K>;
  } catch {
    return null;
  }
}
