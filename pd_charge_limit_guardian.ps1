# =====================================================================
# ASUS ROG USB-C PD 限充停充 (State=6) 断流修复工具  v0.2.1
#
# 双击【PD限充不断流开关.bat】打开控制面板：
#   - 开启修复 / 关闭并恢复出厂
#   - 开关机保护（仅开启时可选）：登录后自动在后台恢复守护
#
# 结构：
#   - GUI 线程      ：只负责绘制界面，不碰任何硬件/WMI，因此不会卡顿。
#   - 后台轮询线程  ：读取 EC 状态、执行开/关操作，把结果放入同步表供界面显示。
#   - 守护进程      ：-BackgroundWorker，无窗口；仅在 PDIN=1, ACIN=0, State=6 时
#                     维持 Reg0x14 = 64 mA、Reg0x15 >= 16800 mV (写入 17000 mV)。
#   - 守护进程与面板通过命名互斥体共享 SMBus 邮筒，避免同时操作。
# =====================================================================

param(
    [switch]$BackgroundWorker
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# 管理员提权（隐藏窗口）
# ---------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $modeArg = if ($BackgroundWorker) { "-BackgroundWorker" } else { "" }
    $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" $modeArg"
    Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs -WindowStyle Hidden
    exit
}

# =====================================================================
# 核心硬件代码（守护进程与后台轮询线程共用；GUI 线程不加载）
# =====================================================================
$CoreCode = @'
$RunMutexName     = "Global\ASUS_PD_Guardian_Run"
$StopEventName    = "Global\ASUS_PD_Guardian_Stop"
$MailboxMutexName = "Global\ASUS_PD_Guardian_Mailbox"
$TaskName         = "ASUS_PD_ChargeLimit_Guardian"

# 固定 EC 地址只在已验证的平台使用；芯片 ID 相同不代表 EC 布局相同。
$computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
$bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
if ($computer.Manufacturer -notmatch 'ASUS|ASUSTeK' -or $computer.Model -notmatch 'GU603VV' -or $bios.SMBIOSBIOSVersion -ne 'GU603VV.315') {
    throw '此版本仅支持 ASUS GU603VV / BIOS GU603VV.315，未访问 EC 邮筒。'
}
$global:PdEcInst = Get-CimInstance -Namespace root\wmi -ClassName IecToolkitInterface -ErrorAction Stop
$WorkerErrorFile = Join-Path $env:LOCALAPPDATA 'ASUS_PD_ChargeLimit_Guardian\last-error.txt'

function Set-WorkerError([string]$message) {
    $null = New-Item -ItemType Directory -Path (Split-Path $WorkerErrorFile) -Force
    Set-Content -LiteralPath $WorkerErrorFile -Value $message -Encoding UTF8
}

function Get-WorkerError {
    if (Test-Path -LiteralPath $WorkerErrorFile) {
        return (Get-Content -LiteralPath $WorkerErrorFile -Raw -ErrorAction Stop).Trim()
    }
    return ''
}

# 白名单：仅允许写入 SMBus 邮筒的 7 个字节
$AllowedMailboxAddrs = @(
    [uint64]0xFE7006CDL,
    [uint64]0xFE700B00L, [uint64]0xFE700B01L, [uint64]0xFE700B02L,
    [uint64]0xFE700B03L, [uint64]0xFE700B04L, [uint64]0xFE700B05L
)

function Read-EcMem([uint64]$addr, [uint64]$len) {
    [uint64[]]$in = @([uint64]0x0000235700800007L, [uint64]0, [uint64]$addr, [uint64]$len, [uint64]0, [uint64]0, [uint64]0)
    $res = Invoke-CimMethod -InputObject $global:PdEcInst -MethodName SystemMethod -Arguments @{InData = $in}
    if ($null -eq $res.OutData -or $res.OutData.Count -lt 2 -or $null -eq $res.OutData[1]) {
        throw '华硕 WMI 接口未返回有效的 EC 数据。'
    }
    return $res.OutData[1]
}

function Write-EcMailboxByte([uint64]$addr, [byte]$val) {
    if ($AllowedMailboxAddrs -notcontains $addr) {
        throw ("安全拦截：禁止向非白名单地址 0x{0:X8} 写入" -f $addr)
    }
    [uint64[]]$in = @([uint64]0x0000235700800007L, [uint64]1, [uint64]$addr, [uint64]$val, [uint64]0, [uint64]0, [uint64]0)
    $null = Invoke-CimMethod -InputObject $global:PdEcInst -MethodName SystemMethod -Arguments @{InData = $in}
}

# 协议寄存器清零是事务完成条件；超时不得使用残留数据。
function Wait-ChargerIdle([int]$attempts = 30) {
    for ($i = 0; $i -lt $attempts; $i++) {
        if ((Read-EcMem 0xFE700B00L 1) -eq 0) { return }
        Start-Sleep -Milliseconds 15
    }
    throw 'SMBus 通信超时；本轮已中止，未确认的数据不会被使用。'
}

# 一次 SMBus Word 事务：$writeValue < 0 表示读取。
function Invoke-ChargerWord([byte]$reg, [int]$writeValue) {
    if ($writeValue -ge 0 -and $reg -notin @(0x14, 0x15)) { throw '禁止写入其它充电芯片寄存器。' }
    if ($writeValue -ge 0 -and $reg -eq 0x14 -and $writeValue -notin @(0, 64)) { throw 'Reg 0x14 值越界。' }
    if ($writeValue -ge 0 -and $reg -eq 0x15 -and ($writeValue -lt 15000 -or $writeValue -gt 17600)) { throw 'Reg 0x15 值越界。' }
    Wait-ChargerIdle 20
    if ($writeValue -ge 0) {
        $lo = [byte]($writeValue -band 0xFF); $hi = [byte](($writeValue -shr 8) -band 0xFF); $proto = [byte]0x08
    } else {
        $lo = [byte]0; $hi = [byte]0; $proto = [byte]0x09
    }
    Write-EcMailboxByte 0xFE700B01L 0x00
    Write-EcMailboxByte 0xFE700B04L $lo
    Write-EcMailboxByte 0xFE700B05L $hi
    Write-EcMailboxByte 0xFE700B02L 0x12
    Write-EcMailboxByte 0xFE700B03L $reg
    Write-EcMailboxByte 0xFE700B00L $proto
    Wait-ChargerIdle 30
    # ACPI EC-SMBus SMB_STS: bits 4:0 are status codes; DONE/ALRM are flags.
    $status = [int](Read-EcMem 0xFE700B01L 1)
    if (($status -band 0x1F) -ne 0) {
        throw ('SMBus 事务失败：寄存器 0x{0:X2}，状态 0x{1:X2}。' -f $reg, $status)
    }
    if ($writeValue -lt 0) { return [uint16](Read-EcMem 0xFE700B04L 2) }
}

function Read-ChargerRegWord([byte]$reg) { return (Invoke-ChargerWord $reg -1) }

function Write-ChargerReg14([int]$ma) {
    if ($ma -ne 0 -and $ma -ne 64) { throw "安全拦截：Reg 0x14 仅允许 0 或 64 mA（请求 $ma）" }
    Invoke-ChargerWord 0x14 $ma
    if ((Read-ChargerRegWord 0x14) -ne $ma) { throw 'Reg 0x14 写后读回不一致。' }
}

function Write-ChargerReg15([int]$mv) {
    if ($mv -lt 15000 -or $mv -gt 17600) { throw "安全拦截：Reg 0x15 超出 [15000,17600] mV（请求 $mv）" }
    Invoke-ChargerWord 0x15 $mv
    if (((Read-ChargerRegWord 0x15) -band 0x7FF8) -ne ($mv -band 0x7FF8)) { throw 'Reg 0x15 写后读回不一致。' }
}

# 硬件指纹：通道 3 必须是 Renesas 0x0049:0x000C
function Test-RenesasPdChip {
    return ((Read-ChargerRegWord 0xFE) -eq 0x0049 -and (Read-ChargerRegWord 0xFF) -eq 0x000C)
}

# 在“邮筒锁”保护下切到通道 3 执行操作，结束后无论如何把 0x6CD 归零
function Invoke-Channel3([scriptblock]$Body) {
    $m = [System.Threading.Mutex]::new($false, $MailboxMutexName)
    $got = $false
    try {
        try { $got = $m.WaitOne(3000) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { throw '等待本工具的 SMBus 邮筒锁超时。' }
        Wait-ChargerIdle 20
        Write-EcMailboxByte 0xFE7006CDL 1
        try { & $Body } finally { Write-EcMailboxByte 0xFE7006CDL 0 }
    }
    finally {
        if ($got) { $m.ReleaseMutex() }
        $m.Dispose()
    }
}

function Get-PowerState {
    $p40 = Read-EcMem 0xFE700640L 1
    return @{
        PdIn  = [int](($p40 -shr 4) -band 1)
        AcIn  = [int](($p40 -shr 3) -band 1)
        State = [int](Read-EcMem 0xFE7006E2L 1)
    }
}

# 复原：仅在 State=6 时才需要（其它状态下 EC 会自行写入正确值）
function Restore-HardwareDefault {
    $ps = Get-PowerState
    if ($ps.PdIn -eq 1 -and $ps.AcIn -eq 0 -and $ps.State -eq 6) {
        Invoke-Channel3 {
            if (Test-RenesasPdChip) {
                $t = [int](Read-EcMem 0xFE700B70L 2)
                if ($t -lt 15000 -or $t -gt 17600) { throw 'EC 电压目标不在预期范围，无法确认恢复完成。' }
                Write-ChargerReg14 0
                Write-ChargerReg15 $t
            }
            else { throw '充电芯片 ID 不匹配，未写充电参数，无法确认恢复完成。' }
        }
    }
    else {
        # 保险：确保通道选择器为 0
        if ((Read-EcMem 0xFE7006CDL 1) -ne 0) { Write-EcMailboxByte 0xFE7006CDL 0 }
    }
}

function Test-WorkerRunning {
    [System.Threading.Mutex]$m = $null
    try {
        if ([System.Threading.Mutex]::TryOpenExisting($RunMutexName, [ref]$m)) { $m.Dispose(); return $true }
        return $false
    }
    catch [System.UnauthorizedAccessException] { return $true }
}

function Test-BootProtectionEnabled {
    return ($null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue))
}

function Enable-BootProtection([string]$ScriptPath) {
    $argStr    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -BackgroundWorker"
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argStr
    $trigger   = New-ScheduledTaskTrigger -AtLogOn -User ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
    $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
}

function Disable-BootProtection {
    if (Test-BootProtectionEnabled) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# 优雅停止守护进程：发信号 -> 等待退出（守护进程自己复原）-> 超时才强制结束
function Stop-Worker {
    [System.Threading.EventWaitHandle]$evt = $null
    try {
        if ([System.Threading.EventWaitHandle]::TryOpenExisting($StopEventName, [ref]$evt)) { [void]$evt.Set(); $evt.Dispose() }
    } catch {}
    for ($i = 0; $i -lt 40; $i++) {
        if (-not (Test-WorkerRunning)) { break }
        Start-Sleep -Milliseconds 100
    }
    if (Test-WorkerRunning) {
        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
            $_.ProcessId -ne $PID -and $_.CommandLine -like "*pd_charge_limit_guardian.ps1*-BackgroundWorker*"
        } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
    }
    Restore-HardwareDefault
    Set-WorkerError ''
}
'@

# =====================================================================
# 模式 A：后台守护进程 (-BackgroundWorker)
# =====================================================================
if ($BackgroundWorker) {
    . ([ScriptBlock]::Create($CoreCode))

    $created = $false
    $runMutex = [System.Threading.Mutex]::new($true, $RunMutexName, [ref]$created)
    if (-not $created) { $runMutex.Dispose(); exit }   # 已有实例在运行

    $stopEvt = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, $StopEventName)
    $state = @{ Verified = $false }
    Set-WorkerError ''

    try {
        while ($true) {
            $wait = 5000
            try {
                $ps = Get-PowerState
                if ($ps.PdIn -eq 1 -and $ps.AcIn -eq 0 -and $ps.State -eq 6) {
                    Invoke-Channel3 {
                        if (-not $state.Verified) { $state.Verified = Test-RenesasPdChip }
                        if (-not $state.Verified) { throw 'PD 充电芯片 ID 不匹配，已停止守护。' }
                        if ($state.Verified) {
                            if ((Read-ChargerRegWord 0x14) -eq 0)     { Write-ChargerReg14 64 }
                            if ((Read-ChargerRegWord 0x15) -lt 16800) { Write-ChargerReg15 17000 }
                        }
                    }
                    $wait = 2000
                }
                else {
                    $state.Verified = $false
                }
            }
            catch {
                # 通信异常时停止干预，保留原因供面板显示。
                try { Set-WorkerError $_.Exception.Message } catch {}
                break
            }
            if ($stopEvt.WaitOne($wait)) { break }
        }
    }
    finally {
        try { Restore-HardwareDefault } catch {
            try { Set-WorkerError ('恢复未确认：' + $_.Exception.Message) } catch {}
        }
        $stopEvt.Dispose()
        $runMutex.ReleaseMutex()
        $runMutex.Dispose()
    }
    exit
}

# =====================================================================
# 模式 B：控制面板
# =====================================================================

# 面板单实例
$guiCreated = $false
$guiMutex = [System.Threading.Mutex]::new($true, "Global\ASUS_PD_Guardian_GUI", [ref]$guiCreated)
if (-not $guiCreated) { exit }

# ---------------- 后台轮询线程 ----------------
$sync = [hashtable]::Synchronized(@{
    Quit       = $false
    Command    = $null
    Busy       = $false
    Data       = $null
    Version    = 0
    Message    = ""
    ScriptPath = $PSCommandPath
})

$PollerScript = {
    param($sync, $CoreCode)
    $ErrorActionPreference = "Stop"
    try {
        Import-Module ScheduledTasks -ErrorAction SilentlyContinue
        . ([ScriptBlock]::Create($CoreCode))
    }
    catch {
        $sync.Data = @{ Error = "无法访问华硕 WMI 接口 (IecToolkitInterface)：$($_.Exception.Message)" }
        $sync.Version++
        return
    }

    # 清理旧版本（无互斥体）遗留的守护进程
    try {
        if (-not (Test-WorkerRunning)) {
            $legacy = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object {
                $_.ProcessId -ne $PID -and $_.CommandLine -like "*pd_charge_limit_guardian.ps1*-BackgroundWorker*"
            })
            if ($legacy.Count -gt 0) {
                $legacy | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                Start-Sleep -Milliseconds 300
                Restore-HardwareDefault
            }
        }
    } catch {}

    $boot = $false
    try { $boot = Test-BootProtectionEnabled } catch {}
    $lastPoll = [datetime]::MinValue

    while (-not $sync.Quit) {
        $force = $false
        $cmd = $sync.Command
        if ($cmd) {
            $sync.Busy = $true
            $sync.Command = $null
            try {
                switch ($cmd) {
                    "enable" {
                        $argList = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($sync.ScriptPath)`" -BackgroundWorker"
                        Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WindowStyle Hidden
                        $ok = $false
                        for ($i = 0; $i -lt 50; $i++) {
                            if (Test-WorkerRunning) { $ok = $true; break }
                            Start-Sleep -Milliseconds 100
                        }
                        $sync.Message = if ($ok) { "已开启。可直接关闭本窗口，守护会在后台继续运行。" } else { "守护进程启动超时，请重试。" }
                        if ($ok) { Start-Sleep -Milliseconds 1500 }   # 等守护进程完成第一轮写入再刷新显示
                    }
                    "disable" {
                        try { Stop-Worker } finally { Disable-BootProtection }
                        $sync.Message = "已停止守护并完成当前状态下的恢复检查。"
                    }
                    "boot-on" {
                        Enable-BootProtection $sync.ScriptPath
                        $sync.Message = "开关机保护已启用：登录后自动在后台恢复守护。"
                    }
                    "boot-off" {
                        Disable-BootProtection
                        $sync.Message = "开关机保护已取消。"
                    }
                }
            }
            catch {
                $sync.Message = "操作失败：$($_.Exception.Message)"
            }
            try { $boot = Test-BootProtectionEnabled } catch {}
            $force = $true
        }

        if ($force -or ([datetime]::Now - $lastPoll).TotalMilliseconds -ge 2000) {
            try {
                $ps   = Get-PowerState
                $soc  = [int](Read-EcMem 0xFE70064EL 1)
                $lim  = [int](Read-EcMem 0xFE7006E6L 1)
                $vbat = [int](Read-EcMem 0xFE70065FL 2)
                $ibat = [int](Read-EcMem 0xFE700663L 2)
                $chg  = [int](((Read-EcMem 0xFE700642L 1) -shr 4) -band 1)
                $r14 = $null; $r15 = $null
                if ($ps.PdIn -eq 1) {
                    $regs = @(Invoke-Channel3 { Read-ChargerRegWord 0x14; Read-ChargerRegWord 0x15 })
                    if ($regs.Count -eq 2) { $r14 = [int]$regs[0]; $r15 = [int]$regs[1] }
                }
                $sync.Data = @{
                    Running = (Test-WorkerRunning); Boot = $boot
                    PdIn = $ps.PdIn; AcIn = $ps.AcIn; State = $ps.State
                    Soc = $soc; Lim = $lim; Vbat = $vbat; Ibat = $ibat; Charging = $chg
                    R14 = $r14; R15 = $r15
                    WorkerError = (Get-WorkerError)
                }
            }
            catch {
                $sync.Data = @{ Error = "读取 EC 状态失败：$($_.Exception.Message)" }
            }
            $lastPoll = [datetime]::Now
            $sync.Version++
            if ($force) { $sync.Busy = $false }
        }
        Start-Sleep -Milliseconds 120
    }
}

$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$poller = [powershell]::Create()
$poller.Runspace = $rs
[void]$poller.AddScript($PollerScript.ToString()).AddArgument($sync).AddArgument($CoreCode)
$pollHandle = $poller.BeginInvoke()

# ---------------- 界面 ----------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PdGuiNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
[void][PdGuiNative]::SetProcessDPIAware()

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$script:S = $g.DpiX / 96.0
$g.Dispose()

function P([int]$x, [int]$y) { New-Object System.Drawing.Point([int]($x * $script:S), [int]($y * $script:S)) }
function Z([int]$w, [int]$h) { New-Object System.Drawing.Size([int]($w * $script:S), [int]($h * $script:S)) }
function C([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
function F([float]$size, [switch]$Bold) {
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    New-Object System.Drawing.Font("Microsoft YaHei UI", $size, $style)
}

function Set-DoubleBuffered($ctl) {
    $prop = $ctl.GetType().GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]"NonPublic,Instance")
    $prop.SetValue($ctl, $true, $null)
}

function Set-Rounded($ctl, [int]$radius) {
    $r = [int]($radius * $script:S); $d = $r * 2
    $w = $ctl.Width; $h = $ctl.Height
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($w - $d - 1, 0, $d, $d, 270, 90)
    $path.AddArc($w - $d - 1, $h - $d - 1, $d, $d, 0, 90)
    $path.AddArc(0, $h - $d - 1, $d, $d, 90, 90)
    $path.CloseFigure()
    $ctl.Region = New-Object System.Drawing.Region($path)
}

function New-Panel($parent, $x, $y, $w, $h, $bg, [int]$radius = 0) {
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = P $x $y; $p.Size = Z $w $h; $p.BackColor = C $bg
    Set-DoubleBuffered $p
    $parent.Controls.Add($p)
    if ($radius -gt 0) { Set-Rounded $p $radius }
    return $p
}

function New-Label($parent, $text, $x, $y, $w, $h, [float]$size, $color, [switch]$Bold) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = P $x $y; $l.Size = Z $w $h
    $l.Font = if ($Bold) { F $size -Bold } else { F $size }
    $l.ForeColor = C $color; $l.BackColor = [System.Drawing.Color]::Transparent
    $l.AutoEllipsis = $true
    $parent.Controls.Add($l)
    return $l
}

function Set-Text($ctl, [string]$text) { if ($ctl.Text -ne $text) { $ctl.Text = $text } }
function Set-Fore($ctl, [string]$hex) { $c = C $hex; if ($ctl.ForeColor -ne $c) { $ctl.ForeColor = $c } }
function Set-Back($ctl, [string]$hex) { $c = C $hex; if ($ctl.BackColor -ne $c) { $ctl.BackColor = $c } }

$form = New-Object System.Windows.Forms.Form
$form.Text = "PD 限充不断流"
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.ClientSize = Z 440 508
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = C "#F3F4F6"
$form.Font = F 9
Set-DoubleBuffered $form

# 顶部标题栏
$header = New-Panel $form 0 0 440 84 "#111827"
[void](New-Label $header "PD 限充不断流" 22 14 260 34 15 "#FFFFFF" -Bold)
[void](New-Label $header "ASUS ROG  ·  USB-C PD 停充断流修复" 24 50 280 22 9 "#9CA3AF")
$pill = New-Label $header "" 306 28 112 28 9.5 "#9CA3AF" -Bold
$pill.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$pill.BackColor = C "#1F2937"
Set-Rounded $pill 14

# 状态横幅
$banner = New-Panel $form 20 100 400 60 "#FFFFFF" 10
$bannerStrip = New-Panel $banner 0 0 6 60 "#9CA3AF"
$bannerTitle = New-Label $banner "正在读取 EC 状态…" 20 9 370 24 10.5 "#111827" -Bold
$bannerDesc  = New-Label $banner "" 20 33 370 20 9 "#6B7280"

# 四个数据卡片
function New-Tile($x, $y, $caption) {
    $t = New-Panel $form $x $y 194 72 "#FFFFFF" 10
    [void](New-Label $t $caption 14 10 170 20 8.5 "#6B7280")
    $v = New-Label $t "—" 14 32 172 30 13 "#111827" -Bold
    return $v
}
$tileSource = New-Tile 20  172 "供电 / 状态"
$tileSoc    = New-Tile 226 172 "电量 / 上限"
$tileIbat   = New-Tile 20  256 "电池电流"
$tileChip   = New-Tile 226 256 "PD 芯片 0x14 · 0x15"

# 主按钮
$btnMain = New-Object System.Windows.Forms.Button
$btnMain.Location = P 20 344
$btnMain.Size = Z 400 50
$btnMain.Font = F 11 -Bold
$btnMain.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnMain.FlatAppearance.BorderSize = 0
$btnMain.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnMain.Text = "读取中…"
$btnMain.Enabled = $false
$btnMain.BackColor = C "#9CA3AF"
$btnMain.ForeColor = C "#FFFFFF"
$form.Controls.Add($btnMain)
Set-Rounded $btnMain 10

# 开关机保护
$bootCard = New-Panel $form 20 406 400 58 "#FFFFFF" 10
$chkBoot = New-Object System.Windows.Forms.CheckBox
$chkBoot.Text = "开关机保护"
$chkBoot.Font = F 10 -Bold
$chkBoot.ForeColor = C "#111827"
$chkBoot.Location = P 14 6
$chkBoot.Size = Z 370 26
$chkBoot.Cursor = [System.Windows.Forms.Cursors]::Hand
$chkBoot.Enabled = $false
$bootCard.Controls.Add($chkBoot)
$bootDesc = New-Label $bootCard "开启修复后可勾选：重启 / 开机登录后自动在后台恢复守护" 34 32 356 20 8.5 "#6B7280"

# 底部提示
$footer = New-Label $form "关闭本窗口不会影响后台守护。" 22 474 398 26 8.5 "#6B7280"

# ---------------- 渲染 ----------------
$script:LastVersion = -1
$script:LastBusy = $null
$script:SuppressCheck = $false

function Render {
    $busy = [bool]($sync.Busy -or $sync.Command)
    $d = $sync.Data

    if ($sync.Message) { Set-Text $footer $sync.Message } 

    if ($null -eq $d) { return }

    if ($d.Error) {
        Set-Back $bannerStrip "#DC2626"
        Set-Text $bannerTitle "无法读取硬件状态"
        Set-Text $bannerDesc $d.Error
        $btnMain.Enabled = $false
        Set-Text $btnMain "不可用"
        Set-Back $btnMain "#9CA3AF"
        $chkBoot.Enabled = $false
        return
    }

    $running = [bool]$d.Running
    $active  = ($d.PdIn -eq 1 -and $d.AcIn -eq 0 -and $d.State -eq 6)

    # 顶部状态胶囊
    if ($running) { Set-Text $pill "● 守护中"; Set-Back $pill "#14532D"; Set-Fore $pill "#4ADE80" }
    else          { Set-Text $pill "○ 未开启"; Set-Back $pill "#1F2937"; Set-Fore $pill "#9CA3AF" }

    # 横幅
    $verifiedSettings = ($null -ne $d.R14 -and $d.R14 -eq 64 -and $null -ne $d.R15 -and $d.R15 -ge 16800 -and $d.R15 -le 17600)
    if ($d.WorkerError) {
        Set-Back $bannerStrip "#DC2626"
        Set-Text $bannerTitle "守护异常，需检查"
        Set-Text $bannerDesc $d.WorkerError
    }
    elseif ($running -and $active -and $verifiedSettings) {
        Set-Back $bannerStrip "#16A34A"
        Set-Text $bannerTitle "修复参数已确认"
        Set-Text $bannerDesc "寄存器已读回；实际供电效果请结合外部功率计确认"
    }
    elseif ($running -and $active) {
        Set-Back $bannerStrip "#F59E0B"
        Set-Text $bannerTitle "等待修复参数"
        Set-Text $bannerDesc "尚未读回目标参数，不能确认修复已生效"
    }
    elseif ($running) {
        Set-Back $bannerStrip "#3B82F6"
        Set-Text $bannerTitle "守护待命"
        Set-Text $bannerDesc "仅在 USB-C 供电且充到上限停充时自动介入"
    }
    elseif ($active) {
        Set-Back $bannerStrip "#F59E0B"
        Set-Text $bannerTitle "PD 已进入停充状态"
        Set-Text $bannerDesc "是否断流需结合外部功率计和电池电流判断"
    }
    else {
        Set-Back $bannerStrip "#9CA3AF"
        Set-Text $bannerTitle "原厂逻辑"
        Set-Text $bannerDesc "后台守护未运行"
    }

    # 数据卡片
    $src = if ($d.AcIn -eq 1) { "圆口" } elseif ($d.PdIn -eq 1) { "USB-C" } else { "电池" }
    $stt = switch ($d.State) { 6 { "停充" } 2 { "充电中" } default { "S$($d.State)" } }
    Set-Text $tileSource "$src · $stt"
    Set-Text $tileSoc "$($d.Soc)% / $($d.Lim)%"

    if ($d.Charging -eq 1)   { Set-Text $tileIbat "+$($d.Ibat) mA"; Set-Fore $tileIbat "#16A34A" }
    elseif ($d.Ibat -lt 80)  { Set-Text $tileIbat "≈0  ($($d.Ibat) mA)"; Set-Fore $tileIbat "#111827" }
    else                     { Set-Text $tileIbat "−$($d.Ibat) mA"; Set-Fore $tileIbat "#D97706" }

    if ($d.PdIn -ne 1)            { Set-Text $tileChip "未接入 PD"; Set-Fore $tileChip "#9CA3AF" }
    elseif ($null -eq $d.R14)     { Set-Text $tileChip "—"; Set-Fore $tileChip "#9CA3AF" }
    else {
        Set-Text $tileChip ("{0} mA · {1:0.00} V" -f $d.R14, ($d.R15 / 1000.0))
        Set-Fore $tileChip $(if ($d.R14 -eq 0 -and $active) { "#D97706" } else { "#111827" })
    }

    # 主按钮
    if ($busy) {
        $btnMain.Enabled = $false
        Set-Text $btnMain "处理中…"
        Set-Back $btnMain "#9CA3AF"
    }
    elseif ($running -or $d.WorkerError -or $d.Boot) {
        $btnMain.Enabled = $true
        Set-Text $btnMain "关闭并恢复出厂"
        Set-Back $btnMain "#DC2626"
        $btnMain.FlatAppearance.MouseOverBackColor = C "#B91C1C"
    }
    else {
        $btnMain.Enabled = $true
        Set-Text $btnMain "开启修复"
        Set-Back $btnMain "#16A34A"
        $btnMain.FlatAppearance.MouseOverBackColor = C "#15803D"
    }

    # 开关机保护
    $chkBoot.Enabled = ($running -and -not $busy)
    if ($chkBoot.Checked -ne [bool]$d.Boot) {
        $script:SuppressCheck = $true
        $chkBoot.Checked = [bool]$d.Boot
        $script:SuppressCheck = $false
    }
}

$btnMain.Add_Click({
    if ($sync.Busy -or $sync.Command -or $null -eq $sync.Data) { return }
    $sync.Message = ""
    $sync.Command = if ($sync.Data.Running -or $sync.Data.WorkerError -or $sync.Data.Boot) { "disable" } else { "enable" }
    Render
})

$chkBoot.Add_CheckedChanged({
    if ($script:SuppressCheck) { return }
    if ($sync.Busy -or $sync.Command) { return }
    $sync.Message = ""
    $sync.Command = if ($chkBoot.Checked) { "boot-on" } else { "boot-off" }
    Render
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.Add_Tick({
    $busy = [bool]($sync.Busy -or $sync.Command)
    if ($sync.Version -ne $script:LastVersion -or $busy -ne $script:LastBusy) {
        $script:LastVersion = $sync.Version
        $script:LastBusy = $busy
        Render
    }
})

$form.Add_Shown({ $timer.Start() })

$form.Add_FormClosing({
    $timer.Stop()
    $sync.Quit = $true
    # 等待轮询线程结束当前事务（最多 2 秒），保证邮筒通道被归零
    [void]$pollHandle.AsyncWaitHandle.WaitOne(2000)
})

[void]$form.ShowDialog()

$guiMutex.ReleaseMutex()
$guiMutex.Dispose()
# 直接结束面板进程（后台守护是独立进程，不受影响）
[System.Environment]::Exit(0)
