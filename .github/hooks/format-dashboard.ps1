<#
.SYNOPSIS
  Reformat a Grafana dashboard JSON to canonical key order and 4-space indent.

.DESCRIPTION
  Called by the pre-commit hook for every staged dashboard.json under
  cluster/apps/grafana-dashboards/.

  Key-ordering rules:
    * Dashboard top-level, panel, target, and gridPos objects use an explicit
      preferred order (derived from the adguard reference dashboard).
    * Every other object sorts keys alphabetically so the output is fully
      deterministic regardless of how the file was last saved (e.g. by
      Grafana's export UI or a manual edit).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

$ErrorActionPreference = 'Stop'

# -- canonical key orders ---------------------------------------------------

$DashboardKeys = @(
    'title','uid','tags','schemaVersion','timezone','editable',
    'graphTooltip','time','refresh','templating','annotations','panels'
)
$PanelKeys = @(
    'id','type','title','description','datasource','gridPos',
    'interval','targets','transformations','fieldConfig','options'
)
$TargetKeys = @('expr','legendFormat','refId','instant','format')
$GridPosKeys = @('h','w','x','y')

# -- helpers ----------------------------------------------------------------

function Reorder([System.Collections.IDictionary]$Obj, [string[]]$Preferred) {
    $out = [ordered]@{}
    foreach ($k in $Preferred) {
        if ($Obj.Contains($k)) { $out[$k] = $Obj[$k] }
    }
    foreach ($k in ($Obj.Keys | Sort-Object)) {
        if (-not $out.Contains($k)) { $out[$k] = $Obj[$k] }
    }
    return $out
}

function SortKeys([System.Collections.IDictionary]$Obj) {
    $out = [ordered]@{}
    foreach ($k in ($Obj.Keys | Sort-Object)) { $out[$k] = $Obj[$k] }
    return $out
}

function Canonicalize($Obj, [string]$Context = '') {
    if ($Obj -is [System.Collections.IDictionary]) {
        $Obj = switch ($Context) {
            'dashboard' { Reorder $Obj $DashboardKeys }
            'panel'     { Reorder $Obj $PanelKeys }
            'target'    { Reorder $Obj $TargetKeys }
            'gridPos'   { Reorder $Obj $GridPosKeys }
            default     { SortKeys $Obj }
        }
        $result = [ordered]@{}
        foreach ($k in @($Obj.Keys)) {
            $v = $Obj[$k]
            if ($Context -eq 'dashboard' -and $k -eq 'panels' -and $v -is [array]) {
                $result[$k] = @(foreach ($p in $v) { Canonicalize $p 'panel' })
            }
            elseif ($Context -eq 'panel' -and $k -eq 'targets' -and $v -is [array]) {
                $result[$k] = @(foreach ($t in $v) { Canonicalize $t 'target' })
            }
            elseif ($Context -eq 'panel' -and $k -eq 'gridPos') {
                $result[$k] = Canonicalize $v 'gridPos'
            }
            else {
                $result[$k] = Canonicalize $v
            }
        }
        return $result
    }
    if ($Obj -is [array]) {
        # Comma operator prevents PowerShell from unrolling empty arrays to $null.
        $items = @(foreach ($item in $Obj) { Canonicalize $item })
        return ,$items
    }
    return $Obj
}

# -- main -------------------------------------------------------------------

$data = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable
$data = Canonicalize $data 'dashboard'
$json = $data | ConvertTo-Json -Depth 100

# ConvertTo-Json uses 2-space indent; double it to 4-space.
$json = $json -replace '(?m)^(  )+', { ' ' * ($_.Value.Length * 2) }

# Normalise to LF + trailing newline.
$json = $json.Replace("`r`n", "`n")
if (-not $json.EndsWith("`n")) { $json += "`n" }

[System.IO.File]::WriteAllText(
    [System.IO.Path]::GetFullPath($Path),
    $json,
    [System.Text.UTF8Encoding]::new($false)
)
