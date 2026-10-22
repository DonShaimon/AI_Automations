<#
.SYNOPSIS
  Converts an ASPICE PLATPD check report (Markdown, produced by the aspice-platpd-check skill)
  into a self-contained HTML report, auto-linking every Polarion work-item ID (e.g. EPGSW-30929,
  VWMS-77364, PAOB-1234) to its Polarion portal page.

.DESCRIPTION
  This is a small hand-rolled Markdown -> HTML converter (no external dependencies / no Node /
  no Python required) tailored to the structure the skill's report-template.md produces:
  headings (#, ##, ###), pipe tables, **bold**, `inline code`, "---" horizontal rules / section
  breaks, and "- " bullet lists. It also color-codes Pass/Fail/Partial/Needs Rework table cells.

.PARAMETER InputPath
  Path to the source .md report file.

.PARAMETER OutputPath
  Path to write the generated .html file. Defaults to the input path with a .html extension.

.PARAMETER ProjectMap
  Hashtable mapping work-item ID prefix -> Polarion project_id, used to build the portal link
  https://polarion.mobileye.com/polarion/redirect/project/{project_id}/workitem?id={PREFIX-NUM}
  Defaults cover the projects seen so far in this workspace (see /memories/repo/polarion-api-facts.md).

.EXAMPLE
  ./md-to-html.ps1 -InputPath "reports/PLATPD-991-ASPICE-report.md"
#>
param(
    [Parameter(Mandatory = $true)][string]$InputPath,
    [string]$OutputPath,
    [string]$PolarionBaseUrl = "https://polarion.mobileye.com/polarion/redirect/project",
    [hashtable]$ProjectMap = @{ "EPGSW" = "app_software"; "VWMS" = "VW_MaaS"; "PAOB" = "Porsche_Audi_One_Box" }
)

if (-not $OutputPath) {
    $OutputPath = [System.IO.Path]::ChangeExtension($InputPath, ".html")
}

function Escape-Html([string]$s) {
    $s = $s -replace '&', '&amp;'
    $s = $s -replace '<', '&lt;'
    $s = $s -replace '>', '&gt;'
    return $s
}

function Expand-ShorthandIdLists([string]$line, [hashtable]$ProjectMap) {
    # Expands comma-separated shorthand lists like "EPGSW-30254, 31781, 30145" into
    # "EPGSW-30254, EPGSW-31781, EPGSW-30145" so every bare number also gets auto-linked.
    $prefixPattern = ($ProjectMap.Keys | Sort-Object { $_.Length } -Descending) -join '|'
    if (-not $prefixPattern) { return $line }
    $regex = "\b($prefixPattern)-(\d+)((?:\s*,\s*\d+)+)\b"
    return [regex]::Replace($line, $regex, {
        param($m)
        $prefix = $m.Groups[1].Value
        $first = $m.Groups[2].Value
        $rest = $m.Groups[3].Value
        $expandedRest = [regex]::Replace($rest, '(\d+)', "$prefix-`$1")
        return "$prefix-$first$expandedRest"
    })
}

function Convert-InlineMarkdown([string]$line, [hashtable]$ProjectMap, [string]$BaseUrl) {
    $line = Expand-ShorthandIdLists $line $ProjectMap
    $line = Escape-Html $line
    # Bold
    $line = [regex]::Replace($line, '\*\*(.+?)\*\*', '<strong>$1</strong>')
    # Inline code
    $line = [regex]::Replace($line, '`([^`]+?)`', '<code>$1</code>')
    # Auto-link work-item IDs (prefix-number), longest prefixes first to avoid partial overlaps
    $prefixPattern = ($ProjectMap.Keys | Sort-Object { $_.Length } -Descending) -join '|'
    if ($prefixPattern) {
        $idRegex = "\b($prefixPattern)-(\d+)\b"
        $line = [regex]::Replace($line, $idRegex, {
            param($m)
            $prefix = $m.Groups[1].Value
            $num = $m.Groups[2].Value
            $project = $ProjectMap[$prefix]
            $id = "$prefix-$num"
            $url = "$BaseUrl/$project/workitem?id=$id"
            return "<a href=""$url"" target=""_blank"" rel=""noopener"">$id</a>"
        })
    }
    return $line
}

function Get-VerdictClass([string]$cellHtml) {
    if ($cellHtml -match 'Fail') { return 'verdict-fail' }
    if ($cellHtml -match 'Needs Rework') { return 'verdict-rework' }
    if ($cellHtml -match 'Partial') { return 'verdict-partial' }
    if ($cellHtml -match '\bPass\b') { return 'verdict-pass' }
    if ($cellHtml -match 'N/A') { return 'verdict-na' }
    return ''
}

$rawLines = Get-Content -Raw $InputPath -Encoding UTF8
$lines = $rawLines -split "`r?`n"

$html = New-Object System.Text.StringBuilder
[void]$html.AppendLine('<!DOCTYPE html>')
[void]$html.AppendLine('<html lang="en"><head><meta charset="utf-8">')
[void]$html.AppendLine('<title>ASPICE Check Report</title>')
[void]$html.AppendLine(@'
<style>
  body { font-family: Segoe UI, Arial, sans-serif; max-width: 1200px; margin: 2em auto; padding: 0 1em; color: #1a1a1a; line-height: 1.5; }
  h1 { border-bottom: 3px solid #2b6cb0; padding-bottom: 0.3em; }
  h2 { border-bottom: 1px solid #ccc; padding-bottom: 0.2em; margin-top: 2em; color: #2b6cb0; }
  h3 { margin-top: 1.6em; color: #1a4971; }
  table { border-collapse: collapse; width: 100%; margin: 0.8em 0 1.2em 0; font-size: 0.92em; }
  th, td { border: 1px solid #ccc; padding: 6px 10px; text-align: left; vertical-align: top; }
  th { background: #2b6cb0; color: #fff; }
  tr:nth-child(even) td { background: #f7f9fb; }
  a { color: #2b6cb0; text-decoration: none; }
  a:hover { text-decoration: underline; }
  code { background: #eef1f4; padding: 1px 5px; border-radius: 3px; font-family: Consolas, monospace; }
  hr { border: none; border-top: 1px solid #ddd; margin: 1.5em 0; }
  .verdict-pass { background: #d9f2df !important; color: #1a6b34; font-weight: 600; }
  .verdict-fail { background: #fbdada !important; color: #a12626; font-weight: 600; }
  .verdict-rework { background: #fdf0d0 !important; color: #8a5a00; font-weight: 600; }
  .verdict-partial { background: #fdf6d0 !important; color: #7a6600; }
  .verdict-na { background: #eaeaea !important; color: #666; }
  ul { margin: 0.4em 0; }
</style>
'@)
[void]$html.AppendLine('</head><body>')

$i = 0
$inList = $false
while ($i -lt $lines.Count) {
    $line = $lines[$i]

    if ($line.Trim() -eq '') {
        if ($inList) { [void]$html.AppendLine('</ul>'); $inList = $false }
        $i++
        continue
    }

    # Horizontal rule (standalone --- line, not a table separator row)
    if ($line.Trim() -eq '---') {
        if ($inList) { [void]$html.AppendLine('</ul>'); $inList = $false }
        [void]$html.AppendLine('<hr>')
        $i++
        continue
    }

    # Headings
    if ($line -match '^(#{1,4})\s+(.*)$') {
        if ($inList) { [void]$html.AppendLine('</ul>'); $inList = $false }
        $level = $Matches[1].Length
        $text = Convert-InlineMarkdown $Matches[2] $ProjectMap $PolarionBaseUrl
        [void]$html.AppendLine("<h$level>$text</h$level>")
        $i++
        continue
    }

    # Table block: header line + separator line (|---|---|)
    if ($line -match '^\|.*\|\s*$' -and ($i + 1) -lt $lines.Count -and $lines[$i + 1] -match '^\|[\s:\-|]+\|\s*$') {
        if ($inList) { [void]$html.AppendLine('</ul>'); $inList = $false }
        $headerCells = ($line.Trim().Trim('|')) -split '\|' | ForEach-Object { $_.Trim() }
        [void]$html.AppendLine('<table><thead><tr>')
        foreach ($hc in $headerCells) {
            [void]$html.AppendLine("<th>$(Convert-InlineMarkdown $hc $ProjectMap $PolarionBaseUrl)</th>")
        }
        [void]$html.AppendLine('</tr></thead><tbody>')
        $i += 2
        while ($i -lt $lines.Count -and $lines[$i] -match '^\|.*\|\s*$') {
            $rowCells = ($lines[$i].Trim().Trim('|')) -split '\|' | ForEach-Object { $_.Trim() }
            [void]$html.AppendLine('<tr>')
            foreach ($rc in $rowCells) {
                $cellHtml = Convert-InlineMarkdown $rc $ProjectMap $PolarionBaseUrl
                $cls = Get-VerdictClass $rc
                if ($cls) {
                    [void]$html.AppendLine("<td class=""$cls"">$cellHtml</td>")
                } else {
                    [void]$html.AppendLine("<td>$cellHtml</td>")
                }
            }
            [void]$html.AppendLine('</tr>')
            $i++
        }
        [void]$html.AppendLine('</tbody></table>')
        continue
    }

    # Bullet list item
    if ($line -match '^\s*-\s+(.*)$') {
        if (-not $inList) { [void]$html.AppendLine('<ul>'); $inList = $true }
        $text = Convert-InlineMarkdown $Matches[1] $ProjectMap $PolarionBaseUrl
        [void]$html.AppendLine("<li>$text</li>")
        $i++
        continue
    }

    # Numbered list item (rendered as its own paragraph line, kept simple)
    if ($line -match '^\s*(\d+)\.\s+(.*)$') {
        if ($inList) { [void]$html.AppendLine('</ul>'); $inList = $false }
        $text = Convert-InlineMarkdown $Matches[2] $ProjectMap $PolarionBaseUrl
        [void]$html.AppendLine("<p><strong>$($Matches[1]).</strong> $text</p>")
        $i++
        continue
    }

    # Default: paragraph
    if ($inList) { [void]$html.AppendLine('</ul>'); $inList = $false }
    $text = Convert-InlineMarkdown $line $ProjectMap $PolarionBaseUrl
    [void]$html.AppendLine("<p>$text</p>")
    $i++
}
if ($inList) { [void]$html.AppendLine('</ul>') }

[void]$html.AppendLine('</body></html>')

Set-Content -Path $OutputPath -Value $html.ToString() -Encoding UTF8
Write-Output "Written: $OutputPath"
