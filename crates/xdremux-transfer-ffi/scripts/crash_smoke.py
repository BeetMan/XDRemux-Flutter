"""Kill only owned receiver subprocesses using the real DLL and loopback mTLS.

No synthetic recovery directories: partial bytes and receipts are produced by
actual uploads. Retains fixtures/audit data in a new explicitly supplied root.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes as c
import hashlib
import http.client
import json
from pathlib import Path
import queue
import socket
import ssl
import subprocess
import sys
import threading
import time
from urllib.parse import urlencode
import uuid


def check(value, message):
    if not value:
        raise AssertionError(message)
    return value


def wait(action, seconds=30):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = action()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError('Crash smoke observation deadline')


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


class Native:
    def __init__(self, library, root, bind):
        self.lib = c.CDLL(str(library))
        signatures = {
            'abi_version': (c.c_uint32, []),
            'create': (c.c_int32, [c.c_void_p, c.c_size_t, c.POINTER(c.c_uint64)]),
            'submit': (c.c_int32, [c.c_uint64, c.c_void_p, c.c_size_t, c.POINTER(c.c_uint64)]),
            'poll': (c.c_int32, [c.c_uint64, c.c_uint32, c.c_uint32, c.POINTER(c.c_void_p)]),
            'stop': (c.c_int32, [c.c_uint64]), 'release': (c.c_int32, [c.c_uint64]),
            'free_string': (c.c_int32, [c.c_void_p]),
        }
        self.api = {}
        for name, (result, parameters) in signatures.items():
            fn = getattr(self.lib, 'xdremux_transfer_' + name)
            fn.restype, fn.argtypes = result, parameters
            self.api[name] = fn
        check(self.api['abi_version']() == 65539, 'ABI 1.3 required')
        self.handle = c.c_uint64()
        self.records = []
        self.status = {}
        self.closed = False
        config = json.dumps({'root': str(root), 'bind': bind}).encode()
        check(self.api['create'](config, len(config), c.byref(self.handle)) == 0, 'Create receiver')
        wait(lambda: self.pump().get('phase') == 1)
        self.ready = self.status['ready']

    def pump(self):
        pointer = c.c_void_p()
        check(self.api['poll'](self.handle, 128, 2097152, c.byref(pointer)) == 0, 'Poll receiver')
        try:
            self.status = json.loads(c.string_at(pointer))
        finally:
            check(self.api['free_string'](pointer) == 0, 'Free ABI result')
        check(not self.status.get('lost'), 'No event overflow in bounded crash fixture')
        self.records.extend(record['body'] for record in self.status['records'])
        return self.status

    def command(self, request):
        data = json.dumps(request).encode()
        operation = c.c_uint64()
        check(self.api['submit'](self.handle, data, len(data), c.byref(operation)) == 0, 'Submit command')

        def completed():
            self.pump()
            for index, record in enumerate(self.records):
                if record.get('operation_id') == operation.value:
                    return self.records.pop(index)
            return None

        result = wait(completed)
        check(result['error'] is None, 'Native command failed: ' + str(result['error']))
        return result['data']

    def event(self, kind):
        def observed():
            self.pump()
            for index, record in enumerate(self.records):
                if record.get('kind') == 'event' and record['event']['kind'] == kind:
                    return self.records.pop(index)['event']
            return None
        return wait(observed)

    def close(self):
        if self.closed:
            return
        check(self.api['stop'](self.handle) == 0, 'Stop owned receiver')
        wait(lambda: self.pump().get('phase') == 3)
        check(self.api['release'](self.handle) == 0, 'Release owned receiver')
        self.closed = True


def child_main(args):
    native = Native(args.library, args.root, args.bind)
    try:
        print(json.dumps({'ok': True, 'data': native.ready}), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            stop = request.get('_stop')
            try:
                if stop:
                    native.close()
                    data = None
                elif '_event' in request:
                    data = native.event(request['_event'])
                else:
                    data = native.command(request)
                print(json.dumps({'ok': True, 'data': data}), flush=True)
            except Exception as error:
                print(json.dumps({'ok': False, 'error': str(error)}), flush=True)
            if stop:
                break
    finally:
        native.close()


class Child:
    def __init__(self, args, index, bind):
        self.log = (args.root / f'child-{index}.log').open('w', encoding='utf-8')
        self.proc = subprocess.Popen([sys.executable, str(Path(__file__).resolve()),
            '--child', '--library', str(args.library), '--root', str(args.root / 'receiver'),
            '--bind', bind], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
            text=True, encoding='utf-8')
        self.incoming = queue.Queue()
        def read():
            for line in self.proc.stdout:
                self.incoming.put(line)
            self.incoming.put(None)
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        try:
            self.ready = self.reply()
        except BaseException:
            self.close()
            raise

    def reply(self):
        line = self.incoming.get(timeout=40)
        check(line is not None, 'Owned receiver exited unexpectedly')
        result = json.loads(line)
        check(result['ok'], result.get('error', 'Child RPC failed'))
        return result['data']

    def command(self, **request):
        self.proc.stdin.write(json.dumps(request) + '\n')
        self.proc.stdin.flush()
        return self.reply()

    def kill(self):
        check(self.proc.poll() is None, 'Receiver must be alive at crash boundary')
        self.proc.kill()
        code = self.proc.wait(timeout=10)
        check(code != 0, 'Abrupt subprocess exit required')
        return code

    def close(self):
        try:
            if self.proc.poll() is None:
                self.command(_stop=True)
                check(self.proc.wait(timeout=10) == 0, 'Normal child cleanup')
        finally:
            if self.proc.poll() is None:
                self.proc.kill()
                self.proc.wait(timeout=10)
            self.reader.join(timeout=2)
            self.proc.stdin.close()
            self.proc.stdout.close()
            self.log.close()


def parent_main(args):
    args.root = args.root.resolve()
    args.library = args.library.resolve(strict=True)
    check(not args.root.exists(), 'Root must be a new directory')
    args.root.mkdir(parents=True)
    report = {'passed': False, 'scope': 'same-host native Windows receiver process crashes',
              'librarySha256': digest(args.library), 'cases': [],
              'osNetworkSettingsChanged': False, 'userFilesUsed': False}
    children = []
    sender = None
    connections = []
    pool = ThreadPoolExecutor(max_workers=1)
    try:
        sender = Native(args.library, args.root / 'sender', '127.0.0.1:0')
        identity = json.loads((args.root / 'sender/identity.json').read_text(encoding='utf-8'))
        cert, key = args.root / 'sender-cert.pem', args.root / 'sender-key.pem'
        cert.write_text(identity['cert'], encoding='utf-8')
        key.write_text(identity['key'], encoding='utf-8')
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.load_cert_chain(cert, key)
        sender.close()
        fixtures = args.root / 'fixtures'
        fixtures.mkdir()
        for name, count in [('baseline.bin', 256), ('partial.bin', 32768), ('after-commit.bin', 512)]:
            (fixtures / name).write_bytes(bytes(range(256)) * count)
        expected = {path.name: {'size': path.stat().st_size, 'sha256': digest(path)} for path in fixtures.iterdir()}

        def start(bind):
            child = Child(args, len(children), bind)
            children.append(child)
            return child

        first = start('127.0.0.1:0')
        address = first.ready['address']
        host, port = address.split(':')
        check(host == '127.0.0.1', 'Loopback receiver required')
        fingerprint = first.ready['fingerprint']

        def connect():
            connection = http.client.HTTPSConnection(host, int(port), context=context, timeout=10)
            connection.connect()
            actual = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest().upper()
            check(actual == fingerprint.upper(), 'Pinned receiver certificate')
            connections.append(connection)
            return connection

        def upload(child, name):
            meta = expected[name]
            file_id = uuid.uuid4().hex
            body = {'info': {'alias': 'P3 owned crash sender', 'version': '2.2',
                    'fingerprint': identity['fingerprint'], 'port': 0, 'protocol': 'https', 'download': False},
                    'files': {file_id: {'id': file_id, 'fileName': name, 'fileType': 'application/octet-stream', **meta}}}
            def prepare():
                connection = connect()
                try:
                    connection.request('POST', '/api/localsend/v2/prepare-upload', json.dumps(body).encode(),
                                       {'Content-Type': 'application/json'})
                    response = connection.getresponse()
                    check(response.status == 200, 'Prepare response')
                    return json.loads(response.read())
                finally:
                    connection.close()
            future = pool.submit(prepare)
            offer = child.command(_event='offer')['offer']
            owned = (offer['peer_fingerprint'].upper() == identity['fingerprint'].upper()
                     and len(offer['files']) == 1 and offer['files'][0]['name'] == name
                     and offer['files'][0]['size'] == meta['size']
                     and offer['files'][0]['sha256'] == meta['sha256'])
            child.command(command='decide', transfer_id=offer['session_id'], accept=owned)
            check(owned, 'Only pinned synthetic fixture accepted')
            prepared = future.result(timeout=15)
            connection = connect()
            query = urlencode({'sessionId': prepared['sessionId'], 'fileId': file_id, 'token': prepared['files'][file_id]})
            connection.putrequest('POST', '/api/localsend/v2/upload?' + query)
            connection.putheader('Content-Length', str(meta['size']))
            connection.endheaders()
            return connection

        baseline = upload(first, 'baseline.bin')
        baseline.send((fixtures / 'baseline.bin').read_bytes())
        response = baseline.getresponse()
        check(response.status == 200, 'Baseline HTTP ACK')
        response.read()
        baseline.close()
        receipt = wait(lambda: first.command(command='receipts', limit=64))[0]
        check(receipt['name'] == 'baseline.bin', 'Baseline receipt')
        # Leave an actual native read lease alive when TerminateProcess is used.
        first.command(command='acquire_receipt', receipt_id=receipt['id'])
        partial = upload(first, 'partial.bin')
        partial.send((fixtures / 'partial.bin').read_bytes()[:65536])
        incoming = args.root / 'receiver/.incoming'
        partial_path = wait(lambda: next((path for path in incoming.glob('txn-*/data')
                            if 0 < path.stat().st_size < expected['partial.bin']['size']), None))
        partial_bytes = partial_path.stat().st_size
        code = first.kill()
        check(partial_path.exists(), 'Actual crash residue retained before restart')
        partial.close()
        second = start(address)
        check(second.ready['fingerprint'] == fingerprint, 'Identity preserved after partial crash')
        check(second.ready['core_instance_id'] != first.ready['core_instance_id'], 'New runtime after crash')
        check(not list(incoming.iterdir()), 'Partial upload recovered')
        check(second.command(command='receipts', limit=64) == [receipt], 'Only completed baseline survives')
        report['cases'].append({'name': 'kill_during_partial_upload', 'passed': True,
                                'observedPartialBytes': partial_bytes, 'abruptExitCode': code,
                                'heldReadLeaseAtCrash': True, 'sameRootAndPortReopened': True})
        completed = upload(second, 'after-commit.bin')
        completed.send((fixtures / 'after-commit.bin').read_bytes())
        committed = second.command(_event='committed')
        check(committed['receipt']['name'] == 'after-commit.bin', 'Actual committed event')
        # Deliberately do not consume HTTP response. This is an unknown client
        # outcome, not proof that no ACK left the server/network stack.
        code = second.kill()
        completed.close()
        third = start(address)
        check(third.ready['fingerprint'] == fingerprint, 'Identity preserved after committed crash')
        check(third.ready['core_instance_id'] != second.ready['core_instance_id'], 'New committed runtime')
        receipts = third.command(command='receipts', limit=64)
        check({row['name'] for row in receipts} == {'baseline.bin', 'after-commit.bin'}, 'Reconcile without replay')
        check(len(receipts) == 2, 'No replay or duplicate after unknown response')
        report['cases'].append({'name': 'kill_after_commit_before_client_reads_response', 'passed': True,
                                'abruptExitCode': code, 'committedReceiptRetained': True,
                                'clientResponseConsumed': False, 'mutationReplayed': False})
        retry = upload(third, 'partial.bin')
        with (fixtures / 'partial.bin').open('rb') as stream:
            while chunk := stream.read(65536):
                retry.send(chunk)
        response = retry.getresponse()
        check(response.status == 200, 'Explicit retry HTTP ACK')
        response.read()
        retry.close()
        receipts = third.command(command='receipts', limit=64)
        check(len(receipts) == 3 and {row['name'] for row in receipts} == set(expected), 'Exactly three completed fixtures')
        audit = args.root / 'audit'
        audit.mkdir()
        for row in receipts:
            lease = third.command(command='acquire_receipt', receipt_id=row['id'])
            path = Path(lease['path'])
            check(path.stat().st_size == row['size'] == expected[row['name']]['size'], 'Disk length')
            check(digest(path) == row['sha256'] == expected[row['name']]['sha256'], 'Independent disk SHA-256')
            (audit / row['name']).write_bytes(path.read_bytes())
            third.command(command='release_receipt', lease_id=lease['lease_id'])
            third.command(command='delete_receipt', receipt_id=row['id'])
        check(third.command(command='receipts', limit=64) == [], 'No stale reader blocks deletion')
        check(all(digest(fixtures / name) == meta['sha256'] for name, meta in expected.items()), 'Sources unchanged')
        report.update({'passed': True, 'fixtures': expected, 'independentDiskHashes': True,
                       'explicitPartialRetryPassed': True, 'noStaleLeaseAfterProcessDeath': True})
    except BaseException as error:
        report['passed'] = False
        report['error'] = type(error).__name__ + ': ' + str(error)
        raise
    finally:
        cleanup_errors = []
        for connection in connections:
            connection.close()
        for child in children:
            try:
                child.close()
            except Exception as error:
                cleanup_errors.append(type(error).__name__)
        if sender is not None:
            try:
                sender.close()
            except Exception as error:
                cleanup_errors.append(type(error).__name__)
        pool.shutdown(wait=True)
        report['ownedChildrenExited'] = all(child.proc.poll() is not None for child in children)
        if cleanup_errors or not report['ownedChildrenExited']:
            report['passed'] = False
            report['cleanupErrors'] = cleanup_errors
        if 'address' in locals():
            try:
                with socket.socket() as listener:
                    if sys.platform == 'win32':
                        listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
                    listener.bind((host, int(port)))
                report['receiverPortReleased'] = True
            except OSError:
                report['receiverPortReleased'] = False
                report['passed'] = False
        (args.root / 'result.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    check(report['passed'], 'Crash smoke including cleanup must pass')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', required=True, type=Path)
    parser.add_argument('--root', required=True, type=Path)
    parser.add_argument('--child', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--bind', default='127.0.0.1:0', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.child:
        child_main(args)
    else:
        parent_main(args)
