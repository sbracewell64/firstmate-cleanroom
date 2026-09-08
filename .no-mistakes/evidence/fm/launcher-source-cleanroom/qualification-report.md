# Captain launcher staging + qualification

- Rendered (UTC): 20260908T211828Z
- Canonical source: bin/enter-firstmate.sh (@ /home/shane/.firstmate-cleanroom/no-mistakes/worktrees/56044c3a23d6/01M21D6N7375DP5S8HR1SGNX4S)
- Runtime home: /tmp/tmp.1PLNQEsLz0/fm-home
- Adopted code root (config/code-root): /tmp/tmp.1PLNQEsLz0/adopted-release
- Current live (donor) code root: /old/donor/code-root
- Console profile (config/console-profile): fable-5.1
- Staging dir: /tmp/tmp.1PLNQEsLz0/staging
- Rollback snapshot: /tmp/tmp.1PLNQEsLz0/staging/rollback/20260908T211828Z (see MANIFEST.txt)

## Automated qualification (this run)
- PASS source: bash -n
- PASS consumer shim: bash -n
- PASS source: shellcheck
- PASS consumer shim: shellcheck
- PASS test: enter-firstmate-arm
- PASS test: enter-firstmate-launch
- PASS test: enter-firstmate-profile
- PASS print-console-menu: renders the four-profile menu

## Live cutover matrix (captain-run; NOT performed here)
Each item is verified live at cutover, not by this staging run:
- Windows .lnk -> wsl.exe -> Ubuntu -> cwd -> launcher (repoint --cd off the donor to the adopted release)
- firstmate-cleanroom Herdr session/socket continuity
- Claude primary composition (fable-5.1 default)
- Codex primary composition (codex-astra / codex-sol)
- Selected profile native auth / provider / model / permission AFTER composition
- Zero-dollar / subscription boundary (no API/gateway fallback, no overage, no budget flag)
- Attach/resume vs fresh-relaunch
- Post-launch cwd / SHA / instruction+skill+hook / inbox / lease evidence

## Cutover (separate, captain-authorized; this script does none of it)
1. Ensure the adopted release exists at: /tmp/tmp.1PLNQEsLz0/adopted-release
2. Copy staged config into the live home: cp -n /tmp/tmp.1PLNQEsLz0/staging/config/* /tmp/tmp.1PLNQEsLz0/fm-home/config/
3. Replace the live launcher with the consumer shim: cp /tmp/tmp.1PLNQEsLz0/staging/enter-firstmate.sh /tmp/tmp.1PLNQEsLz0/fm-home/enter-firstmate.sh
4. Repoint the Windows shortcut(s) --cd from the donor to the adopted release.
5. Rollback if needed: restore files from /tmp/tmp.1PLNQEsLz0/staging/rollback/20260908T211828Z (bytes preserved).
