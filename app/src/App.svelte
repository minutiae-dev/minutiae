<script lang="ts">
  import { onMount } from "svelte";
  import { session } from "./lib/stores/session.svelte";
  import Sidebar from "./lib/components/Sidebar.svelte";
  import CaptureControls from "./lib/components/CaptureControls.svelte";
  import LevelMeter from "./lib/components/LevelMeter.svelte";
  import Scratchpad from "./lib/components/Scratchpad.svelte";
  import MeetingTabs from "./lib/components/MeetingTabs.svelte";
  import SourcesGear from "./lib/components/SourcesGear.svelte";
  import SaasMount from "./lib/SaasMount.svelte";

  onMount(() => {
    session.init();
    return () => session.destroy();
  });

  const showLevels = $derived(
    session.phase === "recording" || session.phase === "stopping",
  );
</script>

<main class="app">
  <Sidebar />

  <section class="content">
    <header class="topbar" data-tauri-drag-region>
      <CaptureControls />
      <div class="topbar-right">
        {#if showLevels}
          <div class="levels">
            <LevelMeter
              compact
              channel="me"
              label="Me"
              db={session.levels.meDb}
            />
            <LevelMeter
              compact
              channel="them"
              label="Them"
              db={session.levels.themDb}
            />
          </div>
        {/if}
        <SourcesGear />
      </div>
    </header>

    <div class="workspace">
      <section class="pane notes">
        <Scratchpad />
      </section>
      <section class="pane tabs">
        <MeetingTabs />
      </section>
    </div>
  </section>

  <!-- Optional skippable startup sign-in (gitignored; SaaS builds only). -->
  <SaasMount name="SignInOverlay" />
</main>

<style>
  .app {
    height: 100vh;
    display: flex;
    background: var(--bg);
  }

  .content {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
  }

  /* Control bar — the one focal surface, sits in the title-bar region. */
  .topbar {
    display: flex;
    align-items: center;
    gap: 20px;
    /* Top pad clears the overlay title bar; the sidebar holds the traffic lights. */
    padding: 14px 22px 14px;
    min-height: 60px;
  }

  .topbar-right {
    display: flex;
    align-items: center;
    gap: 16px;
    margin-left: auto;
  }

  .levels {
    display: flex;
    flex-direction: column;
    gap: 5px;
    width: 280px;
  }

  .workspace {
    flex: 1;
    min-height: 0;
    display: flex;
  }

  /* Flat panes separated by a single hairline — no boxes. */
  .pane {
    flex: 1;
    min-width: 0;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }

  .pane.tabs {
    border-left: 1px solid var(--border-soft);
  }
</style>
