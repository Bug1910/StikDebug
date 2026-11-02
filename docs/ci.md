# CI: GitHub Actions + Codemagic (backup)

Main build line is GitHub Actions (`.github/workflows/`). When its macOS runners are queued out, use Codemagic as the backup: `codemagic.yaml` in the repo root.

## Codemagic (backup, manual only)
- Workflows: `pinfly-ipa` (unsigned Debug + Release IPA, var `PINFLY_BUNDLE_ID`, default `com.pinfly.app`) and `pinfly-sim` (simulator build + AXe + scenarios from var `TESTERS`, default `novice,addplace,realuser,move`; artifacts `summary-out/**` and `out/**`).
- No `triggering:` block, so nothing runs on push. Start a build in the Codemagic UI (Start new build, pick branch `pinfly-build`, pick workflow; edit the variable there if needed).
- No secrets, Apple account or signing: unsigned only. Connect the repo (Bug1910/StikDebug) and log in yourself.
- Quota: personal account gets 500 free build minutes per month on M2 Mac mini; each workflow caps at 60 min. No DerivedData cache here, so every run is a cold build.
- Rough use (estimates, not measured): `pinfly-ipa` about 20-30 min (Debug + Release archives), `pinfly-sim` about 25 min for 4 testers (plus about 3 min per extra tester). So roughly 16-25 ipa runs or 15-20 sim runs a month.
- Syntax reference: https://docs.codemagic.io/yaml-basic-configuration/yaml-getting-started/
