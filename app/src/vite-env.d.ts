/// <reference types="svelte" />
/// <reference types="vite/client" />

interface ImportMetaEnv {
  /**
   * Set ("1") for proprietary SaaS builds. Statically replaced by Vite, so the
   * SaaS UI branch is dead-code-eliminated (and never references the gitignored
   * `lib/saas/` dir) in the OSS build.
   */
  readonly VITE_SAAS?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
