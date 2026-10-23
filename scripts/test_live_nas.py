#!/usr/bin/env python3
"""显式 WebDAV 实测使用临时假存档，不读游戏存档。凭据只在本机读取，不传入命令行或输出；仅删除新建的随机临时目录。
Explicit live WebDAV check using disposable fake saves; never reads game saves.

Credentials are read locally and never passed on command lines or printed.
Only the newly created codex-probe-<UUID> remote directory is removed.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[1]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args()
    config = json.loads(args.config.read_text())
    if not config.get("username") or not config.get("password"):
        raise SystemExit("Please fill username and password in the local config file.")
    base = config["url"].rstrip("/")
    url = urllib.parse.urlsplit(base)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment:
        raise SystemExit("Expected an HTTPS WebDAV directory without credentials or query parameters.")
    remote = base + "/codex-probe-" + str(uuid.uuid4()) + "/"
    auth = "Basic " + base64.b64encode((config["username"] + ":" + config["password"]).encode()).decode()
    opener = urllib.request.build_opener(NoRedirect)

    def request(method, path="", read=False, data=None):
        req = urllib.request.Request(remote + path, data=data, method=method, headers={"Authorization": auth})
        try:
            with opener.open(req, timeout=20) as response:
                return response.read() if read else response.status
        except urllib.error.HTTPError as error:
            return error.code

    with tempfile.TemporaryDirectory(prefix="d2r-live-nas-") as temp:
        work = Path(temp)
        driver = work / "nas-store"
        subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
                        str(ROOT / "dm/host/tests/nas_store_driver.m"), str(ROOT / "dm/ios/Sources/nas_store.m"),
                        str(ROOT / "dm/host/dm_i18n.c"), "-framework", "Foundation", "-o", str(driver)], check=True)
        created = request("MKCOL")
        if created != 201:
            raise SystemExit(f"Temporary directory creation failed: HTTP {created}")
        print("Created isolated remote test directory:", urllib.parse.urlsplit(remote).path, flush=True)
        try:
            env = os.environ.copy()
            env["DM_NAS_TEST_CONFIG"] = str(args.config.resolve())
            devices = {name: str(uuid.uuid4()) for name in ("a", "b", "c")}
            for name in devices:
                (work / name / "save").mkdir(parents=True)

            def run(op, device="a", *extra):
                result = subprocess.run([str(driver), op, remote, str(work / device / "cache"), devices[device],
                                         str(work / device / "save"), *map(str, extra)],
                                        env=env, capture_output=True, text=True, timeout=100)
                output = json.loads(result.stdout.splitlines()[-1])
                # 仅输出存储层固定的用户提示，不输出 HTTP 正文或凭据。
                # Only the store's fixed user-facing message is emitted; no HTTP bodies/credentials.
                print(f"{device} {op}: {json.dumps(output, ensure_ascii=False)}", flush=True)
                if result.returncode or not output["ok"]:
                    raise RuntimeError(f"{device} {op} failed")
                if op == "history":
                    versions = json.loads(result.stdout.splitlines()[0])
                    if len(versions) != 1:
                        raise RuntimeError("Expected exactly one previous backup")
                    output["versions"] = versions
                return output

            run("probe")
            run("probe", "b")
            fake = work / "a/save/probe.bin"
            fake.write_bytes(b"disposable-fake-save-v1")
            run("sync", "a", 1, time.time())
            run("sync", "b")
            if (work / "b/save/probe.bin").read_bytes() != fake.read_bytes():
                raise RuntimeError("First download differs from uploaded data")
            fake.write_bytes(b"disposable-fake-save-v2")
            run("sync", "a", 0, time.time())
            run("sync", "b")
            if (work / "b/save/probe.bin").read_bytes() != fake.read_bytes():
                raise RuntimeError("Updated download differs from uploaded data")
            if request("GET", "save/probe.bin", read=True) != b"disposable-fake-save-v2":
                raise RuntimeError("Raw current save does not match")
            if request("GET", "backup/probe.bin", read=True) != b"disposable-fake-save-v1":
                raise RuntimeError("Raw previous backup does not match")
            run("history")
            fake.write_bytes(b"disposable-fake-save-v3")
            run("sync", "a", 0, time.time())
            run("sync", "b")
            if request("GET", "backup/probe.bin", read=True) != b"disposable-fake-save-v2":
                raise RuntimeError("Previous backup did not rotate")
            run("history")
            metadata = json.loads(request("GET", ".d2r-sync.json", read=True))
            if set(metadata) != {"format", "id", "groups"} or metadata["format"] != 4:
                raise RuntimeError("Unexpected sync metadata")
            run("sync", "c")
            if (work / "c/save/probe.bin").read_bytes() != b"disposable-fake-save-v3":
                raise RuntimeError("Fresh-device download differs")
            # 模拟直接编辑 NAS 文件，不改元数据。
            # Simulate editing NAS files without touching any metadata.
            if request("PUT", "save/probe.bin", data=b"edited-on-nas-with-a-new-length") != 204:
                raise RuntimeError("Could not modify isolated NAS save")
            run("sync", "a")
            if fake.read_bytes() != b"edited-on-nas-with-a-new-length":
                raise RuntimeError("Direct NAS edit did not replace old client cache")
            if request("PUT", "save/added.d2s", data=b"added-character") != 201 or request("DELETE", "save/probe.bin") != 204:
                raise RuntimeError("Could not change isolated NAS file list")
            run("sync", "b")
            if (work / "b/save/probe.bin").exists() or (work / "b/save/added.d2s").read_bytes() != b"added-character":
                raise RuntimeError("NAS additions/deletions were not imported")
            metadata = json.loads(request("GET", ".d2r-sync.json", read=True))
            for group in metadata["groups"].values():
                for slot in ("current", "backup"):
                    manifest = group[slot]
                    if manifest and ("digest" in manifest or any("sha256" in f or "size" in f for f in manifest["files"])):
                        raise RuntimeError("Remote metadata still contains hashes or file sizes")
            print("PASS: editable NAS saves without hash or size configuration, fresh cache, additions/deletions, single backup, byte-for-byte verification", flush=True)
        finally:
            deleted = request("DELETE")
            print(f"Temporary directory cleanup: HTTP {deleted}", flush=True)
            if deleted not in (200, 204):
                raise RuntimeError("Temporary directory cleanup failed")


if __name__ == "__main__":
    main()
