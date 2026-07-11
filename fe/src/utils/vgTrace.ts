/*
 * Listenarr - Audiobook Management System
 * Copyright (C) 2024-2026 Listenarr Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */
/**
 * VirtualGrid trace collector , a sideloaded diagnostic ring buffer for debugging scroll-restore timing.
 *
 * WHY this exists: the plain namespaced Logger prints to the console only. Console lines are ephemeral,
 * un-timestamped, and un-correlated, so a frame-by-frame race (the info-ON restore flakiness) is impossible
 * to SEE after the fact. This buffer captures every event with a shared high-resolution clock and lets you
 * copy the whole ordered timeline in one shot:
 *
 *   localStorage.setItem('la-debug', '1')   // enable (same gate as the console logger)
 *   // ...reproduce...
 *   copy(window.__vgDump())                  // one JSON blob of the whole timeline
 *   window.__vgClear()                       // reset between repros
 *
 * It REUSES the existing logger's `la-debug` gate (via createLogger('VG').isEnabled()) and echoes each record
 * to the console exactly as before , so this is a fold-in, not a second logging system. Inert (no buffer
 * writes, no console) when la-debug is off. Payloads are open-ended: adding a new signal later is a one-liner
 *   vgTrace(inst, 'newEvent', { whatever })
 * that lands in the SAME timeline, no refactor.
 */
import { createLogger } from './logger'

type TraceRec = { t: number; inst: number | string; ev: string; [k: string]: unknown }

// ONE clock for the whole module so VirtualGrid + AudiobooksView events are comparable by `t` (ms since
// module load), even though they carry different `inst` ids.
const T0 = performance.now()
const CAP = 500
const BUFFER: TraceRec[] = []
let instCounter = 0

// The DEV test instance runs on port 4546. On it we default EVERYTHING on (feature + tracing + auto-ship) so a
// fresh/incognito window needs NO console commands (localStorage is wiped per incognito window, which kept us
// testing the old scroller). Elsewhere (e.g. LIVE 4545) behaviour is unchanged: opt in with la-virtualgrid='1'.
const DEV_INSTANCE = typeof location !== 'undefined' && location.port === '4546'

// Tracing follows the same rule as the feature: on by default on DEV, off elsewhere unless la-virtualgrid='1',
// and always killable with la-virtualgrid='0'. No separate debug flag to remember.
const log = createLogger('VG', {
  enabled: () => {
    try {
      const f = localStorage.getItem('la-virtualgrid')
      if (f === '0') return false
      if (f === '1') return true
    } catch {
      /* ignore */
    }
    return DEV_INSTANCE
  },
})

/** Monotonic per-component instance id, so save(N) -> restore(N+1) and stale-rAF-after-unmount are visible. */
export function vgNextInst(): number {
  return ++instCounter
}

// Download the whole timeline to a file (Downloads folder) so it reaches me without a clipboard.
function shipBuffer(name: string): { shipped: number; file: string } {
  const blob = new Blob([JSON.stringify(BUFFER, null, 2)], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = name
  document.body.appendChild(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
  return { shipped: BUFFER.length, file: name }
}

// Ship to the SIDELOADED server sink (POST /ai-log) on the DEV instance: batched + debounced, keepalive so a
// page-unload flush still delivers. ONE server-side file (ai-debug-log.jsonl) = a single continuous timeline
// the AI reads straight off disk, no downloads, no prompts, no fragments, no user commands.
let pending: TraceRec[] = []
let shipTimer: ReturnType<typeof setTimeout> | null = null
function flushToServer(): void {
  shipTimer = null
  if (!pending.length) return
  const batch = pending
  pending = []
  try {
    void fetch('/ai-log', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(batch),
      keepalive: true,
    }).catch(() => {})
  } catch {
    /* ignore */
  }
}
function shipToServer(rec: TraceRec): void {
  if (!DEV_INSTANCE) return
  pending.push(rec)
  if (!shipTimer) shipTimer = setTimeout(flushToServer, 400)
}

/** Record one event. No-op (zero cost) when disabled. Payload is open-ended by design. */
export function vgTrace(inst: number | string, ev: string, payload?: Record<string, unknown>): void {
  if (!log.isEnabled()) return
  const rec: TraceRec = {
    t: Math.round((performance.now() - T0) * 10) / 10,
    inst,
    ev,
    ...payload,
  }
  BUFFER.push(rec)
  if (BUFFER.length > CAP) BUFFER.shift()
  log.debug(ev, rec)
  shipToServer(rec)
}

// Window handles are always exposed (harmless; the buffer only fills when enabled, so __vgDump() returns
// "[]" when idle). Guarded for SSR / non-browser contexts.
if (typeof window !== 'undefined') {
  const w = window as unknown as Record<string, unknown>
  w.__vgTrace = BUFFER
  w.__vgDump = () => JSON.stringify(BUFFER, null, 2)
  w.__vgClear = () => {
    BUFFER.length = 0
  }
  // Manual download still available as a backup (the server sink covers the DEV instance automatically).
  w.__vgShip = (name?: string) => shipBuffer(name || `vg-trace-${Date.now()}.json`)
  // Flush any pending batch when the page is hidden/unloaded (keepalive lets the request complete).
  window.addEventListener('pagehide', flushToServer)
  window.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') flushToServer()
  })
}
