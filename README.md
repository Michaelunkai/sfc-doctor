# SfcDoctor

![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-blue) ![Shell](https://img.shields.io/badge/shell-Windows%20PowerShell%205.1-5391FE) ![License](https://img.shields.io/badge/license-MIT-green) ![Reboot](https://img.shields.io/badge/reboot-never%20required-brightgreen)

**Fixes the dreaded `sfc /scannow` result — Windows Resource Protection found
corrupt files but was unable to fix some of them — WITHOUT REBOOTING.**

SfcDoctor is a single-file Windows PowerShell 5.1 tool that detects exactly which
files SFC could not repair, then heals them live: it repairs the component store
with DISM, and for files that still refuse to heal it performs an in-place,
backup-first, ACL-aware replacement — all while the system keeps running.

## Why this exists

When `sfc /scannow` ends with the unable-to-fix message, the usual advice is
DISM + SFC again and eventually a reboot or an in-place upgrade. SfcDoctor
automates the entire ladder and adds the step nobody automates: if a protected
file (and its WinSxS backup copy, often the very same hard-linked inode) is
corrupt, SfcDoctor finds a healthy source and swaps it in live — in-use files
included, via an NTFS rename-aside — and then re-verifies with a fresh SFC scan.

## How it works

1. **Parse** — reads `CBS.log` `[SR]` lines, splits them into runs, classifies the
   latest verdict: Clean / RepairedAll / Unfixable, extracting every
   Cannot-repair file, its owning component and its projected path.
2. **Scan** — runs `sfc /scannow` and classifies the fresh result.
3. **Heal the store** — runs `DISM /Online /Cleanup-Image /RestoreHealth /NoRestart`
   so Windows Update can rebuild corrupt component payloads.
4. **Live repair** — for files still unfixable: locate a healthy source
   (WinSxS alternate copy, or your own `-SourcePath`), back up the corrupt
   original with its full ACL, then replace it in place. If the file is in use,
   the original is renamed aside first — no PendingFileRenameOperations, no reboot.
5. **Verify** — a fresh SFC pass must come back clean before SfcDoctor declares victory.

Every replaced original is kept as `<file>.sfcdoctor-bak-<timestamp>` right next
to the target, so any repair is one rename away from rollback.

## Requirements

- Windows 10 or 11, any architecture
- An **elevated** Windows PowerShell 5.1 console (the built-in `powershell.exe`)
- Nothing else — no dependencies, no module installs

## Install

Download `SfcDoctor.ps1` from the [latest release](../../releases/latest),
unblock it, and run it from an elevated PowerShell:

```powershell
# one-liner install (downloads straight from GitHub Releases)
irm https://github.com/Michaelunkai/sfc-doctor/releases/latest/download/SfcDoctor.ps1 -OutFile $env:TEMP\SfcDoctor.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File $env:TEMP\SfcDoctor.ps1 -Status
```

Or clone the repo:

```powershell
git clone https://github.com/Michaelunkai/sfc-doctor.git
cd sfc-doctor
.\SfcDoctor.ps1 -CheckOnly
```

## Usage

```powershell
.\SfcDoctor.ps1 -Status        # last SFC verdict + reboot-pending state (read-only)
.\SfcDoctor.ps1 -CheckOnly     # classify the newest SFC run in CBS.log (read-only)
.\SfcDoctor.ps1 -Repair        # full loop: sfc -> DISM -> live replace -> verify
.\SfcDoctor.ps1 -Repair -Yes   # same, without the confirmation prompt
.\SfcDoctor.ps1 -Repair -SkipDism -SourcePath D:\KnownGood   # skip DISM, repair from your own known-good file/dir
.\SfcDoctor.ps1 -Repair -MaxPasses 5   # more verify passes
.\SfcDoctor.ps1 -SelfTest      # built-in test suite (18 checks)
.\SfcDoctor.ps1 -MakeFixtures  # write sample CBS logs to tests\fixtures
```

Exit codes: `0` clean or fully repaired, `1` still unfixable, `2` unfixable
(CheckOnly), `3` no completed SFC run, `4` aborted by user, `5` not elevated.

## Safety

- Every replaced file is **backed up first** as `.sfcdoctor-bak-<timestamp>`
  with its original owner and ACL; rollback = rename the backup back.
- SfcDoctor never schedules reboots, never writes PendingFileRenameOperations,
  never deletes anything except its own temp test files during -SelfTest.
- `-Status` and `-CheckOnly` are strictly read-only.

## The SFP/PnP driver-store flag class (v1.1.0)

Some systems (notably Windows 11 26100.9444-era with Hyper-V active) hit a known
class where sfc /scannow prints unable-to-fix solely because of
DEPLOY [Pnp] Corrupt file / Failed repairing: 160 CBS entries for dozens of
driver payloads (vmbus, usb, acpi, audio APOs...) while every [SR] line is
clean. The files are byte-identical to the store and validly signed - the
undocumented SFP driver-store check false-flags them. SfcDoctor v1.1.0 parses
these entries and reports them exactly, so -CheckOnly matches your console,
and classifies them as PnPOnly (store clean, flags only). DISM RestoreHealth,
pnputil re-staging, CompactOS decompression, hardlink rebuilds and ownership
fixes were all tested against this class and do not clear it; the definitive
clear is the next servicing commit (LCU install) or in-place repair, which
require one reboot. See docs/VERIFICATION.md.

## Troubleshooting

- **No healthy source found for X** — provide one with `-SourcePath` (a matching
  file from another machine running the same build, or extracted from an ISO).
- **DISM RestoreHealth fails** — run it with `/LimitAccess` removed, check WU
  connectivity, or use `-SourcePath` to bypass the store repair entirely.
- **Verdict stays Unfixable after everything** — the remaining entries are often
  harmless false positives (hash mismatches Microsoft never fixes); check the
  files listed in `results.json` before worrying.

## Development

```powershell
.\SfcDoctor.ps1 -SelfTest      # parse gate + fixture parsing + live repair mechanics
.\SfcDoctor.ps1 -MakeFixtures  # regenerate tests\fixtures CBS samples
```

## License

MIT — see [LICENSE](LICENSE).
