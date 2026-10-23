"""使用真实 NSURLSession 与临时单人 WebDAV 服务进行回归。 | Real NSURLSession tests against a disposable single-user WebDAV server."""
import hashlib
import http.server
import json
import os
from email.utils import formatdate
from pathlib import Path
import subprocess
import tempfile
import time
from collections import Counter
import threading
import unittest
import uuid
from unittest.mock import patch
from urllib.parse import urlsplit, quote
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[2]


class DAV(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # 超时或响应过大时，客户端主动断开属于预期测试行为。
    # Client disconnects are expected in timeout and oversized-response tests.
    def handle_one_request(self):
        try:
            super().handle_one_request()
        except ConnectionError:
            self.close_connection = True

    def log_message(self, *args):
        pass

    def respond(self, code, body=b"", **headers):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            try:
                self.wfile.write(body)
            except ConnectionError:
                pass

    def record(self):
        self.server.calls.append((self.command, self.path, dict(self.headers)))
        self.server.connections.add(self.client_address)

    def exists(self, path):
        return path in self.server.files or path in self.server.directories

    def do_MKCOL(self):
        with self.server.lock:
            self.record()
            if self.server.fail_mkdir == self.path:
                return self.respond(503)
            if self.exists(self.path):
                return self.respond(405)
            self.server.directories.add(self.path)
            self.respond(201)

    def do_GET(self):
        time.sleep(self.server.get_delays.get(self.path, 0))
        with self.server.lock:
            self.record()
            if self.path in self.server.redirects:
                return self.respond(302, Location=self.server.redirects[self.path])
            if self.server.bad_get or (self.server.bad_raw_get and "/save/" in self.path):
                return self.respond(503)
            self.server.get_counts[self.path] = self.server.get_counts.get(self.path, 0) + 1
            if self.server.fail_get_nth.get(self.path) == self.server.get_counts[self.path]:
                return self.respond(503)
            value = self.server.files.get(self.path)
            self.respond(404) if value is None else self.respond(200, value)

    def do_PUT(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with self.server.lock:
            self.record()
            if self.server.fail_put and self.server.fail_put in self.path:
                return self.respond(self.server.fail_put_status)
            present = self.path in self.server.files
            if not self.server.pretend_put:
                self.server.files[self.path] = b"server-changed-content" if self.server.corrupt_put == self.path else data
                self.server.clock += 1
                self.server.mtimes[self.path] = formatdate(self.server.clock, usegmt=True)
            self.respond(self.server.put_status or (204 if present else 201))

    def delete(self, path):
        self.server.files = {p: v for p, v in self.server.files.items() if p != path and not (path.endswith("/") and p.startswith(path))}
        self.server.directories = {p for p in self.server.directories if p != path and not (path.endswith("/") and p.startswith(path))}
        self.server.mtimes = {p: v for p, v in self.server.mtimes.items() if p != path and not (path.endswith("/") and p.startswith(path))}

    def do_DELETE(self):
        with self.server.lock:
            self.record()
            if self.server.fail_delete and self.server.fail_delete in self.path:
                return self.respond(503)
            existed = self.exists(self.path)
            self.delete(self.path)
            if self.server.lost_delete_response == self.path:
                return self.respond(503)
            self.respond(204 if existed else 404)

    def do_MOVE(self):
        with self.server.lock:
            self.record()
            if not self.server.support_move:
                return self.respond(405)
            target = urlsplit(self.headers["Destination"]).path
            key = (self.path, target)
            self.server.move_counts[key] = self.server.move_counts.get(key, 0) + 1
            attempt = self.server.move_counts[key]
            if self.server.fail_move_nth.get(key) == attempt:
                return self.respond(503)
            if self.server.fail_move and self.server.fail_move == (self.path, target):
                return self.respond(503)
            if not self.exists(self.path):
                return self.respond(404)
            present = self.exists(target)
            if present and self.headers.get("Overwrite") != "T":
                return self.respond(412)
            self.delete(target)
            if self.path.endswith("/"):
                files = {target + p[len(self.path):]: v for p, v in self.server.files.items() if p.startswith(self.path)}
                times = {target + p[len(self.path):]: v for p, v in self.server.mtimes.items() if p.startswith(self.path)}
                directories = {target + p[len(self.path):] for p in self.server.directories if p.startswith(self.path)}
                self.delete(self.path)
                self.server.files.update(files)
                self.server.mtimes.update(times)
                self.server.directories.update(directories)
            else:
                self.server.files[target] = self.server.files.pop(self.path)
                if self.path in self.server.mtimes:
                    self.server.mtimes[target] = self.server.mtimes.pop(self.path)
            if self.server.lost_move_response == (self.path, target) or self.server.lost_move_nth.get(key) == attempt:
                return self.respond(503)
            self.respond(204 if present else 201)

    def do_PROPFIND(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with self.server.lock:
            self.record()
            if self.server.bad_listing:
                return self.respond(207, b"broken xml")
            if not self.exists(self.path):
                return self.respond(404)
            names = [self.path]
            for path in self.server.directories | self.server.files.keys():
                if path != self.path and path.startswith(self.path) and "/" not in path[len(self.path):].rstrip("/"):
                    names.append(path)
            nodes = []
            for path in sorted(set(names)):
                kind = "<d:collection/>" if path in self.server.directories else ""
                modified = self.server.mtimes.get(path, "Tue, 20 Oct 2026 01:00:00 GMT")
                nodes.append(f"<d:response><d:href>{escape(path)}</d:href><d:propstat><d:prop><d:resourcetype>{kind}</d:resourcetype><d:getlastmodified>{escape(modified)}</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>")
            body = '<d:multistatus xmlns:d="DAV:">' + "".join(nodes) + "</d:multistatus>"
            self.respond(207, body.encode(), **{"Content-Type": "application/xml"})


class NasSyncTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix="d2r-nas-build-")
        cls.driver = Path(cls.build.name) / "nas-store"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "dm/host/tests/nas_store_driver.m"), str(ROOT / "dm/ios/Sources/nas_store.m"),
                        str(ROOT / "dm/host/dm_i18n.c"), "-framework", "Foundation", "-o", str(cls.driver)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="d2r-nas-test-")
        self.base = Path(self.tmp.name)
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), DAV)
        for key, value in {"files": {}, "directories": {"/space/"}, "calls": [], "bad_get": False,
                           "bad_raw_get": False, "bad_listing": False, "fail_put": None, "fail_put_status": 507,
                           "pretend_put": False, "fail_delete": None, "fail_move": None, "lost_move_response": None,
                           "support_move": True, "get_counts": {}, "fail_get_nth": {}, "get_delays": {},
                           "connections": set(), "move_counts": {}, "fail_move_nth": {}, "lost_move_nth": {},
                           "put_status": None, "corrupt_put": None, "fail_mkdir": None, "redirects": {}, "lost_delete_response": None}.items():
            setattr(self.server, key, value)
        self.server.mtimes = {}
        self.server.clock = 1792458000
        self.server.lock = threading.Lock()
        self.url = f"http://127.0.0.1:{self.server.server_port}/space/"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.devices = {name: str(uuid.uuid4()) for name in ("a", "b")}
        for name in self.devices:
            (self.base / name / "save/Settings").mkdir(parents=True)
            (self.base / name / "save/Settings/local").write_text(name)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.tmp.cleanup()

    def run_op(self, op="sync", device="a", *args, ok=True, refresh=False, groups=None, activity=False):
        env = dict(os.environ)
        env.pop("DM_NAS_TEST_REFRESH", None)
        env.pop("DM_NAS_TEST_GROUPS", None)
        env.pop("DM_NAS_TEST_ACTIVITY", None)
        if activity:
            env["DM_NAS_TEST_ACTIVITY"] = "1"
        if groups is not None:
            env["DM_NAS_TEST_GROUPS"] = ";".join(groups)
        if refresh:
            env["DM_NAS_TEST_REFRESH"] = "1"
        if op == "restore" and args and "|" not in str(args[0]):
            args = (str(args[0]) + "|character:Hero", *args[1:])
        result = subprocess.run([str(self.driver), op, self.url, str(self.base / device / "cache"), self.devices[device],
                                 str(self.base / device / "save"), *map(str, args)], text=True, capture_output=True, env=env)
        self.last_stderr = result.stderr
        self.assertTrue(result.stdout.strip(), f"driver exited {result.returncode}: {result.stderr}")
        output = json.loads(result.stdout.splitlines()[-1])
        self.assertEqual(output["ok"], ok, result.stdout + result.stderr)
        return output, result.stdout

    def write(self, device, path, text):
        file = self.base / device / "save" / path
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(text)
        return file

    def contents(self, device, path):
        return (self.base / device / "save" / path).read_text()

    def metadata(self):
        return json.loads(self.server.files["/space/.d2r-sync.json"])

    def group(self, key="character:Hero"):
        return self.metadata()["groups"][key]

    def head(self):
        return self.group()["current"]["id"]

    def aggregate(self, slot):
        return [f for g in self.metadata()["groups"].values() if g[slot] for f in g[slot]["files"]]

    def raw(self, path, folder="save"):
        return self.server.files[f"/space/{folder}/{path}"]

    def edit_remote(self, path, data, *, touch=True):
        self.server.files[path] = data
        if touch:
            self.server.clock += 1
            self.server.mtimes[path] = formatdate(self.server.clock, usegmt=True)

    def seed(self, flat=False):
        for path, text in {"Hero/Hero.d2s": "level-1", "SharedStashSoftCoreV2.d2i": "stash",
                           "sw_elysium.txt": "Hero", "Hero/Hero.swpouch": "pouch"}.items():
            self.write("a", path.replace("Hero/", "") if flat else path, text)
        self.run_op("probe")
        self.run_op("sync", "a", 1, 100)
        self.run_op("sync", "b")

    def test_messages_follow_language_but_error_codes_do_not(self):
        self.server.support_move = False
        with patch.dict(os.environ, DM_LANG="en-US"):
            english, _ = self.run_op("probe", ok=False)
        with patch.dict(os.environ, DM_LANG="zh-CN"):
            chinese, _ = self.run_op("probe", ok=False)
        self.assertEqual(english["errorCode"], 4)
        self.assertEqual(chinese["errorCode"], 4)
        self.assertEqual(english["errorReason"], chinese["errorReason"])
        self.assertNotEqual(english["message"], chinese["message"])

    def test_different_server_failures_share_a_short_message(self):
        self.server.support_move = False
        moved, _ = self.run_op("probe", ok=False)
        self.server.support_move = True
        self.server.fail_put = "Hero.d2s"
        self.server.fail_put_status = 507
        uploaded, _ = self.run_op("probe", ok=False)
        self.assertEqual(moved["errorCode"], 4)
        self.assertEqual(uploaded["errorCode"], 4)
        self.assertEqual(moved["message"], uploaded["message"])
        self.assertNotEqual(moved["errorReason"], uploaded["errorReason"])

    def test_upload_authentication_failure_keeps_its_category(self):
        self.write("a", "Hero.d2s", "local")
        self.run_op()
        self.server.fail_put = ".d2r-probe-"
        self.server.fail_put_status = 401
        result, _ = self.run_op("probe", ok=False)
        self.assertEqual(result["errorCode"], 2)
        self.assertEqual(result["errorReason"], "PUT")

    def test_invalid_listing_has_data_category(self):
        self.server.bad_listing = True
        result, _ = self.run_op("probe", ok=False)
        self.assertEqual(result["errorCode"], 6)

    def test_probe_needs_no_etag_or_locks(self):
        result, _ = self.run_op("probe")
        self.assertEqual(result["errorCode"], 0)
        self.assertFalse(self.server.files)
        self.assertFalse(any(method in ("LOCK", "UNLOCK") or any(k.lower() in ("if", "if-match", "if-none-match") for k in headers)
                             for method, _, headers in self.server.calls))

    def test_probe_rejects_missing_move_and_cleans_up(self):
        self.server.support_move = False
        self.run_op("probe", ok=False)
        self.assertFalse(self.server.files)

    def test_probe_rejects_false_success(self):
        self.server.pretend_put = True
        self.run_op("probe", ok=False)
        self.assertFalse(self.server.files)

    def test_successful_upload_uses_no_immediate_content_readback(self):
        self.seed()
        for status in (200, 201, 204):
            with self.subTest(status=status):
                self.server.put_status = status
                self.server.calls.clear()
                self.write("a", "Hero/Hero.d2s", str(status))
                self.run_op("sync", "a", 0, status + 100)
                reads = [path for method, path, _ in self.server.calls if method == "GET"]
                self.assertFalse(any("/.d2r-upload/" in path or path.endswith(".tmp") for path in reads))
                self.assertEqual(self.raw("Hero/Hero.d2s"), str(status).encode())

    def test_upload_accepts_success_without_comparing_server_bytes(self):
        self.seed()
        self.server.corrupt_put = "/space/.d2r-upload/Hero/Hero.d2s"
        self.write("a", "Hero/Hero.d2s", "new-local-content")
        self.run_op("sync", "a", 0, 200)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"server-changed-content")
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")

    def test_six_file_upload_reuses_connection_and_has_bounded_requests(self):
        for i in range(6):
            self.write("a", "Hero/" + ("Hero.d2s" if i == 0 else f"Hero.sidecar{i}"), "version-1")
        self.write("a", "SharedStashSoftCoreV2.d2i", "stash")
        self.run_op("sync", "a", 0, 100)
        self.write("a", "Hero/Hero.d2s", "version-2")
        self.run_op("sync", "a", 0, 200)
        self.server.calls.clear()
        self.server.connections.clear()
        self.write("a", "Hero/Hero.d2s", "version-3")
        self.run_op("sync", "a", 0, 300, groups={"character:Hero"})
        self.assertLessEqual(len(self.server.calls), 40)
        self.assertEqual(len(self.server.connections), 1)
        directories = Counter(path for method, path, _ in self.server.calls if method == "MKCOL")
        self.assertTrue(all(count == 1 for count in directories.values()), directories)
        checkpoints = [path for method, path, _ in self.server.calls if method == "PUT" and path == "/space/.d2r-transaction.json.tmp"]
        self.assertEqual(len(checkpoints), 4)
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"version-2")
        self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i"), b"stash")
        self.assertRegex(self.last_stderr, r"NAS publish kind=character files=6 requests=\d+ seconds=\d+\.\d+")
        for private in ("Hero", self.url, "secret", str(self.base)):
            self.assertNotIn(private, self.last_stderr)
        moves = [(path, urlsplit(headers["Destination"]).path) for method, path, headers in self.server.calls if method == "MOVE" and not path.endswith(".tmp")]
        self.assertEqual(moves, [("/space/save/Hero/", "/space/backup/Hero/"), ("/space/.d2r-upload/Hero/", "/space/save/Hero/")])
        self.assertFalse(any(method == "PROPFIND" and path.endswith((".d2s", ".sidecar1")) for method, path, _ in self.server.calls))

    def test_directory_move_failures_and_lost_responses_recover_both_versions(self):
        self.seed()
        previous = {"Hero/Hero.d2s": b"level-1", "Hero/Hero.swpouch": b"pouch"}
        stamp = 100
        for phase in ("backup", "publish"):
            for fault in ("fail_move", "lost_move_response"):
                with self.subTest(phase=phase, fault=fault):
                    stamp += 100
                    for name in previous:
                        self.write("a", name, str(stamp))
                    source, target = ("save/Hero/", "backup/Hero/") if phase == "backup" else (".d2r-upload/Hero/", "save/Hero/")
                    setattr(self.server, fault, ("/space/" + source, "/space/" + target))
                    self.run_op("sync", "a", 0, stamp, ok=False)
                    txn = json.loads(self.server.files["/space/.d2r-transaction.json"])
                    self.assertEqual((txn["format"], txn["mode"]), (4, "directory"))
                    setattr(self.server, fault, None)
                    self.run_op("sync", "a", 0)
                    for name in previous:
                        self.assertEqual(self.raw(name), str(stamp).encode())
                        self.assertEqual(self.raw(name, "backup"), previous[name])
                    previous = {name: str(stamp).encode() for name in previous}
                    self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i"), b"stash")

    def test_lost_backup_directory_delete_response_is_replayed(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "200")
        self.run_op("sync", "a", 0, 200)
        self.write("a", "Hero/Hero.d2s", "300")
        self.server.lost_delete_response = "/space/backup/Hero/"
        self.run_op("sync", "a", 0, 300, ok=False)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"200")
        self.server.lost_delete_response = None
        self.run_op("sync", "a", 0)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"300")
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"200")

    def test_directory_preflight_preserves_unregistered_backup_files(self):
        self.seed()
        self.server.directories.add("/space/backup/Hero/")
        self.server.files["/space/backup/Hero/unregistered"] = b"keep-this"
        self.write("a", "Hero/Hero.d2s", "200")
        before = self.metadata()
        self.run_op("sync", "a", 0, 200, ok=False)
        self.assertEqual(self.metadata(), before)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"level-1")
        self.assertEqual(self.server.files["/space/backup/Hero/unregistered"], b"keep-this")
        self.assertNotIn("/space/.d2r-transaction.json", self.server.files)

    def test_empty_unregistered_backup_directory_is_safe_to_replace(self):
        self.seed()
        self.server.directories.add("/space/backup/Hero/")
        self.write("a", "Hero/Hero.d2s", "200")
        self.run_op("sync", "a", 0, 200)
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")

    def interrupt_directory_backup(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "directory-update")
        self.server.lost_move_response = ("/space/save/Hero/", "/space/backup/Hero/")
        self.run_op("sync", "a", 0, 200, ok=False)
        self.server.lost_move_response = None

    def test_directory_recovery_rejects_ambiguous_source_and_target(self):
        self.interrupt_directory_backup()
        for present in (True, False):
            with self.subTest(present=present):
                saved_files, saved_directories = dict(self.server.files), set(self.server.directories)
                if present:
                    self.server.directories.add("/space/save/Hero/")
                    self.server.files["/space/save/Hero/Hero.d2s"] = b"unexpected-current"
                else:
                    self.server.files = {p: d for p, d in self.server.files.items() if not p.startswith("/space/backup/Hero/")}
                    self.server.directories.discard("/space/backup/Hero/")
                before = dict(self.server.files)
                result, _ = self.run_op("sync", "a", ok=False)
                self.assertEqual(result["errorCode"], 6)
                self.assertEqual(self.server.files, before)
                self.server.files, self.server.directories = saved_files, saved_directories
        self.run_op("sync", "a")
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"directory-update")

    def test_directory_recovery_rejects_unknown_staged_files(self):
        self.interrupt_directory_backup()
        self.server.files["/space/.d2r-upload/unregistered"] = b"not-owned"
        before = dict(self.server.files)
        self.run_op("sync", "a", ok=False)
        self.assertEqual(self.server.files, before)

    def test_directory_transaction_validates_record_before_any_mutation(self):
        self.interrupt_directory_backup()
        original = json.loads(self.server.files["/space/.d2r-transaction.json"])
        for field, value in (("mode", "other"), ("cursor", 4), ("cursor", 1.5), ("metadata", None), ("group", "character:Other")):
            with self.subTest(field=field, value=value):
                txn = dict(original, **{field: value})
                self.server.files["/space/.d2r-transaction.json"] = json.dumps(txn).encode()
                before = dict(self.server.files)
                result, _ = self.run_op("sync", "a", ok=False)
                self.assertEqual(result["errorCode"], 6)
                self.assertEqual(self.server.files, before)

    def test_directory_transaction_moves_nested_sidecars_and_reserved_names(self):
        name = "角色 A#%"
        files = [f"{name}/{name}.d2s", f"{name}/nested/附属记录"]
        for path in files:
            self.write("a", path, "old")
        self.run_op("sync", "a", 0, 100)
        for path in files:
            self.write("a", path, "new")
        self.run_op("sync", "a", 0, 200)
        self.run_op("sync", "b")
        for path in files:
            self.assertEqual(self.contents("b", path), "new")
        for path in files:
            self.assertEqual(self.server.files["/space/backup/" + quote(path, safe="/")], b"old")

    def test_first_publication_and_empty_group_keep_file_transaction(self):
        self.write("a", "Hero/Hero.d2s", "new")
        key = ("/space/.d2r-transaction.json.tmp", "/space/.d2r-transaction.json")
        self.server.fail_move_nth[key] = 2
        self.run_op("sync", "a", 0, 100, ok=False)
        self.assertEqual(json.loads(self.server.files["/space/.d2r-transaction.json"])["format"], 3)
        self.server.fail_move_nth.clear()
        self.run_op("sync", "a", 0)
        (self.base / "a/save/Hero/Hero.d2s").unlink()
        self.server.move_counts.clear()
        self.server.fail_move_nth[key] = 2
        self.run_op("sync", "a", 0, 200, ok=False)
        self.assertEqual(json.loads(self.server.files["/space/.d2r-transaction.json"])["format"], 3)
        self.server.fail_move_nth.clear()
        self.run_op("sync", "a", 0)
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"new")

    def test_timeout_rebuilds_session_and_isolates_late_callbacks(self):
        self.server.files.update({"/space/slow": b"late", "/space/next": b"next", "/space/last": b"last"})
        self.server.get_delays.update({"/space/slow": 0.25, "/space/next": 0.35})
        steps = [{"path": "missing", "timeout": 2}, {"path": "slow", "timeout": 0.08}, {"path": "next", "timeout": 2}, {"path": "last", "timeout": 2}]
        path = self.base / "requests.json"
        path.write_text(json.dumps(steps))
        _, output = self.run_op("transport", "a", path)
        results = json.loads(output.splitlines()[0])
        self.assertEqual(results[1]["code"], 3)
        self.assertEqual(results[1]["digest"], "")
        for result, content in zip(results[2:], (b"next", b"last")):
            self.assertEqual(result["code"], 0)
            self.assertEqual(result["status"], 200)
            self.assertEqual(result["digest"], hashlib.sha256(content).hexdigest())
        self.assertEqual(len(self.server.connections), 2)

    def test_reused_session_still_rejects_redirects_and_oversized_responses(self):
        self.server.files["/space/large"] = b"x" * (65 * 1024 * 1024 + 1)
        self.server.files["/space/last"] = b"last"
        self.server.redirects["/space/redirect"] = self.url + "must-not-follow"
        path = self.base / "requests.json"
        path.write_text(json.dumps([{"path": name, "timeout": 2} for name in ("missing", "redirect", "large", "last")]))
        _, output = self.run_op("transport", "a", path)
        results = json.loads(output.splitlines()[0])
        self.assertEqual(results[0]["status"], 404)
        self.assertEqual(results[1]["code"], 1)
        self.assertEqual(results[2]["code"], 3)
        self.assertEqual(results[2]["digest"], "")
        self.assertEqual(results[3]["digest"], hashlib.sha256(b"last").hexdigest())
        self.assertFalse(any("must-not-follow" in path for _, path, _ in self.server.calls))

    def test_phase_internal_move_failures_and_lost_responses_replay_safely(self):
        self.seed(flat=True)
        previous = {"Hero.d2s": b"level-1", "Hero.swpouch": b"pouch"}
        stamp = 100
        for phase in ("backup", "publish"):
            for filename in previous:
                for fault in ("fail_move", "lost_move_response"):
                    with self.subTest(phase=phase, file=filename, fault=fault):
                        stamp += 100
                        for name in previous:
                            self.write("a", name, str(stamp))
                        source = "save/" if phase == "backup" else ".d2r-upload/"
                        target = "backup/" if phase == "backup" else "save/"
                        setattr(self.server, fault, ("/space/" + source + filename, "/space/" + target + filename))
                        self.run_op("sync", "a", 0, stamp, ok=False)
                        setattr(self.server, fault, None)
                        self.run_op("sync", "a", 0)
                        for name in previous:
                            self.assertEqual(self.raw(name), str(stamp).encode())
                            self.assertEqual(self.raw(name, "backup"), previous[name])
                        previous = {name: str(stamp).encode() for name in previous}
                        self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i"), b"stash")

    def test_phase_boundary_write_failure_and_lost_response_stop_and_recover(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "200")
        self.run_op("sync", "a", 0, 200)
        previous = b"200"
        key = ("/space/.d2r-transaction.json.tmp", "/space/.d2r-transaction.json")
        stamp = 200
        for fault in ("fail_move_nth", "lost_move_nth"):
            for checkpoint in (2, 3, 4):
                with self.subTest(fault=fault, checkpoint=checkpoint):
                    stamp += 100
                    self.write("a", "Hero/Hero.d2s", str(stamp))
                    self.server.move_counts.clear()
                    getattr(self.server, fault)[key] = checkpoint
                    self.run_op("sync", "a", 0, stamp, ok=False)
                    calls = self.server.calls
                    failure = [i for i, (method, path, _) in enumerate(calls) if method == "MOVE" and path == key[0]][-1]
                    self.assertFalse(any(method in ("PUT", "MOVE", "DELETE") for method, _, _ in calls[failure + 1:]))
                    getattr(self.server, fault).clear()
                    self.run_op("sync", "a", 0)
                    self.assertEqual(self.raw("Hero/Hero.d2s"), str(stamp).encode())
                    self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), previous)
                    self.assertNotIn("/space/.d2r-transaction.json", self.server.files)
                    previous = str(stamp).encode()

    def test_partial_backup_deletion_replays_before_moving_current(self):
        self.seed(flat=True)
        self.write("a", "Hero.d2s", "200")
        self.run_op("sync", "a", 0, 200)
        self.write("a", "Hero.d2s", "300")
        self.server.fail_delete = "/backup/Hero.swpouch"
        self.run_op("sync", "a", 0, 300, ok=False)
        self.assertEqual(self.raw("Hero.d2s"), b"200")
        self.server.fail_delete = None
        self.run_op("sync", "a", 0)
        self.assertEqual(self.raw("Hero.d2s"), b"300")
        self.assertEqual(self.raw("Hero.d2s", "backup"), b"200")

    def test_failed_directory_creation_is_retried_in_new_recovery(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "200")
        self.server.fail_mkdir = "/space/backup/"
        self.run_op("sync", "a", 0, 200, ok=False)
        self.server.fail_mkdir = None
        self.server.calls.clear()
        self.run_op("sync", "a", 0)
        self.assertTrue(any(method == "MKCOL" and path == "/space/backup/" for method, path, _ in self.server.calls))
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")

    def test_raw_roundtrip_and_no_duplicate_app_directory(self):
        self.seed()
        for path in ("Hero/Hero.d2s", "SharedStashSoftCoreV2.d2i", "sw_elysium.txt", "Hero/Hero.swpouch"):
            self.assertEqual(self.contents("a", path).encode(), self.raw(path))
            self.assertEqual(self.contents("a", path), self.contents("b", path))
        self.assertEqual(self.contents("b", "Settings/local"), "b")
        self.assertFalse(any("/d2r-mobile/" in path or "/objects/" in path or "/revisions/" in path for path in self.server.files))
        self.assertEqual(set(self.server.files), {"/space/.d2r-sync.json"} | {"/space/save/" + f["path"] for f in self.aggregate("current")})

    def test_only_one_previous_remote_backup_after_many_updates(self):
        self.seed()
        for stamp in (200, 300, 400):
            self.write("a", "Hero/Hero.d2s", str(stamp))
            self.run_op("sync", "a", 0, stamp)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"400")
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"300")
        self.assertEqual(self.group()["backup"]["savedAt"], 300)
        self.assertFalse(any(".d2r-upload" in path or ".tmp" in path or "transaction" in path for path in self.server.files))
        _, output = self.run_op("history")
        self.assertEqual(len(json.loads(output.splitlines()[0])), 1)

    def test_unchanged_sync_keeps_backup(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "200")
        self.run_op("sync", "a", 0, 200)
        before = dict(self.server.files)
        self.run_op("sync", "a")
        self.assertEqual(self.server.files, before)

    def test_unchanged_cold_sync_downloads_no_save_or_backup_contents(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "200")
        self.run_op("sync", "a", 0, 200)
        self.server.calls.clear()
        # 每次驱动调用使用新进程，模拟应用冷启动。
        # Each driver invocation is a fresh process, just like a cold app launch.
        self.run_op("sync", "a")
        self.assertFalse(any(method == "GET" and ("/save/" in path or "/backup/" in path)
                             for method, path, _ in self.server.calls))
        self.assertFalse(any("/backup/" in path for _, path, _ in self.server.calls))

    def test_changed_modification_time_downloads_only_changed_file(self):
        self.seed()
        path = "/space/save/Hero/Hero.d2s"
        self.edit_remote(path, b"mtime-new-data")
        self.server.calls.clear()
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "mtime-new-data")
        raw_gets = [name for method, name, _ in self.server.calls if method == "GET" and "/save/" in name]
        self.assertEqual(raw_gets, [path])

    def test_new_revision_cannot_reuse_old_bytes_with_same_modification_times(self):
        self.seed()
        path = "/space/save/Hero/Hero.d2s"
        self.edit_remote(path, b"same-timestamp-new-revision", touch=False)
        meta = self.metadata()
        meta["id"] = str(uuid.uuid4())
        meta["groups"]["character:Hero"]["current"]["id"] = str(uuid.uuid4())
        meta["groups"]["character:Hero"]["current"]["savedAt"] = 200
        self.server.files["/space/.d2r-sync.json"] = json.dumps(meta).encode()
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "same-timestamp-new-revision")

    def test_missing_or_invalid_modification_time_is_never_reused(self):
        self.seed()
        path = "/space/save/Hero/Hero.d2s"
        for modified in ("", "invalid"):
            with self.subTest(modified=modified):
                self.server.mtimes[path] = modified
                self.edit_remote(path, (modified or "missing").encode(), touch=False)
                self.run_op("sync", "b")
                self.assertEqual(self.contents("b", "Hero/Hero.d2s"), modified or "missing")

    def test_missing_local_cached_object_downloads_that_file_again(self):
        self.seed()
        digest = hashlib.sha256(b"level-1").hexdigest()
        (self.base / "b/cache/objects" / digest).unlink()
        self.server.calls.clear()
        self.run_op("sync", "b")
        self.assertEqual([path for method, path, _ in self.server.calls if method == "GET" and "/save/" in path],
                         ["/space/save/Hero/Hero.d2s"])

    def test_failed_download_does_not_commit_new_modification_times(self):
        self.seed()
        self.edit_remote("/space/save/Hero/Hero.d2s", b"retry-changed-file")
        cached = (self.base / "b/cache/current-files.json").read_bytes()
        self.server.bad_raw_get = True
        self.run_op("sync", "b", ok=False)
        self.assertEqual((self.base / "b/cache/current-files.json").read_bytes(), cached)
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "level-1")
        self.server.bad_raw_get = False
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "retry-changed-file")

    def test_malformed_local_timestamp_cache_falls_back_to_full_read(self):
        self.seed()
        for value in ([], "invalid", {"version": self.head(), "manifest": None}):
            with self.subTest(value=value):
                (self.base / "b/cache/current-files.json").write_text(json.dumps(value))
                self.run_op("sync", "b")
                self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "level-1")

    def test_backup_is_only_downloaded_when_restore_is_selected(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "200")
        self.run_op("sync", "a", 0, 200)
        self.server.calls.clear()
        _, output = self.run_op("history", "a")
        self.assertFalse(any("/backup/" in path for _, path, _ in self.server.calls))
        version = json.loads(output.splitlines()[0])[0]
        self.run_op("restore", "a", version["id"])
        self.assertTrue(any(method == "GET" and "/backup/" in path for method, path, _ in self.server.calls))

    def test_first_raw_directory_adoption_does_not_download_backup_contents(self):
        self.server.directories.update(("/space/save/", "/space/backup/"))
        self.server.files["/space/save/Hero.d2s"] = b"current"
        self.server.files["/space/backup/Hero.d2s"] = b"previous"
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", "Hero.d2s"), "current")
        self.assertFalse(any(method == "GET" and "/backup/" in path for method, path, _ in self.server.calls))

    def test_delete_and_restore_only_previous_backup(self):
        self.seed()
        first = self.head()
        (self.base / "a/save/Hero/Hero.d2s").unlink()
        self.run_op("sync", "a", 0, 200)
        self.run_op("sync", "b")
        self.assertFalse((self.base / "b/save/Hero/Hero.d2s").exists())
        self.run_op("restore", "b", first)
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "level-1")
        self.assertNotEqual(self.head(), first)
        self.assertFalse(any(f["path"] == "Hero/Hero.d2s" for f in self.group()["backup"]["files"]))

    def test_stale_backup_cannot_be_selected(self):
        self.seed()
        first = self.head()
        for stamp in (200, 300):
            self.write("a", "Hero/Hero.d2s", str(stamp))
            self.run_op("sync", "a", 0, stamp)
        result, _ = self.run_op("restore", "a", first, ok=False)
        self.assertEqual(result["errorCode"], 8)

    def test_first_connection_adopts_nas_over_fresh_local(self):
        self.seed()
        self.write("b", "Hero/Hero.d2s", "fresh-default")
        (self.base / "b/cache/state.json").unlink()
        self.run_op("sync", "b", 1, 999999)
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "level-1")

    def test_offline_failed_upload_keeps_complete_current_and_backup(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "200")
        self.run_op("sync", "a", 0, 200)
        before = self.metadata()
        self.write("a", "Hero/Hero.d2s", "retry")
        self.server.fail_put = ".d2r-upload/"
        self.run_op("sync", "a", 0, 300, ok=False)
        self.assertEqual(self.metadata(), before)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"200")
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")
        self.server.fail_put = None
        self.run_op("sync", "a", 0)
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "retry")

    def test_partial_upload_resumes_without_reuploading_verified_files(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "resume-me")
        self.server.fail_put = ".d2r-upload/Hero/Hero.swpouch"
        self.run_op("sync", "a", 0, 200, ok=False)
        path = "/space/.d2r-upload/Hero/Hero.d2s"
        count = sum(method == "PUT" and name == path for method, name, _ in self.server.calls)
        self.server.fail_put = None
        self.run_op("sync", "a", 0)
        self.assertEqual(sum(method == "PUT" and name == path for method, name, _ in self.server.calls), count)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"resume-me")

    def test_transaction_does_not_require_stored_hash_or_size(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "transfer")
        self.server.fail_move = ("/space/.d2r-upload/Hero/", "/space/save/Hero/")
        self.run_op("sync", "a", 0, 200, ok=False)
        txn = json.loads(self.server.files["/space/.d2r-transaction.json"])
        for slot in ("current", "backup"):
            for f in txn["metadata"]["groups"]["character:Hero"][slot]["files"]:
                self.assertNotIn("sha256", f)
                self.assertNotIn("size", f)
        self.server.fail_move = None
        self.run_op("sync", "a", 0)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"transfer")

    def test_cached_verification_still_checks_all_paths(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "verify-paths")
        self.server.fail_move = ("/space/.d2r-upload/Hero/", "/space/save/Hero/")
        self.run_op("sync", "a", 0, 200, ok=False)
        old = "/space/.d2r-upload/Hero/Hero.d2s"
        self.server.files[old + "-renamed"] = self.server.files.pop(old)
        self.server.fail_move = None
        self.run_op("sync", "a", 0, ok=False)
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")

    def test_failed_backup_cleanup_does_not_replace_current(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "200")
        self.run_op("sync", "a", 0, 200)
        self.write("a", "Hero/Hero.d2s", "300")
        self.server.fail_delete = "/backup/"
        self.run_op("sync", "a", 0, 300, ok=False)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"200")
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")
        self.server.fail_delete = None
        self.run_op("sync", "a", 0)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"300")
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"200")

    def test_stale_upload_marker_is_cleaned_after_completed_commit(self):
        self.seed()
        self.server.files["/space/.d2r-upload.json"] = b'{"digest":"stale"}'
        self.run_op("sync", "a")
        self.assertNotIn("/space/.d2r-upload.json", self.server.files)

    def test_server_error_is_not_empty_save(self):
        self.seed()
        before = dict(self.server.files)
        self.server.bad_get = True
        self.run_op("sync", "b", ok=False)
        self.assertEqual(self.server.files, before)

    def test_multistatus_put_is_not_success(self):
        self.seed()
        before = self.head()
        self.write("a", "Hero/Hero.d2s", "207")
        self.server.fail_put = ".d2r-upload/"
        self.server.fail_put_status = 207
        self.run_op("sync", "a", 0, 200, ok=False)
        self.assertEqual(self.head(), before)

    def test_interrupted_after_current_moved_to_backup_recovers(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "recover")
        self.server.fail_move = ("/space/.d2r-upload/Hero/", "/space/save/Hero/")
        self.run_op("sync", "a", 0, 200, ok=False)
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")
        self.assertNotIn("/space/save/Hero/Hero.d2s", self.server.files)
        self.server.fail_move = None
        self.run_op("sync", "a", 0)
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "recover")

    def test_lost_move_response_recovers_without_overwriting_previous_backup(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "recover-response")
        self.server.lost_move_response = ("/space/.d2r-upload/Hero/", "/space/save/Hero/")
        self.run_op("sync", "a", 0, 200, ok=False)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"recover-response")
        self.server.lost_move_response = None
        self.run_op("sync", "a", 0)
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")

    def test_metadata_commit_failure_recovers(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "metadata-retry")
        self.server.fail_move = ("/space/.d2r-sync.json.tmp", "/space/.d2r-sync.json")
        self.run_op("sync", "a", 0, 200, ok=False)
        self.server.fail_move = None
        self.run_op("sync", "a", 0)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"metadata-retry")
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")

    def test_direct_nas_edit_ignores_old_metadata_and_refreshes_cache(self):
        self.seed()
        self.edit_remote("/space/save/Hero/Hero.d2s", b"edited-directly-on-nas-with-a-different-length")
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "edited-directly-on-nas-with-a-different-length")
        self.assertTrue(self.group()["current"]["external"])
        self.assertNotIn("digest", self.group()["current"])
        for f in self.group()["current"]["files"]:
            self.assertNotIn("sha256", f)
            self.assertNotIn("size", f)

    def test_manual_refresh_detects_same_size_same_mtime_nas_edit(self):
        self.seed()
        self.server.files["/space/save/Hero/Hero.d2s"] = b"level-9"
        self.run_op("sync", "a")
        self.assertEqual(self.contents("a", "Hero/Hero.d2s"), "level-1")
        self.run_op("sync", "a", refresh=True)
        self.assertEqual(self.contents("a", "Hero/Hero.d2s"), "level-9")

    def test_nas_edit_wins_over_pending_local_upload(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "pending-local")
        self.edit_remote("/space/save/Hero/Hero.d2s", b"manual-nas-edit")
        result, _ = self.run_op("sync", "a", 0, 9999999999)
        self.assertTrue(result["restart"])
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"manual-nas-edit")
        self.run_op("sync", "a", 1)
        self.assertEqual(self.contents("a", "Hero/Hero.d2s"), "manual-nas-edit")

    def test_nas_added_and_deleted_files_update_manifest_automatically(self):
        self.seed()
        del self.server.files["/space/save/Hero/Hero.d2s"]
        self.server.files["/space/save/Hero/New.d2s"] = b"new-character"
        self.run_op("sync", "b")
        self.assertFalse((self.base / "b/save/Hero/Hero.d2s").exists())
        self.assertEqual(self.contents("b", "Hero/New.d2s"), "new-character")

    def test_irrelevant_remote_hash_and_size_cannot_block_nas_edit(self):
        self.seed()
        meta = self.metadata()
        current = meta["groups"]["character:Hero"]["current"]
        current["digest"] = "incorrect"
        for f in current["files"]:
            f["sha256"], f["size"] = "incorrect", -99
        self.server.files["/space/.d2r-sync.json"] = json.dumps(meta).encode()
        self.edit_remote("/space/save/Hero/Hero.d2s", b"new-nas-data")
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "new-nas-data")
        self.assertEqual(self.metadata()["format"], 4)
        self.assertNotIn("digest", self.group()["current"])

    def test_manual_backup_edit_can_be_restored_without_hash_updates(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "newer")
        self.run_op("sync", "a", 0, 200)
        self.server.files["/space/backup/Hero/Hero.d2s"] = b"modified-backup"
        _, output = self.run_op("history", "a")
        version = json.loads(output.splitlines()[0])[0]
        self.run_op("restore", "a", version["id"])
        self.run_op("sync", "a")
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"modified-backup")

    def test_running_game_prefetches_and_requires_restart(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "new-data")
        self.run_op("sync", "a", 0, 300)
        self.write("b", "Hero/Hero.d2s", "older")
        result, _ = self.run_op("sync", "b", 0, 200)
        self.assertTrue(result["restart"])
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "older")
        self.run_op("sync", "b", 1)
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "new-data")

    def test_local_backup_retention_is_also_one(self):
        self.seed()
        for stamp in (200, 300, 400):
            self.write("a", "Hero/Hero.d2s", str(stamp))
            self.run_op("sync", "a", 0, stamp)
            self.run_op("sync", "b")
        self.assertEqual(len(list((self.base / "b/cache/backups").iterdir())), 1)

    def test_restore_is_pinned_and_survives_upload_failure(self):
        self.seed()
        first = self.head()
        self.write("a", "Hero/Hero.d2s", "newer")
        self.run_op("sync", "a", 0, 200)
        self.run_op("restore", "a", first)
        self.server.fail_put = ".d2r-upload/"
        self.run_op("sync", "a", ok=False)
        self.assertEqual(self.contents("a", "Hero/Hero.d2s"), "newer")
        self.server.fail_put = None
        self.run_op("sync", "a")
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"level-1")
        self.assertFalse((self.base / "a/cache/restore.json").exists())

    def test_unicode_spaces_and_reserved_filename_characters(self):
        path = "角色 A/英雄 #1%?.d2s"
        self.write("a", path, "unicode-data")
        self.run_op("probe")
        self.run_op("sync", "a", 1, 100)
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", path), "unicode-data")

    def test_empty_snapshot_rotates_previous_backup(self):
        self.seed()
        for path in (self.base / "a/save").rglob("*"):
            if path.is_file() and "Settings" not in path.parts:
                path.unlink()
        self.run_op("sync", "a", 0, 200)
        self.assertFalse(self.aggregate("current"))
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")

    def test_preexisting_raw_save_can_initialize_nas(self):
        self.server.directories.update(("/space/save/", "/space/save/Hero/"))
        self.server.files["/space/save/Hero/Hero.d2s"] = b"manual-copy"
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "manual-copy")

    def test_invalid_manifest_traversal_is_rejected(self):
        self.seed()
        metadata = self.metadata()
        metadata["groups"]["character:Hero"]["current"]["files"][0]["path"] = "../escape"
        self.server.files['/space/.d2r-sync.json'] = json.dumps(metadata).encode()
        self.run_op("sync", "b", ok=False)
        self.assertFalse((self.base / 'escape').exists())

    def versions(self, device="a"):
        _, output = self.run_op("history", device)
        return json.loads(output.splitlines()[0])

    def test_transfer_activity_follows_groups_for_upload_download_and_restore(self):
        self.seed()
        name = "ModernSharedStashSoftCoreV2"
        self.write("a", "Hero/Hero.d2s", "new-hero")
        self.write("a", f"{name}/{name}.d2i", "stash")
        self.write("a", f"{name}.swvault", "vault")
        result, _ = self.run_op("sync", "a", 0, 200, activity=True)
        self.assertEqual(result["activity"], ["upload:character", "upload:stash"])
        result, _ = self.run_op("sync", "b", activity=True)
        self.assertTrue(result["activity"])
        self.assertIn("download:character", result["activity"])
        self.assertIn("download:stash", result["activity"])
        self.assertFalse(any(event.endswith(":generic") for event in result["activity"]))
        self.write("a", f"{name}.swvault", "vault-2")
        self.run_op("sync", "a", 0, 300)
        chosen = next(v for v in self.versions() if v["group"] == f"stash:{name}")
        result, _ = self.run_op("restore", "a", chosen["id"], activity=True)
        self.assertEqual(result["activity"], ["download:stash"])

    def test_stale_caption_ownership_does_not_block_raw_directory_adoption(self):
        self.server.directories.update({"/space/save/", "/space/save/Hero/"})
        self.server.files["/space/save/Hero/Hero.d2s"] = b"raw-character"
        cache = self.base / "b/cache"
        cache.mkdir(parents=True)
        (cache / "group-owners.json").write_text(json.dumps({"character:Hero": {"kind": "character", "name": "Hero", "root": "Hero"}}))
        self.run_op("sync", "b", activity=True)
        self.assertEqual(self.contents("b", "Hero/Hero.d2s"), "raw-character")

    def test_sidecar_download_remembers_character_kind_after_primary_deletion(self):
        self.seed()
        del self.server.files["/space/save/Hero/Hero.d2s"]
        self.edit_remote("/space/save/Hero/Hero.swpouch", b"updated-pouch")
        result, _ = self.run_op("sync", "b", activity=True)
        self.assertEqual(result["activity"], ["download:character"])

    def test_selected_character_does_not_publish_or_rotate_stash(self):
        self.seed()
        stash = self.group("stash:SharedStashSoftCoreV2")
        self.write("a", "Hero/Hero.d2s", "character-first")
        self.write("a", "SharedStashSoftCoreV2.d2i", "stash-later")
        self.server.calls.clear()
        self.run_op("sync", "a", 0, 200, groups=["character:Hero"])
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"character-first")
        self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i"), b"stash")
        self.assertEqual(self.group("stash:SharedStashSoftCoreV2"), stash)
        self.assertFalse(any(method == "PUT" and "SharedStash" in path for method, path, _ in self.server.calls))
        self.run_op("sync", "a", 0, 201, groups=["stash:SharedStashSoftCoreV2"])
        self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i"), b"stash-later")
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")
        self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i", "backup"), b"stash")

    def test_stash_vault_and_hardcore_are_separate_groups(self):
        for name in ("ModernSharedStashSoftCoreV2", "ModernSharedStashHardCoreV2"):
            self.write("a", f"{name}/{name}.d2i", "stash-old")
            self.write("a", f"{name}.swvault", "vault-old")
            self.write("a", f"{name}/extra", "sidecar")
        self.run_op("sync", "a", 0, 100)
        name = "ModernSharedStashSoftCoreV2"
        self.write("a", f"{name}/{name}.d2i", "stash-new")
        self.write("a", f"{name}.swvault", "vault-new")
        self.run_op("sync", "a", 0, 200)
        soft = self.group(f"stash:{name}")
        hard = self.group("stash:ModernSharedStashHardCoreV2")
        self.assertEqual({f["path"] for f in soft["current"]["files"]}, {f"{name}/{name}.d2i", f"{name}.swvault", f"{name}/extra"})
        self.assertEqual(self.raw(f"{name}.swvault", "backup"), b"vault-old")
        self.assertEqual(self.raw(f"{name}/{name}.d2i", "backup"), b"stash-old")
        self.assertIsNone(hard["backup"])
        self.assertEqual(self.raw("ModernSharedStashHardCoreV2.swvault"), b"vault-old")

    def test_character_sidecars_and_multiple_characters_are_independent(self):
        self.seed()
        for suffix in ("swpage", "sw_kills", "sw_rift", "dm_pets", "map"):
            self.write("a", f"Hero/Hero.{suffix}", suffix)
        self.write("a", "Other/Other.d2s", "other")
        self.run_op("sync", "a", 0, 200)
        other = self.group("character:Other")
        self.write("a", "Hero/Hero.dm_pets", "pets-updated")
        self.run_op("sync", "a", 0, 300)
        self.assertEqual(self.group("character:Other"), other)
        self.assertTrue(all(f["path"].startswith("Hero/") for f in self.group()["current"]["files"]))
        self.assertEqual(self.raw("Hero/Hero.dm_pets", "backup"), b"dm_pets")

    def test_primary_deletion_retains_sidecar_ownership_across_restarts(self):
        self.seed()
        (self.base / "a/save/Hero/Hero.d2s").unlink()
        self.run_op("sync", "a", 0, 200)
        self.write("a", "Hero/Hero.swpouch", "pouch-after-primary-deletion")
        self.run_op("sync", "a", 0, 300)
        self.assertEqual([f["path"] for f in self.group()["current"]["files"]], ["Hero/Hero.swpouch"])
        self.assertEqual(self.raw("Hero/Hero.swpouch", "backup"), b"pouch")
        self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i"), b"stash")

    def test_deleted_primary_ownership_is_available_to_a_cold_scheduler(self):
        self.seed()
        (self.base / "a/save/Hero/Hero.d2s").unlink()
        self.run_op("sync", "a", 0, 200)
        _, output = self.run_op("groups", "a")
        groups = json.loads(output.splitlines()[0])
        self.assertEqual([f["path"] for f in groups["character:Hero"]["files"]], ["Hero/Hero.swpouch"])

    def test_group_validation_rejects_claiming_another_groups_files(self):
        self.seed()
        meta = self.metadata()
        meta["groups"]["stash:SharedStashSoftCoreV2"]["current"]["files"] = self.group()["current"]["files"]
        self.server.files["/space/.d2r-sync.json"] = json.dumps(meta).encode()
        before = dict(self.server.files)
        self.run_op("sync", "a", 0, 200, ok=False)
        self.assertEqual(self.server.files, before)

    def test_flat_character_sidecars_are_grouped(self):
        self.write("a", "Flat.d2s", "flat")
        self.write("a", "Flat.swpage", "pages")
        self.write("a", "Flat.dm_pets", "pets")
        self.write("a", "Flat.map", "map")
        self.run_op("sync", "a", 0, 100)
        self.assertEqual({f["path"] for f in self.group("character:Flat")["current"]["files"]},
                         {"Flat.d2s", "Flat.swpage", "Flat.dm_pets", "Flat.map"})

    def test_restore_changes_only_selected_group_and_keeps_pending_local_groups(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "hero-new")
        self.write("a", "SharedStashSoftCoreV2.d2i", "stash-new")
        self.run_op("sync", "a", 0, 200)
        chosen = next(v for v in self.versions() if v["group"] == "character:Hero")
        stash = self.group("stash:SharedStashSoftCoreV2")
        self.run_op("restore", "a", chosen["id"])
        self.write("a", "SharedStashSoftCoreV2.d2i", "pending-stash")
        self.run_op("sync", "a", 1, 300)
        self.assertEqual(self.contents("a", "Hero/Hero.d2s"), "level-1")
        self.assertEqual(self.contents("a", "SharedStashSoftCoreV2.d2i"), "pending-stash")
        self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i"), b"pending-stash")
        self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i", "backup"), b"stash-new")
        self.assertEqual(self.group("stash:SharedStashSoftCoreV2")["backup"]["id"], stash["current"]["id"])

    def test_restore_reads_only_chosen_backup_group(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "hero-new")
        self.write("a", "SharedStashSoftCoreV2.d2i", "stash-new")
        self.run_op("sync", "a", 0, 200)
        chosen = next(v for v in self.versions() if v["group"] == "character:Hero")
        self.server.calls.clear()
        self.run_op("restore", "a", chosen["id"])
        gets = [p for m, p, _ in self.server.calls if m == "GET" and "/backup/" in p]
        self.assertTrue(gets)
        self.assertTrue(all("/backup/Hero/" in p for p in gets))

    def test_remote_character_change_does_not_block_local_stash_upload(self):
        self.seed()
        self.edit_remote("/space/save/Hero/Hero.d2s", b"remote-hero")
        self.write("a", "SharedStashSoftCoreV2.d2i", "local-stash")
        result, _ = self.run_op("sync", "a", 0, 300)
        self.assertTrue(result["restart"])
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"remote-hero")
        self.assertEqual(self.contents("a", "Hero/Hero.d2s"), "level-1")
        self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i"), b"local-stash")
        self.run_op("sync", "a", 1)
        self.assertEqual(self.contents("a", "Hero/Hero.d2s"), "remote-hero")
        self.assertEqual(self.contents("a", "SharedStashSoftCoreV2.d2i"), "local-stash")

    def test_first_publication_lost_response_preserves_newer_local_progress(self):
        self.write("a", "Hero/Hero.d2s", "first-publication")
        self.server.lost_move_response = ("/space/.d2r-sync.json.tmp", "/space/.d2r-sync.json")
        self.run_op("sync", "a", 0, 100, ok=False)
        self.write("a", "Hero/Hero.d2s", "newer-before-acknowledgement")
        self.server.lost_move_response = None
        self.run_op("sync", "a", 0, 200)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"newer-before-acknowledgement")
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"first-publication")

    def test_auxiliary_display_name_does_not_claim_a_character_directory(self):
        self.write("a", "其他存档/其他存档.d2s", "character")
        self.write("a", "sw_elysium.txt", "global")
        self.run_op("sync", "a", 0, 100)
        self.run_op("sync", "b")
        self.assertEqual(self.contents("b", "其他存档/其他存档.d2s"), "character")
        self.assertIn("auxiliary", self.metadata()["groups"])

    def test_unsupported_metadata_formats_never_overwrite_saves(self):
        self.seed()
        original = self.metadata()
        self.write("a", "Hero/Hero.d2s", "pending")
        for version in (2, 3, 999):
            with self.subTest(format=version):
                meta = dict(original, format=version)
                self.server.files["/space/.d2r-sync.json"] = json.dumps(meta).encode()
                before = dict(self.server.files)
                for operation, args in (("sync", (0, 200)), ("history", ())):
                    result, _ = self.run_op(operation, "a", *args, ok=False)
                    self.assertEqual(result["errorCode"], 7)
                    self.assertEqual(self.server.files, before)
                self.assertEqual(self.contents("a", "Hero/Hero.d2s"), "pending")

    def test_unsupported_transaction_format_is_left_untouched(self):
        self.seed()
        self.server.files["/space/.d2r-transaction.json"] = json.dumps({"format": 2, "metadata": self.metadata()}).encode()
        before = dict(self.server.files)
        result, _ = self.run_op("sync", "a", ok=False)
        self.assertEqual(result["errorCode"], 7)
        self.assertEqual(self.server.files, before)

    def test_restore_requires_a_group_without_modifying_saves(self):
        self.seed()
        snapshot = json.loads((self.base / "a/cache/current-files.json").read_text())["manifest"]
        path = self.base / "a/cache/restore.json"
        path.write_text(json.dumps({"revision": snapshot["id"], "manifest": snapshot}))
        before = dict(self.server.files)
        result, _ = self.run_op("sync", "a", ok=False)
        self.assertEqual(result["errorCode"], 6)
        self.assertTrue(path.exists())
        self.assertEqual(self.server.files, before)
        self.assertEqual(self.contents("a", "Hero/Hero.d2s"), "level-1")

    def test_raw_import_initializes_group_backups_without_reupload(self):
        self.server.directories.update(("/space/save/", "/space/save/Hero/", "/space/backup/", "/space/backup/Hero/"))
        self.server.files.update({"/space/save/Hero/Hero.d2s": b"current-hero",
                                  "/space/save/SharedStashSoftCoreV2.d2i": b"current-stash",
                                  "/space/backup/Hero/Hero.d2s": b"previous-hero",
                                  "/space/backup/SharedStashSoftCoreV2.d2i": b"previous-stash"})
        raw = dict(self.server.files)
        self.run_op("sync", "a")
        self.assertEqual(self.metadata()["format"], 4)
        self.assertEqual(self.contents("a", "Hero/Hero.d2s"), "current-hero")
        self.assertEqual({v["group"] for v in self.versions()}, {"character:Hero", "stash:SharedStashSoftCoreV2"})
        self.assertTrue(all(self.server.files[p] == data for p, data in raw.items()))
        self.assertFalse(any(method == "PUT" and ("/save/" in path or "/backup/" in path) for method, path, _ in self.server.calls))

    def test_group_transaction_recovery_preserves_other_groups(self):
        self.seed()
        other = self.group("stash:SharedStashSoftCoreV2")
        self.write("a", "Hero/Hero.d2s", "interrupted-hero")
        self.server.fail_move = ("/space/.d2r-upload/Hero/", "/space/save/Hero/")
        self.run_op("sync", "a", 0, 200, ok=False)
        self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i"), b"stash")
        self.server.fail_move = None
        self.run_op("sync", "a", 0)
        self.assertEqual(self.group("stash:SharedStashSoftCoreV2"), other)
        self.assertEqual(self.raw("Hero/Hero.d2s"), b"interrupted-hero")
        self.assertEqual(self.raw("Hero/Hero.d2s", "backup"), b"level-1")

    def test_unchanged_groups_keep_independent_backup_times(self):
        self.seed()
        self.write("a", "Hero/Hero.d2s", "hero-200")
        self.run_op("sync", "a", 0, 200)
        hero = self.group()
        for stamp in (300, 400):
            self.write("a", "SharedStashSoftCoreV2.d2i", str(stamp))
            self.run_op("sync", "a", 0, stamp)
        self.assertEqual(self.group(), hero)
        versions = self.versions()
        self.assertEqual({v["group"] for v in versions}, {"character:Hero", "stash:SharedStashSoftCoreV2"})
        self.assertEqual(self.raw("SharedStashSoftCoreV2.d2i", "backup"), b"300")

    def test_symlinks_are_rejected(self):
        (self.base / "a/save/evil").symlink_to("/etc/passwd")
        self.run_op("snapshot", ok=False)

    def test_invalid_directory_listing_is_rejected(self):
        self.server.bad_listing = True
        self.run_op("probe", ok=False)
        self.assertFalse(self.server.files)


if __name__ == '__main__':
    unittest.main()
