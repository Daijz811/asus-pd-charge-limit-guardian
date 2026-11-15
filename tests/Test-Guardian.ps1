param([string]$SourcePath = (Join-Path $PSScriptRoot '..\pd_charge_limit_guardian.ps1'))
$ErrorActionPreference = 'Stop'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $SourcePath), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$assignment = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$CoreCode' }, $true)
$core = $assignment.Right.Find({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true).Value
$coreAst = [System.Management.Automation.Language.Parser]::ParseInput($core, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }

# Load selected definitions only; application and WMI initializers are never run.
foreach ($fn in $coreAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($fn.Name -in @('Invoke-ChargerWord', 'Write-ChargerReg14', 'Write-ChargerReg15')) {
        . ([ScriptBlock]::Create($fn.Extent.Text))
    }
    if ($fn.Name -eq 'Read-EcMem') {
        . ([ScriptBlock]::Create(($fn.Extent.Text -replace 'function Read-EcMem\(', 'function Read-ProviderMock(')))
    }
}
$script:Passed = 0
function Assert-True($condition, [string]$message) { if (-not $condition) { throw $message } }
function Assert-Throws([scriptblock]$body) {
    $caught = $false
    try { & $body | Out-Null } catch { $caught = $true }
    Assert-True $caught 'Expected an exception.'
}
function Test-Case([string]$name, [scriptblock]$body) {
    $script:Mode = 'success'; $script:Started = $false
    $script:DataReads = 0; $script:Writes = @(); $script:Polls = 0
    & $body
    $script:Passed++
    Write-Host ('PASS ' + $name)
}
function Start-Sleep { param([int]$Milliseconds) }
function Read-EcMem([uint64]$addr, [uint64]$len) {
    if ($addr -eq 0xFE700B00L) {
        $script:Polls++
        if ($script:Mode -eq 'busy-before' -or ($script:Started -and $script:Mode -eq 'busy-after')) { return 9 }
        if ($script:Mode -eq 'last-poll' -and $script:Polls -lt 20) { return 9 }
        return 0
    }
    if ($addr -eq 0xFE700B04L) { $script:DataReads++; return 0x0049 }
    throw ('Unexpected mocked read: {0:X}' -f $addr)
}
function Write-EcMailboxByte([uint64]$addr, [byte]$val) {
    $script:Writes += ,@($addr, $val)
    if ($addr -eq 0xFE700B00L) { $script:Started = $true }
}
function Invoke-CimMethod { param($InputObject, $MethodName, $Arguments) return $script:CimResult }

Test-Case 'Normal read returns the result with the original transaction sequence' {
    Assert-True ((Invoke-ChargerWord 0xFE -1) -eq 0x0049) 'Unexpected result.'
    Assert-True ($script:Writes.Count -eq 6 -and $script:Writes[5][1] -eq 9) 'Read sequence changed.'
}
Test-Case 'Busy mailbox times out before transaction writes' {
    $script:Mode = 'busy-before'
    Assert-Throws { Invoke-ChargerWord 0xFE -1 }
    Assert-True ($script:Writes.Count -eq 0 -and $script:Polls -eq 20) 'Busy timeout changed.'
}
Test-Case 'Completion timeout does not return stale data' {
    $script:Mode = 'busy-after'
    Assert-Throws { Invoke-ChargerWord 0xFE -1 }
    Assert-True ($script:DataReads -eq 0 -and $script:Polls -eq 31) 'Stale data was used.'
}
Test-Case 'Idle on the final allowed poll succeeds' {
    $script:Mode = 'last-poll'
    Assert-True ((Invoke-ChargerWord 0xFE -1) -eq 0x0049) 'Final poll was rejected.'
}
Test-Case 'Current and voltage writes keep the original targets and protocol' {
    Write-ChargerReg14 64
    Assert-True ($script:Writes[1][1] -eq 64 -and $script:Writes[2][1] -eq 0 -and $script:Writes[4][1] -eq 0x14 -and $script:Writes[5][1] -eq 8) 'Current write changed.'
    $script:Writes = @()
    Write-ChargerReg15 17000
    Assert-True ($script:Writes[1][1] -eq 0x68 -and $script:Writes[2][1] -eq 0x42 -and $script:Writes[4][1] -eq 0x15 -and $script:Writes[5][1] -eq 8) 'Voltage write changed.'
}
Test-Case 'Null or incomplete WMI results throw' {
    foreach ($bad in @($null, [pscustomobject]@{}, [pscustomobject]@{OutData = @(0)}, [pscustomobject]@{OutData = @(0, $null)})) {
        $script:CimResult = $bad
        Assert-Throws { Read-ProviderMock 0xFE700B00L 1 }
    }
}
Test-Case 'Valid WMI zero and nonzero results remain valid' {
    foreach ($value in @(0, 0x0049)) {
        $script:CimResult = [pscustomobject]@{OutData = @(0, $value)}
        Assert-True ((Read-ProviderMock 0xFE700B00L 1) -eq $value) 'Valid WMI result changed.'
    }
}
Write-Host ('Passed {0} offline tests.' -f $script:Passed)
