"""Isolated cross-platform tests: no installed Navicat or real home files are used."""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "navicat-v2.sh"
H1 = "A" * 32
H2 = "B" * 32


class V21Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="navicat-v21-fixture-")
        self.root = Path(self.tmp.name)
        (self.root / "app").mkdir()
        (self.root / "home" / "support").mkdir(parents=True)
        (self.root / "app" / "version").write_text("18.0.5\n")
        (self.root / "app" / "bundle").write_text("com.navicat.NavicatPremium\n")
        self.prefs = self.root / "home" / "prefs.plist"
        self.prefs.write_text(f"{H1} = foo\n{H2} = bar\nNORMAL_SETTING = preserved\n")
        self.hidden1 = self.root / "home" / "support" / ("." + H1)
        self.hidden2 = self.root / "home" / "support" / ("." + H2)
        self.hidden1.write_bytes(b"first-file")
        self.hidden2.write_bytes(b"second-file")
        self.env = dict(os.environ, NAVICAT_V2_TEST_MODE="1", NAVICAT_V2_TEST_ROOT=str(self.root))

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *args, ok=True, env=None):
        cmd = ["bash", str(SCRIPT), *args]
        result = subprocess.run(cmd, text=True, capture_output=True, env=env or self.env)
        if ok:
            self.assertEqual(result.returncode, 0, f"{cmd}\n{result.stdout}\n{result.stderr}")
        else:
            self.assertNotEqual(result.returncode, 0, f"{cmd} unexpectedly succeeded")
        return result.stdout + result.stderr

    def backup(self):
        output = self.run_script("backup")
        m = re.search(r"Backup complete: id=(\S+)", output)
        self.assertIsNotNone(m, output)
        return m.group(1)

    def test_inspect_dry_run_doctor_truly_read_only(self):
        self.assertIn("version=18.0.5", self.run_script("inspect"))
        self.assertIn("matching_keys=2 matching_hidden_files=2", self.run_script("doctor"))
        self.assertIn("BLOCKED", self.run_script("dry-run"))
        self.assertFalse((self.root / "state").exists())
        self.backup()
        logfile = self.root / "state" / "logs" / "run.log"
        data = logfile.read_bytes()
        self.run_script("inspect")
        self.run_script("doctor")
        self.run_script("dry-run")
        self.assertEqual(logfile.read_bytes(), data)


    def test_navicat18_audit_is_read_only_and_reports_fingerprints(self):
        before_prefs = self.prefs.read_bytes()
        before_hidden = (self.hidden1.read_bytes(), self.hidden2.read_bytes())
        output = self.run_script("audit-18")
        self.assertIn("Navicat 18 read-only audit", output)
        self.assertIn("matching_keys=2 matching_hidden_files=2", output)
        self.assertIn("preferences: size=", output)
        self.assertIn("matching_hidden_file[1]: size=", output)
        self.assertIn("reset remains blocked", output)
        self.assertNotIn(H1, output)
        self.assertNotIn(H2, output)
        self.assertFalse((self.root / "state").exists())
        self.assertEqual(self.prefs.read_bytes(), before_prefs)
        self.assertEqual((self.hidden1.read_bytes(), self.hidden2.read_bytes()), before_hidden)

    def test_navicat18_audit_rejects_other_versions(self):
        (self.root / "app" / "version").write_text("17.3.6\n")
        output = self.run_script("audit-18", ok=False)
        self.assertIn("requires Navicat Premium version 18", output)
        self.assertFalse((self.root / "state").exists())

    def test_backup_verify_and_unchanged_restore(self):
        backup_id = self.backup()
        snapshot = self.root / "state" / "backups" / backup_id
        self.assertEqual(len((snapshot / "manifest.sha256").read_text().splitlines()), 4)
        self.assertIn("SHA-256 manifest OK", self.run_script("verify-backup", backup_id))
        self.run_script("restore", backup_id, "--confirm", "RESTORE")
        self.assertEqual(self.prefs.read_bytes(), (snapshot / "prefs.plist").read_bytes())
        self.assertEqual(self.hidden2.read_bytes(), (snapshot / "hidden" / self.hidden2.name).read_bytes())

    def test_corrupt_backup_aborts_before_any_restore(self):
        backup_id = self.backup()
        snapshot = self.root / "state" / "backups" / backup_id
        (snapshot / "hidden" / self.hidden1.name).write_text("tampered")
        self.prefs.write_text("live different prefs")
        self.assertIn("checksum or inventory mismatch", self.run_script("verify-backup", backup_id, ok=False))
        self.run_script("restore", backup_id, "--confirm", "RESTORE", ok=False)
        self.assertEqual(self.prefs.read_text(), "live different prefs")

    def test_conflict_rejects_before_changes(self):
        backup_id = self.backup()
        self.prefs.write_text("new setting")
        self.hidden2.write_text("new file")
        self.assertIn("refusing overwrite", self.run_script("restore", backup_id, "--confirm", "RESTORE", ok=False))
        self.assertEqual(self.prefs.read_text(), "new setting")
        self.assertEqual(self.hidden2.read_text(), "new file")
        self.assertEqual(list((self.root / "state" / "recovery").glob("*")), [])

    def test_archive_conflicts_then_restore(self):
        backup_id = self.backup()
        self.prefs.write_text("user changed")
        self.hidden1.write_text("user edited hidden")
        output = self.run_script("restore", backup_id, "--confirm", "RESTORE", "--on-conflict", "archive")
        self.assertIn("conflicts_archived=2", output)
        journal = next((self.root / "state" / "recovery").iterdir())
        self.assertEqual((journal / "original" / "prefs.plist").read_text(), "user changed")
        self.assertEqual((journal / "original" / "hidden" / self.hidden1.name).read_text(), "user edited hidden")
        self.assertEqual((journal / "status").read_text().strip(), "COMMITTED")
        self.assertIn("NORMAL_SETTING", self.prefs.read_text())

    def test_rollback_after_injected_mid_write_failure(self):
        backup_id = self.backup()
        self.prefs.write_text("altered prefs")
        self.hidden1.write_text("altered hidden")
        env = dict(self.env, NAVICAT_V2_TEST_FAIL_AFTER_WRITE="2")
        self.run_script("restore", backup_id, "--confirm", "RESTORE", "--on-conflict", "archive", ok=False, env=env)
        self.assertEqual(self.prefs.read_text(), "altered prefs")
        self.assertEqual(self.hidden1.read_text(), "altered hidden")
        self.assertEqual(self.hidden2.read_text(), "second-file")
        journal = next((self.root / "state" / "recovery").iterdir())
        self.assertEqual((journal / "status").read_text().strip(), "ROLLED_BACK_ATTEMPTED")

    def test_version_18_reset_rejected_without_changes(self):
        before = self.prefs.read_bytes()
        self.assertIn("Reset blocked", self.run_script("reset", "--confirm", "RESET", ok=False))
        self.assertEqual(self.prefs.read_bytes(), before)
        self.assertFalse(list((self.root / "state" / "backups").glob("[0-9]*")))

    def test_legacy_version_reset_preserves_non_matching_data(self):
        (self.root / "app" / "version").write_text("17.3.6\n")
        self.run_script("reset", "--confirm", "RESET")
        self.assertEqual(self.prefs.read_text(), "NORMAL_SETTING = preserved\n")
        self.assertFalse(self.hidden1.exists())
        self.assertFalse(self.hidden2.exists())
        self.assertEqual(len(list((self.root / "state" / "backups").glob("[0-9]*"))), 1)

    def test_legacy_unverified_backup_explicit_opt_in(self):
        backup_id = self.backup()
        (self.root / "state" / "backups" / backup_id / "manifest.sha256").unlink()
        self.run_script("verify-backup", backup_id, ok=False)
        self.assertIn("no checksums", self.run_script("verify-backup", backup_id, "--allow-legacy-backup"))
        self.run_script("restore", backup_id, "--confirm", "RESTORE", "--allow-legacy-backup")

    def test_corrupt_plist_and_wrong_bundle(self):
        self.prefs.write_text("CORRUPT_PLIST\n")
        self.run_script("inspect", ok=False)
        self.prefs.unlink()
        (self.root / "app" / "bundle").write_text("bad.bundle\n")
        self.run_script("backup", ok=False)

    def test_running_app_blocks_writes(self):
        (self.root / "running").touch()
        self.run_script("backup", ok=False)
        self.assertFalse(list((self.root / "state" / "backups").glob("*")))

    def test_symlinked_hidden_file_not_scanned(self):
        self.hidden2.unlink()
        self.hidden2.symlink_to(self.hidden1)
        self.assertIn("matching_hidden_files=1", self.run_script("inspect"))

    def test_backup_version_mismatch_rejected(self):
        backup_id = self.backup()
        (self.root / "app" / "version").write_text("18.0.6\n")
        self.run_script("restore", backup_id, "--confirm", "RESTORE", ok=False)
        self.assertEqual(len(list((self.root / "state" / "recovery").iterdir())), 0)

    def test_manifest_path_traversal_rejected(self):
        backup_id = self.backup()
        mf = self.root / "state" / "backups" / backup_id / "manifest.sha256"
        mf.write_text(mf.read_text() + ("a" * 64) + "  ../bad\n")
        self.run_script("verify-backup", backup_id, ok=False)

if __name__ == "__main__":
    unittest.main(verbosity=2)
