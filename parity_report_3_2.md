# Parity Report — Phase 3.2 Daily WIP Sync

`daily_wip_sync.json` (n8n, 52 nodes) vs. `infor/appscript/main.js :: runDailyWipTaskCollector` (AppScript, 1100 lines).

Built by Codex (`019e7d93-9dfd-7730-b208-1f674b306b90`) via MCP, reviewed by Claude.

---

## 1. Behavioral parity

| Concern | AppScript | n8n (3.2) | Status |
|---|---|---|---|
| Trigger | Time-based daily | Webhook `POST /daily-wip-sync` (calendar trigger swap in 3.4) | ✅ intentional drift |
| Source of transcript | Drive folder scan for file containing `yyyy/MM/dd` + prefix `Komosion stand up` | Calendar event of the day matching `dailyMeetingTitlePattern` → `event.attachments[]` Google Doc | ✅ design upgrade (per spec) |
| Doc → text | Drive REST `export?mimeType=text/plain` via `ScriptApp.getOAuthToken` | HTTP Request to same Drive v3 export endpoint with `googleOAuth2Api` | ✅ parity |
| `cleanTranscriptContent` | regex chain anchored on `📖 Transcript` | Ported in `Clean Transcript` Code node, with `let startIndex` fix | ✅ parity |
| Active tasks snapshot | `readSheetAsTable_` from "today" tab | `Load Active Projects` Supabase getAll `status not in (complete, dropped)` | ✅ parity (DB instead of sheet) |
| GPT patch plan | `gpt-4.1-2025-04-14`, temp 0.2, `response_format: json_object`, returns `{updates, creates, merges}` | Two-stage: (1) Classify mentions per project_client (2) Per-project Extract Actions → `{actions:[{action, task, lead, status, note, next_step, existing_task_id}]}`. Model from `system_config.llm_model`. `merges` dropped (was dead in AppScript). | ⚠ structural drift (intentional) — see §3 |
| Title validation | `applyUpdates_` rejects unknown titles → `unmatchedTitles[]` | LLM is given task ids; `update`/`complete` actions key on `existing_task_id`. Match Layer A guards `create`. | ✅ stronger |
| Inserts | `applyCreates_` raw append, no dedupe | Match Layer A → flips create→update on confidence ≥ `wipConfidenceThreshold`. DB-side `UNIQUE(project_client, task)` final defence. `continueOnFail` on `Supabase Create WIP`. | ✅ stronger |
| Cascade close tickets | (none — AppScript didn't touch tickets) | `Collect Completed for Cascade` + `Cascade Close Tickets` (Supabase update `tickets SET status='resolved' WHERE wip_task_id=...`) | ➕ new behaviour required by 3.2 spec |
| Meeting persistence | (none — only sheet tab existed) | Upsert `meetings` by `calendar_event_id`; insert into `meeting_tasks` junction | ➕ new |
| Email: success | `sendDailyUpdateSuccessEmail_` | `Gmail Send Summary` with C/U/D counts, tickets auto-closed, errors list, doubleRunWarning | ✅ parity + counts |
| Email: no meeting | "No meeting today" | `Gmail Send No standup today` (when no calendar event) | ✅ parity |
| Email: no transcript | (folded into no-meeting in AppScript) | Separate `Gmail Send No transcript on meeting` (meeting exists, doc missing) | ➕ extra branch |
| Email: empty LLM output | Still sends success with no warnings | `Gmail Send No actionable items` if classifier returns empty mentions; otherwise summary with zero counts if Extract Actions yields nothing | ⚠ small drift — see §3 |
| Double-run guard | "target sheet exists AND has data" → reuse + `doubleRunWarning=true` | `Lookup Existing Meeting` + `Lookup Existing Meeting Tasks` + `Check Double Run Guard` set `doubleRunWarning` in summary email | ✅ parity (DB-shaped) |
| Monthly rollover (1st of month) | `maybeCreateMonthlyReportOnFirstDay_`, `ensureMonthlyFolderAndSpreadsheet_`, `tryMoveNewMonthSheets_` | **NOT implemented** — separate workflow per Phase 3.3 | ❎ out of scope |
| Sort + highlight (sheet UI) | `sortProjectClientWithInternalLast_`, `highlightInternalColumnA_` | Dropped (view concern) | ❎ out of scope (per analysis §5) |
| Error handling | `try/catch` → tag email + rethrow | `continueOnFail: true` on persistence nodes, errors aggregated into summary email's `errors[]` | ✅ parity, plus richer reporting |

---

## 2. Field-level parity (LLM action → DB)

| LLM field | n8n target | wip_tasks column | Notes |
|---|---|---|---|
| `task` | `Supabase Create WIP` | `task` | Required |
| `lead` | Create/Update WIP | `lead` | Empty string fallback |
| `status` | Create/Update WIP | `status` | Enum guarded by CHECK constraint; default `to_do` on create / `in_progress` on update |
| `note` | Create/Update WIP | `note` | Raw replacement (AppScript also did raw — `appendNote_` was dead) |
| `next_step` | Create/Update WIP | `next_step` | |
| `existing_task_id` | Filter on Update/Complete | `id` | Drives action routing in Switch |
| `action: 'complete'` | `Supabase Complete WIP` | `status='complete'` + cascades to tickets | Cascade is **new** vs AppScript |
| `origin_source` | hard-coded `'standup'` on insert | `origin_source` | |

---

## 3. Known drifts (intentional or noted)

1. **`merges[]` removed**: was declared in AppScript GPT contract but never consumed (`main_js_analysis.md` §4). Dropped.
2. **Two-stage LLM** vs single-call: 3.2 spec required per-project extraction. This costs an extra OpenAI call per mentioned project, but scales better than a single mega-prompt as the active-task list grows past Sheets era (`main_js_analysis.md` §6 "Title enum scaling").
3. **"No actionable items" email**: 3.2 spec adds this short-circuit. AppScript silently sent success with zero changes. Drift is benign — easier to spot dead runs.
4. **Monthly rollover**: deferred to Phase 3.3 per task brief. Day-1 invocations of 3.2 will simply skip rollover.
5. **Sheets mirror**: dropped entirely (per Ver2 / Supabase-first direction). AppSheet reads from Supabase via Ver2's sync sheet, not from this workflow.

---

## 4. Open items requiring user input before first run

1. **`Config.supabaseUrl`** — placeholder `<PLACEHOLDER_SUPABASE_URL>` must be filled (same pattern as `helpdesk_v2.json`, see memory `project-wip-linking`).
2. **`Config.calendarId`** — the Komosion calendar that hosts "Daily WIP" events.
3. **Credentials** — three placeholders need wiring on import: `Supabase - Komosion`, `OpenAI - Komosion`, `Google - truc.pham`.
4. **`system_config` rows to add** (if not already present):
   - `dailyMeetingTitlePattern` (string, e.g. `"Daily WIP"`)
   - `summary_email_to` / `summary_email_cc`
   - `no_standup_email_to` (currently summary recipient is reused — confirm)
   - `wipConfidenceThreshold` (0.7 per existing `project-wip-linking` memory)
   - `llm_model_fast` (used by Match Layer A; falls back to `llm_model`)

---

## 5. Codex's flagged uncertainties (Claude review)

From Codex's return message — investigated:

| Flag | Verdict |
|---|---|
| Supabase filter field names | ✅ matches Ver2 helper (`keyName`/`condition`/`keyValue` under `filters.conditions`) |
| Gmail `ccList` option shape | ✅ string under `options.ccList` is valid for `n8n-nodes-base.gmail` |
| OpenAI `responseFormat: json_object` | ✅ correct path is `options.responseFormat` for `n8n-nodes-base.openAi` chat |
| Google Calendar `attachments` availability | ⚠ verify on first live test — some calendars return `attachments` only when explicitly attached via "Add attachment" in event UI. If empty for transcripts, swap to `event.description` regex for Doc link, or query Drive directly by date. |
| Sandbox refusal on validation | Claude validated via `node -e "require('./daily_wip_sync.json')"`: parses, 52 nodes, 0 orphan connection refs. |

---

## 6. Validation steps remaining

- [ ] Import `daily_wip_sync.json` into n8n staging.
- [ ] Fill credentials + `Config.supabaseUrl` + `Config.calendarId`.
- [ ] Seed missing `system_config` keys (see §4).
- [ ] Pick a past meeting day with known transcript; invoke webhook with `{"date": "YYYY-MM-DD"}`.
- [ ] Capture AppScript output for the same day from the legacy spreadsheet's daily tab; diff wip_tasks row-by-row.
- [ ] Confirm calendar attachment shape — adjust `Extract Transcript Attachment` if needed.
- [ ] Verify cascade by completing a wip_task that has a ticket linked.

---

Build artefacts: `daily_wip_sync.json` (52 nodes — 15 Code, 12 Supabase, 6 IF, 6 sticky notes, 4 Gmail, 3 OpenAI, 1 each: Webhook, Set, Google Calendar, HTTP, SplitInBatches, Switch).
