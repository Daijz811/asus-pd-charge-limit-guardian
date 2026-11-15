# ASUS PD Charge-Limit Guardian

A runtime workaround for the ASUS ROG Zephyrus G16 (2023, GU603VV) drawing 0 W from USB-C PD after reaching its battery charge limit and switching to battery power.

On the maintainer's GU603VV with BIOS 315, the original 17000 mV configuration restored over 40 W of PD input while battery current fell from roughly 2.8–3.0 A discharge to about 15–27 mA.

## Use

1. Download and extract the repository ZIP. Run **PD限充不断流开关.bat** and allow administrator access.
2. Enable the fix in the panel. The background worker keeps running after the panel closes.
3. Use the stop/restore button to stop the worker and restore the EC charging targets.

The optional startup checkbox registers a task for the current user's logon. Before changing script versions or locations, stop the existing worker through its panel.

The script uses ASUS `IecToolkitInterface`; no third-party driver installation is needed. Tested on GU603VV / BIOS 315. Other models may use different EC addresses.

## Operation

Only when `PDIN=1`, `ACIN=0`, and `State=6`:

- Set register `0x14` to `0x0040` if it is zero.
- Set register `0x15` to **16400 mV** whenever its value differs from 16400.

The tool changes runtime registers without flashing firmware. Check external PD power and battery current to assess the result. See the [investigation notes](docs/INVESTIGATION.md).

## Known issue: slow battery charging

This workaround retains a nonzero charging target (`0x14=0x0040`) to sustain PD input. A small current may continue to charge the battery, gradually raising its state of charge above the MyASUS / G-Helper limit.

The current voltage target is **16400 mV**. The resulting state of charge depends on battery condition and load; assess it using measured current and state of charge. Device validation of the 16400 mV configuration is pending.

## Credits

- **Daijz811**: project lead, device testing, and maintenance.
- **OpenAI GPT-6.1 Sol**: early research, offline ACPI/EC analysis, publication preparation, and communication fixes.
- **Anthropic Claude Opus 5.5**: repair suggestions and final UI visual polish.
- **Google Gemini 4 Argon**: subsequent observations, experiments, and the initial script.

See [CREDITS.md](CREDITS.md).

## License

Copyright © 2026 Daijz811. Licensed under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/): attribution, noncommercial use, and the same license for shared adaptations. See [LICENSE](LICENSE).
