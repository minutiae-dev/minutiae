<script lang="ts">
  import type { Segment } from "../ipc";
  import { fmtClock } from "../time";

  let { segment }: { segment: Segment } = $props();

  // "them:spk1"-style sub-labels (M4) still badge as Them.
  const who = $derived(segment.channel.startsWith("them") ? "them" : "me");
</script>

<div class="segment" class:nonfinal={!segment.final}>
  <span class="badge {who}">{who === "me" ? "Me" : "Them"}</span>
  <span class="time">[{fmtClock(segment.t0)}]</span>
  <span class="text">{segment.text}</span>
</div>

<style>
  .segment {
    display: flex;
    align-items: baseline;
    gap: 8px;
    padding: 3px 0;
  }

  .segment.nonfinal {
    opacity: 0.6;
  }

  .badge {
    flex: none;
    width: 44px;
    text-align: center;
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    border-radius: 4px;
    padding: 1px 0;
    user-select: none;
    -webkit-user-select: none;
  }

  .badge.me {
    color: var(--me);
    background: color-mix(in srgb, var(--me) 16%, transparent);
  }

  .badge.them {
    color: var(--them);
    background: color-mix(in srgb, var(--them) 16%, transparent);
  }

  .time {
    flex: none;
    color: var(--text-dim);
    font-size: 11px;
    font-variant-numeric: tabular-nums;
    user-select: none;
    -webkit-user-select: none;
  }

  .text {
    user-select: text;
    -webkit-user-select: text;
    cursor: text;
  }
</style>
