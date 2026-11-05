"""Exercise the actual shared library via ctypes; payloads stay on disk."""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
import socket
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("library", type=Path)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    lib = c.CDLL(str(args.library.resolve()))
    api = {}
    signatures = {
        "abi_version": (c.c_uint32, []),
        "create": (c.c_int32, [c.c_void_p, c.c_size_t, c.POINTER(c.c_uint64)]),
        "submit": (c.c_int32, [c.c_uint64, c.c_void_p, c.c_size_t, c.POINTER(c.c_uint64)]),
        "poll": (c.c_int32, [c.c_uint64, c.c_uint32, c.c_uint32, c.POINTER(c.c_void_p)]),
        "stop": (c.c_int32, [c.c_uint64]),
        "release": (c.c_int32, [c.c_uint64]),
        "free_string": (c.c_int32, [c.c_void_p]),
    }
    for name, (result, parameters) in signatures.items():
        fn = getattr(lib, "xdremux_transfer_" + name)
        fn.restype, fn.argtypes = result, parameters
        api[name] = fn
    assert api["abi_version"]() == 65539
    assert api["stop"](0) == 2
    bad = c.c_uint64()
    assert api["create"](None, 1, c.byref(bad)) == 1
    assert api["create"](b"{}", 65537, c.byref(bad)) == 1
    timings = []
    handles = {}

    def call(name, *values):
        start = time.perf_counter()
        result = api[name](*values)
        timings.append((name, (time.perf_counter() - start) * 1000))
        return result

    def create(root, bind=None):
        cfg = {"root": str(root)}
        if bind:
            cfg["bind"] = bind
        data = json.dumps(cfg).encode()
        handle = c.c_uint64()
        assert call("create", data, len(data), c.byref(handle)) == 0
        handles[handle.value] = {"records": [], "status": {}}
        return handle.value

    def pump():
        for h, state in handles.items():
            ptr = c.c_void_p()
            assert call("poll", h, 128, 2097152, c.byref(ptr)) == 0
            page = json.loads(c.string_at(ptr))
            assert call("free_string", ptr) == 0
            state["status"] = page
            state["records"].extend(r["body"] for r in page["records"])

    def until(predicate, seconds=45):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            pump()
            result = predicate()
            if result:
                return result
            time.sleep(0.01)
        raise AssertionError("ABI smoke deadline")

    def submit(h, request):
        data = json.dumps(request, ensure_ascii=False).encode()
        op = c.c_uint64()
        assert call("submit", h, data, len(data), c.byref(op)) == 0
        return op.value

    def result(h, op, error=None):
        r = until(lambda: next((r for r in handles[h]["records"] if r.get("operation_id") == op), None))
        assert r["error"] == error, r
        return r["data"]

    def query(h, command, **fields):
        return result(h, submit(h, {"command": command, **fields}))

    def event(h, kind):
        return until(lambda: next((r["event"] for r in handles[h]["records"]
                                  if r.get("kind") == "event" and r["event"]["kind"] == kind), None))

    def stop(h):
        assert call("stop", h) == 0
        assert call("stop", h) == 0
        until(lambda: handles[h]["status"].get("phase") == 3)

    with tempfile.TemporaryDirectory(prefix="xdremux-abi-") as tmp:
        root = Path(tmp)
        a, b = create(root / "a"), create(root / "b")
        until(lambda: all(handles[h]["status"].get("phase") == 1 for h in (a, b)))
        ready = handles[b]["status"]["ready"]
        peer = query(a, "probe", address=ready["address"])
        assert peer["fingerprint"] == ready["fingerprint"]
        paths = [root / "照片😀.heic", root / "empty.bin", root / "payload.bin"]
        paths[0].write_bytes(b"opaque-photo\0private-tail\xff")
        paths[1].write_bytes(b"")
        paths[2].write_bytes(bytes(range(256)) * 8192)
        expected = {p.name: (p.stat().st_size, hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths}
        send_op = submit(a, {"command": "send", "peer": peer, "paths": [str(p) for p in paths]})
        send = result(a, send_op)
        offer = event(b, "offer")["offer"]
        pending = query(b, "transfer", transfer_id=offer["session_id"], limit=64)
        assert pending["transfer"]["phase"] == "pending"
        # This harness explicitly accepts only the test fixtures created above.
        assert {f["name"] for f in offer["files"]} == set(expected)
        query(b, "decide", transfer_id=offer["session_id"], accept=True)
        sent = event(a, "sent")
        assert sent["report"]["error"] is None
        prepared = event(a, "prepared")
        assert {f["id"] for f in prepared["files"]} == {f["id"] for f in sent["report"]["files"]}
        restored = query(a, "send_report", transfer_id=send["transfer_id"])
        assert restored["error"] is None
        assert {f["id"] for f in restored["files"]} == {f["id"] for f in prepared["files"]}
        progress = [r["event"] for r in handles[a]["records"] if r.get("kind") == "event" and r["event"]["kind"] == "progress"]
        assert progress and all(p["file_id"] in {f["id"] for f in prepared["files"]} for p in progress)
        state = query(a, "transfer", transfer_id=send["transfer_id"], limit=1)
        assert state["transfer"]["phase"] == "completed" and state["next"]
        assert state["files"][0]["phase"] == "sent"
        page2 = query(a, "transfer", transfer_id=send["transfer_id"], after=state["next"], limit=64)
        assert len(page2["files"]) == 2
        assert query(a, "operation", operation_id=send_op)["data"] == send
        receipts = query(b, "receipts", limit=64)
        assert len(receipts) == 3
        for receipt in receipts:
            lease = query(b, "acquire_receipt", receipt_id=receipt["id"])
            payload = Path(lease["path"])
            assert (payload.stat().st_size, hashlib.sha256(payload.read_bytes()).hexdigest()) == expected[receipt["name"]]
            op = submit(b, {"command": "delete_receipt", "receipt_id": receipt["id"]})
            result(b, op, "busy")
            query(b, "release_receipt", lease_id=lease["lease_id"])
            query(b, "delete_receipt", receipt_id=receipt["id"])
            assert not payload.exists()
        assert query(b, "receipts", limit=64) == []
        # Same-folder names keep 1000 paths below the 64 KiB ABI input cap.
        batch_dir = root / "batch"
        batch_dir.mkdir()
        batch_expected = {}
        for i in range(1000):
            path = batch_dir / f"p23-{i:04}.bin"
            payload = i.to_bytes(4, "little") + bytes(1020)
            path.write_bytes(payload)
            batch_expected[path.name] = hashlib.sha256(payload).hexdigest()
        for h in (a, b):
            handles[h]["records"].clear()
        batch_request = {"command": "send_batch", "peer": peer,
                         "directory": str(batch_dir), "names": list(batch_expected)}
        assert len(json.dumps(batch_request).encode()) < 65536
        batch = result(a, submit(a, batch_request))
        offer = event(b, "offer")["offer"]
        assert {f["name"] for f in offer["files"]} == set(batch_expected)
        query(b, "decide", transfer_id=offer["session_id"], accept=True)
        sent = event(a, "sent")["report"]
        assert sent["error"] is None and len(sent["files"]) == 1000, sent["error"]
        after, observed = None, 0
        while True:
            page = query(a, "transfer", transfer_id=batch["transfer_id"], after=after, limit=64)
            assert all(f["phase"] == "sent" for f in page["files"])
            observed += len(page["files"])
            after = page["next"]
            if after is None:
                break
        assert observed == 1000
        after, checked = None, 0
        while True:
            page = query(b, "receipts", after=after, limit=64)
            for receipt in page:
                lease = query(b, "acquire_receipt", receipt_id=receipt["id"])
                assert hashlib.sha256(Path(lease["path"]).read_bytes()).hexdigest() == batch_expected[receipt["name"]]
                query(b, "release_receipt", lease_id=lease["lease_id"])
                checked += 1
            if len(page) < 64:
                break
            after = page[-1]["id"]
        assert checked == 1000
        # Outstanding output buffers are bounded and remain independently freeable.
        pointers = []
        for _ in range(64):
            ptr = c.c_void_p()
            assert api["poll"](a, 1, 2097152, c.byref(ptr)) == 0
            pointers.append(ptr)
        ptr = c.c_void_p()
        assert api["poll"](a, 1, 2097152, c.byref(ptr)) == 3
        for ptr in pointers:
            assert api["free_string"](ptr) == 0
        assert api["free_string"](ptr) == 1
        assert api["release"](a) == 3
        # Stop an in-flight sender waiting for acceptance.
        handles[b]["records"].clear()
        result(a, submit(a, {"command": "send", "peer": peer, "paths": [str(paths[0])]}))
        event(b, "offer")
        stop(a)
        stop(b)
        address = ready["address"].split(":")
        with socket.socket() as probe:
            probe.bind((address[0], int(address[1])))
        # Reopen the exact root and port before releasing the old numeric handle.
        restarted = create(root / "b", ready["address"])
        until(lambda: handles[restarted]["status"].get("phase") == 1)
        assert handles[restarted]["status"]["ready"]["fingerprint"] == ready["fingerprint"]
        assert handles[restarted]["status"]["ready"]["core_instance_id"] != ready["core_instance_id"]
        stop(restarted)
        for h in list(handles):
            assert call("release", h) == 0
            assert call("release", h) == 2
            del handles[h]
    report = {"passed": True, "abi": api["abi_version"](), "files": len(expected),
              "bytes": sum(s for s, _ in expected.values()), "independentHashes": True, "batchFiles": 1000,
              "checks": ["unicode_and_empty", "prepared_progress_terminal_ids", "snapshot_paging", "operation_recovery",
                         "lease_delete_busy", "managed_delete", "buffer_cap_and_free", "invalid_input_handle",
                         "pending_send_stop", "idempotent_stop", "stale_handle", "port_and_root_reopen",
                         "1000_send_batch", "1000_file_snapshot_pages", "1000_disk_hashes"],
              "maxCallMilliseconds": {name: round(max(t for n, t in timings if n == name), 3) for name in sorted({n for n, _ in timings})},
              "librarySha256": hashlib.sha256(args.library.read_bytes()).hexdigest(), "libraryBytes": args.library.stat().st_size}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
