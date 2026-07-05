<!--
  TanStack Virtual grid PROOF OF CONCEPT (throwaway, route /poc-grid).
  Not wired into the real AudiobooksView. Books/authors = square tiles; series = wide 2:1 tiles with
  a fanned cover stack (mimics AudiobooksView's series look). Virtualized, per-group scroll preserved.
  New file only; fork-clean.
-->
<template>
  <div class="poc-page">
    <div class="poc-toolbar">
      <h2>TanStack Virtual — Grid POC</h2>
      <div class="poc-group">
        <button
          v-for="g in groups"
          :key="g"
          class="poc-btn"
          :class="{ active: groupBy === g }"
          @click="setGroup(g)"
        >
          {{ g }}
        </button>
      </div>
      <span class="poc-hint">
        {{ cells.length }} {{ groupBy }} · {{ cols }} cols · {{ rowCount }} rows · rendering
        {{ virtualRows.length }} rows
      </span>
      <span class="poc-spacer-flex" />
      <button class="poc-btn" @click="jumpToIndex(0)">Top</button>
      <button class="poc-btn" @click="jumpToIndex(500)">Jump 500</button>
      <button class="poc-btn" @click="jumpToIndex(cells.length - 1)">Bottom</button>
    </div>

    <div ref="parentRef" class="poc-scroll">
      <div class="poc-inner" :style="{ height: totalHeight + 'px' }">
        <div
          v-for="vRow in virtualRows"
          :key="vRow.index"
          class="poc-row"
          :style="{ transform: `translateY(${vRow.start}px)`, height: rowHeight + 'px' }"
        >
          <div
            v-for="cell in rowItems(vRow.index)"
            :key="cell.key"
            class="poc-tile"
            :class="cell.kind === 'book' ? 'poc-status-' + cell.status : 'poc-tile--collection'"
            tabindex="0"
            @click="onCellClick(cell)"
            @keydown.enter="onCellClick(cell)"
          >
            <div class="poc-cover-box" :style="{ aspectRatio: isSeries ? '2 / 1' : '1 / 1' }">
              <!-- series: fanned cover stack -->
              <template v-if="cell.kind === 'collection' && cell.type === 'series'">
                <div class="poc-series">
                  <div
                    v-for="(url, i) in cell.covers.slice(0, 8)"
                    :key="i"
                    class="poc-series-item"
                    :style="seriesCoverStyle(i, Math.min(cell.covers.length, 8))"
                  >
                    <img class="poc-series-img" :src="url" loading="lazy" @error="onImgError" />
                  </div>
                </div>
                <div class="poc-count-badge">{{ cell.count }}</div>
              </template>
              <!-- books + authors: single cover -->
              <template v-else>
                <img class="poc-cover" :src="cellCover(cell)" loading="lazy" @error="onImgError" />
                <div v-if="cell.kind === 'book'" class="poc-status-bar" />
                <div v-else class="poc-count-badge">{{ cell.count }}</div>
              </template>
              <div class="poc-overlay">
                <div class="poc-t" :title="cell.title">{{ cell.title }}</div>
                <div class="poc-a">{{ cell.subtitle }}</div>
              </div>
            </div>
          </div>
          <div
            v-for="n in cols - rowItems(vRow.index).length"
            :key="'pad' + n"
            class="poc-tile poc-tile--pad"
          />
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted, onBeforeUnmount, nextTick } from 'vue'
import { useRouter } from 'vue-router'
import { useVirtualizer } from '@tanstack/vue-virtual'
import { useLibraryStore } from '@/stores/library'
import { useProtectedImages } from '@/composables/useProtectedImages'
import { buildApiPath } from '@/services/apiBase'
import { getPlaceholderUrl } from '@/utils/placeholder'
import { safeText } from '@/utils/textUtils'
import { computeAudiobookStatus } from '@/utils/audiobookStatus'
import type { Audiobook } from '@/types'

type GroupBy = 'books' | 'authors' | 'series'
type BookCell = {
  kind: 'book'
  key: string
  id: number
  title: string
  subtitle: string
  cover: string
  status: string
}
type CollectionCell = {
  kind: 'collection'
  key: string
  type: 'author' | 'series'
  name: string
  title: string
  subtitle: string
  covers: string[]
  count: number
}
type GridCell = BookCell | CollectionCell

const router = useRouter()
const libraryStore = useLibraryStore()
const { getProtectedImageSrc } = useProtectedImages()
const noDownloads = new Set<number>()

const groups: GroupBy[] = ['books', 'authors', 'series']
const groupBy = ref<GroupBy>('books')
const isSeries = computed(() => groupBy.value === 'series')

const books = computed(() => libraryStore.audiobooks)

function cover(book: Audiobook): string {
  return getProtectedImageSrc(book.imageUrl, getPlaceholderUrl(), { size: 'grid' })
}
function authorCover(name: string): string {
  return getProtectedImageSrc(
    buildApiPath(`/images/${encodeURIComponent(name)}`),
    getPlaceholderUrl(),
    { size: 'grid' },
  )
}
function status(book: Audiobook): string {
  return computeAudiobookStatus(book, noDownloads)
}
function seriesNames(book: Audiobook): string[] {
  const m = book.seriesMemberships
  if (m && m.length) {
    const out: string[] = []
    const seen = new Set<string>()
    for (const x of m) {
      const n = (x.seriesName || '').trim()
      if (n && !seen.has(n.toLowerCase())) {
        seen.add(n.toLowerCase())
        out.push(n)
      }
    }
    if (out.length) return out
  }
  const legacy = (book.series || '').trim()
  return legacy ? [legacy] : []
}
function cellCover(cell: GridCell): string {
  return cell.kind === 'book' ? cell.cover : cell.covers[0] || getPlaceholderUrl()
}

const cells = computed<GridCell[]>(() => {
  if (groupBy.value === 'books') {
    return books.value.map((b) => ({
      kind: 'book',
      key: 'b' + b.id,
      id: b.id,
      title: safeText(b.title),
      subtitle: (b.authors || []).map(safeText).filter(Boolean).join(', ') || 'Unknown Author',
      cover: cover(b),
      status: status(b),
    }))
  }
  const type: 'author' | 'series' = groupBy.value === 'authors' ? 'author' : 'series'
  const map = new Map<string, { name: string; count: number; covers: string[] }>()
  for (const b of books.value) {
    const names =
      groupBy.value === 'authors'
        ? // primary author only (authors[] can include narrators/translators as later entries)
          b.authors && b.authors.length
          ? [safeText(b.authors[0])].filter(Boolean)
          : []
        : seriesNames(b)
    for (const name of names.length ? names : ['Unknown']) {
      let ex = map.get(name)
      if (!ex) {
        ex = { name, count: 0, covers: [] }
        map.set(name, ex)
      }
      ex.count++
      if (type === 'series') {
        const c = cover(b)
        if (ex.covers.length < 8 && c && !ex.covers.includes(c)) ex.covers.push(c)
      }
    }
  }
  return [...map.values()]
    .sort((a, b) => a.name.localeCompare(b.name))
    .map((g) => ({
      kind: 'collection',
      key: 'c' + g.name,
      type,
      name: g.name,
      title: g.name,
      subtitle: `${g.count} book${g.count === 1 ? '' : 's'}`,
      covers: type === 'author' ? [authorCover(g.name)] : g.covers,
      count: g.count,
    }))
})

const parentRef = ref<HTMLElement | null>(null)
const GAP = 12
const cols = ref(6)
const rowHeight = ref(200)

function recalc() {
  const w = parentRef.value?.clientWidth ?? 1200
  const min = groupBy.value === 'series' ? 340 : 170
  const nextCols = Math.max(1, Math.floor((w - 24 + GAP) / (min + GAP)))
  const tileW = (w - 24 - GAP * (nextCols - 1)) / nextCols
  cols.value = nextCols
  // series tiles are 2:1 (half height), books/authors are 1:1
  const boxH = groupBy.value === 'series' ? tileW / 2 : tileW
  rowHeight.value = Math.round(boxH + 8)
}

const rowCount = computed(() => Math.ceil(cells.value.length / cols.value))

const rowVirtualizer = useVirtualizer(
  computed(() => ({
    count: rowCount.value,
    getScrollElement: () => parentRef.value,
    estimateSize: () => rowHeight.value,
    overscan: 5,
  })),
)

const virtualRows = computed(() => rowVirtualizer.value.getVirtualItems())
const totalHeight = computed(() => rowVirtualizer.value.getTotalSize())

function rowItems(rowIndex: number): GridCell[] {
  const start = rowIndex * cols.value
  return cells.value.slice(start, start + cols.value)
}

// Fan the series covers horizontally across the 2:1 box (percentage-based, so it scales with tile
// width). Each cover is a square = half the box width (100% of the box height); first cover on top.
function seriesCoverStyle(index: number, count: number) {
  const coverWpct = 50
  const span = 100 - coverWpct
  const spacing = count <= 1 ? 0 : span / (count - 1)
  const left = count === 1 ? span / 2 : index * spacing
  return {
    left: `${left}%`,
    width: `${coverWpct}%`,
    zIndex: count === 1 ? 1 : Math.max(1, 100 - index),
  }
}

function onImgError(e: Event) {
  const img = e.target as HTMLImageElement
  const ph = getPlaceholderUrl()
  if (img && img.src !== ph) img.src = ph
}
function onCellClick(cell: GridCell) {
  if (cell.kind === 'book') router.push(`/audiobooks/${cell.id}`)
  else router.push(`/collection/${cell.type}/${encodeURIComponent(cell.name)}`)
}
function jumpToIndex(itemIndex: number) {
  const clamped = Math.max(0, Math.min(itemIndex, cells.value.length - 1))
  rowVirtualizer.value.scrollToIndex(Math.floor(clamped / cols.value), { align: 'start' })
}

const SCROLL_KEY = 'poc-grid-scroll.'
const GROUP_KEY = 'poc-grid-group'
function saveScroll() {
  try {
    sessionStorage.setItem(SCROLL_KEY + groupBy.value, String(parentRef.value?.scrollTop ?? 0))
  } catch {
    /* ignore */
  }
}
function restoreScroll() {
  const saved = Number(sessionStorage.getItem(SCROLL_KEY + groupBy.value) || 0)
  requestAnimationFrame(() => rowVirtualizer.value.scrollToOffset(saved > 0 ? saved : 0))
}
function setGroup(g: GroupBy) {
  if (g === groupBy.value) return
  saveScroll()
  groupBy.value = g
  try {
    sessionStorage.setItem(GROUP_KEY, g)
  } catch {
    /* ignore */
  }
  nextTick(() => {
    recalc()
    restoreScroll()
  })
}

let ro: ResizeObserver | null = null
onMounted(async () => {
  const savedGroup = sessionStorage.getItem(GROUP_KEY)
  if (savedGroup === 'books' || savedGroup === 'authors' || savedGroup === 'series') {
    groupBy.value = savedGroup
  }
  if (books.value.length === 0) await libraryStore.fetchLibrary()
  await nextTick()
  recalc()
  ro = new ResizeObserver(() => recalc())
  if (parentRef.value) ro.observe(parentRef.value)
  await nextTick()
  restoreScroll()
})
onBeforeUnmount(() => {
  saveScroll()
  ro?.disconnect()
  ro = null
})
</script>

<style scoped>
.poc-page {
  height: calc(100dvh - var(--app-top-offset, 60px));
  display: flex;
  flex-direction: column;
  background: #141414;
}
.poc-toolbar {
  display: flex;
  align-items: center;
  gap: 12px;
  padding: 10px 16px;
  border-bottom: 1px solid #2a2a2a;
}
.poc-toolbar h2 {
  font-size: 15px;
  margin: 0;
  color: #eee;
}
.poc-group {
  display: flex;
  gap: 4px;
}
.poc-hint {
  color: #8aa;
  font-size: 12px;
}
.poc-spacer-flex {
  flex: 1;
}
.poc-btn {
  padding: 6px 12px;
  border: 1px solid #444;
  background: #2a2a2a;
  color: #eee;
  border-radius: 6px;
  cursor: pointer;
  font-size: 13px;
  text-transform: capitalize;
}
.poc-btn:hover {
  border-color: #7aa;
}
.poc-btn.active {
  border-color: #2ecc71;
  color: #2ecc71;
}
.poc-scroll {
  flex: 1;
  overflow-y: auto;
  overflow-x: hidden;
  padding: 12px;
}
.poc-inner {
  position: relative;
  width: 100%;
}
.poc-row {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  display: flex;
  gap: 12px;
}
.poc-tile {
  flex: 1 1 0;
  min-width: 0;
  cursor: pointer;
  border-radius: 8px;
  outline: none;
}
.poc-tile:focus-visible {
  box-shadow: 0 0 0 2px #7aa;
}
.poc-tile--pad {
  visibility: hidden;
}
.poc-cover-box {
  position: relative;
  width: 100%;
  background: #1b1b1b;
  border-radius: 8px;
  overflow: hidden;
  transition: transform 0.1s;
}
.poc-tile:hover .poc-cover-box {
  transform: translateY(-2px);
}
.poc-cover {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
/* series fanned covers */
.poc-series {
  position: absolute;
  inset: 0;
}
.poc-series-item {
  position: absolute;
  top: 0;
  height: 100%;
  aspect-ratio: 1 / 1;
  border-radius: 6px;
  overflow: hidden;
  box-shadow: rgba(17, 17, 17, 0.45) 4px 0 6px;
}
.poc-series-img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.poc-overlay {
  position: absolute;
  inset: auto 0 0 0;
  padding: 8px 8px 10px;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.9), rgba(0, 0, 0, 0.55) 55%, rgba(0, 0, 0, 0));
  z-index: 15;
}
.poc-t {
  font-size: 12px;
  font-weight: 600;
  color: #fff;
  line-height: 1.2;
  max-height: 2.4em;
  overflow: hidden;
}
.poc-a {
  font-size: 11px;
  color: #c9d3dd;
  line-height: 1.2;
  max-height: 1.2em;
  overflow: hidden;
  white-space: nowrap;
  text-overflow: ellipsis;
}
.poc-status-bar {
  position: absolute;
  left: 0;
  right: 0;
  bottom: 0;
  height: 4px;
  background: transparent;
  z-index: 16;
}
.poc-status-downloading .poc-status-bar {
  background: #3498db;
}
.poc-status-no-file .poc-status-bar {
  background: #e74c3c;
}
.poc-status-quality-mismatch .poc-status-bar {
  background: #f39c12;
}
.poc-status-quality-match .poc-status-bar {
  background: #2ecc71;
}
.poc-count-badge {
  position: absolute;
  top: 8px;
  right: 8px;
  min-width: 22px;
  height: 22px;
  padding: 0 6px;
  border-radius: 11px;
  background: rgba(0, 0, 0, 0.72);
  color: #fff;
  font-size: 12px;
  font-weight: 600;
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 18;
}
</style>
