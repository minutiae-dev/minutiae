<script lang="ts">
  // Mount point for the optional SaaS UI (account, sign-in, sync).
  //
  // The actual components live in the gitignored `./saas/` dir and ship only in
  // `--features saas` / VITE_SAAS builds. `import.meta.glob` resolves to `{}`
  // when that dir is absent, so the OSS `vite build` stays green; the
  // `VITE_SAAS` guard is statically eliminated so the loader is never even
  // emitted in OSS builds.
  //
  // Pass `name` to pick which gitignored component to mount, e.g.
  // `<SaasMount name="SignInOverlay" />`.
  import { onMount } from "svelte";

  let { name = "Account" }: { name?: string } = $props();

  let Component = $state<any>(null);

  onMount(async () => {
    if (!import.meta.env.VITE_SAAS) return;
    const mods = import.meta.glob("./saas/*.svelte");
    const loader = mods[`./saas/${name}.svelte`];
    if (loader) {
      Component = ((await loader()) as { default: unknown }).default;
    }
  });
</script>

{#if Component}
  <Component />
{/if}
