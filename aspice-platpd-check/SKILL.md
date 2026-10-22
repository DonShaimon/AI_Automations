---
name: aspice-platpd-check
description: >-
  Perform an ASPICE compliance check on a PLATPD JIRA ticket and its linked Polarion work-items, then generate a
  structured ASPICE report. Use when: "perform ASPICE check", "ASPICE check to PLATPD", "check PLATPD <number>",
  "run ASPICE review", "generate ASPICE report", or any request to validate PLATPD requirements against ASPICE
  criteria (atomicity, feasibility, unambiguity, completeness, comprehensibility, verifiability, traceability,
  consistency). Also use for "PLATPD pending approvals", "who has not approved", or approval reports for
  assigned PLATPDs grouped by platform and approver. Connects to JIRA and Polarion via MCPX tools.
argument-hint: 'PLATPD ticket number or link, e.g. "check PLATPD-1234"'
---

# ASPICE Check for PLATPD

Follows the procedure defined in [../../../guidance.md](../../../guidance.md) (workspace root). If that file changes, re-read it before running this skill — it is the source of truth for the check steps.

## Connections (MCPX)

- **JIRA**: use `mcp_mcpx_jira-mcp__*` tools (`jira_search`, `jira_get_issue`, `jira_get_field_metadata`).
- **Polarion**: use `mcp_mcpx_polarion-mcp__*` tools (`polarion_get_work_item`, `polarion_search_work_items`, `polarion_get_work_item_links`, `polarion_search_workitem_by_jira`).
- Load these tools with `tool_search` before first use if not already loaded in the session.

## Pending-Approvals Report Workflow

Use this workflow for reporting pending approvers across PLATPD tickets, not the ASPICE assessment below. Do not ask for Selected_Project or perform content-quality assessments unless requested.

### Collect Evidence

- Jira and Polarion collection is **read-only**. Send progress updates in chat; never add Jira comments, change approvals, or modify remote items to announce or test retrieval.
- Use the user's supplied filter or ticket list. For "my assigned PLATPDs in review", use `assignee = currentUser() AND status = "In Review" AND project = PLATPD`. Record the JQL, snapshot date, total tickets, and coverage gaps; do not silently truncate.
- Retrieve exact ticket summaries, descriptions, platform fields, and Polarion references using Jira search. Prefer the platform field; otherwise use the SV62/CH63/DR64 summary tag. Flag unknown platforms instead of guessing.
- Read each description's **Approval report** link and decode its `filter_query` for the work-item scope. If missing, use the Jira Polarion reference field described in step 3 below and disclose that fallback. Record discrepancies between these scopes rather than silently merging them.
- Retain each item's project and ID, including cross-project references. Batch-fetch `id,title,type,status,approvals`; exclude recycled items with `NOT HAS_VALUE:recycleBin` when collecting a fresh report. Separate architecture/text items from requirement totals unless explicitly included by the user.
- Determine pending entries **per approver**: include `waiting` and `disapproved`, exclude `approved`. Work-item workflow status is not an individual approval status. Approval relationship IDs identify assigned users but do not prove which users are pending.
- Use `polarion_get_work_item_approvals(work_item_id, project_id)` for exact statuses, or scoped `polarion_search_work_items` queries per candidate login using `approvals:fullxxxwaitingxxxLOGIN` and `approvals:fullxxxdisapprovedxxxLOGIN`. Resolve display names with `polarion_get_user`. If states are combined, label them **not approved (waiting or disapproved)** and disclose that distinction is unavailable.
- Verify actual returned counts and unique IDs against search totals. Some observed responses returned only 100 rows or repeated the first page despite `start_at`; if this occurs, split the ID set into smaller batches or exclude already-returned IDs. Do not assume the requested limit proves completeness.

### Organize and Link

- Maintain one report at `reports/PLATPD-pending-approvals.html`, replacing it on each fresh run rather than creating dated report files. Include the snapshot date, scope, coverage gaps, and fallback notes in the HTML. Do not hard-code ticket-specific counts or people in this skill.
- Start with a platform summary table: platform, distinct PLATPD tickets, and approver/requirement/ticket appearances. Report unique requirement counts separately from repeated appearances.
- Group details as **Platform (SV62 / CH63 / DR64) -> Approver -> PLATPD -> Requirements**. Preserve shared items under every applicable ticket and approver; deduplicate identical rows within each group.
- Link each ticket key and place its exact fetched title beside it: `[PLATPD-123](https://jira.mobileye.com/browse/PLATPD-123) - **Ticket summary**: ...`.
- Link every requirement ID explicitly in Markdown to `https://polarion.mobileye.com/polarion/redirect/project/{PROJECT_ID}/workitem?id={WORK_ITEM_ID}`. Use the known project. Observed mappings: `EPGSW` -> `app_software`, `EYEQ-PLATFORMS-SW` -> `eyeq_platforms_sw`, `AVP` -> `AV_Platforms`.
- Link each approver heading to **only the deduplicated item IDs listed beneath that name in its platform section**, using this query:

  ```text
  id:(ID1 ID2 ID3) AND NOT HAS_VALUE:recycleBin
  ```

- URL pattern: `https://polarion.mobileye.com/polarion/#/workitems?query={ENCODED_QUERY}`. Encode the entire query, including parentheses (`%28`, `%29`), spaces, and colons, to preserve it in Markdown and HTML.
- Do **not** add approval-status, approver, or assignee clauses to the name links, or expand them to all of a person's items across Polarion. Earlier browser tests rewrote combined approval-state links to disapproved-only; the agreed navigation uses the existing ID lists instead.
- Explain the ID-list scope and recycle-bin exclusion. For link-only updates, preserve the current snapshot rows/counts and disclose that recycled items are excluded from linked results only. Refresh rows and totals only when fresh data is collected.

### Generate HTML and Validate

- Produce **only** the maintained HTML report; do not leave a Markdown report or dated report archive in `reports/`. Build the Markdown source in a temporary location, convert it with the bundled Python converter using an explicit output path, and remove the temporary source after successful validation. The converter preserves explicit Markdown links:

  ```bash
  python3 .github/skills/aspice-platpd-check/references/md-to-html.py \
    -i "$TMPDIR/PLATPD-pending-approvals.md" \
    -o "reports/PLATPD-pending-approvals.html"
  ```

- Do not hand-author a separate HTML copy or assume another converter supports explicit links without checking its output.
- Check ticket titles/platforms against source data, correct destinations for ticket/item links, and no empty approver groups or identical duplicate rows.
- Recompute platform totals, unique requirements, and repeated appearances from the body; reconcile the summary and account explicitly for scoped tickets with no pending entries.
- Decode every name URL and verify its query is exactly the associated section's deduplicated ID list plus `AND NOT HAS_VALUE:recycleBin`, with no approval-status clauses.
- Verify every approver name link renders as an HTML anchor with the exact ID-only query, and that ticket titles and item links render correctly. Confirm the maintained HTML exists and contains the snapshot, scope, and reconciled counts. After successful validation, remove obsolete dated pending-approval report files. Syntax and anchor checks do not prove live navigation; disclose when browser behavior was not tested.

## Step-by-Step Procedure

### 1. Gather inputs
- If the user has not provided it, ask for the **PLATPD JIRA link or ticket number**.
- Ask the user to pick **Selected_Project**:
  - `Porsche_Audi_One_Box` → work-item IDs start with `PAOB` (e.g. `PAOB-1234`)
  - `VW_MaaS` → work-item IDs start with `VWMS` (e.g. `VWMS-1234`)
- Normalize the PLATPD input to a bare issue key (e.g. extract `PLATPD-1234` from a URL).

### 2. Fetch the PLATPD ticket
- **Do not use `jira_get_issue`** to get the full ticket — this MCPX tool only returns a fixed subset (`id, key, summary, url, description`) regardless of the `fields` parameter; status/assignee/custom fields are silently omitted.
- Instead use `jira_search` with `jql="key = <PLATPD-xxxx>"` and `fields="*all"`. This returns the complete field set (status, assignee, all `customfield_XXXXX`).
- Large results get written to a session resource file wrapped as `{"result": "<escaped JSON string>"}` with no real newlines, so `read_file` will show one giant truncated line. Don't fight this with `read_file`/`grep_search` — instead parse it in a terminal:
  ```powershell
  $outer = Get-Content -Raw <content.json path> | ConvertFrom-Json
  $issue = ($outer.result | ConvertFrom-Json).issues[0]
  ```
  Then access fields directly, e.g. `$issue.status.name`, `$issue.assignee.display_name`, `$issue.customfield_29648`.
- On the **first** run against this JIRA instance, discover the custom field IDs for "Impact Teams" and "Polarion URL" via `jira_get_field_metadata(operation="edit", issue_key=<any-issue>, include_optional=true)`, then filter the returned `fields` object by `.name` matching "Impact"/"Polarion" to get their `customfield_XXXXX` ids. Save the mapping to `/memories/repo/jira-custom-fields.md` (JIRA base URL + field name → id) so future runs skip this discovery step — check that file first before re-discovering.
- Extract and record for the report:
  - `summary`
  - `assignee.display_name`
  - `status.name`
  - **Impact teams** (`customfield_29648` on this instance) — array of team name strings
  - **Polarion references** (`customfield_25982` on this instance, labeled "Polarion URL" but **is not a URL**) — see step 3

### 3. Resolve Polarion work-items from the "Polarion URL" field
- The "Polarion URL" custom field actually contains a **Lucene query string** shaped `id:(project/ID1 project/ID2 ...)`, enumerating every Polarion work-item tied to the PLATPD ticket (used internally to build a traceability-report link). Parse out each `project/ID` token directly — **this is the authoritative root work-item list**, do not treat it as a hyperlink to parse.
- This list is typically the most complete source (e.g. one observed PLATPD ticket: 41 items via this field vs. only 23 found via the OSLC fallback below) — prefer it over the fallback when present and non-empty.
- **Fallback**, only if the field is empty/missing: use `polarion_search_work_items(lucene_query="id:<workItemId>")` to resolve a single known id, or `polarion_search_workitem_by_jira(jira_search="<PLATPD-xxxx>")` to discover work items linked back from Polarion to this JIRA ticket via OSLC (covers cases where the JIRA field is missing/stale).
- **Fallback / cross-check (works even if JIRA is unreachable):** `polarion_search_workitem_by_jira(jira_search="<PLATPD-xxxx>")` finds every Polarion work-item whose OSLC external links reference the PLATPD ticket (link role `http://open-services.net/ns/rm#implementedBy`). Use this whenever the JIRA "Polarion URL" field can't be read (e.g. JIRA connector down) — it independently reconstructs the JIRA→Polarion association from the Polarion side.
- Build the list of **root work-items** to assess (these are the work-items directly referenced by the PLATPD ticket). In practice these root items are often mid-level software work-items (e.g. `app_software` project, `EPGSW-xxxx` prefix) — NOT directly in Selected_Project. That is expected; traceability to Selected_Project is established in step 5 via a recursive upward walk, not necessarily a single hop.

### 4. Per-work-item ASPICE assessment
- **Efficiency: batch-fetch, don't loop `polarion_get_work_item` one-by-one.** `polarion_search_work_items` accepts a Lucene `id:(ID1 ID2 ID3 ...)` query and returns up to `limit` full work-items (attributes **and** relationships) in a **single call** — verified with 41 IDs / 162KB response in one round-trip. Always prefer this over per-item `polarion_get_work_item`/`polarion_get_work_item_links` calls; batch in groups of ~40-50 IDs per call (split into multiple calls only if the root list is larger).
  ```
  polarion_search_work_items(
    lucene_query="id:(EPGSW-30254 EPGSW-31781 ... )",
    fields="id,title,type,status,description,verificationCriteria,linkedWorkItems,backlinkedWorkItems",
    limit=50
  )
  ```
- Response shape: `result.work_items[]`, each `{ id: "project/ID", attributes: {id, type, title, description:{value}, status, verificationCriteria:{value}}, relationships: {linkedWorkItems:{data:[{id:"srcProj/srcId/role/tgtProj/tgtId"}]}, backlinkedWorkItems:{data:[...]}} }`. Same shape as `polarion_get_work_item`/`polarion_get_work_item_links` combined — parse the relationship `id` string by splitting on `/` (5 parts: source project, source id, role, target project, target id) instead of making separate link calls.
- Large results get written to a session resource file as **real nested JSON** (not escaped-string wrapped like JIRA's `jira_search`) — parse directly with `Get-Content -Raw <path> | ConvertFrom-Json` (single-level, no double-parse needed), then extract fields via PowerShell (e.g. `$r.result.work_items | ForEach-Object { $_.attributes.id, $_.attributes.status }`) rather than reading the raw file with `read_file` (it truncates long lines).
- `result...attributes.description.value` — **HTML**; strip tags before reading/quoting in the report.
- `result...attributes.verificationCriteria.value` — may be **absent/null** if no VC was authored (treat as Fail for criterion 6) — **except** for non-requirement types (`systemArchitectureElement`, `heading`, diagrams) where VC is architecturally not applicable; mark those items' criteria as **N/A** rather than Fail, and exclude them from Pass/Fail totals (but still include them in traceability, since they can mediate refinement chains — see below).

Assess these 6 criteria:

1. **Atomic** — describes a single testable behavior, not a bundle of unrelated statements.
2. **Feasible** — technically implementable and not self-contradictory.
3. **Unambiguous** — exactly one interpretation; no vague terms ("appropriate", "as needed", "etc.").
4. **Complete** — no missing conditions, values, or dangling references (TBD, TBC). A requirement that says "as defined in [linked work-item]" for a shared value/enum table is an accepted decomposition pattern in this project (centralizing DTC/DID value tables in one parent item) — mark **Partial** (not Fail) as long as the reference resolves to a real, existing work-item.
5. **Comprehensible** — clear grammar/structure, understandable without external context.
6. **Verifiable** — the `verificationCriteria` field exists and is testable (pass/fail, concrete values). Flag if `verificationCriteria` is empty or vague.

Record a **Pass/Fail/Partial/N/A** verdict with a 1-sentence justification for each of the 6 criteria.

**7. Approval Status (gating criterion, checked separately from the 6 quality criteria above):**
- Read `attributes.status` (already present in the step-4 batch result — no extra call needed).
- **Pass** only if `status` is exactly `approved` (case-insensitive). **Fail** for any other value (`draft`, `inReview`, or anything else), with justification quoting the actual status (e.g. "Fail — status is `inReview`, not yet approved").
- This is a **hard gate** on the Overall Verdict (see below), independent of how well the 6 quality criteria score — a well-written but not-yet-approved requirement must not be reported as an overall Pass.
- For non-requirement types (`systemArchitectureElement`, `heading`) where the 6 quality criteria are N/A, still record the Approval Status check (it's a workflow-state fact, not content-quality), but keep the item's Overall Verdict as N/A/excluded from requirement totals per the existing rule.

**Overall Verdict determination** (used in step 7's per-item block and Summary Table):
- **Fail** — if Approval Status = Fail (status not `approved`), OR any of the 6 quality criteria = Fail, OR Traceability = Fail.
- **Needs Rework** — otherwise, if any of the 6 quality criteria = Partial, or Consistency = Partially Consistent (i.e. status is approved, nothing is an outright Fail, but something needs polishing).
- **Pass** — status is `approved` AND all 6 quality criteria = Pass AND Traceable AND Consistent.
- In the per-item write-up, when Overall Verdict is driven primarily by the status gate (i.e. the 6 quality criteria and traceability/consistency are otherwise fine), say so explicitly, e.g. "Overall Verdict: Fail — not yet approved (status: inReview); no content defects found." This distinguishes a workflow/process gap from a genuine content defect so reviewers don't conflate the two.

### 5. Traceability check
- **Reuse the relationship data already fetched in the step-4 batch call** — do not call `polarion_get_work_item_links` per item when the item was already included in that batch. Only call it (or issue a follow-up `polarion_search_work_items` batch) for **intermediate hub items** discovered during the upward walk that weren't in the original root list (e.g. an `EPGSW-30151`-style architecture-element hub, or a not-yet-fetched Selected_Project parent).
- Parse relationship entries from `attributes`/`relationships` as returned by step 4: each `linkedWorkItems.data[].id` / `backlinkedWorkItems.data[].id` is a string `"sourceProject/sourceId/role/targetProject/targetId"` — split on `/` to get `{source, role, target}`. (If falling back to a direct `polarion_get_work_item_links` call for a hub item, the equivalent shape is `result.linked_work_items[]` / `result.backlinked_work_items[]` with explicit `{role, target_project, target_work_item}` / `{role, source_project, source_work_item}` fields — same information, different envelope.)
  - Observed `role` values include `refines`, `parent` (almost always a duplicate pairing alongside `refines` for the same target — dedupe these, they represent one logical link), `relates_to`, `depends_on`, `branched_from`. Treat any role matching `refines`/`allocat*` (case-insensitive, e.g. `allocated_to`, `allocates`) as the traceability-relevant role; ignore `relates_to`/`depends_on`/`branched_from` for ASPICE traceability purposes.
- **Downward** ( = "is refined by" / "is allocated to"): entries in `backlinked_work_items` whose `role` matches `refines`/`allocat*`. Report whether at least one such downward link exists.
- **Upward** ( = "refines"/"is allocated to"): entries in `linked_work_items` whose `role` matches `refines`/`allocat*`.
  - **Recursive walk required**: the immediate upward target is frequently in an intermediate project (e.g. `app_software`/`EPGSW-xxxx`), not yet in Selected_Project. If the target's ID prefix does not match Selected_Project (`PAOB-`/`VWMS-`), recursively call `polarion_get_work_item_links` on that target and continue following its own `refines`/`allocat*` outgoing links upward. Since step 4 already batch-fetched relationships for all root items in one call, resolve as many hops as possible from that same batch result before making additional calls for not-yet-fetched intermediate items.
  - **Architecture-element / heading hubs**: it's common for many `swrequirement` items to refine a single `systemArchitectureElement` (e.g. a diagram) which itself refines several `sysrequirement` items that connect to Selected_Project — a 3-hop chain (`swrequirement` → arch element → `sysrequirement` → Selected_Project). This hub item is often *not* in the root work-item list from step 3 (it wasn't directly linked to the PLATPD ticket) — fetch it explicitly when discovered as a repeated intermediate target. Also expect a `heading`-type organizational container reachable via `parent` links from nearly every item — its `parent` link is structural/organizational only, not a refinement; exclude `parent`-to-`heading` links from the traceability walk (only follow `refines`/`allocat*`).
  - Cap recursion at ~6 hops and track visited `project/id` pairs to avoid cycles; if the cap is hit or a dead end (no further upward links) is reached without finding a Selected_Project item, flag traceability as **Fail**.
  - Collect **all** distinct Selected_Project items found this way as the upward parents for step 6 (there can be more than one).
- If no upward path to a Selected_Project item exists, flag traceability as **Fail** and skip step 6 for this item (nothing to compare against).

### 6. Consistency to upper level
- Collect the **full set of distinct Selected_Project parent IDs** found across all root items' upward walks first, then fetch all of them in **one batched** `polarion_search_work_items(lucene_query="id:(PARENT1 PARENT2 ...)", fields="id,title,type,status,description")` call rather than one `polarion_get_work_item` per parent (same efficiency principle as step 4; verified working with 23 parents in one call).
- Compare each current work-item's description against **each** of its parent's descriptions for logical consistency (no contradiction, no scope creep beyond parent intent, terminology alignment).
- Record **Consistent / Inconsistent / Partially Consistent** with a short justification per parent.
- Only compare against parents belonging to **Selected_Project** — ignore parents from other projects.

**Structured consistency table — required only for `type = sysrequirement` items:**
- For every root work-item whose `attributes.type` is exactly `sysrequirement` (case-insensitive), replace the free-text consistency paragraph with a **structured table** instead, comparing this item's description against the description of **each** work-item it links to via a `refines` (or `allocat*`) role whose target is directly in **Selected_Project** (i.e. the item's own 1-hop upward links — do not walk further up for this table; multi-hop parents reached only through an intermediate `swrequirement`/architecture hub are out of scope for this specific table, since the table is keyed off *this* item's own direct `refines` links).
- Table format (Markdown), placed under a `**Consistency Check (refines → Selected_Project):**` heading, immediately before/in place of the old prose `**Consistency:**` line:
  ```
  | Linked VW_MaaS Item (refines) | Linked Item Description (paraphrased) | Consistency Verdict | Justification |
  |---|---|---|---|
  | VWMS-xxxxx | <1-2 sentence plain-text paraphrase of the parent's description, HTML stripped> | Pass / Partial / Fail | <1 sentence: why it does/doesn't align> |
  ```
  - State *this* item's own description once, in plain text (HTML-stripped, paraphrased to 1-3 sentences), directly above the table — do not repeat it in every row.
  - Perform an actual LLM read-and-compare of the two descriptions per row (not a templated "Consistent" filler): check for contradiction, scope mismatch, and — importantly — **numeric/value mismatches** (thresholds, ranges, units) between the child and the parent, since these are real defects a prose summary tends to hide. E.g. differing velocity/yaw-rate/threshold envelopes between a child DTC/DID and one of several parents it refines should be flagged **Partial** (not silently passed) even if nothing else is wrong.
  - **Fail** only for a genuine contradiction (child states something the parent's intent rules out). **Partial** for incomplete coverage of one parent among several, or a numeric/unit discrepancy worth a reviewer's attention. **Pass** for full alignment.
  - One row per linked Selected_Project item (an item refining 6 parents gets a 6-row table).
  - If a `sysrequirement` item has **no** direct `refines` link into Selected_Project (i.e. it only reaches Selected_Project via a multi-hop walk through another hub item), fall back to the prose format for that item and note why (rare case).
- For all other types (`swrequirement`, `systemArchitectureElement`, `heading`, etc.), keep the existing prose-based consistency write-up unchanged — the structured table applies **only** to `sysrequirement`-type items.

### 7. Generate the report
Use the template in [references/report-template.md](./references/report-template.md). Fill in:
- PLATPD header block (summary, assignee, status, impact teams, Selected_Project)
- A short cross-cutting findings section calling out repeated patterns (e.g. "N items missing VC", "external value references are an accepted pattern here") so the reader isn't left to spot them across dozens of rows — reference "Appendix A" (not "per-item tables below") when pointing readers to the detailed breakdown, since that section is now placed at the end.
- A **Summary Table** listing every work-item with an overall verdict (Pass / Fail / Needs Rework), placed right after the cross-cutting findings — this is what most readers scan first.
- A **Recommendations** section.
- Finally, **Appendix A: Work-Item Assessments** — one sub-section per Polarion work-item with the 6 quality criteria + traceability + consistency results. This is the longest, most granular section and belongs at the very end (as a true appendix) so the narrative sections (findings/summary/recommendations) aren't buried under dozens of item write-ups.

**Report section order (top to bottom):** Ticket Summary → Traceability Summary → Cross-Cutting Findings → Summary Table → Recommendations → Appendix A: Work-Item Assessments.

**Small scope (roughly ≤15 work-items):** present the full report as the final chat message, and still save it to `reports/<PLATPD-ID>-ASPICE-report.md` so step 8 (mandatory HTML generation) has a source file to convert.
**Large scope (roughly >15 work-items, e.g. "assess all" on a ticket with 40+ linked items):** writing the whole per-item breakdown inline produces an unreadable wall of chat text. Instead, save the full report to `reports/<PLATPD-ID>-ASPICE-report.md` in the workspace (create the `reports/` folder if needed) and give the user a concise chat summary: total counts (Pass/Partial/Fail/N/A), the specific items needing rework and why, the traceability/consistency pass rate, and a link to the saved report file. This was validated on a 41-item run in this project (PLATPD-991) and worked well.

### 8. Generate the HTML version with clickable Polarion links (mandatory)
Always generate `reports/<PLATPD-ID>-ASPICE-report.html` alongside the markdown report as the final step of every run — do not wait for the user to ask, and don't replace the `.md` file, produce both. The HTML conversion is fully **script-based** (deterministic PowerShell, not an LLM re-authoring step) so it adds negligible cost/risk and must not be skipped.
- **Use the reusable converter script**: [references/md-to-html.ps1](./references/md-to-html.ps1). It is a dependency-free PowerShell Markdown→HTML converter (no Node/Python required) purpose-built for this skill's report structure (headings, pipe tables, bold, inline code, bullet lists, `---` rules). It also color-codes Pass/Fail/Partial/Needs-Rework/N/A table cells and auto-expands shorthand comma-separated ID lists (e.g. `EPGSW-30254, 31781, 30145` → each number individually linked).
  ```powershell
  ./.github/skills/aspice-platpd-check/references/md-to-html.ps1 -InputPath "reports/<PLATPD-ID>-ASPICE-report.md"
  ```
  This writes `reports/<PLATPD-ID>-ASPICE-report.html` (same basename, `.html` extension) by default.
- **macOS / no PowerShell**: `pwsh` is not installed on the macOS host — use the equivalent Python port [references/md-to-html.py](./references/md-to-html.py) instead (same output, same defaults):
  ```bash
  python3 .github/skills/aspice-platpd-check/references/md-to-html.py -i "reports/<PLATPD-ID>-ASPICE-report.md"
  ```
  Extra prefix mappings: `--project-map "NEWPFX=Project_Id,OTHER=Other_Project"`. Keep both scripts in sync if the report structure changes.
- **Polarion portal link pattern** used by the script: `https://polarion.mobileye.com/polarion/redirect/project/{PROJECT_ID}/workitem?id={WORK_ITEM_ID}` — construct directly from the known project_id + work-item id, no extra API call needed (see `/memories/repo/polarion-api-facts.md`). The script's default `-ProjectMap` covers the prefixes seen so far: `EPGSW` → `app_software`, `VWMS` → `VW_MaaS`, `PAOB` → `Porsche_Audi_One_Box`. If a new work-item ID prefix/project shows up, pass an updated `-ProjectMap` hashtable to the script (and consider adding the new default mapping here once confirmed).
- Run the script after the markdown report is finalized (it reads the `.md` file as the single source of truth — never hand-author the HTML separately, always regenerate it from the markdown so the two stay in sync).
- **This step is mandatory, not optional** — every completed check must produce both the `.md` and `.html` report files before the run is considered done. If the script fails (e.g. new/unmapped ID prefix), fix the `-ProjectMap`/script rather than skipping HTML generation, and tell the user if it truly cannot be produced.

## Iteration Notes

- After generating a report, confirm with the user whether the content/coverage matches expectations. If a step failed (e.g. tool error, missing field, ambiguous link direction), fix the procedure in this SKILL.md rather than only patching the one-off run, so future runs benefit.
- Record durable, reusable facts (custom field IDs, project prefix conventions, quirks of this JIRA/Polarion instance) in `/memories/repo/`. Do not record ticket-specific data (that belongs only in the report output).

## Known Issues / Troubleshooting

- **JIRA MCPX 401 (token expired/invalid)**: `mcp_mcpx_jira-mcp__jira_get_issue` may fail with `Authentication failed for Jira API (401)`. This requires the user to refresh/re-authenticate the JIRA MCPX connection (outside agent control) — do not retry silently more than once. If it persists, tell the user plainly and proceed with the Polarion-only portion of the check (steps 3-7 below), clearly marking the JIRA header fields as "pending — JIRA connector unavailable" in the report.
- **Atlassian MCP 503**: The alternate `mcp_atlassian_mcp_jira_*` tools may also be unavailable (server-side outage). Treat as an equally valid JIRA source if the primary `mcp_mcpx_jira-mcp__*` tools fail — try it once as a fallback, but don't loop between the two.
- **Large PLATPD tickets (many linked Polarion work-items)**: it's common to find 40+ linked work-items for a single PLATPD ticket. Thanks to the step-4/6 batch-fetch approach, fetching all of them is cheap (a handful of tool calls total, not one per item) — so tool-call cost is no longer the main constraint. The report **length** still is: tell the user the total count found and ask whether to (a) assess all — expect a saved-to-file report per step 7's large-scope guidance, (b) assess only items in a specific status (e.g. `inReview`/`approved`), or (c) assess a representative sample first. Do not silently truncate without telling the user how many items exist vs. how many were assessed.
- **HTML description fields**: `description.value` and `verificationCriteria.value` are HTML/plain text mixed; strip HTML tags (keep table content as readable text) before quoting in the report — do not paste raw HTML.
- **Multi-parent refines**: a single work-item can `refines` several Selected_Project items at once (one-to-many). Assess consistency against each parent separately; don't assume a 1:1 mapping. If the item's scope only plausibly satisfies part of a parent's requirement (e.g. it defines a data structure while the parent also demands an end-to-end behavior like logging/notification), mark **Partially Consistent** (or **Partial** in the `sysrequirement` structured table) and say what is and isn't covered — don't force a binary Pass/Fail when evidence is incomplete. For `sysrequirement` items this maps directly to one row per parent in the step-6 structured table (see step 6).
