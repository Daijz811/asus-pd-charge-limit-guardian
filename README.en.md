# ASUS PD Charge Limit Guardian

**A Windows runtime workaround for USB-C PD input dropping to 0 W at the battery charge limit on ASUS GU603VV.**

[中文说明](README.md) · [Investigation and evidence](docs/INVESTIGATION.md) · [Credits](CREDITS.md)

On the maintainer's 2023 ROG Zephyrus G16 / GU603VV, reaching a configured battery charge limit caused USB-C PD input to fall to **0 W**. The laptop discharged its battery until charging resumed, repeatedly cycling around the limit. The barrel adapter behaved differently.

The original script restored PD input to the observed system demand (roughly **40 W or more**) while reported battery discharge current fell from approximately **2.8–3.0 A** to **15–27 mA**. These are maintainer-reported observations, not independently reproduced measurements or a guarantee of electrically isolated battery bypass.

## Compatibility and version

- **Only ASUS GU603VV with BIOS `GU603VV.315` is accepted.** Fixed EC addresses are not portable across models or BIOS versions.
- Windows 10/11, Windows PowerShell 5.1, administrator privileges, and the existing ASUS `root\wmi:IecToolkitInterface` provider are required. No additional low-level driver is installed by this tool.
- Public version **v0.2.1** adds timeout handling, SMBus status checks, register readback, model/BIOS checks and accurate UI messages. These changes have offline mock coverage; the public revision has **not yet undergone fresh hardware regression testing**. The maintainer's hardware success report concerns the preceding script.

## Quick start

1. Download the repository ZIP and extract it to a permanent directory.
2. Run `PD限充不断流开关.bat` and approve the administrator prompt.
3. Keep your preferred MyASUS / G-Helper charge limit. Click the green enable button. Leave automatic startup disabled for the first trial.
4. Check an external USB power meter and battery telemetry. A confirmed register setting is not a measurement of actual PD input power.

Closing the panel leaves the separate worker running. Open the launcher again to access the controls.

The optional startup checkbox registers `ASUS_PD_ChargeLimit_Guardian` for the **current user's logon**. It does not run while the laptop is shut down. The red stop/restore button stops the worker, removes that task, and attempts to restore the EC-requested settings. A failed restore is reported rather than presented as success. Disable startup before moving the directory. If the panel cannot open, disable or remove that named task in Windows Task Scheduler, restart normally, and inspect the resulting behavior.

## Runtime intervention

Only when `PDIN=1`, `ACIN=0` and `State=6`, the worker checks the charger fingerprint (`0x0049:0x000C`) and:

- Sets register `0x14` to raw value `0x0040` if it reads zero (nominally 64 mA in the original project).
- Sets register `0x15` to 17000 if its current value is below 16800 (nominally 17 V).
- Checks about every two seconds while active and every five seconds otherwise.

No BIOS or EC flash image is modified. The original successful parameter pair is retained. The exact silicon variant and board current-sense scaling have not been independently established; **64 mA is not a guaranteed absolute battery-current ceiling**. The source IDs alone do not identify a unique charger part.

## Limitations

- Even panel monitoring uses the EC-SMBus mailbox and channel selector. It is not strictly read-only.
- The mutex coordinates this tool's own processes, not firmware or other ASUS/monitoring applications. Bus contention and state-transition races remain possible.
- Communication errors stop intervention and trigger a restore attempt. The last error is stored at `%LOCALAPPDATA%\ASUS_PD_ChargeLimit_Guardian\last-error.txt`.
- A small nonzero charge target may cause slow charge-level drift over time. Long-term battery aging, sleep/resume, and sustained high-load behavior still require validation.
- Hardware input-power limits remain unchanged. A 100 W PD source does not become a 240 W barrel adapter.
- Process exit does not itself reset every volatile hardware register. Restoration depends on successful communication and EC behavior.

## Background and credits

The project documents a working runtime approach on one machine; it does not claim to be the first solution worldwide. Similar symptoms on other ASUS models have also been addressed by official firmware. See the [investigation notes](docs/INVESTIGATION.md) for evidence boundaries and public references.

**Daijz811** owns the investigation, device observations, manual validation and publication. **OpenAI GPT-6.1 Sol** assisted the initial research and offline firmware tracing, then prepared publication documentation and the error-handling revision. **Anthropic Claude Opus 5.5** reviewed the earlier work, advised on repair feasibility and later polished the final UI. **Google Gemini 4 Argon** carried out the subsequent observation/test work and produced the initial script. Contributions follow the maintainer's record. See [CREDITS.md](CREDITS.md) for the complete attribution and official model-name references.

Run the offline suite with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Guardian.ps1
```

The suite does not execute the application or real hardware access. No open-source license has been selected yet; contact the maintainer regarding reuse or redistribution. This project is unaffiliated with ASUS, Renesas or the AI providers named above.
