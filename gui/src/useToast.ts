export type ToastKind = "error" | "success" | "warning";

export interface Toast {
  id: number;
  kind: ToastKind;
  message: string;
  ttl: number; // seconds until auto-dismiss; 0 = manual only
}

let _nextId = 1;
function nextId() { return _nextId++; }

// Per-kind cooldown: prevent spamming the same message
const _cooldownUntil: Record<string, number> = {}; // message → epoch seconds
const COOLDOWN_S = 5;

let _toasts: Toast[] = [];

type Subscriber = (t: Toast[]) => void;
const _subscribers = new Set<Subscriber>();

function _addToast(kind: ToastKind, message: string, ttl: number) {
  const key = `${kind}:${message}`;
  const now = Date.now() / 1000;
  if (_cooldownUntil[key] && _cooldownUntil[key] > now) return;
  _cooldownUntil[key] = now + COOLDOWN_S;
  const t: Toast = { id: nextId(), kind, message, ttl };
  _toasts = [..._toasts, t];
  _subscribers.forEach(s => s(_toasts));
}

export interface ToastHandle {
  error(message: string, ttl?: number): void;
  success(message: string, ttl?: number): void;
  warning(message: string, ttl?: number): void;
}

// Singleton toaster
export const toast: ToastHandle = {
  error: (msg, ttl = 5) => _addToast("error", msg, ttl),
  success: (msg, ttl = 3) => _addToast("success", msg, ttl),
  warning: (msg, ttl = 5) => _addToast("warning", msg, ttl),
};

export function subscribeToasts(fn: Subscriber): () => void {
  _subscribers.add(fn);
  fn(_toasts); // immediately call with current state
  return () => { _subscribers.delete(fn); };
}

export function removeToast(id: number) {
  _toasts = _toasts.filter(t => t.id !== id);
  _subscribers.forEach(s => s(_toasts));
}
