<!--
  VirtualGrid , headless, sideloaded virtualized grid (TanStack Virtual).
  Owns ONLY the scroll host + row virtualization; the parent supplies each card via the default slot, so
  all existing card markup/CSS is preserved. Faithful to the app's CSS grid:
    - dynamic column width: cols packed like `repeat(auto-fill, minmax(minItemWidth, 1fr))`, laid out per row
      as `repeat(cols, minmax(0,1fr))` (identical widths, clean edge splits).
    - DETERMINISTIC uniform row height COMPUTED from tile width (poster aspect + fixed extra + gap) , no
      per-frame measurement, no getBoundingClientRect, so scroll positions are stable and restorable
      (the app's scroll-restore relies on deterministic row heights; see AudiobooksView "#676" note).
  Row-virtualizes: count = ceil(items/cols); grid modes N cols; list mode fixedColumns=1 + fixedRowHeight.
-->
<template>
  <div ref="parentRef" class="vg-scroll">
    <div class="vg-inner" :style="{ height: totalSize + 'px' }">
      <div
        v-for="vRow in virtualRows"
        :key="vRow.index"
        class="vg-row"
        :style="{
          transform: `translateY(${vRow.start}px)`,
          gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`,
          gap: gap + 'px',
        }"
      >
        <slot
          v-for="cell in rowCells(vRow.index)"
          :key="itemKey(cell.item, cell.index)"
          :item="cell.item"
          :index="cell.index"
        />
      </div>
    </div>
  </div>
</template>

<script setup lang="ts" generic="T">
import { ref, computed, onMounted, onBeforeUnmount, nextTick, watch } from 'vue'
import { useVirtualizer } from '@tanstack/vue-virtual'
import { createLogger } from '@/utils/logger'

// Verbose diagnostics via the shared namespaced Logger. Quiet by default; enable at runtime with
// localStorage.setItem('la-debug','1')  (or 'VG').
const log = createLogger('VG')
function vlog(tag: string, data?: unknown) {
  log.debug(tag, data ?? '')
}

const props = withDefaults(
  defineProps<{
    items: T[]
    itemKey: (item: T, index: number) => string | number
    /** min tile width to pack columns like minmax(minItemWidth, 1fr). Ignored if fixedColumns set. */
    minItemWidth?: number
    /** grid gap (px) , matches the app's 20px. */
    gap?: number
    /** force a fixed column count (list mode = 1). */
    fixedColumns?: number
    /** horizontal padding inside the scroll host (px each side) to subtract when packing columns. */
    padX?: number
    overscan?: number
    /** poster aspect (height / width): 1 = square (books/authors), 0.5 = 2:1 wide (series). */
    aspectRatio?: number
    /** fixed extra height added under the tile (e.g. the details block = 64). Changes -> row height recomputes. */
    extraHeight?: number
    /** if > 0, use this fixed row height directly instead of computing from tile width (list mode). */
    fixedRowHeight?: number
    /** if set, VirtualGrid self-manages scroll save/restore under this sessionStorage key (POC pattern):
     *  restores on mount (after width is measured) and saves on unmount. */
    scrollKey?: string
  }>(),
  {
    minItemWidth: 180,
    gap: 20,
    fixedColumns: 0,
    padX: 0,
    overscan: 6,
    aspectRatio: 1,
    extraHeight: 0,
    fixedRowHeight: 0,
    scrollKey: '',
  },
)

const parentRef = ref<HTMLElement | null>(null)
const containerWidth = ref(1200)

function measureContainer() {
  containerWidth.value = parentRef.value?.clientWidth ?? containerWidth.value
}

const cols = computed(() => {
  if (props.fixedColumns && props.fixedColumns > 0) return props.fixedColumns
  const w = containerWidth.value - props.padX * 2
  // auto-fill minmax(min,1fr): floor((avail + gap) / (min + gap))
  return Math.max(1, Math.floor((w + props.gap) / (props.minItemWidth + props.gap)))
})

const tileWidth = computed(() => {
  const w = containerWidth.value - props.padX * 2 - props.gap * (cols.value - 1)
  return Math.max(0, w / cols.value)
})

// DETERMINISTIC row height , computed, never measured. Recomputes when width/cols/aspect/extra change
// (incl. the details toggle via extraHeight), which is exactly when it should.
const rowHeight = computed(() => {
  if (props.fixedRowHeight && props.fixedRowHeight > 0) return props.fixedRowHeight
  return Math.max(1, Math.round(tileWidth.value * props.aspectRatio + props.extraHeight + props.gap))
})

const rowCount = computed(() => Math.max(1, Math.ceil(props.items.length / cols.value)))

const rowVirtualizer = useVirtualizer(
  computed(() => {
    // Read rowHeight HERE (not only inside the estimateSize closure) so THIS options object changes when
    // the height changes (info toggle / width measure). vue-virtual only calls setOptions + re-measures on
    // an options change; otherwise the virtualizer keeps a STALE total size and scrollToOffset lands on the
    // wrong row — the info-on bug.
    const size = rowHeight.value
    return {
      count: rowCount.value,
      getScrollElement: () => parentRef.value,
      estimateSize: () => size,
      overscan: props.overscan,
    }
  }),
)
const virtualRows = computed(() => rowVirtualizer.value.getVirtualItems())
const totalSize = computed(() => rowVirtualizer.value.getTotalSize())

// Belt-and-suspenders: when the row height changes, drop the virtualizer's cached measurements so total
// size / positions recompute from the new size before we restore scroll.
watch(rowHeight, (h, prev) => {
  if (h !== prev) rowVirtualizer.value?.measure()
})

// Log geometry whenever any input changes (mount, width measure, info toggle). This reveals whether a
// rowHeight change (e.g. extraHeight toggle) actually flows into totalSize, or the virtualizer stays stale.
watch(
  () => [
    containerWidth.value,
    props.extraHeight,
    cols.value,
    Math.round(tileWidth.value),
    rowHeight.value,
    rowCount.value,
    totalSize.value,
    props.items.length,
  ],
  () =>
    vlog('geom ' + props.scrollKey, {
      containerWidth: containerWidth.value,
      extraHeight: props.extraHeight,
      cols: cols.value,
      tileWidth: Math.round(tileWidth.value),
      rowHeight: rowHeight.value,
      rowCount: rowCount.value,
      totalSize: totalSize.value,
      items: props.items.length,
    }),
  { immediate: true },
)

function rowCells(rowIndex: number): { item: T; index: number }[] {
  const start = rowIndex * cols.value
  const end = Math.min(start + cols.value, props.items.length)
  const out: { item: T; index: number }[] = []
  for (let i = start; i < end; i++) out.push({ item: props.items[i], index: i })
  return out
}

// Self-contained scroll save/restore, when scrollKey is set. We save at exactly ONE moment — when the grid
// unmounts (leaving to a detail, the sidebar, anywhere off the page) — and restore on mount. No per-frame
// tracking: it isn't needed and was the source of the restore fighting the user and of stale/garbage saves.
const SCROLL_PREFIX = 'la-vg-scroll.'

function saveScroll() {
  if (!props.scrollKey) return
  try {
    const top = parentRef.value?.scrollTop ?? 0
    vlog('save ' + props.scrollKey, { top, rowHeight: rowHeight.value, totalSize: totalSize.value })
    sessionStorage.setItem(SCROLL_PREFIX + props.scrollKey, String(top))
  } catch {
    /* ignore */
  }
}

// Restore lifecycle guards: userInteracted aborts an in-flight re-assert so it never fights the user;
// disposed + restoreRaf let us cancel the loop on unmount so we never scroll a torn-down virtualizer.
let userInteracted = false
let disposed = false
let restoreRaf = 0
function onUserIntent() {
  userInteracted = true
}

function restoreScroll() {
  if (!props.scrollKey) return
  const saved = Number(sessionStorage.getItem(SCROLL_PREFIX + props.scrollKey) || 0)
  vlog('restore:req ' + props.scrollKey, {
    saved,
    rowHeight: rowHeight.value,
    totalSize: totalSize.value,
    scrollHeight: parentRef.value?.scrollHeight,
    clientHeight: parentRef.value?.clientHeight,
  })
  if (saved <= 0) return
  // The virtualizer applies its new total height on a later async cycle, so an early scrollToOffset
  // CLAMPS a few rows short (the flaky "2-3 rows too high"). Re-assert each frame until scrollTop reaches
  // the saved offset, bailing if the user grabs the scroll or the component unmounts mid-restore.
  userInteracted = false
  let tries = 0
  const apply = () => {
    restoreRaf = 0
    if (disposed || userInteracted) return
    rowVirtualizer.value.scrollToOffset(saved)
    tries += 1
    const got = parentRef.value?.scrollTop ?? 0
    if (Math.abs(got - saved) > 1 && tries < 12) {
      restoreRaf = requestAnimationFrame(apply)
    } else {
      vlog('restore:done ' + props.scrollKey, {
        want: saved,
        got,
        tries,
        totalSize: totalSize.value,
        scrollHeight: parentRef.value?.scrollHeight,
      })
    }
  }
  restoreRaf = requestAnimationFrame(apply)
}

let ro: ResizeObserver | null = null
onMounted(async () => {
  measureContainer()
  vlog('mounted ' + props.scrollKey, {
    items: props.items.length,
    extraHeight: props.extraHeight,
    rowHeight: rowHeight.value,
  })
  ro = new ResizeObserver(() => measureContainer())
  if (parentRef.value) {
    ro.observe(parentRef.value)
    parentRef.value.addEventListener('wheel', onUserIntent, { passive: true })
    parentRef.value.addEventListener('touchstart', onUserIntent, { passive: true })
    parentRef.value.addEventListener('keydown', onUserIntent)
  }
  await nextTick()
  restoreScroll()
})
onBeforeUnmount(() => {
  // Save on leaving the grid — covers EVERY exit (detail click, sidebar, any navigation off the page).
  saveScroll()
  // Stop any in-flight restore re-assert so it can't scrollToOffset a torn-down virtualizer.
  disposed = true
  if (restoreRaf) cancelAnimationFrame(restoreRaf)
  parentRef.value?.removeEventListener('wheel', onUserIntent)
  parentRef.value?.removeEventListener('touchstart', onUserIntent)
  parentRef.value?.removeEventListener('keydown', onUserIntent)
  ro?.disconnect()
  ro = null
})
</script>

<style scoped>
.vg-scroll {
  height: 100%;
  overflow-y: auto;
  overflow-x: hidden;
}
.vg-inner {
  position: relative;
  width: 100%;
}
.vg-row {
  position: absolute;
  top: 0;
  left: 0;
  width: 100%;
  display: grid;
  align-content: start;
}
</style>
