<#
.SYNOPSIS
  Deterministically computes upward traceability (to a Selected_Project) and downward refinement links
  for a set of root Polarion work-items, from one or more raw `polarion_search_work_items` batch-fetch
  JSON files. This is the scriptable part of aspice-platpd-check step 5 (Traceability check) — no LLM
  judgment is involved, it is a pure graph walk over already-fetched relationship data.

.DESCRIPTION
  Input files must be the raw tool-result JSON saved from `polarion_search_work_items` calls (shape:
  `{ result: { work_items: [ { attributes: {id,type,status,...}, relationships: { linkedWorkItems: { data:
  [ {id:"srcProj/srcId/role/tgtProj/tgtId"} ] }, backlinkedWorkItems: { data: [...] } } } ] } }`).
  Pass every batch file you fetched (root items + any hub items + Selected_Project parent items) via
  -WorkItemsJsonPath; they get merged into one lookup keyed by bare work-item id.

  Only relationship roles matching ^(refines|allocat) (case-insensitive) are followed for traceability —
  `parent`, `relates_to`, `depends_on`, `branched_from` are structural/non-gating and ignored, per the
  skill's traceability rules.

  Each item's output record includes both `Parents` (all distinct Selected_Project items reached at any
  hop depth) and `DirectParents` (only those reached via a *direct*, Hop-1 refines/allocat* link from the
  root item itself — i.e. not via a recursive walk through an intermediate hub/architecture element).
  `DirectParents` is what build-report.ps1 uses to build the per-item structured consistency table for
  `sysrequirement`-type items (see that script's header and the skill's step 6).

.PARAMETER WorkItemsJsonPath
  One or more paths to raw polarion_search_work_items result JSON files to merge.

.PARAMETER SelectedProjectPrefix
  The work-item ID prefix that marks an item as belonging to Selected_Project, e.g. "VWMS" or "PAOB".

.PARAMETER RootItemIds
  The root work-item ids (bare, e.g. "EPGSW-30254") to compute upward/downward traceability for.

.PARAMETER MaxHops
  Recursion cap for the upward walk (default 6).

.PARAMETER OutputPath
  Where to write the resulting traceability JSON.

.EXAMPLE
  ./compute-traceability.ps1 -WorkItemsJsonPath "reports/data/PLATPD-991/polarion-workitems-raw.json","reports/data/PLATPD-991/polarion-hubs-raw.json","reports/data/PLATPD-991/polarion-parents-raw.json" `
    -SelectedProjectPrefix "VWMS" -RootItemIds (Get-Content "reports/data/PLATPD-991/root-ids.json" | ConvertFrom-Json) `
    -OutputPath "reports/data/PLATPD-991/traceability.json"
#>
param(
    [Parameter(Mandatory = $true)][string[]]$WorkItemsJsonPath,
    [Parameter(Mandatory = $true)][string]$SelectedProjectPrefix,
    [Parameter(Mandatory = $true)][string[]]$RootItemIds,
    [int]$MaxHops = 6,
    [Parameter(Mandatory = $true)][string]$OutputPath
)

$TraceRoleRegex = '(?i)^(refines|allocat)'

# ---- Load & merge all work items into one lookup keyed by bare id ("EPGSW-41881") ----
$lookup = @{}
foreach ($path in $WorkItemsJsonPath) {
    $raw = Get-Content -Raw $path -Encoding UTF8 | ConvertFrom-Json
    foreach ($wi in $raw.result.work_items) {
        $id = $wi.attributes.id
        if ($lookup.ContainsKey($id)) { continue }  # first occurrence wins if an id appears in multiple files

        $linked = @()
        foreach ($rel in $wi.relationships.linkedWorkItems.data) {
            $parts = $rel.id -split '/'
            if ($parts.Count -eq 5) {
                $linked += [PSCustomObject]@{ SourceProject = $parts[0]; SourceId = $parts[1]; Role = $parts[2]; TargetProject = $parts[3]; TargetId = $parts[4] }
            }
        }
        $backlinked = @()
        foreach ($rel in $wi.relationships.backlinkedWorkItems.data) {
            $parts = $rel.id -split '/'
            if ($parts.Count -eq 5) {
                $backlinked += [PSCustomObject]@{ SourceProject = $parts[0]; SourceId = $parts[1]; Role = $parts[2]; TargetProject = $parts[3]; TargetId = $parts[4] }
            }
        }

        $lookup[$id] = [PSCustomObject]@{
            Id           = $id
            Type         = $wi.attributes.type
            Status       = $wi.attributes.status
            Title        = $wi.attributes.title
            LinkedItems  = $linked
            Backlinked   = $backlinked
        }
    }
}

function Test-IsSelectedProject([string]$id) {
    return $id -match "^$([regex]::Escape($SelectedProjectPrefix))-"
}

# ---- Upward recursive walk ----
function Get-UpwardParents {
    param([string]$Id, [int]$Hop, [System.Collections.Generic.HashSet[string]]$Visited)

    $results = @()  # list of {ParentId, Hops, Path (array of ids from Id to ParentId inclusive)}
    if ($Hop -gt $MaxHops) { return $results }
    if (-not $Visited.Add($Id)) { return $results }  # cycle guard

    $item = $lookup[$Id]
    if (-not $item) { return $results }  # not fetched — dead end for this path

    foreach ($rel in $item.LinkedItems) {
        if ($rel.Role -notmatch $TraceRoleRegex) { continue }
        $targetId = $rel.TargetId
        if (Test-IsSelectedProject $targetId) {
            $results += [PSCustomObject]@{ ParentId = $targetId; Hops = $Hop; Path = @($Id, $targetId) }
        }
        else {
            $sub = @(Get-UpwardParents -Id $targetId -Hop ($Hop + 1) -Visited $Visited)
            foreach ($s in $sub) {
                $results += [PSCustomObject]@{ ParentId = $s.ParentId; Hops = $s.Hops; Path = (@($Id) + $s.Path) }
            }
        }
    }
    # Callers wrap this call in @(...) to force array context; PowerShell enumerates $results onto the
    # pipeline here (correct even for 0 or 1 elements, since @() at the call site reassembles the array).
    return $results
}

$perItem = @{}
$allDistinctParents = New-Object System.Collections.Generic.HashSet[string]
$tracedCount = 0

foreach ($rootId in $RootItemIds) {
    $visited = New-Object System.Collections.Generic.HashSet[string]
    $upward = @(Get-UpwardParents -Id $rootId -Hop 1 -Visited $visited)

    $distinctParents = @($upward | Select-Object -ExpandProperty ParentId -Unique | Sort-Object)
    $minHops = if ($upward.Count -gt 0) { ($upward | Measure-Object -Property Hops -Minimum).Minimum } else { $null }
    $examplePath = if ($upward.Count -gt 0) { ($upward | Sort-Object Hops)[0].Path -join ' -> ' } else { $null }

    $item = $lookup[$rootId]
    $downwardRefines = @()
    $downwardOther = @()
    if ($item) {
        foreach ($rel in $item.Backlinked) {
            if ($rel.Role -match $TraceRoleRegex) {
                $downwardRefines += $rel.SourceId
            }
            elseif ($rel.Role -notin @('parent')) {
                $downwardOther += [PSCustomObject]@{ Id = $rel.SourceId; Role = $rel.Role }
            }
        }
    }

    $traceable = $distinctParents.Count -gt 0
    if ($traceable) {
        $tracedCount++
        foreach ($p in $distinctParents) { [void]$allDistinctParents.Add($p) }
    }

    # DirectParents: parents reached via a *direct* (Hop 1) refines/allocat* link from this root item
    # itself into Selected_Project — i.e. NOT via a recursive walk through an intermediate hub. Used by
    # build-report.ps1 to build the per-item structured consistency table (sysrequirement items only),
    # per the skill's rule that this table only covers the item's own direct upward links.
    $directParents = @($upward | Where-Object { $_.Hops -eq 1 } | Select-Object -ExpandProperty ParentId -Unique | Sort-Object)

    $perItem[$rootId] = [PSCustomObject]@{
        Id              = $rootId
        Traceable       = $traceable
        MinHops         = $minHops
        Parents         = $distinctParents
        DirectParents   = $directParents
        ExamplePath     = $examplePath
        DownwardRefines = @($downwardRefines | Select-Object -Unique)
        DownwardOther   = @($downwardOther)
        Fetched         = [bool]$item
    }
}

$output = [PSCustomObject]@{
    SelectedProjectPrefix = $SelectedProjectPrefix
    TotalRoots            = $RootItemIds.Count
    TracedCount           = $tracedCount
    UntracedIds           = @($RootItemIds | Where-Object { -not $perItem[$_].Traceable })
    AllDistinctParents    = @($allDistinctParents | Sort-Object)
    Items                 = $perItem
}

$output | ConvertTo-Json -Depth 8 | Set-Content -Path $OutputPath -Encoding UTF8
Write-Output "Traceability computed: $tracedCount / $($RootItemIds.Count) root items trace to $SelectedProjectPrefix. Written to $OutputPath"
