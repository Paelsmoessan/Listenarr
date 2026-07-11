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
 * Browser-cache prewarmer for images. Server-side thumbnail pre-warm makes the SERVER fast, but the browser
 * still fetches each cover as it first scrolls into view (virtualization + lazy loading), so a fresh grid feels
 * "load as you go" until you've scrolled the whole library once and the browser cache is full.
 *
 * This trickles those exact image URLs into the browser cache in the background, at low priority and bounded
 * concurrency, so scrolling is instant from the start. Pass the SAME URLs the grid renders (e.g. the
 * `?size=grid` thumbnails) so the eventual <img> requests are true cache hits.
 *
 * Returns a cancel function (call it on unmount / navigation so a half-finished warm doesn't keep loading).
 */
export function prewarmImages(urls: string[], opts?: { concurrency?: number }): () => void {
  const concurrency = Math.max(1, opts?.concurrency ?? 6)
  let i = 0
  let cancelled = false
  const inflight = new Set<HTMLImageElement>()

  function startNext() {
    if (cancelled || i >= urls.length) return
    const url = urls[i++]
    if (!url) {
      startNext()
      return
    }
    const img = new Image()
    inflight.add(img)
    const done = () => {
      inflight.delete(img)
      img.onload = null
      img.onerror = null
      startNext() // chain: as each finishes, pull the next one, keeping `concurrency` in flight
    }
    img.onload = done
    img.onerror = done
    // Hint the browser this is background work so it never competes with visible covers.
    try {
      ;(img as unknown as { fetchPriority?: string }).fetchPriority = 'low'
    } catch {
      /* not supported */
    }
    img.decoding = 'async'
    img.src = url
  }

  for (let k = 0; k < concurrency; k++) startNext()

  return () => {
    cancelled = true
    inflight.forEach((img) => {
      img.onload = null
      img.onerror = null
      // Detaching the src aborts an in-flight load in most browsers.
      img.src = ''
    })
    inflight.clear()
  }
}
