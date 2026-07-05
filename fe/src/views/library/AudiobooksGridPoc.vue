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
          <div v-for="book in rowItems(vRow.index)" :key="book.id" class="poc-tile">
            <div class="poc-cover-box">
              <img class="poc-cover" :src="cover(book)" loading="lazy" @error="onImgError" />
            </div>
            <div class="poc-title" :title="book.title">{{ book.title }}</div>
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
import { useVirtualizer } from '@tanstack/vue-virtual'
import { useLibraryStore } from '@/stores/library'
import { useProtectedImages } from '@/composables/useProtectedImages'
import { getPlaceholderUrl } from '@/utils/placeholder'
import type { Audiobook } from '@/types'

const libraryStore = useLibraryStore()
const { getProtectedImageSrc } = useProtectedImages()

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
  // square cover (aspect-ratio 1/1 = tileW tall) + ~40px for the title/gap
  rowHeight.value = Math.round(tileW + 40)
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

let ro: ResizeObserver | null = null
onMounted(async () => {
  if (books.value.length === 0) await libraryStore.fetchLibrary()
  await nextTick()
  recalc()
  ro = new ResizeObserver(() => recalc())
  if (parentRef.value) ro.observe(parentRef.value)
})
onBeforeUnmount(() => {
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
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.poc-tile--pad {
  visibility: hidden;
}
.poc-cover-box {
  aspect-ratio: 1 / 1;
  width: 100%;
  background: #1b1b1b;
  border-radius: 8px;
  overflow: hidden;
}
.poc-cover {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.poc-title {
  font-size: 12px;
  color: #ddd;
  line-height: 1.2;
  max-height: 2.4em;
  overflow: hidden;
}
</style>
