# Offline only: parse source, load selected function definitions, and mock all EC I/O.
param([string]$SourcePath = (Join-Path $PSScriptRoot '..\pd_charge_limit_guardian.ps1'))
$ErrorActionPreference = 'Stop'
$tokens = $null; $parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $SourcePath), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$source = [IO.File]::ReadAllText((Resolve-Path $SourcePath))
$coreAssignment = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$CoreCode' }, $true)
$coreString = $coreAssignment.Right.Find({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true)
$core = $coreString.Value
$coreAst = [System.Management.Automation.Language.Parser]::ParseInput($core, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }

# Never dot-source the application or CoreCode: both have hardware-affecting initializers.
$names = @('Wait-ChargerIdle', 'Invoke-ChargerWord', 'Read-ChargerRegWord', 'Write-ChargerReg14', 'Write-ChargerReg15', 'Test-RenesasPdChip', 'Invoke-Channel3', 'Get-PowerState', 'Restore-HardwareDefault')
foreach ($fn in $coreAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    if ($fn.Name -in $names) { . ([ScriptBlock]::Create($fn.Extent.Text)) }
}
$providerFn = $coreAst.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Read-EcMem' }, $false)
. ([ScriptBlock]::Create(($providerFn.Extent.Text -replace 'function Read-EcMem\(', 'function Read-ProviderMock(')))

$MailboxMutexName = 'Local\PD_Guardian_OfflineTest_' + [guid]::NewGuid().ToString('N')
$script:Passed = 0

function Assert-True($condition, [string]$message) {
    if (-not $condition) { throw $message }
}
function Assert-Throws([scriptblock]$body) {
    $threw = $false
    try { & $body | Out-Null } catch { $threw = $true }
    Assert-True $threw 'Expected an exception, but the operation continued.'
}
function Test-Case([string]$name, [scriptblock]$body) {
    Reset-Simulation
    & $body
    $script:Passed++
    Write-Host ('PASS ' + $name)
}
function Reset-Simulation {
    $script:Sim = @{
        Mode = 'success'; Started = $false; Status = 0x80; Command = 0
        Lo = 0; Hi = 0; VTarget = 16071; P40 = 0x10; State = 6
        Registers = @{ 0x14 = 0; 0x15 = 16064; 0xFE = 0x0049; 0xFF = 0x000C }
        Writes = [System.Collections.Generic.List[object]]::new()
        DataReads = 0; ChargerWrites = 0
    }
}
function Start-Sleep { param([int]$Milliseconds) } # No real waits in mocks.
function Read-EcMem([uint64]$addr, [uint64]$len) {
    switch ($addr) {
        0xFE700B00L {
            if ($script:Sim.Mode -eq 'busy-before' -or ($script:Sim.Started -and $script:Sim.Mode -eq 'busy-after')) { return 9 }
            return 0
        }
        0xFE700B01L { return $script:Sim.Status }
        0xFE700B04L { $script:Sim.DataReads++; return $script:Sim.Registers[$script:Sim.Command] }
        0xFE700B70L { return $script:Sim.VTarget }
        0xFE700640L { return $script:Sim.P40 }
        0xFE7006E2L { return $script:Sim.State }
        0xFE7006CDL { return 0 }
        default { throw ('Unexpected mocked read address: 0x{0:X}' -f $addr) }
    }
}
function Write-EcMailboxByte([uint64]$addr, [byte]$val) {
    $script:Sim.Writes.Add(@{ Address = $addr; Value = $val })
    switch ($addr) {
        0xFE700B03L { $script:Sim.Command = [int]$val }
        0xFE700B04L { $script:Sim.Lo = [int]$val }
        0xFE700B05L { $script:Sim.Hi = [int]$val }
        0xFE700B00L {
            $script:Sim.Started = $true
            if ($val -eq 8) {
                $script:Sim.ChargerWrites++
                if ($script:Sim.Mode -ne 'readback-mismatch') {
                    $script:Sim.Registers[$script:Sim.Command] = ($script:Sim.Hi -shl 8) -bor $script:Sim.Lo
                }
            }
        }
    }
}
function Invoke-CimMethod { param($InputObject, $MethodName, $Arguments) return $script:CimResult }

Test-Case 'Script and embedded hardware functions parse without execution' {
    Assert-True ($coreAst -ne $null) 'Core AST missing.'
}
Test-Case 'Busy mailbox aborts before any mailbox writes' {
    $script:Sim.Mode = 'busy-before'
    Assert-Throws { Read-ChargerRegWord 0xFE }
    Assert-True ($script:Sim.Writes.Count -eq 0) 'Busy mailbox was overwritten.'
}
Test-Case 'Busy mailbox aborts before changing the channel selector' {
    $script:Sim.Mode = 'busy-before'
    Assert-Throws { Invoke-Channel3 { Read-ChargerRegWord 0xFE } }
    Assert-True ($script:Sim.Writes.Count -eq 0) 'Channel changed while mailbox was busy.'
}
Test-Case 'Completion timeout never returns stale data' {
    $script:Sim.Mode = 'busy-after'
    Assert-Throws { Read-ChargerRegWord 0xFE }
    Assert-True ($script:Sim.DataReads -eq 0) 'Stale result buffer was read.'
}
Test-Case 'Device NACK status is rejected' {
    $script:Sim.Status = 0x10
    Assert-Throws { Read-ChargerRegWord 0xFE }
    Assert-True ($script:Sim.DataReads -eq 0) 'Failed transaction data was used.'
}
Test-Case 'Success supports DONE and optional alarm flag' {
    $script:Sim.Status = 0xC0
    Assert-True ((Read-ChargerRegWord 0xFE) -eq 0x0049) 'Valid transaction rejected.'
}
Test-Case 'Compatible successful status zero is accepted' {
    $script:Sim.Status = 0
    Assert-True ((Read-ChargerRegWord 0xFE) -eq 0x0049) 'Status-zero success rejected.'
}
Test-Case 'Unexpected charger write register is rejected at transport boundary' {
    Assert-Throws { Invoke-ChargerWord 0x3C 1 }
    Assert-True ($script:Sim.Writes.Count -eq 0) 'Unexpected register write reached mailbox.'
}
Test-Case 'Out-of-range register 14 write is rejected' {
    Assert-Throws { Invoke-ChargerWord 0x14 128 }
    Assert-True ($script:Sim.Writes.Count -eq 0) 'Out-of-range write reached mailbox.'
}
Test-Case 'Out-of-range register 15 write is rejected' {
    Assert-Throws { Write-ChargerReg15 18000 }
    Assert-True ($script:Sim.Writes.Count -eq 0) 'Out-of-range voltage reached mailbox.'
}
Test-Case 'Original register pair writes and reads back successfully' {
    Write-ChargerReg14 64
    Write-ChargerReg15 17000
    Assert-True ($script:Sim.Registers[0x14] -eq 64 -and $script:Sim.Registers[0x15] -eq 17000) 'Pair changed.'
}
Test-Case 'Current readback mismatch is rejected' {
    $script:Sim.Mode = 'readback-mismatch'
    Assert-Throws { Write-ChargerReg14 64 }
}
Test-Case 'Voltage readback mismatch is rejected' {
    $script:Sim.Mode = 'readback-mismatch'
    Assert-Throws { Write-ChargerReg15 17000 }
}
Test-Case 'Channel selector resets when body throws' {
    Assert-Throws { Invoke-Channel3 { throw 'Injected failure' } }
    $last = $script:Sim.Writes[$script:Sim.Writes.Count - 1]
    Assert-True ($last.Address -eq 0xFE7006CDL -and $last.Value -eq 0) 'Channel cleanup missing.'
}
Test-Case 'Restore rejects invalid EC target before charger writes' {
    $script:Sim.VTarget = 1000
    Assert-Throws { Restore-HardwareDefault }
    Assert-True ($script:Sim.ChargerWrites -eq 0) 'Partial restore started with invalid target.'
}
Test-Case 'Restore rejects different chip before charger writes' {
    $script:Sim.Registers[0xFF] = 0x1234
    Assert-Throws { Restore-HardwareDefault }
    Assert-True ($script:Sim.ChargerWrites -eq 0) 'Wrong chip was written.'
}
Test-Case 'Restore uses EC target and zero charge-current request' {
    $script:Sim.Registers[0x14] = 64
    Restore-HardwareDefault
    Assert-True ($script:Sim.Registers[0x14] -eq 0 -and $script:Sim.Registers[0x15] -eq 16071) 'Restore did not use current EC target.'
}
Test-Case 'Malformed WMI data is rejected' {
    $script:CimResult = [pscustomobject]@{ OutData = @() }
    Assert-Throws { Read-ProviderMock 0xFE700640L 1 }
}
Test-Case 'Valid WMI data is returned through the provider wrapper' {
    $script:CimResult = [pscustomobject]@{ OutData = @(0, 16) }
    Assert-True ((Read-ProviderMock 0xFE700640L 1) -eq 16) 'Provider result changed.'
}

# Exercise the actual disable switch arm with mocked stop/task functions.
$disableArm = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true) |
    ForEach-Object { $_.Clauses } | Where-Object { $_.Item1.Extent.Text -eq '"disable"' } | Select-Object -First 1
Test-Case 'Startup task removal is attempted even when restore fails' {
    $script:Disabled = $false
    function Stop-Worker { throw 'Injected restore failure' }
    function Disable-BootProtection { $script:Disabled = $true }
    $text = $disableArm.Item2.Extent.Text
    Assert-Throws { . ([ScriptBlock]::Create($text.Substring(1, $text.Length - 2))) }
    Assert-True $script:Disabled 'Startup task cleanup was skipped.'
}

# Evaluate only the pre-EC model/BIOS guard using a fake CIM function.
$guardStart = $core.IndexOf('$computer = Get-CimInstance')
$guardEnd = $core.IndexOf('$global:PdEcInst =')
$guard = [ScriptBlock]::Create($core.Substring($guardStart, $guardEnd - $guardStart))
function Get-CimInstance {
    param($ClassName, $ErrorAction)
    if ($ClassName -eq 'Win32_ComputerSystem') { return [pscustomobject]@{ Manufacturer = 'ASUSTeK COMPUTER INC.'; Model = $script:TestModel } }
    if ($ClassName -eq 'Win32_BIOS') { return [pscustomobject]@{ SMBIOSBIOSVersion = $script:TestBios } }
    throw 'Unexpected CIM call in offline guard test.'
}
Test-Case 'Known model and BIOS pass pre-EC guard' {
    $script:TestModel = 'ROG Zephyrus G16 GU603VV_GU603VV'; $script:TestBios = 'GU603VV.315'
    & $guard
}
Test-Case 'Other model fails pre-EC guard' {
    $script:TestModel = 'GU603VI'; $script:TestBios = 'GU603VV.315'
    Assert-Throws { & $guard }
}
Test-Case 'Other BIOS fails pre-EC guard' {
    $script:TestModel = 'GU603VV'; $script:TestBios = 'GU603VV.317'
    Assert-Throws { & $guard }
}
Write-Host ('Passed {0} offline tests. No real hardware, task or application was executed.' -f $script:Passed)
