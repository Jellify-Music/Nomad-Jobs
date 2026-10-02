# valheim

Dedicated Valheim server, via
[`mbround18/valheim`](https://github.com/mbround18/valheim-docker)'s Odin
manager. World name "Jellify", server name "Cosmonautical" — see the `WORLD`
env var's own comment in
[`valheim.nomad.hcl`](valheim.nomad.hcl) before ever changing it (a rename
after first boot starts a brand new world, it doesn't rename the existing
one).

## Notable choices

- **`amd64`-only constraint.** Valheim's dedicated server and its SteamCMD
  installer are amd64-only, and the container driver's Rosetta translation on
  the arm64 jellify nodes (galileo/hopper) can't run SteamCMD's 32-bit
  bootstrap binary — runs on the x86_64 jellify nodes
  (kepler/fibonacci/euler/dijkstra) instead, added to the cluster
  specifically for jobs like this one and `minecraft`. Of those, it only
  runs on Nomadable's `game_servers` inventory group (euler/kepler), via the
  `meta.inventory_groups` node meta.
- **`PUBLIC = "0"`.** Friends-only server, reachable by direct IP/Steam
  invite — not listed in the public Steam server browser, avoiding random
  scan/join attempts against a modded, password-protected server.
- **`ENABLE_CROSSPLAY = "0"`.** BepInEx mods hook Steam networking
  specifically, and crossplay (Xbox/PlayStation via PlayFab) is mutually
  exclusive with them with no workaround. Costs nothing here since every
  client is already on Steam (Linux/Windows/macOS).
- **Everything under `/home/steam/valheim` is persisted** (server binary,
  BepInEx install, fetched mods), not just the world save — Odin owns that
  whole tree, so a redeploy doesn't have to re-download BepInEx/mods from
  Thunderstore every time.

## Mods — "the Jellify pack"

Toil-reduction only, deliberately no stat/balance/loot changes.

| Mod | Version | Purpose |
|---|---|---|
| [Jotunn](https://valheim.thunderstore.io/package/ValheimModding/Jotunn/) | 2.30.2 | Modding library — a dependency of other mods in the pack, not user-facing on its own. |
| [Quick Stack Store Sort Trash Restock](https://valheim.thunderstore.io/package/Goldenrevolver/Quick_Stack_Store_Sort_Trash_Restock/) | 1.4.15 | Chest quick-stack/sort/restock QoL. |
| [EquipmentAndQuickSlots](https://valheim.thunderstore.io/package/RandyKnapp/EquipmentAndQuickSlots/) | 3.1.3 | Extra hotbar/equipment slots. |
| [OttoFuel](https://valheim.thunderstore.io/package/potto007/OttoFuel/) | 1.6.5 | Auto-feeds fuel/ore into smelters/kilns/fires/torches from nearby chests and ground items. |
| [Better Beehives](https://valheim.thunderstore.io/package/MaxFoxGaming/Better_Beehives/) | 1.3.0 | Queen bee/royal jelly drop chance on honey harvest, plus a pollination growth buff for crops near hives. Does **not** auto-collect honey — no maintained mod does that without also requiring the ServerSync hard-block below, or being single-player-only. |

### Why these, and not alternatives

Every mod above is bare-BepInEx: no Jotunn-registered content and no
ServerSync version handshake, so a vanilla client can still join and play,
just without that mod's QoL.

**AzuAutoStore and AzuCraftyBoxes were tried and dropped** (2026-09-29).
Both are Azumatt/ServerSync-based, and ServerSync's networking handshake
requires the *client* to have the mod installed at all, independent of its
"Lock Configuration" setting — a vanilla client never answers that handshake
and gets disconnected with an "Incompatible version" error. Vanilla-client
compatibility was chosen over those two mods' QoL, since this server is
meant to stay joinable without asking every player to install a mod loader.

## Persistence

World/save/BepInEx-plugin data all live on the Jellify NFS share (mounted at
`/mnt/jellify/valheim/...`), same reasoning as `minecraft`'s NFS-backed data
— see `../CHANGELOG.md`'s minecraft entries for the NFS-stall/local-disk
tradeoffs that don't apply the same way here (Valheim doesn't have the same
autosave-thread stall issue that forced minecraft onto a local-disk hot
copy).

## Consul KV keys

| Key | Used for |
|---|---|
| `valheim/SERVER_PASSWORD` | Server join password |

## Adding or dropping a mod

1. Confirm it's bare-BepInEx (or, if it needs Jotunn/ServerSync, confirm
   *every* player is willing to install the mod client-side — see the
   AzuAutoStore/AzuCraftyBoxes note above).
2. Add `<Author>-<Name>-<Version>` to the `MODS` heredoc in
   [`valheim.nomad.hcl`](valheim.nomad.hcl) (Thunderstore's own naming
   scheme — Odin resolves and installs it by that string).
3. Add a row here, and record the decision (especially anything rejected and
   why) in `../CHANGELOG.md` under a new dated entry.
