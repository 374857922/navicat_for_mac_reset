# Navicat V2 — guarded macOS script

V2 preserves the original scripts, and adds a new entrypoint: `navicat-v2.sh`.

## Compatibility

- **Navicat Premium 16.x and 17.0–17.3.6:** legacy local reset is enabled only when matching legacy records are found.
- **Navicat Premium 17.3.7+ and 18.x:** detection, backup and dry-run are supported; reset is blocked because the new authorization layout has not been independently verified.
- **Keychain:** V2 does not read secrets, delete entries or restore Keychain. Restoring files is not a complete license-state rollback.

This script does not patch applications, create a license, or guarantee renewed trial access. Respect applicable Navicat terms.

## Commands

```bash
bash navicat-v2.sh inspect
bash navicat-v2.sh dry-run
bash navicat-v2.sh backup
bash navicat-v2.sh backups
bash navicat-v2.sh reset --confirm RESET
bash navicat-v2.sh restore BACKUP_ID --confirm RESTORE
```

Actions requiring changes refuse to proceed while Navicat Premium is running. Backups and operational logs are stored under `~/Library/Application Support/NavicatTrialV2/` with private permissions. `inspect` and `dry-run` do not write anything.

Restore refuses to overwrite a differing current preference file or a conflicting hidden file. Preserve a separate export of connection settings and credentials as well.

## Known limitations / next steps

- **Not yet validated on a real Mac**; static inspection is not an integration test.
- Version eligibility is deliberately conservative. A recognized version does not prove the reset will work.
- The legacy format is matched using 32-character uppercase alphanumeric keys and hidden filenames.
- Review and improve error recovery, snapshot integrity, automated Bats tests and macOS ShellCheck before relying on this script.
- Never use `sudo` or `chmod 777`.

Original legacy scripts are retained unchanged.
