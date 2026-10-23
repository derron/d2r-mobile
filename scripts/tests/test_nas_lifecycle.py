"""使用真实生命周期钩子与队列、假传输和临时存档。 | Real lifecycle hooks/dispatch queues, fake transport, temporary save files."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class NasLifecycleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="nas-lifecycle-build-")
        cls.driver = Path(cls.build.name) / "nas-lifecycle"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "dm/host/tests/nas_lifecycle_driver.m"), str(ROOT / "dm/host/dm_i18n.c"), "-framework", "Foundation",
                        "-framework", "Security", "-framework", "Network", "-o", str(cls.driver)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def run_scenario(self, name):
        result = subprocess.run([str(self.driver), name], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PASS", result.stdout)

    def test_character_select_uploads_early_and_also_uploads_late_commits(self):
        self.run_scenario("exit-late-save")

    def test_build_caption_tracks_transfer_and_only_successful_batch_completion(self):
        self.run_scenario("presentation")

    def test_timer_cannot_upload_old_snapshot_ahead_of_queued_new_save(self):
        self.run_scenario("queued-new-save")

    def test_manual_sync_bypasses_exit_delay(self):
        self.run_scenario("manual")

    def test_background_sync_bypasses_exit_delay(self):
        self.run_scenario("background")

    def test_failed_sync_keeps_snapshot_and_resets_button_before_retry(self):
        self.run_scenario("failed-retry")

    def test_save_arriving_during_upload_is_retained_and_uploaded_afterward(self):
        self.run_scenario("save-during-upload")

    def test_group_completion_labels_and_final_checking(self):
        self.run_scenario("group-presentation")

    def test_unchanged_commit_does_not_queue_another_upload(self):
        self.run_scenario("no-change")

    def test_failed_network_attempt_backs_off_despite_more_exit_commits(self):
        self.run_scenario("failed-backoff")

    def test_empty_offline_boot_snapshot_retries_all_groups(self):
        self.run_scenario("empty-offline-start")

    def test_group_quiet_times_are_independent_when_snapshot_delivery_is_queued(self):
        self.run_scenario("group-quiet-times")

    def test_upload_and_download_captions_identify_character_and_stash(self):
        self.run_scenario("transfer-kind")
