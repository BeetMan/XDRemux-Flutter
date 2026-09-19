import assert from 'node:assert/strict';
import { QueueSandbox, SandboxPathPolicy } from '../entry/src/main/ets/queue/QueueSandbox.ts';

const MISSING = 13900002;

const fileStat = (size) => ({ size, isFile: true, isDirectory: false, isSymbolicLink: false });
const directoryStat = () => ({ size: 0, isFile: false, isDirectory: true, isSymbolicLink: false });
const symlinkStat = () => ({ size: 0, isFile: false, isDirectory: false, isSymbolicLink: true });

class MemorySandboxIo {
  constructor(withTree = true) {
    this.stats = new Map();
    this.directories = new Map();
    this.unlinkCalls = [];
    this.failUnlink = new Set();
    this.failStat = new Map();
    if (withTree) {
      this.addDirectory('/sandbox');
      this.addDirectory('/sandbox/inputs');
      this.addDirectory('/sandbox/outputs');
    }
  }

  missing(path) {
    const error = new Error(`missing ${path}`);
    error.code = MISSING;
    return error;
  }

  addFile(path, size) {
    this.stats.set(path, fileStat(size));
  }

  addDirectory(path) {
    this.stats.set(path, directoryStat());
  }

  addSymlink(path) {
    this.stats.set(path, symlinkStat());
  }

  setDirectoryEntries(path, names) {
    this.directories.set(path, names.slice());
  }

  async stat(path) {
    if (this.failStat.has(path)) throw this.failStat.get(path);
    const value = this.stats.get(path);
    if (value === undefined) throw this.missing(path);
    return { ...value };
  }

  async list(path) {
    if (!this.directories.has(path)) throw this.missing(path);
    return this.directories.get(path).slice();
  }

  async unlink(path) {
    this.unlinkCalls.push(path);
    if (this.failUnlink.has(path)) throw new Error(`unlink failed ${path}`);
    if (!this.stats.has(path)) throw this.missing(path);
    this.stats.delete(path);
  }
}

const policy = () => new SandboxPathPolicy('/sandbox/');

const expectThrow = (operation, pattern) => {
  assert.throws(operation, (error) => {
    assert.ok(error instanceof Error);
    if (pattern !== undefined) assert.match(error.message, pattern);
    return true;
  });
};

const testPathPolicy = () => {
  const paths = policy();
  assert.equal(paths.root, '/sandbox');
  assert.equal(paths.inputDirectory, '/sandbox/inputs');
  assert.equal(paths.outputDirectory, '/sandbox/outputs');
  assert.equal(paths.kindOf('/sandbox/inputs/input-1.jpg'), 'input');
  assert.equal(paths.kindOf('/sandbox/outputs/xdremux-1.heic'), 'output');
  assert.equal(paths.leaf('/sandbox/inputs/input-1.jpg'), 'input-1.jpg');
  assert.equal(paths.leaf('/sandbox/outputs/xdremux-1.heic'), 'xdremux-1.heic');
  assert.equal(paths.artifactPath('input', 'input-1.jpg'), '/sandbox/inputs/input-1.jpg');
  assert.equal(paths.artifactPath('output', 'xdremux-1.heic'), '/sandbox/outputs/xdremux-1.heic');
  assert.equal(paths.artifactPath('output', 'xdremux-1.heic.tmp'), '/sandbox/outputs/xdremux-1.heic.tmp');
  assert.equal(
    paths.artifactPath('output', '.apple-features-base-job-1.heic'),
    '/sandbox/outputs/.apple-features-base-job-1.heic'
  );

  for (const root of ['', '/sandbox/../escape', '/sandbox\\escape', 'content://picker', '/sandbox\u0000x']) {
    expectThrow(() => new SandboxPathPolicy(root), /沙盒根目录无效/);
  }
  for (const path of [
    '/sandbox',
    '/sandbox/inputs',
    '/sandbox/inputs/nested/input-1.jpg',
    '/sandbox/inputs/../outputs/xdremux-1.heic',
    '/sandbox/inputs/input-1.jpg/child',
    '/sandbox/outputs/xdremux-1.heic\\child',
    'content://picker/input-1.jpg',
    '/other/inputs/input-1.jpg'
  ]) {
    expectThrow(() => paths.validate(path), /路径不在应用沙盒输入\/输出目录/);
  }
  for (const leaf of ['', '.', '..', 'input-1.jpg/child', 'input-1.jpg\\child', '../input-1.jpg', 'content://x']) {
    expectThrow(() => paths.artifactPath('input', leaf), /沙盒文件名无效/);
  }
  for (const leaf of ['photo.jpg', 'input-1.tmp', 'xdremux-1.heic', '.apple-features-base-job-1.heic']) {
    expectThrow(() => paths.artifactPath('input', leaf), /不是受支持/);
  }
  for (const leaf of ['', '.', '..', 'xdremux-1.heic/child', 'xdremux-1.heic\\child', '../x.heic', 'content://x']) {
    expectThrow(() => paths.artifactPath('output', leaf), /沙盒文件名无效/);
  }
  for (const leaf of ['photo.jpg', 'output.tmp', '.apple-features-base-job-1.tmp']) {
    expectThrow(() => paths.artifactPath('output', leaf), /不是受支持/);
  }

  assert.equal(paths.isArtifactCandidate('/sandbox/inputs/input-a.jpg'), true);
  assert.equal(paths.isArtifactCandidate('/sandbox/inputs/input-a.tmp'), false);
  assert.equal(paths.isArtifactCandidate('/sandbox/outputs/xdremux-a.heic'), true);
  assert.equal(paths.isArtifactCandidate('/sandbox/outputs/xdremux-a.heic.tmp'), true);
  assert.equal(paths.isArtifactCandidate('/sandbox/outputs/.apple-features-base-a.heic'), true);
  assert.equal(paths.isArtifactCandidate('/sandbox/outputs/random.heic'), false);
};

const testStatusAndMissingDirectories = async () => {
  const io = new MemorySandboxIo();
  const sandbox = new QueueSandbox('/sandbox', io);
  const input = '/sandbox/inputs/input-1.jpg';
  const empty = '/sandbox/inputs/input-empty.jpg';
  const output = '/sandbox/outputs/xdremux-1.heic';
  const directory = '/sandbox/outputs/directory';
  const symlink = '/sandbox/outputs/leaf-link.heic';
  io.addFile(input, 17);
  io.addFile(empty, 0);
  io.addFile(output, 23);
  io.addDirectory(directory);
  io.addSymlink(symlink);

  assert.equal(await sandbox.status(input), 'file');
  assert.equal(await sandbox.status(empty), 'empty');
  assert.equal(await sandbox.status(output), 'file');
  assert.equal(await sandbox.status('/sandbox/inputs/missing.jpg'), 'missing');
  assert.equal(await sandbox.status(directory), 'unsafe');
  assert.equal(await sandbox.status(symlink), 'unsafe');
  io.stats.set('/sandbox/outputs/not-a-file.heic', { size: -1, isFile: true, isDirectory: false, isSymbolicLink: false });
  assert.equal(await sandbox.status('/sandbox/outputs/not-a-file.heic'), 'unsafe');
  const ioError = new Error('permission denied');
  io.failStat.set('/sandbox/outputs/denied.heic', ioError);
  await assert.rejects(sandbox.status('/sandbox/outputs/denied.heic'), /permission denied/);

  // Missing input/output directories are expected during a fresh install and
  // are treated as empty maintenance scopes.
  const missingIo = new MemorySandboxIo(false);
  const missingSandbox = new QueueSandbox('/sandbox', missingIo);
  assert.deepEqual(await missingSandbox.usage(), {
    inputFiles: 0,
    outputFiles: 0,
    inputBytes: 0,
    outputBytes: 0,
    candidateFiles: 0
  });
  const orphanReport = await missingSandbox.cleanupOrphans(new Set(), false);
  assert.deepEqual(orphanReport, {
    deletedPaths: [],
    missingPaths: [],
    failedPaths: [],
    deletedBytes: 0
  });
};

const testLeafAndParentSymlinkSafety = async () => {
  const io = new MemorySandboxIo();
  const sandbox = new QueueSandbox('/sandbox', io);
  const leaf = '/sandbox/outputs/xdremux-leaf.heic';
  const parented = '/sandbox/inputs/input-parent.jpg';
  io.addSymlink(leaf);
  io.addFile(parented, 11);
  io.addSymlink('/sandbox/inputs');
  io.addDirectory('/sandbox/outputs');
  io.setDirectoryEntries('/sandbox/inputs', ['input-parent.jpg']);
  io.setDirectoryEntries('/sandbox/outputs', ['xdremux-leaf.heic']);

  assert.equal(await sandbox.status(leaf), 'unsafe');
  assert.equal(await sandbox.status(parented), 'unsafe');

  await assert.rejects(sandbox.cleanupOwned([leaf]), /部分失败/);
  assert.equal(io.stats.has(leaf), true);
  await assert.rejects(sandbox.cleanupOrphans(new Set(), false), /沙盒目录不安全|部分失败/);
  assert.equal(io.stats.has(leaf), true);
  assert.equal(io.stats.has(parented), true);
  assert.deepEqual(io.unlinkCalls, []);
};

const testUsageAndArtifactOrphanCleanup = async () => {
  const io = new MemorySandboxIo();
  const sandbox = new QueueSandbox('/sandbox', io);
  io.setDirectoryEntries('/sandbox/inputs', [
    'input-one.jpg',
    '/input-two.heic',
    'input-three.tmp',
    'unrelated.bin',
    'input-missing.jpg'
  ]);
  io.setDirectoryEntries('/sandbox/outputs', [
    'xdremux-one.heic',
    '/xdremux-two.heic.tmp',
    '.apple-features-base-old.heic',
    'random.heic',
    'xdremux-missing.heic'
  ]);
  io.addFile('/sandbox/inputs/input-one.jpg', 10);
  io.addFile('/sandbox/inputs/input-three.tmp', 99);
  io.addFile('/sandbox/outputs/xdremux-one.heic', 20);
  io.addFile('/sandbox/outputs/xdremux-two.heic.tmp', 30);
  io.addFile('/sandbox/outputs/.apple-features-base-old.heic', 40);
  io.addFile('/sandbox/outputs/random.heic', 50);

  const usage = await sandbox.usage();
  assert.deepEqual(usage, {
    inputFiles: 1,
    outputFiles: 3,
    inputBytes: 10,
    outputBytes: 90,
    candidateFiles: 7
  });

  const referenced = new Set(['/sandbox/inputs/input-one.jpg', '/sandbox/outputs/xdremux-one.heic']);
  const report = await sandbox.cleanupOrphans(referenced, false);
  assert.deepEqual(report.deletedPaths.sort(), [
    '/sandbox/outputs/.apple-features-base-old.heic',
    '/sandbox/outputs/xdremux-two.heic.tmp'
  ].sort());
  assert.deepEqual(report.missingPaths, [
    '/sandbox/inputs/input-two.heic',
    '/sandbox/inputs/input-missing.jpg',
    '/sandbox/outputs/xdremux-missing.heic'
  ]);
  assert.equal(report.deletedBytes, 70);
  assert.equal(io.stats.has('/sandbox/inputs/input-one.jpg'), true);
  assert.equal(io.stats.has('/sandbox/outputs/xdremux-one.heic'), true);
  assert.equal(io.stats.has('/sandbox/inputs/input-three.tmp'), true);
  assert.equal(io.stats.has('/sandbox/outputs/random.heic'), true);
};

const testOwnedCleanupAndAtomicValidation = async () => {
  const io = new MemorySandboxIo();
  const sandbox = new QueueSandbox('/sandbox', io);
  const input = '/sandbox/inputs/input-owned.jpg';
  const output = '/sandbox/outputs/xdremux-owned.heic';
  const missing = '/sandbox/outputs/xdremux-missing.heic';
  io.addFile(input, 12);
  io.addFile(output, 34);

  const report = await sandbox.cleanupOwned([input, output, missing]);
  assert.deepEqual(report.deletedPaths, [input, output]);
  assert.deepEqual(report.missingPaths, [missing]);
  assert.deepEqual(report.failedPaths, []);
  assert.equal(report.deletedBytes, 46);
  assert.deepEqual(io.unlinkCalls, [input, output]);

  io.addFile(input, 12);
  io.addFile(output, 34);
  const invalid = '/sandbox/outputs/nested/file.heic';
  await assert.rejects(sandbox.cleanupOwned([input, invalid]), /路径不在应用沙盒输入\/输出目录/);
  assert.equal(io.stats.has(input), true);
  assert.deepEqual(io.unlinkCalls, [input, output]);

  await assert.rejects(sandbox.cleanupOwned([input, input]), /归属路径重复/);
  assert.equal(io.stats.has(input), true);
};

const testBusyAndPartialUnlinkFailure = async () => {
  const io = new MemorySandboxIo();
  const sandbox = new QueueSandbox('/sandbox', io);
  const first = '/sandbox/outputs/xdremux-first.heic';
  const second = '/sandbox/outputs/xdremux-second.heic';
  io.setDirectoryEntries('/sandbox/outputs', ['xdremux-first.heic', 'xdremux-second.heic']);
  io.addFile(first, 5);
  io.addFile(second, 7);

  await assert.rejects(sandbox.cleanupOrphans(new Set(), true), /暂不能清理沙盒/);
  assert.equal(io.stats.has(first), true);
  assert.equal(io.stats.has(second), true);
  assert.deepEqual(io.unlinkCalls, []);

  io.failUnlink.add(second);
  await assert.rejects(sandbox.cleanupOrphans(new Set(), false), /孤儿沙盒文件清理部分失败/);
  assert.equal(io.stats.has(first), false);
  assert.equal(io.stats.has(second), true);
  assert.deepEqual(io.unlinkCalls, [first, second]);

  const owned = '/sandbox/inputs/input-failed.jpg';
  io.addFile(owned, 9);
  io.failUnlink.add(owned);
  await assert.rejects(sandbox.cleanupOwned([owned]), /任务沙盒清理部分失败/);
  assert.equal(io.stats.has(owned), true);
};

testPathPolicy();
await testStatusAndMissingDirectories();
await testLeafAndParentSymlinkSafety();
await testUsageAndArtifactOrphanCleanup();
await testOwnedCleanupAndAtomicValidation();
await testBusyAndPartialUnlinkFailure();

console.log('Harmony queue sandbox tests passed: path-policy/status/symlink/missing-dir/usage/orphans/owned/busy/partial-unlink');
