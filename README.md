# Galadari — Voice Ordering Agent

A voice-first **AI waiter** for a Bengali (Kolkata) restaurant. A guest speaks
naturally; the agent recommends dishes, answers menu questions, builds an order,
and shows a live bill. Built on [LiveKit Agents](https://docs.livekit.io/agents/)
with a RAG layer over the menu, plus a small Next.js web front end.

---

## 1. What it does

- **Natural spoken ordering** — full-sentence requests, not button taps.
- **Recommendations & Q&A** — "something spicy and veg", "what's in the Mudo Dal", "anything without peanuts".
- **Menu-scoped & guarded** — only talks about the menu/order; declines off-topic chatter.
- **Validation** — if a dish isn't on the menu (e.g. pizza), it says so and suggests the closest match.
- **Upsell / cross-sell** — suggests pairings (rice/bread with a curry, a starter, a chutney).
- **Live cart** — the current order is pushed to the web UI and rendered as a printed bill.

---

## 2. Architecture (high level)

```
   Browser (Next.js web/)                 Python agent (agent.py)
 ┌────────────────────────┐   LiveKit   ┌──────────────────────────────┐
 │  LiveKitRoom (mic+audio)│◀──room────▶│  DriveThruAgent (Realtime LLM)│
 │  thali visualizer       │   WebRTC    │   ├─ tool: order_dish         │
 │  printed-bill cart  ◀───┼──RPC───────┤   ├─ tool: query_menu (RAG)   │
 └────────────────────────┘ set_cart_   │   ├─ tool: remove/list items  │
        ▲ token              content     │   └─ system prompt + menu     │
        │ /api/connection-details        └──────────────┬───────────────┘
        │ (livekit-server-sdk)                           │
                                                         ▼
                                          menu_rag.py ── Chroma (chroma-storage/)
                                                         + OpenAI embeddings
                                                         from data/menu.csv
```

**Two responsibilities are deliberately split:**

| Job | Mechanism | Why |
|-----|-----------|-----|
| Knowing what exists / validating | Compact menu in the **system prompt** + exact-match **catalog** | Instant, precise, no false matches |
| Discovery / recommendations / allergen filtering | **RAG** (`query_menu` over Chroma) | Semantic, fuzzy, filterable |
| Committing an order | **`order_dish`** tool against the catalog | Only real dishes get added |

RAG is for *finding*; the catalog is the *source of truth* for ordering. Vector
search is never used to validate availability (it always returns a nearest
neighbor, so it can't say "no").

---

## 3. Code map

| File | Role |
|------|------|
| `agent.py` | LiveKit agent: session setup (pure Realtime voice), `DriveThruAgent`, the `order_dish` / `remove` / `list` tools, `format_cart`, and the RPC cart push to the web UI. |
| `menu_rag.py` | Everything menu-data: parses `data/menu.csv`, builds the **Chroma** index + the `query_menu` RAG tool, `build_menu_catalog()` (id-keyed order catalog), `menu_overview()` (prompt menu), and `SYSTEM_PROMPT` (waiter persona). |
| `order.py` | `OrderedDish` model + `OrderState` (in-memory order with an `on_change` hook). |
| `data/menu.csv` | The 108-dish Bengali menu. Has a curated `embedding_text` column plus structured fields (price, dish_type, is_veg, allergens, spice, pairings…). |
| `chroma-storage/` | Persisted vector index (built once from the CSV; auto-rebuilt if deleted). |
| `database.py` | Legacy McDon's FakeDB — **no longer used** by the agent (kept on disk only). |
| `web/` | Next.js front end (see §6). |

---

## 4. How the menu / RAG works

1. **Build** (one-time, automatic on first run): each CSV row → a LlamaIndex
   `Document` embedded from `embedding_text` only (metadata excluded from the
   vector), stored in a persistent **Chroma** collection using OpenAI
   `text-embedding-3-small`. Structured columns are stored as metadata; each
   allergen also becomes a `has_<allergen>` flag.
2. **Query** (`query_menu` tool): the LLM passes a free-text `query` plus optional
   **hard filters** — `is_veg`, `max_price`, `exclude_allergens`. Filters run
   first (Chroma `where`), embeddings rank what's left. Results include price,
   veg flag, spice, allergens and a `pairs with` hint for cross-sell. If the top
   match is below a relevance threshold, the tool reports the item isn't on the
   menu.

> Changing the menu = edit `data/menu.csv`, delete `chroma-storage/`, and restart
> (it re-embeds on next launch). Keep the `embedding_text` column.

---

## 5. Setup

### Prerequisites
- **Python 3.12** (pinned; `requirements.txt` is pinned to the versions the live demo runs) and **Node 18+** (Node 24 tested).
- A **LiveKit** project (URL + API key/secret) — [livekit.io](https://livekit.io) cloud or self-hosted.
- An **OpenAI API key** (Realtime model + embeddings).

### 5.1 Backend (the agent)

```bash
git clone https://github.com/charming727/galadari_project.git
cd galadari_project
python3.12 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
```

Create `.env` in the repo root by copying the template:

```bash
cp .env.example .env     # then fill in the values
```

See [§5.4](#54-environment-variables) for what each variable is for.

Run the agent:

```bash
# Web/phone clients (registers a worker that joins real rooms):
python agent.py dev

# Terminal-only quick test (mic in your terminal, no web UI / no cart):
python agent.py console
```

> First `dev`/`console` launch builds the Chroma index (a few seconds of
> embedding calls), then caches it in `chroma-storage/`.

### 5.2 Front end (the web UI)

```bash
cd web
npm install
cp .env.local.example .env.local     # then fill in LIVEKIT_URL / KEY / SECRET
npm run dev                          # http://localhost:3000 (falls back to 3001 if busy)
```

`.env.local` needs the **same three LiveKit values** as the agent's `.env`
(`LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`). The browser only ever
receives a short-lived room token minted by `/api/connection-details`.

### 5.3 Use it
1. Start the agent: `python agent.py dev`.
2. Start the web app: `npm run dev`.
3. Open the URL → **Begin your order** → allow the mic → talk.
   The agent auto-joins your room (automatic dispatch) and the bill fills as you order.

---

### 5.4 Environment variables

Copy `.env.example` to `.env` for the agent. The frontend has its own
`web/.env.local` (template: `web/.env.local.example`). **Nothing secret is
committed** — both templates ship with empty values.

| Variable | Needed by | What it's for |
|----------|-----------|---------------|
| `LIVEKIT_URL` | agent + web | WebSocket URL of the LiveKit Cloud project the agent and browser both join. For this demo that is the **`that-corner`** project: `wss://that-corner-sq64jjhg.livekit.cloud`. |
| `LIVEKIT_API_KEY` | agent + web | LiveKit project key. The agent uses it to register a worker; the web app uses it to mint short-lived room tokens. From the LiveKit Cloud dashboard → Settings → Keys. |
| `LIVEKIT_API_SECRET` | agent + web | Signing secret paired with the key above. Server-side only — it is never sent to the browser. |
| `OPENAI_API_KEY` | agent | Used for **two** things: the Realtime speech-to-speech model (`gpt-4o`-class, voice `marin`) and the `text-embedding-3-small` embeddings that build the Chroma menu index. |
| `AGENT_NAME` | agent + web | Dispatch mode. Unset/empty = **automatic** dispatch (the worker joins any room on the project) — correct for local dev. Set to the *same* non-empty value on both sides (e.g. `galadari-waiter`) for **explicit** dispatch, so a hosted worker only picks up rooms meant for it. |
| `NUM_IDLE_PROCESSES` | agent | Idle worker processes kept warm. **Unset = LiveKit's default of one per CPU core.** See [§8](#8-deployment) before hosting. |

`DEEPGRAM_API_KEY` appears in older `.env` files and in the template as a
comment. It is **not used**: the agent runs pure speech-to-speech and the
Deepgram plugin is neither installed nor imported. You can ignore it.

---

## 6. Front end (`web/`)

Next.js (App Router, TypeScript) using `@livekit/components-react`.

- `app/api/connection-details/route.ts` — mints a LiveKit token server-side. Each
  visitor gets a **fresh room** (`galadari-<random>`), so concurrent testers never
  land in each other's conversation.
- `app/page.tsx` — landing + connected "Table"; custom mic/disconnect controls, an
  alpana **thali** audio visualizer, a live caption, and a **cart** that registers
  the `set_cart_content` RPC and renders the agent's bill.
- `app/globals.css` — the warm "Kitchen of Bengal" editorial theme (Fraunces +
  Hanken Grotesk + Noto Serif Bengali via `next/font`).

The agent → UI contract is one RPC method, **`set_cart_content`**, whose payload
is the markdown produced by `format_cart` (`**bold**` names, `[[Rs N]]` prices).

---

## 7. Voice configuration (important)

The agent uses a **pure speech-to-speech Realtime model**:

```python
llm = openai.realtime.RealtimeModel(voice="marin")   # its own VAD + transcription
```

Do **not** re-attach an external STT / VAD / turn detector (Deepgram + Silero +
MultilingualModel). That hybrid desynced the model's conversation state and made
it cut off mid-sentence and speak gibberish. Turn-taking is best tested in the
**web UI** (the browser does acoustic echo cancellation); `console` mode can echo.

---

## 8. Deployment

The two halves deploy **separately**.

### Frontend — Vercel (already live)

The Next.js app in `web/` is **deployed separately on Vercel**, at
<https://galadari-voice-demo.vercel.app/>. It is not served by the Python
agent and is not part of the agent's container image (`web/` is in
`.dockerignore`). Vercel builds from `web/`; set `LIVEKIT_URL`,
`LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` and (optionally) `AGENT_NAME` in the
Vercel project's environment variables — never in a committed file.

### Agent — any container host (e.g. Railway)

The agent is a long-running worker, not an HTTP service: it dials out to
LiveKit and waits for rooms. Build from the `Dockerfile` (Python 3.12) and run
`python agent.py start`.

**Set `NUM_IDLE_PROCESSES=4` on a hosted platform.** This matters for cost.
LiveKit's production default for idle warm processes is `ceil(cpu_count())` —
one prewarmed Python process *per core*. On the 128-core VM this demo was
built on that is a ceiling of **128 idle processes**, each loading chromadb and
the menu index. On a metered host you would pay for all of that to sit idle.
The agent deliberately keeps the framework default when the variable is unset,
so behaviour on the existing VM is unchanged; the knob is there to be set at
deploy time:

```bash
NUM_IDLE_PROCESSES=4     # a sane warm pool for a hosted worker
```

Also set at deploy time:

- `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `OPENAI_API_KEY`
- `AGENT_NAME=galadari-waiter` — and the **same** value in Vercel, so the
  hosted worker and the hosted frontend agree on explicit dispatch. Without
  this, a hosted worker will also pick up rooms from local dev sessions.

The Chroma index is **not** committed or baked into the image. On first boot
the agent rebuilds it from `data/menu.csv` (one embedding pass over 108
dishes), so the container needs `OPENAI_API_KEY` present at startup, and a
writable working directory.

---

## 9. Known gaps / next steps
- `test_agent.py` still references the old McDonald's models and will fail until migrated.
- Image / visual-menu support is out of scope for now.
- `database.py` (FakeDB) is dead code, kept only for reference.
