# SfcDoctor - Live Verification Record (2026-10-26)

Machine: Windows 11, build 26200, Windows PowerShell 5.1, elevated session.
System boot: 2026-10-26 01:26:56 - unchanged across every test below (no reboot at any point).

## Baseline

Fresh sfc /scannow at 14:58 gave Clean (Repairing 0 components). The historical
unable-to-fix event had already rolled out of CBS.log, so the failure state was
reproduced deliberately to test the tool end to end.

## Proof 1 - manual live repair path (sfc - live replace - sfc)

1. Target: C:\Windows\System32\whoami.exe (payload hard-linked to its WinSxS
   component amd64_microsoft-windows-whoami ... 10.0.26100.1882, so the SFC
   backup copy is the very same inode).
2. Pristine copy saved, then 36 junk bytes appended - the shared inode corrupted
   BOTH the projected file and the component-store payload.
3. sfc /scannow produced the exact failure:
   [SR] Cannot repair member file [l:10]'whoami.exe' of Microsoft-Windows-WhoAmI ... in the store, hash mismatch
   [SR] Could not reproject corrupted file \??\C:\WINDOWS\System32\\whoami.exe; source file in store is also corrupted
   (the CBS equivalent of: Windows Resource Protection found corrupt files but
   was unable to fix some of them).
4. SfcDoctor.ps1 -Repair -Yes -SkipDism -SourcePath <pristine copy>:
   pass 1 Unfixable - live replacement (direct copy, no reboot) - pass 2 Clean. Exit 0.
5. Verified: SHA-256 identical to pristine (23240EF9F8B0A9A3...), whoami.exe
   executes, .sfcdoctor-bak-* backup created, last boot unchanged.

## Proof 2 - default pipeline incl. DISM (sfc - DISM RestoreHealth - sfc)

1. Target: C:\Windows\System32\hostname.exe, same hard-link corruption method.
2. SfcDoctor.ps1 -Repair -Yes (launched via Task Scheduler as SYSTEM):
   pass 1 Unfixable - DISM /Online /Cleanup-Image /RestoreHealth /NoRestart
   (repair payload downloaded from Windows Update, about 17 minutes) - pass 2:
   SFC itself repaired the file from the healed store - RepairedAll. Exit 0.
3. Bonus: during RestoreHealth, DISM also detected and repaired a REAL
   pre-existing corruption on this machine (C:\WINDOWS\System32\WMALFXGFXDSP.dll;
   CBS logged: Corrupt file / Failed repairing file: 160) - evidence the
   store-repair stage catches genuine corruption, not just the test damage.
4. Verified: hostname.exe SHA-256 identical to pristine (22EC2260B5C32177...),
   executes correctly, last boot unchanged.

## Test suite

SfcDoctor.ps1 -SelfTest - 18/18 passed: parse gate, modern and legacy CBS
format parsing, verdict classification, dedupe, target path resolution, run
splitting, and live repair mechanics on temp files.


## Addendum (v1.1.0) - the SFP/PnP driver-store flag class on this machine

A later live scan of the same machine showed sfc /scannow still printing
unable-to-fix while every [SR] line was clean. Root cause of the message:
DEPLOY [Pnp] Corrupt file / Failed repairing file: 160 entries for 151
driver payloads (usb, acpi, vmbus, audio APOs, etc.). Investigated and
disproven as the trigger: NTFS/CompactOS compression (files decompressed,
flags persisted), in-use locking (unloaded files also flagged), hardlink
self-copy (link broken, fresh inode, still flagged), ownership (all
TrustedInstaller), version skew (same-package same-version files unflagged),
link count, and pending-file-rename state (PFRO unrelated). DISM
RestoreHealth and pnputil package re-staging do not clear it. Files are
byte-identical to the store, correctly versioned and signed - the
undocumented SFP driver-store check false-flags them (a known community-
documented class on 26100.9444-era builds, unresolved without servicing
commit). SfcDoctor v1.1.0 parses DEPLOY/PnP entries, so -CheckOnly now
reproduces the exact user-facing verdict (151 unfixable, PnPOnly, [SR] clean)
and distinguishes real corruption from this benign class. Definitive clear:
next LCU commit or in-place repair (one reboot, Windows mechanism).
