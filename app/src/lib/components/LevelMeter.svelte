<script lang="ts">
  let { label, db }: { label: string; db: number } = $props();

  // Map -60..0 dBFS onto 0..100% bar width.
  const pct = $derived(Math.min(1, Math.max(0, (db + 60) / 60)) * 100);
  const hot = $derived(db > -6);
</script>

<div class="meter">
  <span class="label">{label}</span>
  <div class="track">
    <div class="fill" class:hot style:width="{pct}%"></div>
  </div>
  <span class="db">{db <= -119 ? "-∞" : db.toFixed(0)} dB</span>
</div>

<style>
  .meter {
    display: flex;
    align-items: center;
    gap: 8px;
    flex: 1;
    min-width: 0;
    user-select: none;
    -webkit-user-select: none;
  }

  .label {
    width: 40px;
    flex: none;
    text-align: right;
    color: var(--text-dim);
    font-size: 12px;
  }

  .track {
    flex: 1;
    height: 6px;
    border-radius: 3px;
    background: var(--bg-inset);
    border: 1px solid var(--border);
    overflow: hidden;
  }

  .fill {
    height: 100%;
    background: var(--them);
    border-radius: 3px;
    transition: width 80ms linear;
  }

  .fill.hot {
    background: var(--warn);
  }

  .db {
    width: 52px;
    flex: none;
    color: var(--text-dim);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
    text-align: right;
  }
</style>
