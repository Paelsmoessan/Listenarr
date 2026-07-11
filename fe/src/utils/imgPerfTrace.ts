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
 * Image load instrumentation. Instead of THEORIZING about whether the cover prewarm actually populates the
 * browser cache and whether the grid <img> reads from it, this measures it: a PerformanceObserver on resource
 * timings. For SAME-ORIGIN requests (our /images/ URLs are same-origin), `transferSize === 0` means the browser
 * served it FROM CACHE (memory/disk); `> 0` means it went to the NETWORK. So every cover load is tagged
 * cached=true/false and shipped to the AI debug log, where the truth is readable directly.
 *
 * Enabled only when vgTrace is (DEV instance / la-virtualgrid). Idempotent.
 */
import { vgTrace } from './vgTrace'

let observing = false

// Settle detector: cover loads on a back-nav arrive in a burst then stop. We fire `grid:settled` once no new
// /images/ load has been seen for SETTLE_MS, and report how many loaded in the burst + when it started. Pairing
// grid:settled.t with the preceding restore:index.t gives the real "time to fully render" (the ~2s), which the
// first-paint probes undercount.
const SETTLE_MS = 500
let settleTimer: ReturnType<typeof setTimeout> | null = null
let burstCount = 0
let burstStart = 0

function noteImageForSettle(): void {
  if (burstCount === 0) burstStart = performance.now()
  burstCount++
  if (settleTimer) clearTimeout(settleTimer)
  settleTimer = setTimeout(() => {
    vgTrace('IMG', 'grid:settled', {
      covers: burstCount,
      burstMs: Math.round(performance.now() - burstStart - SETTLE_MS),
    })
    settleTimer = null
    burstCount = 0
  }, SETTLE_MS)
}

export function observeImagePerf(): void {
  if (observing || typeof PerformanceObserver === 'undefined') return
  observing = true
  try {
    const po = new PerformanceObserver((list) => {
      for (const entry of list.getEntries()) {
        const r = entry as PerformanceResourceTiming
        if (!r.name.includes('/images/')) continue
        vgTrace('IMG', 'img-load', {
          // strip origin so the URL is short + comparable
          url: r.name.replace(/^https?:\/\/[^/]+/, ''),
          // 0 transfer bytes on a same-origin request == served from the browser cache (mem or disk)
          cached: r.transferSize === 0,
          transferSize: r.transferSize,
          encodedSize: r.encodedBodySize,
          durationMs: Math.round(r.duration),
          initiator: r.initiatorType,
        })
        noteImageForSettle()
      }
    })
    // buffered:true also replays entries that landed just before we started observing.
    po.observe({ type: 'resource', buffered: true })
  } catch {
    observing = false
  }
}
