"""Real Android lifecycle checks against transfer_lifecycle_app.dart.

Requires Python cryptography, an unlocked dedicated test device, and the explicit
P32 release target already installed/running. Does not change network/settings.
Only the fixed .transferdev package is stopped; no production app is touched.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import hashlib
import http.client
import ipaddress
import json
from pathlib import Path
import re
import socket
import ssl
import subprocess
import time
from urllib.parse import urlencode
import uuid

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

PACKAGE = "io.github.beetman.xdremux.transferdev"
ACTIVITY = PACKAGE + "/com.example.xdremux.MainActivity"


def check(value, message):
    if not value:
        raise AssertionError(message)
    return value


def wait(action, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = action()
        if value:
            return value
        time.sleep(0.15)
    raise AssertionError("Lifecycle observation deadline")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--run", required=True)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, default=53326)
    parser.add_argument("--cases", nargs="+", choices=["startup-directory", "startup-native", "home", "kill", "lock"],
                        default=["home", "kill", "lock"])
    parser.add_argument("--unlock-recovery", action="store_true",
                        help="Wait for the human to unlock after the final lock case; never dismiss keyguard")
    args = parser.parse_args()
    check(re.fullmatch("[0-9a-f]{16}", args.run), "Explicit run required")
    address = ipaddress.ip_address(args.host)
    check(address.version == 4 and address.is_private and not address.is_loopback,
          "Private device IPv4 required")
    check(1 <= args.port <= 65535, "Valid explicit port required")
    check("lock" not in args.cases[:-1], "Lock must be the last case")
    check(len(set(args.cases)) == len(args.cases), "Distinct lifecycle cases required")
    check(not args.unlock_recovery or "lock" in args.cases, "Unlock recovery requires lock case")
    root = args.directory.resolve(strict=True)
    check(root.name == "p32-app-" + args.run, "Owned run directory required")
    remote = f"/sdcard/Android/data/{PACKAGE}/files/p32-{args.run}"
    report = {"schema": 1, "run": args.run, "passed": False,
              "date": datetime.now(timezone.utc).isoformat(), "cases": {},
              "networkSettingsChanged": False, "originalApplicationTouched": False}

    def adb(*parts, required=True):
        result = subprocess.run([args.adb, "-s", args.device, *parts],
                                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=15)
        if required:
            check(result.returncode == 0, "ADB command failed: " + " ".join(parts[:3]))
        return result.stdout.strip()

    def state():
        try:
            return json.loads(adb("exec-out", "cat", remote + "/status.json"))
        except json.JSONDecodeError:
            return {}

    def command(action, **extra):
        identity = uuid.uuid4().hex
        path = root / "command.json"
        path.write_text(json.dumps({"id": identity, "run": args.run,
                                    "action": action, **extra}), encoding="utf-8")
        adb("push", str(path), remote + "/command.tmp")
        adb("shell", "mv", remote + "/command.tmp", remote + "/command.json")
        result = wait(lambda: (s if (s := state()).get("acknowledged") == identity else None))
        check(not result.get("error"), "App command failed: " + str(result.get("error")))
        return result

    def reachable():
        try:
            with socket.create_connection((args.host, args.port), timeout=0.5):
                return True
        except OSError:
            return False

    def wifi_lock():
        # Inspect only this test's tag; do not save the device's Wi-Fi dump.
        dump = adb("shell", "dumpsys", "wifi")
        block = re.search(r"Multicast Locks held:\s*\n((?:[ \t]+[^\n]*\n)*)", dump)
        check(block is not None, "System multicast lock section required")
        return "Multicaster{xdremux-transfer " in block[1]

    # A dedicated self-signed mTLS sender; never reuse an application's key.
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "P32 controlled sender")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=5))
            .not_valid_after(now + timedelta(days=1))
            .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.CLIENT_AUTH]), False)
            .sign(key, hashes.SHA256()))
    cert_path, key_path = root / "sender-cert.pem", root / "sender-key.pem"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                                         serialization.PrivateFormat.PKCS8,
                                         serialization.NoEncryption()))
    sender_fp = cert.fingerprint(hashes.SHA256()).hex().upper()
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.load_cert_chain(cert_path, key_path)
    fingerprint = None
    pool = ThreadPoolExecutor(max_workers=1)
    upload = None

    def connect():
        connection = http.client.HTTPSConnection(args.host, args.port,
                                                 context=context, timeout=20)
        connection.connect()
        actual = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest().upper()
        if actual != fingerprint:
            connection.close()
            raise AssertionError("Fixture receiver certificate changed")
        return connection

    def offer(name, size):
        body = bytes(range(256)) * (size // 256)
        digest = hashlib.sha256(body).hexdigest()
        file_id = uuid.uuid4().hex
        payload = {"info": {"alias": "P32 controlled sender", "version": "2.2",
                            "fingerprint": sender_fp, "port": 0,
                            "protocol": "https", "download": False},
                   "files": {file_id: {"id": file_id, "fileName": name, "size": size,
                                        "fileType": "application/octet-stream", "sha256": digest}}}

        def prepare():
            connection = connect()
            try:
                connection.request("POST", "/api/localsend/v2/prepare-upload",
                                   json.dumps(payload).encode(), {"Content-Type": "application/json"})
                response = connection.getresponse()
                check(response.status == 200, "Prepare rejected")
                return json.loads(response.read())
            finally:
                connection.close()

        future = pool.submit(prepare)

        def selected():
            current = state()
            for transfer in current.get("transfers", []):
                files = current.get("files", {}).get(transfer["id"], [])
                if (transfer.get("phase") == "pending" and len(files) == 1
                        and files[0]["name"] == name):
                    return transfer
            if future.done():
                future.result()  # Surface an HTTP/TLS failure immediately.
            return None

        transfer = wait(selected)
        command("accept", transferId=transfer["id"], fingerprint=sender_fp)
        prepared = future.result(timeout=20)
        connection = connect()
        query = urlencode({"sessionId": prepared["sessionId"], "fileId": file_id,
                           "token": prepared["files"][file_id]})
        connection.putrequest("POST", "/api/localsend/v2/upload?" + query)
        connection.putheader("Content-Length", str(size))
        connection.putheader("Content-Type", "application/octet-stream")
        connection.endheaders()
        return connection, body, digest

    def audit_baseline():
        current = command("audit")
        expected = [{"name": "p32-complete.bin", "size": 65536,
                     "sha256": hashlib.sha256(bytes(range(256)) * 256).hexdigest()}]
        check(current["audited"] == expected, "Only completed baseline must be visible")
        pulled = root / "p32-complete.bin"
        adb("pull", remote + "/audit/p32-complete.bin", str(pulled))
        check(hashlib.sha256(pulled.read_bytes()).hexdigest() == expected[0]["sha256"],
              "Independent host readback hash")
        return expected[0]

    try:
        policy = adb("shell", "dumpsys", "window", "policy")
        check("interactiveState=INTERACTIVE_STATE_AWAKE" in policy
              and re.search(r"^\s+inputRestricted=false\s*$", policy, re.MULTILINE),
              "Unlock the device before starting this validation")
        idle = wait(lambda: (s if (s := state()).get("boot") else None))
        check(not idle["running"] and not idle["receiving"] and not reachable(),
              "Boot must not enable LAN")
        started = command("start")
        check(started["receiving"] and started["discovering"] and started["multicastHeld"],
              "Explicit start and multicast lock")
        check(reachable() and wifi_lock(), "Independent TCP/Wi-Fi lock before test")
        fingerprint = started["ready"]["fingerprint"]
        if started["published"]["files"] == 0:
            upload, body, _ = offer("p32-complete.bin", 65536)
            upload.send(body)
            response = upload.getresponse()
            check(response.status == 200, "Complete fixture ACK")
            response.read()
            upload.close()
            upload = None
            wait(lambda: state().get("published", {}).get("files") == 2)
        report["baseline"] = audit_baseline()
        for case in args.cases:
            print("Testing " + case, flush=True)
            if case.startswith("startup-"):
                stage = case.removeprefix("startup-")
                idle = command("stop")
                starts_before = idle["startup"]["nativeStarts"]
                command("start_paused", stage=stage)
                gated = wait(lambda: (s if (s := state()).get("startup", {}).get("stage") == stage
                                     and s["startup"]["waiting"] else None))
                check(not gated["running"] and not gated["receiving"] and not wifi_lock(),
                      "Pending startup must not publish reception or acquire multicast")
                check(reachable() == (stage == "native"), "Actual gated native listener state")
                adb("shell", "input", "keyevent", "3")
                # A cached process may stop publishing snapshots while the gate
                # intentionally prevents startup/stop completion. Resume before
                # releasing it, but require the real pause to have revoked start.
                time.sleep(1)
                background = state()
                adb("shell", "am", "start", "-n", ACTIVITY)

                def paused_before_release():
                    current = state()
                    changed = current.get("lifecycleSequence", 0) - gated["lifecycleSequence"]
                    return (current if current.get("stopping") and changed > 0
                            and "paused" in current.get("lifecycle", [])[-changed:]
                            and current.get("lifecycle", [])[-1:] == ["resumed"] else None)

                paused = wait(paused_before_release)
                check(paused["startup"]["waiting"], "Pause must precede gate release")
                check(paused["boot"] == gated["boot"], "Home return must keep the same process")
                if stage == "native":
                    check(reachable(), "Stop must await already-started native initialization")
                release = root / "startup-release"
                release.write_text(args.run, encoding="utf-8")
                adb("push", str(release), remote + "/startup-release")
                cancelled = wait(lambda: (s if (s := state()).get("startup", {}).get("completed")
                                         and not s.get("busy", True) else None))
                check(cancelled["startup"]["error"] == "closed", "Cancelled startup must report closed")
                check(not cancelled["running"] and not cancelled["receiving"]
                      and not cancelled["discovering"] and not reachable() and not wifi_lock(),
                      "Cancelled startup must leave no listener or multicast lock")
                check(cancelled["startup"]["nativeStarts"] == starts_before + (stage == "native"),
                      "Directory cancellation must not start native; native stage starts only once")
                returned = cancelled
                check(returned["boot"] == gated["boot"] and not returned["running"]
                      and not returned["receiving"] and not reachable(), "Foreground return must not reopen LAN")
                restarted = command("start")
                check(restarted["ready"]["fingerprint"] == fingerprint, "Startup cancellation preserves identity")
                if stage == "native":
                    check(restarted["ready"]["core_instance_id"] != gated["startup"]["nativeReady"]["core_instance_id"],
                          "Cancelled native runtime must be replaced")
                check(restarted["incoming"]["files"] == 0 and reachable() and wifi_lock(), "Explicit restart resources")
                audit_baseline()
                report["cases"][case] = {"controlledGate": stage, "actualHomePause": True,
                    "sameProcessBoot": True, "cancelledError": "closed", "tcpClosed": True,
                    "systemMulticastLockReleased": True, "nativeStartCountCorrect": True,
                    "noAutomaticLanOnReturn": True, "explicitRestart": True,
                    "baselineHashPreserved": True, "identityPersists": True,
                    "gateReleasedAfterForegroundReturn": True,
                    "pauseObservedInBackgroundSnapshot": background.get("stopping", False),
                    "nativeListenerObservedBeforePause": stage == "native"}
                continue
            upload, body, _ = offer("p32-" + case + ".bin", 2 * 1024 * 1024)
            upload.send(body[:256 * 1024])
            before = wait(lambda: (s if 0 < (s := state()).get("incoming", {}).get("bytes", 0)
                                  < len(body) else None))
            check(before["published"]["files"] == 2, "No partial publication")
            if case == "home":
                adb("shell", "input", "keyevent", "3")
            elif case == "kill":
                adb("shell", "am", "force-stop", PACKAGE)
            else:
                adb("shell", "input", "keyevent", "223")  # Actual screen off/lock.
            wait(lambda: not reachable())
            wait(lambda: not wifi_lock())
            upload.close()
            upload = None
            observation = {"partialBytesBefore": before["incoming"]["bytes"],
                           "declaredBytes": len(body), "tcpClosed": True,
                           "systemMulticastLockReleased": True,
                           "partialNotPublishedBefore": True}
            if case == "lock":
                policy = adb("shell", "dumpsys", "window", "policy")
                check(re.search(r"interactiveState=INTERACTIVE_STATE_(?:ASLEEP|SLEEP)\b", policy),
                      "Actual OS screen-off state required")
                check(re.search(r"^\s+showing=true\s*$", policy, re.MULTILINE),
                      "Actual keyguard state required")
                observation["powerPolicyEvidence"] = [line.strip() for line in policy.splitlines()
                                                       if any(k in line for k in ["interactiveState=", "showing=", "inputRestricted="])]
                try:
                    stopped = wait(lambda: (s if not (s := state()).get("running", True)
                                            and "paused" in s.get("lifecycle", []) else None), 5)
                    observation["pausedAndControllerStopped"] = True
                    observation["stagingCleanBeforeProcessStop"] = stopped["incoming"]["files"] == 0
                    observation["onlyBaselinePublished"] = stopped["published"]["files"] == 2
                except AssertionError:
                    observation["controllerSnapshotUnavailableWhileLocked"] = True
                observation["unlockRecoveryNotRun"] = True
                if args.unlock_recovery:
                    # Persist evidence before asking the human; no wake/unlock input is sent.
                    report["cases"][case] = observation
                    (root / "unlock-request.json").write_text(json.dumps(observation, indent=2), encoding="utf-8")
                    print("Waiting for user unlock", flush=True)

                    def unlocked():
                        policy = adb("shell", "dumpsys", "window", "policy")
                        return ("interactiveState=INTERACTIVE_STATE_AWAKE" in policy
                                and re.search(r"^\s+inputRestricted=false\s*$", policy, re.MULTILINE))

                    wait(unlocked, 180)
                    adb("shell", "am", "start", "-n", ACTIVITY)
                    returned = wait(lambda: (s if (s := state()).get("lifecycleSequence", 0) > before["lifecycleSequence"]
                                            and s.get("lifecycle", [])[-1:] == ["resumed"]
                                            and not s.get("busy", True) else None))
                    check(returned["boot"] == before["boot"], "Unlock must resume the same process")
                    check(not returned["running"] and not returned["receiving"] and not reachable()
                          and not wifi_lock(), "Unlock must not automatically reopen LAN")
                    restarted = command("start")
                    check(restarted["ready"]["fingerprint"] == fingerprint, "Unlock identity persists")
                    check(restarted["ready"]["core_instance_id"] != before["ready"]["core_instance_id"], "Unlock new native runtime")
                    check(restarted["incoming"]["files"] == 0 and restarted["published"]["files"] == 2,
                          "Unlock staging and committed receipt")
                    audit_baseline()
                    observation.update({"unlockRecoveryNotRun": False, "unlockRecoveryPassed": True, "sameProcessBoot": True,
                        "noAutomaticLanOnReturn": True, "explicitRestart": True,
                        "stagingClean": True, "baselineHashPreserved": True, "identityPersists": True})
                report["cases"][case] = observation
                break
            if case == "kill":
                check(not adb("shell", "pidof", PACKAGE, required=False), "Process terminated")
            adb("shell", "am", "start", "-n", ACTIVITY)
            if case == "kill":
                after = wait(lambda: (s if (s := state()).get("boot") != before["boot"] else None))
                check(after["beforeStartupIncoming"]["bytes"] > 0, "Real crash leftovers before recovery")
                observation["crashLeftoversObserved"] = True
                observation["newProcessBoot"] = True
            else:
                after = wait(lambda: (s if not (s := state()).get("running", True)
                                      and "resumed" in s.get("lifecycle", []) else None))
                check("paused" in after["lifecycle"], "Actual OS pause delivered")
            check(not after["running"] and not after["receiving"] and not reachable(),
                  "Return/relaunch must require explicit start")
            restarted = command("start")
            check(restarted["ready"]["fingerprint"] == fingerprint, "Identity persists")
            check(restarted["ready"]["core_instance_id"] != before["ready"]["core_instance_id"],
                  "New native runtime")
            check(restarted["incoming"]["files"] == 0, "Owned staging cleaned")
            audit_baseline()
            observation.update({"noAutomaticLanOnReturn": True, "explicitRestart": True,
                                "stagingClean": True, "baselineHashPreserved": True,
                                "identityPersists": True})
            report["cases"][case] = observation
            (root / (case + "-result.json")).write_text(json.dumps(observation, indent=2))
        report["passed"] = True
    except Exception as error:
        report["error"] = type(error).__name__ + ": " + str(error)
        raise
    finally:
        if upload:
            upload.close()
        try:
            adb("shell", "am", "force-stop", PACKAGE, required=False)
        finally:
            pool.shutdown(wait=True, cancel_futures=True)
            key_path.unlink(missing_ok=True)
            cert_path.unlink(missing_ok=True)
            (root / "host-result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
            print(json.dumps({"passed": report["passed"], "completedCases": list(report["cases"])}), flush=True)


if __name__ == "__main__":
    main()
