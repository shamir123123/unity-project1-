# Project Rules

## 0) Code Index — read before exploring

`CODE_INDEX.md` (repo root) maps every script in the Studio place: full path,
kind, line count, purpose, public functions. The game source lives only in
Studio, so to find code: **`Grep` CODE_INDEX.md first**, get the exact
`Full.Path.Name`, then `script_read` only that script. Don't walk the game tree
to locate things. After adding/removing/renaming scripts, regenerate it (Luau at
the bottom of CODE_INDEX.md).

## 0b) What This Game Is â€” design rules for every system

- **It is a SIMULATION.** Nothing is faked. A number the player sees comes from the sim
  (real households, real kW, real mÂ³), never a timer or a random roll dressed up as one.
  If a building has no water, it is because no water reached it.
- **Public on Roblox, played by a lot of kids.** Every system is EASY on the surface and
  deep inside: the default path must be obvious (e.g. "put a water tower by a road"), and
  the depth (separate grids, trading at the map edge, batteries, pumps vs outlets) is
  there for players who go looking. It should be a little challenging, never punishing:
  warn before anything bad happens, give a grace period, make the fix clear.
- **Consequences are gradual and visible.** A missing service costs happiness and makes
  families move out ONE AT A TIME, with a badge over the building and a notice saying
  what to build. Never wipe out a district in one tick.
- **Low-end devices first.** Sims run on the server on a slow tick; the client only draws
  what a view needs (e.g. pipes only in the water view). No per-frame work that scales
  with the city.

**Backlog (after utilities â€” water, electricity, sewage â€” are finished):** police, fire
department and hospital/healthcare systems. Do not start these until the user says so.

## 0c) A change is not done until you know what it touches

Learned on the 2026-10-05 load-time pass: every one of these "worked" in the one Studio test it
got, and broke something else. Think it through BEFORE writing the code, not after a tester finds it.

- **List who else reads or writes the same state, and when.** Moving work earlier, later or into
  parallel changes what everything around it sees. (Terrain was streamed to the client earlier, so
  it went out before the roads re-cut the ground: grass through every road, cliffs on hilly maps.)
- **A shortcut that skips work must hold on every path that reaches it.** "Keep what is unchanged",
  "only send what changed", "already done" -- name each path and check it: first load on a fresh
  server; the SAME city reloaded in a server where it still stands (rejoin, multiplayer); switching
  cities; players already in the server while it loads; the teleport from the lobby; a load that
  fails halfway. (Roads kept as "unchanged" after the terrain load had wiped their ground cuts:
  every road in a trench after a rejoin.)
- **Studio Play is not live.** In Studio the server and the client share ONE thread; on Roblox they
  are two machines, each city is its own reserved server, players arrive by teleport, and several
  can be in one city. Say which of these your change was tested on and which it was not.
- **Prove it with numbers, not one screenshot.** Time it before and after (two runs each; Studio
  drifts about a second). For correctness, compare the state itself (e.g. client ground against
  server ground at every road), and run the same check on the OLD code so you know it can fail.
  A change that measures slower is reverted, not explained away.
- **Saves hold source data; derived state is rebuilt on load** (road cuts, building pads, the nav
  graph). Reorder a load and every derived thing must exist before anything reads it or sends it.
- **Anything a player could notice behaving differently is the user's call.** Ask before you change
  it (e.g. walkers not resumed on load, a smaller loading radius), and note the decision in a
  comment where it lives.

Before reporting a change done, write one line saying which of the paths above you checked.

## 1) Script Placement and Run Context

- Server-only code lives in `ServerScriptService` or `ServerStorage`. Never in `ReplicatedStorage`.
- Shared code (used by both client and server) lives in `ReplicatedStorage`.
- Client-only code lives in `StarterPlayerScripts` or `ReplicatedStorage` (if it must be required by client modules).
- Assets the client needs to see live in `ReplicatedStorage`. Assets only the server uses live in `ServerStorage`.
- A `ModuleScript` in `ReplicatedStorage` is visible to exploiters. Do not put server-only logic there, even if "nothing requires it from the client."

## 2) Service Lifecycle

Startup follows a fixed order:
1. Core Systems (DataStore, Networking, Configuration)
2. Gameplay Systems
3. Event Linking
4. Activation

- Every dependency must be declared explicitly in the service definition.
- A missing required dependency must throw during `Init` with a clear message — not silently degrade.
- Services must not rely on boot order outside their declared phase.
- Services must not yield during `Init` unless explicitly documented — a yielding `Init` blocks the entire boot sequence.
- No service waits indefinitely for another. Use a timeout; hard-fail if it is missed.
- `Start` may yield. `Init` may not. `Bind` connects events and must not yield.

## 3) Module Behavior

- Distinguish service modules from library modules:
  - **Service modules** expose `Init()`, `Start()`, or `Bind()` and participate in the lifecycle.
  - **Library modules** are pure utilities — no lifecycle, no state, no side effects on `require`.
- **One convention for how you depend on each, so the dependency graph is honest:**
  - **Library modules** are `require`d directly at the top of the file. They are stateless, so there is nothing to inject.
  - **Stateful services** are injected via `Init(...)` — never `require`d directly from another service. A direct `require` of a stateful service hides the edge from Bootstrap and makes the real coupling worse than the wiring shows.
  - The single allowed exception is a true infra singleton that nearly everything needs (today: `TerrainDataService`/`TerrainGradeService`/`TerrainPadService`, `NPCDriverService`). If a service is on this list it is `require`d directly *everywhere* and never also injected — pick one path per service, never both.
- Modules must not run imperative code at top level.
- Loading a module must have zero side effects.
- A module must be loadable in a test environment without requiring a live game server.

## 4) Ownership and State

- Each service owns exactly one domain.
- Each domain has exactly one source of truth.
- State changes must go through the owning service's public interface.
- External systems access state through getters on the owning service — not by reading internal tables directly.
- A service's internal state is private unless explicitly exposed.
- Never use `_G`, `shared`, or shared module-level tables as a communication channel.

## 5) Communication

- Services communicate through defined events or typed request interfaces.
- No hidden cross-service coupling. If two services share data, one owns it and the other requests it.
- `RemoteEvent` and `RemoteFunction` are transport only — no business logic inside the handler.
- Network handlers validate immediately, then hand off to a server-side service.
- `BindableEvent` and `BindableFunction` are preferred over direct cross-service calls when the consumer should not depend on the producer's interface.
- Never pass instance references across the client-server boundary that the receiving side does not need or own.

## 6) Security

- Treat every client input as untrusted, regardless of context.
- Validate on the server: type, range, ownership, rate, and sequence.
- Server is authoritative for all gameplay state. The client may predict — the server decides.
- Rate-limit all remote calls. Reject and log violations immediately.
- Never trust a client-sent player ID, character reference, or tool state. Use `Player` from the remote's first argument.
- Never expose server-only modules or internal data to the client.
- Do not store sensitive flags, currency values, or progression state on the client expecting the server to read them back.
- `RemoteFunction` invoked by the server on the client can yield indefinitely or error — prefer `RemoteEvent` for server-to-client unless a response is required.

## 7) Data Persistence

- One service owns player data. Nothing else writes to `DataStore` directly.
- Assume `DataStore` calls can and will fail. Handle the failure case explicitly every time.
- Wrap every `DataStore` call in `pcall` and implement retry with exponential backoff.
- Respect `DataStore` request budgets. Do not write on every state change — buffer and flush.
- On load failure, do not give the player a default state and then save over their real data. Kick the player or mark the session as non-persistent.
- Use `UpdateAsync`, not `SetAsync`, for anything that could race.
- Use session locking to prevent the same player's data being written from two servers.
- Store source data only. Never persist derived values — compute them at runtime.
- Validate loaded data against a schema before trusting it. Handle schema migrations explicitly.
- Always save on `PlayerRemoving` and on `BindToClose`. `BindToClose` must yield until saves complete (with a timeout).

## 8) Player Lifecycle

- `PlayerAdded` and `PlayerRemoving` are the two most failure-prone flows in the game. Handle both explicitly in every service that cares about players.
- Always handle the late-join case: players may already be present when a service initializes. Iterate `Players:GetPlayers()` after connecting `PlayerAdded`.
- Never assume a player is still in the game after a yield. Check `player.Parent ~= nil` or equivalent before acting on a player reference following any async gap.
- Async operations that can outlive a player — data loads, callbacks, delayed tasks — must verify the player is still valid before completing.
- On `PlayerRemoving`, cleanup must run synchronously and reliably. Do not fire-and-forget.
- `CharacterAdded` can fire multiple times per player. Track the current character explicitly.

## 9) Cleanup and Memory

- Every `RBXScriptConnection` must be tracked and disconnected when the owning system is done with it.
- Use a cleanup object (Maid, Trove, or equivalent) for anything scoped to a player, a round, or a temporary object.
- Destroying an instance does not reliably disconnect all its connections — clean up explicitly.
- Every service that allocates per-player state must release it on `PlayerRemoving`, unconditionally.
- Do not assume the garbage collector handles leaked connections or instances. It does not.
- `task.delay` and `task.spawn` create references that can outlive their context — track them if they touch state that may be cleaned up.

## 10) Error Handling

- Errors must be caught at clear service boundaries.
- One failing system must not crash the game. Isolate faults.
- Log with: system, operation, player (if relevant), cause, and traceback.
- Use severity consistently:
  - `warn` — recoverable, degraded behavior, needs investigation
  - `error` — unrecoverable in context, player or system is affected
- Do not swallow errors silently. If you catch and do not rethrow, log it.
- Invalid state must be surfaced immediately, not left to cause downstream failures.
- `pcall` is for expected failures (network, datastore). It is not a substitute for fixing logic bugs.

## 11) Async

- Spawn tasks intentionally. Every `task.spawn` must have a clear reason.
- Do not spawn uncontrolled tasks inside loops or event handlers.
- Never use `wait()` or `task.wait()` without a timeout in code that depends on an external condition. Use a timed loop or signal with a deadline.
- Keep `Heartbeat`, `Stepped`, and `RenderStepped` handlers minimal — reads and lightweight checks only.
- Move heavy work into scheduled tasks or dedicated threads.
- Gameplay correctness must not depend on async resolution order. Use explicit sequencing or completion flags — not timing assumptions.
- Every spawned task that can error must be covered by a `pcall` or an error boundary.
- Prefer `task.defer` over `task.spawn` when ordering within the frame matters.

## 12) Configuration

- Config is immutable at runtime unless a setting is explicitly designed to change.
- Magic numbers and string literals do not belong in logic — they go in a constants module.
- Environment-specific values (dev vs live, feature flags) live in a dedicated config layer, separate from constants.
- Do not read config inside hot paths — cache it at startup.
- Use `table.freeze` on every config and constants table.

## 13) Naming

- `PascalCase` — services, modules, classes, types, `RemoteEvent`s, `BindableEvent`s
- `camelCase` — local variables, functions, parameters
- `UPPER_SNAKE_CASE` — constants
- `_leadingUnderscore` — private fields not meant for external access
- File names match their primary responsibility exactly. No `Misc`, `Utils`, or `Manager2`.
- Event names describe what happened, not what to do: `PlayerDied`, not `KillPlayer`.
- Remote names describe the action from the client's perspective: `RequestPurchase`, not `HandlePurchase`.

## 14) Architecture

- No God objects. No `GameManager`. No service that touches everything.
- Prefer small domain services that can be understood in isolation.
- Prefer composition over inheritance. Inheritance beyond one level requires justification.
- Every service must be replaceable without rewriting its consumers.
- Modules must be designed for isolation — testable without a full game boot.
- A service that depends on more than four other services is a sign of unclear ownership.

## 15) Testing

- Use a specific framework: TestEZ or Jest-Lua. Pick one per project and stick to it.
- Critical paths must have tests: player join, data load, currency, progression, inventory.
- Test the contract, not the implementation. Internal refactors must not break tests.
- A module that cannot be tested without a running game server is a design problem, not a testing problem — fix the design.
- Tests live alongside the module they cover, not in a disconnected folder. Convention: `Foo.lua` and `Foo.spec.lua`.
- A test that passes by coincidence is worse than no test. Tests must fail when the thing they cover breaks.
- Mock external systems (`DataStore`, `HttpService`, remotes) — never hit live services from tests.

## 16) Luau

- `--!strict` everywhere. No exceptions.
- Type every public interface explicitly. Do not rely on inference across module boundaries.
- Avoid mixed tables. Arrays are arrays, dictionaries are dictionaries.
- Cache repeated lookups in hot paths. Do not re-resolve the same reference repeatedly.
- Reuse vectors and instances where allocation cost matters.
- Use `table.freeze` on constants and config tables that must not be mutated.
- Prefer `if not x then` over `if x == nil then` for nil checks unless the distinction matters.

## 17) Performance

- Profile before optimizing. Do not guess at bottlenecks. Use `MicroProfiler` and `Script Performance`.
- Keep per-frame code minimal — no allocations, no table rebuilds, no `FindFirstChild`.
- Cache references at `Init`, not at call time.
- Push non-critical work into scheduled tasks outside the frame loop.
- Avoid per-frame string formatting or concatenation.
- Prefer `WaitForChild` with a timeout over an infinite wait.
- Use `CollectionService` over deep instance traversal for tagging gameplay entities.

## 18) Deprecation

- Deprecated interfaces must be marked with `-- @deprecated: use X instead`, with the replacement named.
- Deprecated code must remain functional until all known usages are removed.
- Do not silently delete a public interface. Search for all usages before removing anything.
- When a service is removed, its consumers must be updated in the same change — not later.

## 19) Code Style

- Write direct code.
- No fake abstractions — a wrapper that adds nothing should not exist.
- Comment only when logic is genuinely non-obvious. Do not explain what the code already shows.
- Each function does one thing. If you need "and" to describe it, split it.
- Early-return on failure cases. Do not nest happy-path logic inside layers of `if`.
- Do not write AI-style code: no unnecessary verbosity, no padding, no over-structured output dressed up as architecture.
- The test of readable code: another developer understands it without asking you.

## 20) Source Control

- Do not make commits.
.
