"""Prepare or run an explicit Windows -> Android network interruption check.

No Wi-Fi, firewall, adapter or device setting is changed. Manual mode requires
fresh operator checkpoint responses. Self-test uses owned loopback services and
an injected relay cut; its report never claims real network/device validation.
"""
import argparse
from collections import deque
import ctypes as c
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import select
import socket
import subprocess
import threading
import time
import uuid

PACKAGE = "io.github.beetman.xdremux.transferdev"
SIZE = 2 * 1024 * 1024
NAMES = ("pnet-one.bin", "pnet-two.bin")


def check(value, message):
    if not value:
        raise RuntimeError(message)
    return value


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def save(path, value):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def private_ipv4(value):
    address = ipaddress.ip_address(value)
    check(address.version == 4 and address.is_private and not address.is_loopback
          and not address.is_multicast and not address.is_unspecified, "Private device IPv4 required")
    return str(address)


def validate_answer(value, request):
    check(value.get("checkpoint_id") == request["checkpoint_id"], "Stale checkpoint response")
    check(value.get("action") == request["action"], "Wrong checkpoint action")
    if request["action"] in ("confirm-initial", "confirm-retry"):
        check(str(value.get("fingerprint", "")).upper() == request["fingerprint"], "Fingerprint confirmation mismatch")
    if request["action"] == "reconnect":
        private_ipv4(value.get("host", ""))
        check(isinstance(value.get("device"), str) and value["device"].strip(), "Explicit connected ADB device required")
    return value


class Native:
    def __init__(self, library):
        self.library = c.CDLL(str(library))
        signatures = {
            "abi_version": (c.c_uint32, []),
            "create": (c.c_int32, [c.c_void_p, c.c_size_t, c.POINTER(c.c_uint64)]),
            "submit": (c.c_int32, [c.c_uint64, c.c_void_p, c.c_size_t, c.POINTER(c.c_uint64)]),
            "poll": (c.c_int32, [c.c_uint64, c.c_uint32, c.c_uint32, c.POINTER(c.c_void_p)]),
            "free_string": (c.c_int32, [c.c_void_p]),
            "stop": (c.c_int32, [c.c_uint64]), "release": (c.c_int32, [c.c_uint64]),
        }
        self.api = {}
        self.handles = {}
        for name, (result, parameters) in signatures.items():
            fn = getattr(self.library, "xdremux_transfer_" + name)
            fn.restype, fn.argtypes = result, parameters
            self.api[name] = fn
        check(self.api["abi_version"]() == 65539, "ABI 1.3 required")

    def create(self, root):
        data = json.dumps({"root": str(root), "bind": "127.0.0.1:0", "alias": "Owned network fixture"}).encode()
        handle = c.c_uint64()
        check(self.api["create"](data, len(data), c.byref(handle)) == 0, "Native create failed")
        h = handle.value
        self.handles[h] = {"page": {}, "results": {}, "events": deque(maxlen=256)}
        self.wait(lambda: self.handles[h]["page"].get("phase") in (1, 3))
        check(self.handles[h]["page"].get("phase") == 1, "Native startup failed")
        return h

    def pump(self):
        for h, state in self.handles.items():
            pointer = c.c_void_p()
            check(self.api["poll"](h, 128, 2097152, c.byref(pointer)) == 0, "Native poll failed")
            try:
                page = json.loads(c.string_at(pointer))
            finally:
                check(self.api["free_string"](pointer) == 0, "Native buffer release failed")
            state["page"] = page
            check(not page["lost"], "Native overflow: reconcile manually; no mutation replay")
            for record in page["records"]:
                body = record["body"]
                if body.get("kind") == "result":
                    state["results"][body["operation_id"]] = body
                elif body.get("kind") == "event":
                    state["events"].append(body["event"])
                elif body.get("kind") in ("fatal", "start_failed"):
                    raise RuntimeError("Native runtime failed")

    def wait(self, action, seconds=45):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.pump()
            value = action()
            if value:
                return value
            time.sleep(.02)
        raise RuntimeError("Observation deadline; outcome must be reconciled, not replayed")

    def query(self, h, command, **fields):
        data = json.dumps({"command": command, **fields}, ensure_ascii=False).encode()
        operation = c.c_uint64()
        check(self.api["submit"](h, data, len(data), c.byref(operation)) == 0, "Native submit failed")
        result = self.wait(lambda: self.handles[h]["results"].pop(operation.value, None))
        check(result["error"] is None, "Native command failed: " + str(result["error"]))
        return result["data"]

    def ready(self, h):
        return self.handles[h]["page"]["ready"]

    def stop(self, h):
        if h not in self.handles:
            return
        check(self.api["stop"](h) == 0, "Native stop failed")
        self.wait(lambda: self.handles[h]["page"].get("phase") == 3)
        check(self.api["release"](h) == 0, "Native handle release failed")
        del self.handles[h]


class Relay:
    """Opaque TLS byte relay, loopback-only, with a bounded upload window.

    Manual mode only pauses/resumes forwarding; only self-test calls cut().
    No TLS termination, certificate substitution or synthetic HTTP response.
    """
    def __init__(self, host, port):
        self.target = (host, port)
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.listener.settimeout(.1)
        self.address = "127.0.0.1:" + str(self.listener.getsockname()[1])
        self.paused = threading.Event()
        self.closed = threading.Event()
        self.threads = []
        self.sockets = []
        self.lock = threading.Lock()
        thread = threading.Thread(target=self.accept, daemon=True)
        self.threads.append(thread)
        thread.start()

    def accept(self):
        while not self.closed.is_set():
            try:
                client, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                remote = socket.create_connection(self.target, timeout=5)
                remote.settimeout(5)
                client.settimeout(5)
                with self.lock:
                    self.sockets.extend([client, remote])
                thread = threading.Thread(target=self.forward, args=(client, remote), daemon=True)
                self.threads.append(thread)
                thread.start()
            except OSError:
                client.close()

    def forward(self, client, remote):
        try:
            while not self.closed.is_set():
                watched = [remote] if self.paused.is_set() else [client, remote]
                ready, _, _ = select.select(watched, [], [], .05)
                for source in ready:
                    target = remote if source is client else client
                    data = source.recv(4096)
                    if not data:
                        return
                    target.sendall(data)
                    if source is client:
                        time.sleep(.01)  # roughly 400 KiB/s; payloads are 2 MiB
        except OSError:
            pass  # Native TLS/HTTP must report the actual broken connection.
        finally:
            client.close()
            remote.close()

    def cut(self):
        self.closed.set()
        self.listener.close()
        with self.lock:
            for connection in self.sockets:
                try:
                    connection.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                connection.close()
        for thread in self.threads:
            thread.join(timeout=6)


class LocalReceiver:
    def __init__(self, native, root, manifest):
        self.native, self.root, self.manifest = native, root, manifest
        self.handle = None

    def start(self, host=None, device=None):
        if self.handle is not None:
            self.native.stop(self.handle)
        self.handle = self.native.create(self.root)
        return self.native.ready(self.handle)

    def progress(self):
        receipts = self.native.query(self.handle, "receipts", limit=64)
        incoming = self.root / ".incoming"
        partial = sum(p.stat().st_size for p in incoming.rglob("*") if p.is_file())
        return {"receipts": receipts, "partial": partial}

    def accept(self, names, sender_fp):
        page = self.native.query(self.handle, "snapshot", limit=64)
        pending = [t for t in page["transfers"] if t["phase"] == "pending"]
        if not pending:
            return False
        check(len(pending) == 1, "Only one owned offer expected")
        transfer = pending[0]
        check(transfer["peer_fingerprint"].upper() == sender_fp, "Unexpected sender identity")
        files = self.native.query(self.handle, "transfer", transfer_id=transfer["id"], limit=64)["files"]
        validate_offer(files, names, self.manifest)
        self.native.query(self.handle, "decide", transfer_id=transfer["id"], accept=True)
        return True

    def audit(self):
        result = []
        for receipt in self.native.query(self.handle, "receipts", limit=64):
            lease = self.native.query(self.handle, "acquire_receipt", receipt_id=receipt["id"])
            try:
                path = Path(lease["path"])
                result.append({"name": receipt["name"], "size": path.stat().st_size, "sha256": digest(path)})
            finally:
                self.native.query(self.handle, "release_receipt", lease_id=lease["lease_id"])
        return result

    def stop(self):
        if self.handle is not None:
            self.native.stop(self.handle)
            self.handle = None


def validate_offer(files, names, manifest):
    check(len(files) == len(names) and {f["name"] for f in files} == set(names), "Unexpected offer files")
    for f in files:
        check(f["size"] == manifest[f["name"]]["size"] and f["sha256"] == manifest[f["name"]]["sha256"], "Unexpected fixture metadata")


class AndroidReceiver:
    def __init__(self, adb, device, host, port, run, root, manifest):
        self.adb_path, self.device, self.host, self.port = adb, device, host, port
        self.remote = f"/sdcard/Android/data/{PACKAGE}/files/p32-{run}"
        self.run, self.root, self.manifest = run, root, manifest

    def adb(self, *parts):
        result = subprocess.run([self.adb_path, "-s", self.device, *parts], capture_output=True,
            text=True, encoding="utf-8", errors="replace", timeout=15)
        check(result.returncode == 0, "ADB unavailable; provide a reconnected device explicitly")
        return result.stdout

    def state(self):
        state = json.loads(self.adb("exec-out", "cat", self.remote + "/status.json"))
        check(state.get("run") == self.run, "Wrong installed test run")
        return state

    def command(self, action, **fields):
        identity = uuid.uuid4().hex
        request = self.root / "device-command.json"
        save(request, {"id": identity, "run": self.run, "action": action, **fields})
        self.adb("push", str(request), self.remote + "/command.tmp")
        self.adb("shell", "mv", self.remote + "/command.tmp", self.remote + "/command.json")
        end = time.monotonic() + 20
        while time.monotonic() < end:
            state = self.state()
            if state.get("acknowledged") == identity:
                check(not state.get("error"), "Fixture command failed")
                return state
            time.sleep(.15)
        raise RuntimeError("Device command outcome unknown; do not replay automatically")

    def start(self, host=None, device=None):
        self.host, self.device = host or self.host, device or self.device
        ready = self.command("network_start", interface=self.host)["ready"]
        check(ready["address"] == f"{self.host}:{self.port}", "Test fixture port/interface mismatch")
        return ready

    def progress(self):
        state = self.state()
        return {"receipts": list(state["inbox"].values()), "partial": state["incoming"]["bytes"]}

    def accept(self, names, sender_fp):
        state = self.state()
        pending = [t for t in state["transfers"] if t["phase"] == "pending"]
        if not pending:
            return False
        check(len(pending) == 1, "Unexpected pending offers")
        transfer = pending[0]
        check(transfer["peer_fingerprint"].upper() == sender_fp, "Unexpected sender identity")
        validate_offer(state["files"][transfer["id"]], names, self.manifest)
        self.command("accept_network", transferId=transfer["id"], fingerprint=sender_fp,
            expected=[self.manifest[name] for name in names])
        return True

    def audit(self):
        rows = self.command("audit")["audited"]
        checked = []
        for row in rows:
            name = row["name"]
            check(name in self.manifest, "Unexpected receiver receipt")
            path = self.root / ("readback-" + name)
            self.adb("pull", self.remote + "/audit/" + name, str(path))
            checked.append({"name": name, "size": path.stat().st_size, "sha256": digest(path)})
            check(checked[-1] == row, "App and independent host readback disagree")
        return checked

    def stop(self):
        self.command("stop")


def checkpoint(native, root, action, seconds=600, **fields):
    request = {"checkpoint_id": uuid.uuid4().hex, "action": action, **fields}
    save(root / "checkpoint.json", request)
    response = root / ("answer-" + request["checkpoint_id"] + ".json")
    print("Checkpoint " + action + "; respond in " + str(response), flush=True)
    return native.wait(lambda: validate_answer(json.loads(response.read_text(encoding="utf-8")), request)
        if response.exists() else None, seconds)


def run(args):
    root = args.directory.resolve(strict=True)
    manifest_data = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    run_id = manifest_data["run"]
    check(root.name == "pnet-" + run_id and re.fullmatch("[0-9a-f]{16}", run_id), "Owned prepared directory required")
    check(not (root / "result.json").exists() and not (root / "sender").exists(), "Use a fresh prepared run; retry plans cannot survive process restart")
    manifest = {entry["name"]: entry for entry in manifest_data["files"]}
    check(set(manifest) == set(NAMES), "Fixed synthetic fixture set required")
    for name, entry in manifest.items():
        path = root / name
        check(path.is_file() and not path.is_symlink() and path.stat().st_size == SIZE
              and entry["size"] == SIZE and digest(path) == entry["sha256"], "Prepared source changed")
    report = {"schema": 1, "passed": False, "mode": args.mode,
        "phase": "startup",
        "realNetworkValidation": "not_run" if args.mode == "self-test" else "incomplete",
        "direction": "Windows native sender -> receiver", "networkSettingsChangedByScript": False,
        "relayTerminatesTls": False, "relayCutInjected": False, "checks": [],
        "scope": "controlled_loopback_rehearsal" if args.mode == "self-test" else "operator_outage_and_explicit_retry_via_opaque_relay",
        "phoneOperated": args.mode == "manual",
        "limits": ["raw native ABI sender; ordinary Flutter page/worker UI not exercised",
            "opaque relay provides a controlled upload window; not a direct-path performance test",
            "manual Wi-Fi/settings interaction can also trigger Android foreground-stop policy",
            "two failed TCP probes and operator confirmation do not isolate the OS-level outage cause",
            "Windows-to-Android only; reverse direction and official-client coexistence remain pending"]}
    native, receiver, relay = None, None, None
    try:
        native = Native(args.library.resolve(strict=True))
        sender = native.create(root / "sender")
        if args.mode == "self-test":
            receiver = LocalReceiver(native, root / "receiver", manifest)
        else:
            check(args.adb and args.device and args.host, "Explicit ADB/device/host required")
            receiver = AndroidReceiver(args.adb, args.device, private_ipv4(args.host), args.port, run_id, root, manifest)
        ready = receiver.start()
        initial_endpoint = ready["address"]
        original_fp = ready["fingerprint"].upper()
        check(not receiver.progress()["receipts"], "Receiver run must start with an empty inbox")
        if args.mode == "manual":
            report["phase"] = "confirm-initial"
            checkpoint(native, root, "confirm-initial", fingerprint=original_fp,
                instruction="Compare full fingerprint on the test app; create response only after confirming.")
        host, port = ready["address"].rsplit(":", 1)
        relay = Relay(host, int(port))
        peer = native.query(sender, "probe", address=relay.address)
        check(peer["fingerprint"].upper() == original_fp, "TLS identity through opaque relay")
        transfer = native.query(sender, "send", peer=peer, paths=[str(root / name) for name in NAMES])["transfer_id"]
        report["phase"] = "first-ack-and-partial"
        sender_fp = native.ready(sender)["fingerprint"].upper()
        native.wait(lambda: receiver.accept(list(NAMES), sender_fp))

        def partial_after_ack():
            page = native.query(sender, "transfer", transfer_id=transfer, limit=64)
            acked = [f["name"] for f in page["files"] if f["phase"] == "sent"]
            check(page["transfer"]["phase"] != "completed", "Outage window missed; no network pass")
            if len(acked) != 1:
                return None
            state = receiver.progress()
            return (acked, state) if len(state["receipts"]) == 1 and 0 < state["partial"] < SIZE // 2 else None

        acked, partial = native.wait(partial_after_ack, 60)
        relay.paused.set()
        report["ackedBeforeOutage"] = acked
        report["partialBytesBeforeOutage"] = partial["partial"]
        report["checks"].append("one_ack_and_actual_partial_before_outage")
        if args.mode == "self-test":
            relay.cut()
            report["relayCutInjected"] = True
            receiver.stop()
        else:
            report["phase"] = "network-down"
            checkpoint(native, root, "network-down", seconds=20,
                instruction="Manually disconnect phone Wi-Fi NOW, then acknowledge. Do not reconnect until next checkpoint.")
            # Observe the endpoint becoming unreachable; no synthetic disconnect.
            for _ in range(2):
                try:
                    with socket.create_connection((host, int(port)), timeout=1):
                        raise RuntimeError("Endpoint still reachable; real outage not observed")
                except OSError:
                    pass
            relay.paused.clear()

        def failed():
            page = native.query(sender, "transfer", transfer_id=transfer, limit=64)
            return page if page["transfer"]["phase"] in ("failed", "completed") else None

        report["phase"] = "wait-for-native-failure"
        terminal = native.wait(failed, 330)
        check(terminal["transfer"]["phase"] == "failed", "Transfer succeeded across outage; retry scenario not exercised")
        failure = native.query(sender, "send_report", transfer_id=transfer)
        check(failure["error"] in ("network", "timed_out", "remote_failure", "cancelled"), "Unexpected failure cause")
        check({f["name"] for f in failure["files"]} == set(acked), "ACK set changed unexpectedly")
        report["failureCode"] = failure["error"]
        if args.mode == "manual":
            report["phase"] = "reconnect"
            answer = checkpoint(native, root, "reconnect",
                instruction="Manually reconnect Wi-Fi and ADB, unlock/open the independent test app; provide current host/device.")
            ready = receiver.start(answer["host"], answer["device"])
        else:
            ready = receiver.start()
        check(ready["fingerprint"].upper() == original_fp, "Receiver identity changed; do not retry")
        report["endpointChanged"] = ready["address"] != initial_endpoint
        check(not args.require_new_endpoint or report["endpointChanged"], "Endpoint did not change; switch scenario not exercised")
        check({r["name"] for r in receiver.progress()["receipts"]} == set(acked)
              and receiver.progress()["partial"] == 0, "Committed receipt/staging recovery mismatch")
        if args.mode == "manual":
            report["phase"] = "confirm-retry"
            checkpoint(native, root, "confirm-retry", fingerprint=original_fp,
                instruction="Compare the full fingerprint again at the current endpoint before explicit retry.")
        peer = native.query(sender, "probe", address=ready["address"])
        check(peer["fingerprint"].upper() == original_fp, "Reconnect pin mismatch")
        retry = native.query(sender, "retry_send", transfer_id=transfer, peer=peer)["transfer_id"]
        report["phase"] = "explicit-retry"
        remaining = [name for name in NAMES if name not in acked]
        native.wait(lambda: receiver.accept(remaining, sender_fp))
        native.wait(lambda: native.query(sender, "transfer", transfer_id=retry, limit=64)["transfer"]["phase"] in ("completed", "failed"))
        final = native.query(sender, "send_report", transfer_id=retry)
        check(final["error"] is None and {f["name"] for f in final["files"]} == set(remaining), "Retry must send only unACKed files")
        report["phase"] = "independent-readback"
        readback = receiver.audit()
        check(len(readback) == 2 and sorted(readback, key=lambda x: x["name"]) == sorted(manifest.values(), key=lambda x: x["name"]), "Duplicate/missing/corrupt final receipts")
        check(all(digest(root / name) == manifest[name]["sha256"] for name in NAMES), "Sources changed")
        report.update({"passed": True, "realNetworkValidation": "not_run" if args.mode == "self-test" else "covered_case_passed",
            "phase": "complete",
            "retryFiles": remaining, "independentHashes": True, "receivedFiles": 2,
            "sameIdentity": True, "librarySha256": digest(args.library)})
        report["checks"].extend(["failed_transfer_preserves_ack_set", "staging_clean_after_explicit_restart",
            "same_identity_explicit_retry_excludes_acked", "two_unique_receipts_and_independent_hashes", "sources_unchanged"])
    except Exception as error:
        report["error"] = type(error).__name__  # no paths/PINs/raw requests in report
        raise
    finally:
        if relay:
            relay.cut()
        try:
            if receiver:
                receiver.stop()
        except Exception:
            report["receiverCleanupUnconfirmed"] = True
        if native:
            for handle in list(native.handles):
                try:
                    native.stop(handle)
                except Exception:
                    report["nativeCleanupUnconfirmed"] = True
        if report.get("receiverCleanupUnconfirmed") or report.get("nativeCleanupUnconfirmed"):
            report["passed"] = False
            report["phase"] = "cleanup-unconfirmed"
            report["realNetworkValidation"] = "not_run" if args.mode == "self-test" else "incomplete"
        save(root / "result.json", report)
    check(report["passed"], "Run did not finish with confirmed cleanup; inspect result.json")


def prepare(directory):
    directory = directory.absolute()
    check(re.fullmatch(r"pnet-[0-9a-f]{16}", directory.name), "Directory name must be pnet-<16 lowercase hex>")
    directory.mkdir(parents=False, exist_ok=False)
    entries = []
    for index, name in enumerate(NAMES):
        path = directory / name
        block = bytes((i + index) % 251 for i in range(65536))
        with path.open("xb") as output:
            for _ in range(SIZE // len(block)):
                output.write(block)
        entries.append({"name": name, "size": SIZE, "sha256": digest(path)})
    save(directory / "manifest.json", {"schema": 1, "run": directory.name[5:], "files": entries,
        "deviceValidation": "not_run"})
    print(json.dumps({"prepared": True, "run": directory.name[5:], "deviceValidation": "not_run"}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    prep.add_argument("--directory", required=True, type=Path)
    answer = sub.add_parser("answer")
    answer.add_argument("--directory", required=True, type=Path)
    answer.add_argument("--checkpoint-id", required=True)
    answer.add_argument("--action", choices=["confirm-initial", "network-down", "reconnect", "confirm-retry"], required=True)
    answer.add_argument("--fingerprint")
    answer.add_argument("--host")
    answer.add_argument("--device")
    execute = sub.add_parser("run")
    execute.add_argument("--directory", required=True, type=Path)
    execute.add_argument("--library", required=True, type=Path)
    execute.add_argument("--mode", choices=["manual", "self-test"], required=True)
    execute.add_argument("--adb")
    execute.add_argument("--device")
    execute.add_argument("--host")
    execute.add_argument("--port", type=int, default=53326)
    execute.add_argument("--require-new-endpoint", action="store_true",
                         help="Require a changed IP/port rather than only an outage/reconnect")
    args = parser.parse_args()
    if args.command == "prepare":
        prepare(args.directory)
    elif args.command == "answer":
        root = args.directory.resolve(strict=True)
        check(re.fullmatch(r"pnet-[0-9a-f]{16}", root.name), "Owned run directory required")
        request = json.loads((root / "checkpoint.json").read_text(encoding="utf-8"))
        check(re.fullmatch(r"[0-9a-f]{32}", request.get("checkpoint_id", "")), "Invalid checkpoint identifier")
        value = {"checkpoint_id": args.checkpoint_id, "action": args.action,
            "fingerprint": args.fingerprint, "host": args.host, "device": args.device}
        validate_answer(value, request)
        response = root / ("answer-" + request["checkpoint_id"] + ".json")
        check(not response.exists(), "Checkpoint already answered")
        save(response, value)
    else:
        check(1 <= args.port <= 65535, "Valid explicit port required")
        run(args)


if __name__ == "__main__":
    main()
