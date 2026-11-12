# Roblox Server-Authoritative Abilities & Status Effects System

A production-grade, highly secure, and modular ability and status effect framework for Roblox Studio. Built with **Client Prediction**, state **Reconciliation**, a centralized server-authoritative tick loop, and a fully code-generated modern hotbar UI.

> **⚠️ Important Architectural Note:** This system serves as an **advanced architectural example and a structural guideline** for writing clean, secure combat and skill code. To integrate this into your own project, you must adapt it to match your game's specific loop, attribute databases, and combat mechanics.

---

## Key Features

- **Client Prediction & Reconciliation:** 
  - Instant client-side responsiveness (vfx, animations, and predictions fire immediately on keypress). 
  - The server validates inputs in the background; if a cast is rejected, the client gracefully rolls back cooldowns and plays fail-feedback without breaking UI state.
- **Optimized Status Effect Manager (`StatusEffectManager`):** 
  - Avoids per-effect thread leaks by running a single unified `Heartbeat` loop on the server that automatically sleeps when idle. 
  - Handles dot-damage, healing-over-time (HoT), and multiplicative speed stacking with safe cleanup on character death.
- **Anti-Exploit & Token-Bucket Rate Limiting:** 
  - Strict server-side validation (raycast line-of-sight checks, distance clamps, and `OverlapParams` hitboxes). 
  - Built-in token-bucket rate limiter to protect against request spamming.
- **Procedural Responsive UI & Hotbar:** 
  - Fully code-generated hotbar, dynamic resource bars (Mana/Stamina with smooth lerp interpolation), and animated cooldown overlays.

---

## System Architecture & Structure

- **`AbilityConfig.lua` (ReplicatedStorage):** Shared static ability definitions, resource pools, slot keybinds, and client-side visual effect hooks.
- **`AbilityServer.server.lua` (ServerScriptService):** Core server logic handling cast validation, token buckets, resource costs, global cooldowns, and built-in type handlers (Dash, AOE projectiles, Heals, Buffs).
- **`StatusEffectManager.lua` (ServerScriptService):** Optimized server-side manager handling active status effects and attribute flags (`Fx_*`).
- **`AbilityClient.client.lua` (StarterPlayerScripts):** Pure client script handling hotbar inputs, predictive local casting, animation playback, and server reconciliation.

---

## Installation & Setup

1. Place the **`Abilities`** folder containing `AbilityConfig` and a `Remotes` folder inside `ReplicatedStorage`.
2. Place **`AbilityServer`** and **`StatusEffectManager`** inside a folder in `ServerScriptService`.
3. Place **`AbilityClient`** as a `LocalScript` inside `StarterPlayerScripts`.

---

## License

This project is open-source and available under the [MIT License](LICENSE).
