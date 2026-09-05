<script lang="ts">
  // A small animated equalizer — used as the "thinking" loader.
  let { label = "Thinking…" }: { label?: string } = $props();
  const bars = [0, 1, 2, 3, 4, 5, 6];
</script>

<div class="wave" role="status" aria-label={label}>
  <div class="bars" aria-hidden="true">
    {#each bars as i (i)}
      <span class="bar" style="animation-delay: {i * 0.11}s"></span>
    {/each}
  </div>
  <span class="label">{label}</span>
</div>

<style>
  .wave {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 4px 22px 12px;
    user-select: none;
    -webkit-user-select: none;
  }

  .bars {
    display: flex;
    align-items: center;
    gap: 3px;
    height: 18px;
  }

  .bar {
    width: 3px;
    height: 100%;
    border-radius: 2px;
    background: var(--accent);
    transform: scaleY(0.25);
    transform-origin: center;
    animation: eq 1s ease-in-out infinite;
  }

  .label {
    font-size: 12px;
    color: var(--text-dim);
  }

  @keyframes eq {
    0%,
    100% {
      transform: scaleY(0.25);
      opacity: 0.6;
    }
    50% {
      transform: scaleY(1);
      opacity: 1;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .bar {
      animation: none;
      transform: scaleY(0.6);
    }
  }
</style>
