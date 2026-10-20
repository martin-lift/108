# Export maintained JSON lists as native AdGuard DNS filters. Does not contact AdGuard.
#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'

function Read-DomainList([string]$Name){
    $list=Get-Content -LiteralPath (Join-Path $PSScriptRoot $Name) -Raw -Encoding UTF8 | ConvertFrom-Json
    if($list.SchemaVersion -ne 1 -or $list.Mode -ne 'ReviewOnly'){throw "Unsupported source list: $Name"}
    foreach($entry in $list.Entries){
        if($entry.MatchScope -notin 'ExactHost','DomainAndSubdomains' -or $entry.Domain -cnotmatch '^(?=.{1,253}$)([a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$'){
            throw "Unsupported domain or match scope in $Name"
        }
        if($entry.ReviewStatus -notin 'NeedsReview','Confirmed','Rejected'){throw "Unsupported review status in $Name"}
        if($entry.MatchScope -eq 'DomainAndSubdomains' -and ($entry.ReviewStatus -ne 'Confirmed' -or $entry.Decision -ne 'Block' -or $entry.DecisionBasis -ne 'ExplicitTeacherInstruction' -or $Name -eq 'Approved-Domains.json')){
            throw "Broad blocking requires an explicit teacher decision in $Name"
        }
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
    @{File='Games.txt';Source='Games.json';Title='Classroom 307 - Games and video (review/test)';List=$games;Allow=$false},
    @{File='AI-Assistants.txt';Source='AI-Assistants.json';Title='Classroom 307 - AI assistants (review/test)';List=$ai;Allow=$false},
    @{File='Approved-Domains.txt';Source='Approved-Domains.json';Title='Classroom 307 - Reviewed and allowed';List=$approved;Allow=$true}
)
foreach($specification in $specifications){
    if($specification.Allow){
        $domains=@($allowedNames)
        # Both anchors limit the exception to the exact hostname.
        $rules=@($domains | ForEach-Object {'@@|'+$_+'|'})
    } else {
        $entries=@($specification.List.Entries | Where-Object {$_.ReviewStatus -ne 'Rejected' -and $_.Domain -notin $allowedNames})
        # DomainAndSubdomains uses AdGuard anchors; plain names match only the exact host.
        $rules=@($entries | ForEach-Object {if ($_.MatchScope -eq 'DomainAndSubdomains') {'||'+$_.Domain+'^'} else {$_.Domain}} | Sort-Object -Unique)
    }
    $header=@(
        '! Title: '+$specification.Title
        '! Version: '+$specification.List.Revision
        '! Homepage: https://github.com/martin-lift/108/tree/main/Cabinet-307/Remote-Administration/domain-lists'
        '! Source: '+$specification.Source
        '! Plain domains match exact hosts; ||domain^ includes the domain and all subdomains.'
        '! Rules: '+$rules.Count
    )
    if(-not $specification.Allow){$header+='! Includes candidates for teacher review. Enable manually in AdGuard only when desired.'}
    $content=(@($header)+@('')+@($rules)) -join "`n"
    [IO.File]::WriteAllText((Join-Path $outputDirectory $specification.File),($content+"`n"),[Text.UTF8Encoding]::new($false))
    [pscustomobject]@{File=$specification.File;Rules=$rules.Count;Type=$(if($specification.Allow){'Allowlist'}else{'Blocklist'})}
}
