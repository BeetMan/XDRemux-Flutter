param(
    [Parameter(Mandatory=$true)][string]$AndroidHost,
    [Parameter(Mandatory=$true)][string]$WindowsHost,
    [Parameter(Mandatory=$true)][string]$AdbPath,
    [Parameter(Mandatory=$true)][string]$FixtureDirectory,
    [Parameter(Mandatory=$true)][string]$WindowsBinary,
    [Parameter(Mandatory=$true)][string]$AndroidBinary
)
$ErrorActionPreference='Stop'
$parsedIp=$null
if(-not [Net.IPAddress]::TryParse($AndroidHost,[ref]$parsedIp) -or -not [Net.IPAddress]::TryParse($WindowsHost,[ref]$parsedIp)){throw 'Use literal IP addresses'}
function Invoke-Adb {
    param([string[]]$Arguments)
    $output = & $AdbPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "ADB failed: $($Arguments[0])" }
    return $output
}
function Start-Tool {
    param([string]$Executable,[string[]]$Arguments,[string]$LogPrefix)
    foreach($argument in $Arguments) {if($argument.Contains('"')) {throw 'Double quotes in arguments are not supported'}}
    $text=($Arguments | ForEach-Object {'"'+$_+'"'}) -join ' '
    Start-Process -FilePath $Executable -ArgumentList $text -WindowStyle Hidden -PassThru -RedirectStandardOutput "$LogPrefix.stdout" -RedirectStandardError "$LogPrefix.stderr"
}
function Wait-Ready {
    param([System.Diagnostics.Process]$Process,[string]$Log)
    $deadline=[DateTime]::UtcNow.AddSeconds(15)
    while([DateTime]::UtcNow -lt $deadline) {
        if($Process.HasExited) {throw 'Receiver exited before ready'}
        if(Test-Path -LiteralPath $Log) {
            $line=@(Get-Content -LiteralPath $Log | Where-Object {$_ -match '"event":"ready"'})
            if($line.Count -gt 0){return ($line[-1] | ConvertFrom-Json)}
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'Receiver readiness timeout'
}
$fixtures=@(Get-ChildItem -LiteralPath $FixtureDirectory -File)
if($fixtures.Count -eq 0 -or ($fixtures | Where-Object {$_.Name -notmatch '^xdremux-poc-[A-Za-z0-9._-]+$'})) {throw 'Only xdremux-poc-* fixtures are accepted'}
$manifest=@($fixtures | ForEach-Object {[pscustomobject]@{name=$_.Name;size=$_.Length;sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}})
$runId=[guid]::NewGuid().ToString('N')
$root=Join-Path $PSScriptRoot "../target/runs/android-$runId"
New-Item -ItemType Directory -Path $root -Force | Out-Null
$root=(Resolve-Path -LiteralPath $root).Path
$remote="/data/local/tmp/xdremux-p1-$runId"
$androidPort=Get-Random -Minimum 35000 -Maximum 55000
$windowsPort=$androidPort+1
Invoke-Adb @('shell','mkdir','-p',"$remote/fixtures") | Out-Null
Invoke-Adb @('push',$AndroidBinary,"$remote/transfer") | Out-Null
Invoke-Adb @('shell','chmod','700',"$remote/transfer") | Out-Null
foreach($file in $fixtures) {Invoke-Adb @('push',$file.FullName,"$remote/fixtures/$($file.Name)") | Out-Null}
$androidReceiver=$windowsReceiver=$sender=$null
try {
    $androidReceiver=Start-Tool $AdbPath @('shell',"$remote/transfer receive $remote/rx ${AndroidHost}:$androidPort 35 $remote/received.json --accept-test-files") (Join-Path $root 'android-receiver')
    $ready=Wait-Ready $androidReceiver (Join-Path $root 'android-receiver.stdout')
    $sendArgs=@('send',(Join-Path $root 'tx'),"${AndroidHost}:$androidPort",$ready.fingerprint,(Join-Path $root 'windows-sent.json')) + @($fixtures.FullName)
    $sender=Start-Tool $WindowsBinary $sendArgs (Join-Path $root 'windows-sender')
    $sender.WaitForExit()
    if($sender.ExitCode -ne 0) {throw 'Windows to Android send failed; inspect stderr'}
    $windowsReceiver=Start-Tool $WindowsBinary @('receive',(Join-Path $root 'rx'),"${WindowsHost}:$windowsPort",'25',(Join-Path $root 'windows-received.json'),'--accept-test-files') (Join-Path $root 'windows-receiver')
    $ready=Wait-Ready $windowsReceiver (Join-Path $root 'windows-receiver.stdout')
    $paths=($fixtures | ForEach-Object {"$remote/fixtures/$($_.Name)"}) -join ' '
    Invoke-Adb @('shell',"$remote/transfer send $remote/tx ${WindowsHost}:$windowsPort $($ready.fingerprint) $remote/sent.json $paths") | Out-Null
    $windowsReceiver.WaitForExit(); $androidReceiver.WaitForExit()
    if($windowsReceiver.ExitCode -ne 0 -or $androidReceiver.ExitCode -ne 0){throw 'Receiver failed; inspect stderr'}
    Invoke-Adb @('pull',"$remote/received.json",(Join-Path $root 'android-received.json')) | Out-Null
    Invoke-Adb @('pull',"$remote/sent.json",(Join-Path $root 'android-sent.json')) | Out-Null
    foreach($direction in @('windows','android')) {
        $receipts=@(Get-Content -LiteralPath (Join-Path $root "$direction-received.json") -Raw | ConvertFrom-Json)
        if($receipts.Count -ne $manifest.Count){throw 'File count differs'}
        foreach($expected in $manifest) {
            $receipt=@($receipts | Where-Object {$_.name -eq $expected.name})
            if($receipt.Count -ne 1 -or $receipt[0].size -ne $expected.size -or $receipt[0].sha256 -ne $expected.sha256 -or -not $receipt[0].peer_hash_present){throw 'Receipt integrity differs'}
            $id=$receipt[0].id
            if($id -notmatch '^[0-9a-f-]{36}$'){throw 'Unexpected receipt ID'}
            if($direction -eq 'windows') {
                $data=Join-Path $root "rx/received/file-$id/data"
                if((Get-Item -LiteralPath $data).Length -ne $expected.size -or (Get-FileHash -LiteralPath $data -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected.sha256){throw 'Independent Windows verification failed'}
            } else {
                $hash=Invoke-Adb @('shell',"sha256sum $remote/rx/received/file-$id/data")
                $size=Invoke-Adb @('shell',"stat -c %s $remote/rx/received/file-$id/data")
                if($hash.Split(' ')[0].Trim() -ne $expected.sha256 -or [long]$size -ne $expected.size){throw 'Independent Android verification failed'}
            }
        }
    }
    foreach($expected in $manifest) {if((Get-FileHash -LiteralPath (Join-Path $FixtureDirectory $expected.name) -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected.sha256){throw 'Source changed'}}
    $summary=[pscustomobject]@{transport='direct LAN HTTPS; ADB deployment, control and independent verification only'; filesPerDirection=$manifest.Count;bytesPerDirection=($manifest|Measure-Object size -Sum).Sum;allLengthsAndSha256Match=$true;independentDiskVerification=$true;sourceFilesUnchanged=$true;fixtures=$manifest}
    $summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root 'summary.json') -Encoding UTF8
    $summary | Format-List transport,filesPerDirection,bytesPerDirection,allLengthsAndSha256Match,independentDiskVerification
    Write-Output "Evidence: $root"
} finally {
    foreach($process in @($sender,$windowsReceiver,$androidReceiver)) {
        if($null -ne $process -and -not $process.HasExited){$process.Kill()}
    }
}
