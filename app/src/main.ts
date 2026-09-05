import { mount } from "svelte";
import "./styles.css";
import App from "./App.svelte";

if (import.meta.env.MODE === "native-test") void import("@wdio/tauri-plugin");

const app = mount(App, {
  target: document.getElementById("app")!,
});

export default app;
