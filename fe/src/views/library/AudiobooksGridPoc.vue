<!--
  TanStack Virtual grid PROOF OF CONCEPT (throwaway, route /poc-grid).
  Not wired into the real AudiobooksView. Demonstrates: virtualized multi-column grid over the real
  library, covers in aspect-ratio boxes (reserve space -> no layout shift), and scrollToIndex (the
  scroll-preservation primitive). New file only; fork-clean.
-->
<template>
  <div class="poc-page">
    <div class="poc-toolbar">
      <h2>TanStack Virtual — Grid POC</h2>
      <span class="poc-hint">{{ books.length }} books · {{ cols }} cols · {{ rowCount }} rows · rowH {{ rowHeight }}px · rendering {{ virtualRows.length }} rows</span>
      <span class="poc-spacer-flex" />
      <button class="poc-btn" @click="jumpToIndex(0)">Top</button>
      <button class="poc-btn" @click="jumpToIndex(500)">Jump to #500</button>
      <button class="poc-btn" @click="jumpToIndex(books.length - 1)">Bottom</button>
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
            v-for="book in rowItems(vRow.index)"
            :key="book.id"
            class="poc-tile"
            :class="'poc-status-' + status(book)"
            tabindex="0"
            @click="goToBook(book.id)"
            @keydown.enter="goToBook(book.id)"
          >
            <div class="poc-cover-box">
              <img class="poc-cover" :src="cover(book)" loading="lazy" @error="onImgError" />
              <div class="poc-overlay">
                <div class="poc-t" :title="book.title">{{ book.title }}</div>
                <div class="poc-a">{{ (book.authors || []).map(safeText).join(', ') || 'Unknown Author' }}</div>
              </div>
              <div class="poc-status-bar" />
            </div>
          </div>
          <!-- keep last row left-aligned when it isn't full -->
          <div
            v-for="n in (cols - rowItems(vRow.index).length)"
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
import { getPlaceholderUrl } from '@/utils/placeholder'
import { safeText } from '@/utils/textUtils'
import { computeAudiobookStatus } from '@/utils/audiobookStatus'
import type { Audiobook } from '@/types'

const router = useRouter()
const libraryStore = useLibraryStore()
const { getProtectedImageSrc } = useProtectedImages()
const noDownloads = new Set<number>()

function status(book: Audiobook): string {
  return computeAudiobookStatus(book, noDownloads)
}
function goToBook(id: number) {
  router.push(`/audiobooks/${id}`)
}

const books = computed(() => libraryStore.audiobooks)

const parentRef = ref<HTMLElement | null>(null)
const TILE_MIN = 170
const GAP = 12
const cols = ref(6)
const rowHeight = ref(230)

function recalc() {
  const w = parentRef.value?.clientWidth ?? 1200
  const nextCols = Math.max(1, Math.floor((w - 24 + GAP) / (TILE_MIN + GAP)))
  const tileW = (w - 24 - GAP * (nextCols - 1)) / nextCols
  cols.value = nextCols
  // square cover (aspect-ratio 1/1 = tileW tall); title/author are overlaid on the cover
  rowHeight.value = Math.round(tileW + 8)
}

const rowCount = computed(() => Math.ceil(books.value.length / cols.value))

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

function rowItems(rowIndex: number): Audiobook[] {
  const start = rowIndex * cols.value
  return books.value.slice(start, start + cols.value)
}

function cover(book: Audiobook): string {
  return getProtectedImageSrc(book.imageUrl, getPlaceholderUrl(), { size: 'grid' })
}

function onImgError(e: Event) {
  const img = e.target as HTMLImageElement
  const ph = getPlaceholderUrl()
  if (img && img.src !== ph) img.src = ph
}

function jumpToIndex(itemIndex: number) {
  const clamped = Math.max(0, Math.min(itemIndex, books.value.length - 1))
  const row = Math.floor(clamped / cols.value)
  rowVirtualizer.value.scrollToIndex(row, { align: 'start' })
}

const SCROLL_KEY = 'poc-grid-scroll'
let ro: ResizeObserver | null = null

onMounted(async () => {
  if (books.value.length === 0) await libraryStore.fetchLibrary()
  await nextTick()
  recalc()
  ro = new ResizeObserver(() => recalc())
  if (parentRef.value) ro.observe(parentRef.value)

  // Restore scroll (saved when we last left). The virtualizer's total height is deterministic
  // (rows * rowHeight, independent of image loading), so scrollToOffset lands exactly, no drift.
  const saved = Number(sessionStorage.getItem(SCROLL_KEY) || 0)
  if (saved > 0) {
    await nextTick()
    requestAnimationFrame(() => rowVirtualizer.value.scrollToOffset(saved))
  }
})

onBeforeUnmount(() => {
  // Save before we leave so returning restores the position (this view remounts, no keep-alive).
  try {
    sessionStorage.setItem(SCROLL_KEY, String(parentRef.value?.scrollTop ?? 0))
  } catch {
    /* ignore */
  }
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
}
.poc-btn:hover {
  border-color: #7aa;
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
  aspect-ratio: 1 / 1;
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
.poc-overlay {
  position: absolute;
  inset: auto 0 0 0;
  padding: 8px 8px 10px;
  background: linear-gradient(to top, rgba(0, 0, 0, 0.9), rgba(0, 0, 0, 0.55) 55%, rgba(0, 0, 0, 0));
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
</style>
