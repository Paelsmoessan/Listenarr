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
import { vgTrace, vgNextInst } from '@/utils/vgTrace'

// Verbose diagnostics -> the shared vgTrace ring buffer (timestamped + instance-correlated; dump the whole
// timeline via window.__vgDump()). Honors the same `la-debug` gate as the console logger; quiet by default.
const inst = vgNextInst()
function vlog(ev: string, data?: Record<string, unknown>) {
  vgTrace(inst, ev, data)
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

vgTrace(inst, 'create', {
  scrollKey: props.scrollKey,
  items: props.items.length,
  extraHeight: props.extraHeight,
})

const parentRef = ref<HTMLElement | null>(null)
const containerWidth = ref(1200)

function measureContainer(source: 'mount' | 'ro') {
  const old = containerWidth.value
  const next = parentRef.value?.clientWidth ?? old
  containerWidth.value = next
  vgTrace(inst, 'measure', { source, old, new: next })
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

// Index-based scroll restore. We do NOT save a pixel: a pixel only survives if the geometry is identical at
// save and restore time, and the info-ON row-height settle (container-width measure + estimateSize flush)
// breaks that, so the saved pixel lands on the wrong content = the flakiness. Instead the parent records the
// CLICKED item's key via saveAnchor() at click time, and on remount we scrollToIndex to that item, which is
// geometry-INDEPENDENT (the virtualizer recomputes the pixel from the current rowHeight/cols), so the
// width / silent-refetch / cover settle can't drift it. This is TanStack used as intended.
const ANCHOR_PREFIX = 'la-vg-anchor.'
type Anchor = { key: string; align: 'start' | 'center' | 'end' }

function saveAnchor(key: string | number, align: 'start' | 'center' | 'end' = 'center') {
  if (!props.scrollKey) return
  try {
    const anchor: Anchor = { key: String(key), align }
    sessionStorage.setItem(ANCHOR_PREFIX + props.scrollKey, JSON.stringify(anchor))
    vgTrace(inst, 'anchor:save', anchor)
  } catch {
    /* ignore */
  }
}

function readAnchor(): Anchor | null {
  if (!props.scrollKey) return null
  try {
    const raw = sessionStorage.getItem(ANCHOR_PREFIX + props.scrollKey)
    if (!raw) return null
    const a = JSON.parse(raw) as Partial<Anchor>
    if (a && typeof a.key === 'string') return { key: a.key, align: a.align ?? 'center' }
  } catch {
    /* ignore */
  }
  return null
}

function clearAnchor() {
  if (!props.scrollKey) return
  try {
    sessionStorage.removeItem(ANCHOR_PREFIX + props.scrollKey)
  } catch {
    /* ignore */
  }
}

// Diagnostic-only watchdog: after a restore, watch for the row height / total size STILL changing (the late
// async settle). Fires post-restore-shift on any change; bounded to ~1200ms and cancelled on unmount. Pure
// observation, no scroll side effects.
let stopPostRestoreWatch: (() => void) | null = null
function startPostRestoreWatch() {
  stopPostRestoreWatch?.()
  const prevRowHeight = rowHeight.value
  const prevTotalSize = totalSize.value
  const stop = watch([rowHeight, totalSize], ([rh, ts]) => {
    vgTrace(inst, 'post-restore-shift', {
      rowHeight: rh,
      prevRowHeight,
      totalSize: ts,
      prevTotalSize,
      scrollTopNow: parentRef.value?.scrollTop ?? 0,
    })
  })
  stopPostRestoreWatch = () => {
    stop()
    stopPostRestoreWatch = null
  }
  window.setTimeout(() => stopPostRestoreWatch?.(), 1200)
}

function restoreAnchor() {
  const anchor = readAnchor()
  if (!anchor) {
    vgTrace(inst, 'restore:skip', { reason: 'no-anchor' })
    return
  }
  const idx = props.items.findIndex((it, i) => String(props.itemKey(it, i)) === anchor.key)
  if (idx < 0) {
    // Item is gone (re-sorted/filtered away); leave scroll at top rather than jump somewhere wrong.
    vgTrace(inst, 'restore:index', { found: false, savedKey: anchor.key, itemsLen: props.items.length })
    clearAnchor()
    return
  }
  const row = Math.floor(idx / cols.value)
  const tScroll = performance.now()
  rowVirtualizer.value.scrollToIndex(row, { align: anchor.align })
  // DIAGNOSTIC: the scroll jump re-renders the target screenful of cards. Measure how long the main thread
  // stays blocked afterwards (double-rAF fires only once it's free) — prime suspect for the ~1.6s stall
  // before covers load.
  requestAnimationFrame(() =>
    requestAnimationFrame(() =>
      vgTrace(inst, 'restore:thread-free', { ms: Math.round(performance.now() - tScroll) }),
    ),
  )
  vgTrace(inst, 'restore:index', {
    found: true,
    savedKey: anchor.key,
    foundIndex: idx,
    targetRow: row,
    align: anchor.align,
    cols: cols.value,
    rowHeight: rowHeight.value,
    scrollAfter: parentRef.value?.scrollTop ?? 0,
  })
  clearAnchor()
  startPostRestoreWatch()
}

let ro: ResizeObserver | null = null
onMounted(async () => {
  measureContainer('mount')
  vlog('mounted ' + props.scrollKey, {
    items: props.items.length,
    extraHeight: props.extraHeight,
    containerWidth: containerWidth.value,
    cols: cols.value,
    tileWidth: Math.round(tileWidth.value),
    rowHeight: rowHeight.value,
    totalSize: totalSize.value,
  })
  ro = new ResizeObserver(() => measureContainer('ro'))
  if (parentRef.value) {
    ro.observe(parentRef.value)
  }
  await nextTick()
  restoreAnchor()
})
onBeforeUnmount(() => {
  vgTrace(inst, 'unmount', { scrollTop: parentRef.value?.scrollTop ?? 0 })
  stopPostRestoreWatch?.()
  ro?.disconnect()
  ro = null
})

// The parent calls saveAnchor(clickedItemKey) from its navigate-to-detail handler while this grid is still
// mounted; on remount restoreAnchor() centers that item. That is the whole save/restore contract now.
defineExpose({ saveAnchor })
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
