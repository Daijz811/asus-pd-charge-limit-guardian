# Changelog

## 0.2.1 — 2026-11-15

Initial public package, based on the maintainer's working v2 script.

- Retain the original runtime register pair and visual panel.
- Add GU603VV / BIOS 315 gating, SMBus timeout/status handling, write readback, and explicit mutex timeout errors.
- Stop intervention on communication failure and report unconfirmed restoration.
- Show register confirmation separately from real power-flow measurements.
- Include Chinese/English documentation, contribution attribution, and offline hardware-mocked tests.

Hardware success is reported for the preceding script. New error-handling changes are offline-tested and await hardware regression.
