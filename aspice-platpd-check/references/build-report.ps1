<#
.SYNOPSIS
  Deterministically assembles the ASPICE check report (Summary Table, Totals, Appendix A) from:
  raw Polarion work-item data, computed traceability results, and LLM-authored semantic judgments.
  This is the scriptable "compute + format" half of aspice-platpd-check steps 4/6/7 — it does NOT make
  any quality/consistency judgment calls itself; those must come pre-populated in -JudgmentsJsonPath.

.DESCRIPTION
  Deterministic rules implemented here (no LLM judgment):
    - Approval Status: Pass iff work-item status == "approved", else Fail.
    - Non-requirement types (anything not in -RequirementTypes, e.g. systemArchitectureElement/heading):
      all 6 criteria + Consistency are forced to "N/A" regardless of the judgments file, Overall Verdict
      = "N/A (not a requirement)", and the item is excluded from Pass/Fail totals (shown for info only).
    - Overall Verdict formula (requirement types only):
        Fail        if Approval Status = Fail, OR any of the 6 criteria = Fail, OR not Traceable
        Needs Rework if (not Fail) AND (any criterion = Partial OR Consistency != Consistent)
        Pass        otherwise
    - Totals/statistics: Pass/Needs-Rework/Fail counts, Fail split into "content defect" vs
      "approval-status-only", traceability %, consistency-conflict count.
    - Summary Table and Appendix A markdown formatting.

  The 6 quality criteria verdicts/justifications and the Consistency verdict/justification are NOT
  computed here — they must be authored by the LLM (semantic judgment of requirement prose) and supplied
  via -JudgmentsJsonPath, keyed by work-item id:
    { "EPGSW-12345": { "criteria": { "atomic": {"verdict":"Pass","justification":"..."}, "feasible": {...},
      "unambiguous": {...}, "complete": {...}, "comprehensible": {...}, "verifiable": {...} },
      "consistency": {"verdict":"Consistent","justification":"..."} } }

  STRUCTURED CONSISTENCY TABLE (sysrequirement items only, per skill step 6): for work-items whose type is
  in -StructuredConsistencyTypes (default: sysrequirement), if the judgments entry additionally provides
  "consistencyThisItemSummary" and "consistencyTable", the script renders a per-parent comparison table
  instead of the single prose "Consistency:" line, e.g.:
    { "EPGSW-30142": { "criteria": {...},
        "consistencyThisItemSummary": "<LLM 1-3 sentence paraphrase of this item's own description>",
        "consistencyTable": [
          { "parentId": "VWMS-86162", "parentSummary": "<LLM paraphrase of the parent's description>",
            "verdict": "Pass", "justification": "..." },
          ... one row per DirectParent (see compute-traceability.ps1's DirectParents field) ...
        ]
    } }
  Every id in that item's DirectParents (from -TraceabilityJsonPath) MUST have a matching row — the script
  throws if any direct refines-parent is missing a row, to stop an incomplete table from being silently
  rendered. The plain "consistency" object above is still used as a fallback for non-structured types (or
  for a sysrequirement item lacking direct Selected_Project links — rare; see skill step 6).
  The aggregate consistency verdict feeding the Overall Verdict formula is derived from the table: any row
  Fail -> "Inconsistent"; else any row Partial -> "Partially Consistent"; else "Consistent".

  Narrative prose (Ticket Summary intro, architectural note, traceability summary text, cross-cutting
  findings, recommendations) is also LLM-authored and supplied as ready-to-paste markdown via
  -NarrativeJsonPath: { "ticketSummaryTable": "...", "architecturalNote": "...",
  "traceabilityNarrative": "...", "crossCuttingFindings": "...", "recommendations": "...",
  "selectedProject": "...", "generated": "...", "scope": "..." }

.PARAMETER WorkItemsJsonPath
  One or more raw polarion_search_work_items batch result JSON files covering the root work-items.

.PARAMETER RootItemIds
  Root work-item ids in the desired display order (bare ids, e.g. "EPGSW-30254").

.PARAMETER TraceabilityJsonPath
  Path to the JSON produced by compute-traceability.ps1.

.PARAMETER JudgmentsJsonPath
  Path to the LLM-authored per-item semantic judgments JSON (see schema above).

.PARAMETER NarrativeJsonPath
  Path to the LLM-authored narrative/prose JSON (see schema above).

.PARAMETER RequirementTypes
  Work-item types treated as "requirements" subject to the full 6-criteria scoring (default:
  sysrequirement, swrequirement, cstrequirement).

.PARAMETER StructuredConsistencyTypes
  Work-item types that get the per-parent structured consistency table instead of a single prose line
  (default: sysrequirement only — see skill step 6).

.PARAMETER OutputPath
  Where to write the assembled Markdown report.
#>
param(
    [Parameter(Mandatory = $true)][string[]]$WorkItemsJsonPath,
    [Parameter(Mandatory = $true)][string[]]$RootItemIds,
    [Parameter(Mandatory = $true)][string]$TraceabilityJsonPath,
    [Parameter(Mandatory = $true)][string]$JudgmentsJsonPath,
    [Parameter(Mandatory = $true)][string]$NarrativeJsonPath,
    [string[]]$RequirementTypes = @("sysrequirement", "swrequirement", "cstrequirement"),
    [string[]]$StructuredConsistencyTypes = @("sysrequirement"),
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$CriteriaOrder = @("atomic", "feasible", "unambiguous", "complete", "comprehensible", "verifiable")
$CriteriaLabel = @{ atomic = "Atomic"; feasible = "Feasible"; unambiguous = "Unambiguous"; complete = "Complete"; comprehensible = "Comprehensible"; verifiable = "Verifiable" }

# ---- Load inputs ----
$lookup = @{}
foreach ($path in $WorkItemsJsonPath) {
    $raw = Get-Content -Raw $path -Encoding UTF8 | ConvertFrom-Json
    foreach ($wi in $raw.result.work_items) {
        $id = $wi.attributes.id
        if ($lookup.ContainsKey($id)) { continue }
        $lookup[$id] = [PSCustomObject]@{
            Id     = $id
            Type   = $wi.attributes.type
            Status = $wi.attributes.status
            Title  = $wi.attributes.title
            HasVC  = [bool]$wi.attributes.verificationCriteria.value
        }
    }
}
$trace = Get-Content -Raw $TraceabilityJsonPath -Encoding UTF8 | ConvertFrom-Json
$judgments = Get-Content -Raw $JudgmentsJsonPath -Encoding UTF8 | ConvertFrom-Json
$narrative = Get-Content -Raw $NarrativeJsonPath -Encoding UTF8 | ConvertFrom-Json

function Get-TraceItem([string]$id) {
    if ($trace.Items.PSObject.Properties[$id]) { return $trace.Items.$id }
    return $null
}
function Get-Judgment([string]$id) {
    if ($judgments.PSObject.Properties[$id]) { return $judgments.$id }
    return $null
}

# ---- Per-item computation ----
$assessments = @()
foreach ($id in $RootItemIds) {
    $wi = $lookup[$id]
    if (-not $wi) { throw "Work-item '$id' not found in supplied -WorkItemsJsonPath data." }
    $isReq = $wi.Type -in $RequirementTypes
    $approvalPass = ($wi.Status -eq "approved")
    $approvalJust = if ($approvalPass) { "status is ``approved``" } else { "status is ``$($wi.Status)``, not yet approved" }
    $t = Get-TraceItem $id

    if (-not $isReq) {
        $assessments += [PSCustomObject]@{
            Id = $id; Type = $wi.Type; Status = $wi.Status; Title = $wi.Title
            IsRequirement = $false
            Criteria      = $null
            ApprovalPass  = $approvalPass; ApprovalJust = $approvalJust
            Traceable     = $t.Traceable
            Consistency   = $null
            Overall       = "N/A (not a requirement)"
            OverallReason = "excluded from Pass/Fail scoring (not a requirement work-item type)"
            Trace         = $t
        }
        continue
    }

    $j = Get-Judgment $id
    if (-not $j) { throw "No judgments entry found for requirement-type work-item '$id'. Supply criteria+consistency in -JudgmentsJsonPath." }

    $criteria = [ordered]@{}
    $anyFail = $false; $anyPartial = $false
    foreach ($c in $CriteriaOrder) {
        $cj = $j.criteria.$c
        $criteria[$c] = $cj
        if ($cj.verdict -eq "Fail") { $anyFail = $true }
        if ($cj.verdict -eq "Partial") { $anyPartial = $true }
    }
    $traceable = [bool]$t.Traceable

    # ---- Consistency: structured per-parent table (sysrequirement, etc.) vs. single prose line ----
    $useStructuredConsistency = ($wi.Type -in $StructuredConsistencyTypes) -and $j.consistencyTable -and $j.consistencyTable.Count -gt 0
    if ($useStructuredConsistency) {
        $directParents = @($t.DirectParents)
        $providedParents = @($j.consistencyTable | ForEach-Object { $_.parentId })
        $missing = @($directParents | Where-Object { $_ -notin $providedParents })
        if ($missing.Count -gt 0) {
            throw "Work-item '$id': consistencyTable in judgments.json is missing a row for direct refines-parent(s): $($missing -join ', '). Every id in DirectParents (traceability.json) must have a matching consistencyTable entry."
        }
        if (-not $j.consistencyThisItemSummary) {
            throw "Work-item '$id': consistencyTable is present but consistencyThisItemSummary is missing — supply a short paraphrase of this item's own description."
        }
        $anyRowFail = [bool]($j.consistencyTable | Where-Object { $_.verdict -eq "Fail" })
        $anyRowPartial = [bool]($j.consistencyTable | Where-Object { $_.verdict -eq "Partial" })
        $consistencyVerdict = if ($anyRowFail) { "Inconsistent" } elseif ($anyRowPartial) { "Partially Consistent" } else { "Consistent" }
        $consistencyOk = ($consistencyVerdict -eq "Consistent")
    }
    else {
        if (-not $j.consistency) { throw "Work-item '$id': no 'consistency' (prose) or 'consistencyTable' (structured) entry found in judgments.json." }
        $consistencyVerdict = $j.consistency.verdict
        $consistencyOk = ($consistencyVerdict -eq "Consistent")
    }

    if (-not $approvalPass -or $anyFail -or -not $traceable) {
        $overall = "Fail"
        if (-not $approvalPass -and -not $anyFail -and $traceable) {
            $overallReason = "not yet approved (status: $($wi.Status)); no content defects found"
        }
        elseif ($anyFail) {
            $failCriteria = ($CriteriaOrder | Where-Object { $criteria[$_].verdict -eq "Fail" } | ForEach-Object { $CriteriaLabel[$_] }) -join ", "
            $overallReason = "content defect ($failCriteria = Fail)" + $(if (-not $approvalPass) { "; also not yet approved" } else { " (approved otherwise)" })
        }
        else {
            $overallReason = "not traceable to Selected_Project"
        }
    }
    elseif ($anyPartial -or -not $consistencyOk) {
        $overall = "Needs Rework"
        $partialCriteria = ($CriteriaOrder | Where-Object { $criteria[$_].verdict -eq "Partial" } | ForEach-Object { $CriteriaLabel[$_] }) -join ", "
        if ($partialCriteria) {
            $overallReason = "approved, but $partialCriteria=Partial"
        }
        else {
            $overallReason = "approved, but consistency is not fully Consistent"
        }
    }
    else {
        $overall = "Pass"
        $overallReason = $null
    }

    $assessments += [PSCustomObject]@{
        Id = $id; Type = $wi.Type; Status = $wi.Status; Title = $wi.Title
        IsRequirement = $true
        Criteria      = $criteria
        ApprovalPass  = $approvalPass; ApprovalJust = $approvalJust
        Traceable     = $traceable
        ConsistencyMode      = if ($useStructuredConsistency) { "table" } else { "prose" }
        ConsistencyVerdict   = $consistencyVerdict
        Consistency          = $j.consistency
        ConsistencyThisItemSummary = $j.consistencyThisItemSummary
        ConsistencyTable     = $j.consistencyTable
        Overall       = $overall
        OverallReason = $overallReason
        Trace         = $t
    }
}

# ---- Totals ----
$reqAssessments = $assessments | Where-Object { $_.IsRequirement }
$passItems = @($reqAssessments | Where-Object { $_.Overall -eq "Pass" })
$reworkItems = @($reqAssessments | Where-Object { $_.Overall -eq "Needs Rework" })
$failItems = @($reqAssessments | Where-Object { $_.Overall -eq "Fail" })
$failContentDefect = @($failItems | Where-Object { $_.OverallReason -like "content defect*" })
$failApprovalOnly = @($failItems | Where-Object { $_.OverallReason -like "not yet approved*" })
$tracedReq = @($reqAssessments | Where-Object { $_.Traceable }).Count
$inconsistentReq = @($reqAssessments | Where-Object { $_.ConsistencyVerdict -ne "Consistent" }).Count
$nonReqItems = @($assessments | Where-Object { -not $_.IsRequirement })

# ---- Markdown builders ----
function Format-TraceabilityText($a) {
    $t = $a.Trace
    $downParts = @()
    if ($t.DownwardRefines -and $t.DownwardRefines.Count -gt 0) {
        $downParts += "``" + ($t.DownwardRefines -join '``, ``') + "`` (refines)"
    }
    if ($t.DownwardOther -and $t.DownwardOther.Count -gt 0) {
        $byRole = $t.DownwardOther | Group-Object Role
        foreach ($g in $byRole) {
            $ids = ($g.Group | ForEach-Object { $_.Id }) -join '``, ``'
            $downParts += "``$ids`` ($($g.Name))"
        }
    }
    $downText = if ($downParts.Count -gt 0) { "Downward: " + ($downParts -join '. ') + "." } else { "Downward: none." }

    if ($a.Traceable) {
        $parentsText = ($t.Parents | ForEach-Object { "**$_**" }) -join ', '
        $hopWord = if ($t.MinHops -eq 1) { "hop" } else { "hops" }
        $upText = "Upward: $($t.ExamplePath) -> $parentsText ($($t.MinHops) $hopWord)."
    }
    else {
        $upText = "Upward: NOT TRACED to Selected_Project."
    }
    return "$downText $upText"
}

function Format-CriteriaTable($a) {
    $lines = @("| Criterion | Verdict | Justification |", "|---|---|---|")
    if (-not $a.IsRequirement) {
        foreach ($c in $CriteriaOrder) {
            $lines += "| $($CriteriaLabel[$c]) | N/A | not applicable to type ``$($a.Type)`` |"
        }
        $lines += "| Approval Status | $(if($a.ApprovalPass){'Pass'}else{'**Fail**'}) | $($a.ApprovalJust) (informational only) |"
        return $lines -join "`n"
    }
    foreach ($c in $CriteriaOrder) {
        $cj = $a.Criteria[$c]
        $verdictText = if ($cj.verdict -eq "Pass") { "Pass" } else { "**$($cj.verdict)**" }
        $lines += "| $($CriteriaLabel[$c]) | $verdictText | $($cj.justification) |"
    }
    $approvalText = if ($a.ApprovalPass) { "Pass" } else { "**Fail**" }
    $lines += "| Approval Status | $approvalText | $($a.ApprovalJust) |"
    return $lines -join "`n"
}

function Format-SummaryRow($a) {
    if (-not $a.IsRequirement) {
        return "| $($a.Id) | $($a.Type) | $($a.Status) | N/A | N/A | N/A | N/A | N/A | N/A | Fail (info only) | $(if($a.Traceable){'Pass'}else{'Fail'}) | N/A | **N/A (not a requirement)** |"
    }
    $cells = foreach ($c in $CriteriaOrder) {
        $v = $a.Criteria[$c].verdict
        if ($v -eq "Pass") { "Pass" } else { "**$v**" }
    }
    $approvalCell = if ($a.ApprovalPass) { "Pass" } else { "**Fail**" }
    $traceCell = if ($a.Traceable) { "Pass" } else { "**Fail**" }
    $consistCell = if ($a.ConsistencyVerdict -eq "Consistent") { "Pass" } else { "**$($a.ConsistencyVerdict)**" }
    $overallCell = if ($a.Overall -eq "Pass") { "Pass" } else { "**$($a.Overall)**" }
    return "| $($a.Id) | $($a.Type) | $($a.Status) | $($cells -join ' | ') | $approvalCell | $traceCell | $consistCell | $overallCell |"
}

# ---- Assemble Summary Table ----
$summaryHeader = "| Work-Item | Type | Status | Atomic | Feasible | Unambiguous | Complete | Comprehensible | Verifiable | Approval Status | Traceable | Consistent | Overall |`n|---|---|---|---|---|---|---|---|---|---|---|---|---|"
$summaryRows = $assessments | ForEach-Object { Format-SummaryRow $_ }
$summaryTable = "$summaryHeader`n" + ($summaryRows -join "`n")

# ---- Assemble Totals ----
$totalReq = $reqAssessments.Count
$totalsLines = @()
$totalsLines += "**Totals ($totalReq requirement-type items, excluding $($nonReqItems.Count) architecture-element item(s)):**"
$totalsLines += "- **Pass: $($passItems.Count) / $totalReq ($([math]::Round($passItems.Count/$totalReq*100))%)** — $(($passItems | ForEach-Object {'`' + $_.Id + '`'}) -join ', ')"
$totalsLines += "- **Needs Rework: $($reworkItems.Count) / $totalReq ($([math]::Round($reworkItems.Count/$totalReq*100))%)** — $(($reworkItems | ForEach-Object {'`' + $_.Id + '`'}) -join ', ')"
$totalsLines += "- **Fail: $($failItems.Count) / $totalReq ($([math]::Round($failItems.Count/$totalReq*100))%)**, split into two root causes:"
$totalsLines += "  - **$($failContentDefect.Count) — genuine content defect:** $(($failContentDefect | ForEach-Object {'`' + $_.Id + '`'}) -join ', ')"
$totalsLines += "  - **$($failApprovalOnly.Count) — Approval Status gate only (not yet approved):** $(($failApprovalOnly | ForEach-Object {'`' + $_.Id + '`'}) -join ', ')"
$totalsLines += "- Traceability to Selected_Project: $tracedReq / $totalReq ($([math]::Round($tracedReq/$totalReq*100))%)"
$totalsLines += "- Consistency conflicts: $inconsistentReq / $totalReq ($([math]::Round($inconsistentReq/$totalReq*100))%)"
foreach ($nr in $nonReqItems) {
    $totalsLines += "- ``$($nr.Id)`` ($($nr.Type)) is ``$($nr.Status)``; excluded from the requirement totals above (not a requirement type); shown for information only."
}
$totalsBlock = $totalsLines -join "`n"

# ---- Assemble Appendix A ----
function Format-ConsistencyBlock($a) {
    if (-not $a.IsRequirement) {
        return "**Consistency:** N/A (architecture element, not a requirement)."
    }
    if ($a.ConsistencyMode -eq "table") {
        $lines = @()
        $lines += "**Consistency Check (refines → Selected_Project):**"
        $lines += "*This item's description:* $($a.ConsistencyThisItemSummary)"
        $lines += ""
        $lines += "| Linked VW_MaaS Item (refines) | Linked Item Description (paraphrased) | Consistency Verdict | Justification |"
        $lines += "|---|---|---|---|"
        foreach ($row in $a.ConsistencyTable) {
            $verdictText = if ($row.verdict -eq "Pass") { "Pass" } else { "**$($row.verdict)**" }
            $lines += "| $($row.parentId) | $($row.parentSummary) | $verdictText | $($row.justification) |"
        }
        return $lines -join "`n"
    }
    return "**Consistency:** $($a.Consistency.justification)"
}

$appendixBlocks = foreach ($a in $assessments) {
    $block = @()
    $block += "### $($a.Id) — $($a.Title)"
    $block += "**Type:** $($a.Type) | **Status:** $($a.Status)"
    $block += ""
    $block += Format-CriteriaTable $a
    $block += ""
    $block += "**Traceability:** $(Format-TraceabilityText $a)"
    $block += ""
    $block += Format-ConsistencyBlock $a
    $block += ""
    $reasonSuffix = if ($a.OverallReason) { " — $($a.OverallReason)" } else { "" }
    $overallText = if ($a.Overall -eq "Pass") { "Pass" } else { "**$($a.Overall)**$reasonSuffix" }
    $block += "**Overall Verdict:** $overallText"
    $block -join "`n"
}
$appendixSection = $appendixBlocks -join "`n`n---`n`n"

# ---- Full report assembly ----
$rootListText = ($RootItemIds -replace '^EPGSW-', '') -join ', '
$report = @"
# ASPICE Check Report — $($narrative.platpdId)

**Selected Project:** $($narrative.selectedProject)
**Generated:** $($narrative.generated)
**Scope:** $($narrative.scope)

## PLATPD Ticket Summary

$($narrative.ticketSummaryTable)

**Root work-items ($($RootItemIds.Count)):** EPGSW-$rootListText

**Architectural note:** $($narrative.architecturalNote)

## Traceability Summary (upward, to Selected_Project = $($narrative.selectedProject))

$($narrative.traceabilityNarrative)

## Cross-Cutting Findings (apply to multiple items — see Appendix A for detail)

$($narrative.crossCuttingFindings)

---

## Summary Table

$summaryTable

$totalsBlock

## Recommendations
$($narrative.recommendations)

---

## Appendix A: Work-Item Assessments

$appendixSection
"@

$report | Set-Content -Path $OutputPath -Encoding UTF8
Write-Output "Report assembled: $($assessments.Count) items ($totalReq requirements: $($passItems.Count) Pass / $($reworkItems.Count) Needs Rework / $($failItems.Count) Fail). Written to $OutputPath"
