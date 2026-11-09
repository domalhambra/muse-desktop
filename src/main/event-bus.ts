import type { AppEvent } from '../shared/protocol'

// Fan-out for main-process listeners (the bridges) of the same events the
// window receives.

type Listener = (event: AppEvent) => void
const listeners = new Set<Listener>()

export function subscribe(listener: Listener) {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function publish(event: AppEvent) {
  for (const listener of listeners) {
    try {
      listener(event)
    } catch {
      // A bridge listener must never break the UI event path.
    }
  }
}
