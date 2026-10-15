# Export maintained JSON lists as native AdGuard DNS filters. Does not contact AdGuard.
#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'

function Read-DomainList([string]$Name){
    $list=Get-Content -LiteralPath (Join-Path $PSScriptRoot $Name) -Raw -Encoding UTF8 | ConvertFrom-Json
    if($list.SchemaVersion -ne 1 -or $list.Mode -ne 'ReviewOnly'){throw "Unsupported source list: $Name"}
    foreach($entry in $list.Entries){
        if($entry.MatchScope -ne 'ExactHost' -or $entry.Domain -cnotmatch '^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'){
            throw "Unsupported domain or match scope in $Name"
        }
        if($entry.ReviewStatus -notin 'NeedsReview','Confirmed','Rejected'){throw "Unsupported review status in $Name"}
    }
    $list
}

$games=Read-DomainList 'Games.json'
$ai=Read-DomainList 'AI-Assistants.json'
$approved=Read-DomainList 'Approved-Domains.json'
$allowedNames=@($approved.Entries | Where-Object {$_.Decision -eq 'Allow' -and $_.ReviewStatus -eq 'Confirmed'} | ForEach-Object Domain | Sort-Object -Unique)
$outputDirectory=Join-Path $PSScriptRoot 'adguard'
$null=New-Item -ItemType Directory -Path $outputDirectory -Force
$specifications=@(
    @{File='Games.txt';Source='Games.json';Title='Classroom 307 - Games (review/test)';List=$games;Allow=$false},
    @{File='AI-Assistants.txt';Source='AI-Assistants.json';Title='Classroom 307 - AI assistants (review/test)';List=$ai;Allow=$false},
    @{File='Approved-Domains.txt';Source='Approved-Domains.json';Title='Classroom 307 - Reviewed and allowed';List=$approved;Allow=$true}
)
foreach($specification in $specifications){
    if($specification.Allow){
        $domains=@($allowedNames)
        # Both anchors limit the exception to the exact hostname.
        $rules=@($domains | ForEach-Object {'@@|'+$_+'|'})
    } else {
        $domains=@($specification.List.Entries | Where-Object {$_.ReviewStatus -ne 'Rejected' -and $_.Domain -notin $allowedNames} | ForEach-Object Domain | Sort-Object -Unique)
        # AdGuard domains-only syntax blocks the exact hostname, without its subdomains.
        $rules=@($domains)
    }
    $header=@(
        '! Title: '+$specification.Title
        '! Version: '+$specification.List.Revision
        '! Homepage: https://github.com/martin-lift/108/tree/main/Cabinet-307/Remote-Administration/domain-lists'
        '! Source: '+$specification.Source
        '! Exact hostnames only. No wildcard subdomains.'
        '! Rules: '+$rules.Count
    )
    if(-not $specification.Allow){$header+='! Includes candidates for teacher review. Enable manually in AdGuard only when desired.'}
    $content=(@($header)+@('')+@($rules)) -join "`n"
    [IO.File]::WriteAllText((Join-Path $outputDirectory $specification.File),($content+"`n"),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{File=$specification.File;Rules=$rules.Count;Type=$(if($specification.Allow){'Allowlist'}else{'Blocklist'})}
}
