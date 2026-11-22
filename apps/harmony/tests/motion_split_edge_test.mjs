import assert from 'node:assert/strict';
import {
  buildMotionSplitPathPlan,
  parseMotionSplitJson,
  runMotionSplitPipeline
} from '../entry/src/main/ets/queue/MotionPhotoSplitModel.ts';

const ROOT = '/sandbox';
const SOURCE = '/sandbox/inputs/imported-motion.photo';
const SOURCE_BYTES = 1000;
const STILL_BYTES = 400;
const VIDEO_BYTES = 600;
const PRIMARY_BYTES = 400;

const fileStat = (size) => ({
  size,
  isFile: true,
  isDirectory: false,
  isSymbolicLink: false
});

const planFor = (itemId = 'job-1', serial = 1) => (
  buildMotionSplitPathPlan(ROOT, itemId, 1700000000000, serial, SOURCE)
);

const splitReport = (plan, {
  dual = false,
  stillPath = plan.stillJpgPath,
  videoPath = plan.videoPath,
  primaryVideoPath = dual ? plan.primaryPath : undefined,
  stillMime = 'image/jpeg'
} = {}) => ({
  success: true,
  isMotionPhoto: true,
  sourceKind: dual ? 'oppoLivePhoto' : 'androidMotionPhotoV1',
  stillStart: 0,
  stillEnd: STILL_BYTES,
  videoStart: STILL_BYTES,
  videoEnd: SOURCE_BYTES,
  isDualStream: dual,
  items: [
    { mime: stillMime, semantic: 'Primary', length: 0, padding: 0 },
    { mime: 'video/mp4', semantic: 'MotionPhoto', length: VIDEO_BYTES, padding: 0 }
  ],
  primaryBytes: dual ? PRIMARY_BYTES : undefined,
  secondaryBytes: dual ? VIDEO_BYTES - PRIMARY_BYTES : undefined,
  stillPath,
  videoPath,
  primaryVideoPath
});

const statsFor = (plan, {
  still = 'jpg',
  videoSize = VIDEO_BYTES,
  primarySize = PRIMARY_BYTES,
  includePrimary = false,
  primaryStat = fileStat(primarySize)
} = {}) => {
  const stats = new Map();
  stats.set(still === 'heic' ? plan.stillHeicPath : plan.stillJpgPath, fileStat(STILL_BYTES));
  stats.set(plan.videoPath, fileStat(videoSize));
  if (includePrimary) stats.set(plan.primaryPath, primaryStat);
  return stats;
};

const parse = (plan, report, stats = statsFor(plan)) => (
  parseMotionSplitJson(JSON.stringify(report), plan, SOURCE, SOURCE_BYTES, stats)
);

const expectThrow = async (operation, pattern) => {
  await assert.rejects(operation, (error) => {
    assert.ok(error instanceof Error);
    if (pattern !== undefined) assert.match(error.message, pattern);
    return true;
  });
};

const expectSyncThrow = (operation, pattern) => {
  assert.throws(operation, (error) => {
    assert.ok(error instanceof Error);
    if (pattern !== undefined) assert.match(error.message, pattern);
    return true;
  });
};

const makeHooks = (plan, {
  report = splitReport(plan),
  statusOverrides = new Map(),
  persistError,
  runError,
  writePartial = false,
  statOverrides = new Map()
} = {}) => {
  const calls = [];
  const files = new Map();
  const status = async (path) => {
    calls.push(['status', path]);
    if (statusOverrides.has(path)) return statusOverrides.get(path);
    if (files.has(path)) return 'file';
    return path === SOURCE ? 'file' : 'missing';
  };
  const stat = async (path) => {
    calls.push(['stat', path]);
    if (statOverrides.has(path)) return statOverrides.get(path);
    if (path === SOURCE) return fileStat(SOURCE_BYTES);
    if (files.has(path)) return files.get(path);
    throw new Error('missing synthetic stat: ' + path);
  };
  const register = (paths) => calls.push(['register', [...paths]]);
  const persist = async () => {
    calls.push(['persist']);
    if (persistError !== undefined) throw new Error(persistError);
  };
  const copy = async (sourcePath, destinationPath) => {
    calls.push(['copy', sourcePath, destinationPath]);
    files.set(destinationPath, fileStat(SOURCE_BYTES));
  };
  const runSplit = async (inputPath, outputDirectory) => {
    calls.push(['runSplit', inputPath, outputDirectory]);
    if (writePartial) files.set(plan.stillJpgPath, fileStat(STILL_BYTES));
    if (runError !== undefined) throw new Error(runError);
    if (!writePartial) {
      const stillPath = report.stillPath;
      files.set(stillPath, fileStat(STILL_BYTES));
      files.set(plan.videoPath, fileStat(VIDEO_BYTES));
      if (report.primaryVideoPath !== undefined) {
        files.set(report.primaryVideoPath, fileStat(PRIMARY_BYTES));
      }
    }
    return JSON.stringify(report);
  };
  const cleanup = async (paths) => {
    calls.push(['cleanup', [...paths]]);
    for (const path of paths) files.delete(path);
  };
  return {
    calls,
    files,
    hooks: { status, stat, register, persist, copy, runSplit, cleanup }
  };
};

const optionsFor = (plan) => ({
  plan,
  sourceInputPath: SOURCE,
  sourceBytes: SOURCE_BYTES
});

const testSafePlanAndPreflight = async () => {
  const plan = planFor();
  assert.equal(plan.outputDirectory, '/sandbox/outputs');
  assert.equal(new Set(plan.ownedPaths).size, plan.ownedPaths.length);
  assert.ok(plan.scratchInputPath.startsWith('/sandbox/inputs/'));
  assert.ok(plan.videoPath.endsWith('.video.mp4'));
  assert.ok(plan.primaryPath.endsWith('.primary.mp4'));

  for (const root of ['/sandbox/../escape', 'file://sandbox', 'C:\\sandbox', '/sandbox\u0000']) {
    expectSyncThrow(
      () => buildMotionSplitPathPlan(root, 'job-1', 1700000000000, 1, SOURCE),
      /沙盒根目录无效/
    );
  }
  expectSyncThrow(
    () => buildMotionSplitPathPlan(ROOT, 'job/escape', 1700000000000, 1, SOURCE),
    /任务 ID/
  );
  expectSyncThrow(
    () => buildMotionSplitPathPlan(ROOT, 'job-1', 0, 1, SOURCE),
    /尝试序号/
  );

  for (const existingState of ['file', 'empty', 'unsafe']) {
    const collisionHooks = makeHooks(plan, {
      statusOverrides: new Map([[plan.videoPath, existingState]])
    });
    await expectThrow(
      runMotionSplitPipeline(optionsFor(plan), collisionHooks.hooks),
      /预留路径必须不存在|路径不安全/
    );
    assert.equal(collisionHooks.calls.some((call) => call[0] === 'register'), false);
    assert.equal(collisionHooks.calls.some((call) => call[0] === 'persist'), false);
    assert.equal(collisionHooks.calls.some((call) => call[0] === 'copy'), false);
    assert.equal(collisionHooks.calls.some((call) => call[0] === 'runSplit'), false);
    assert.equal(collisionHooks.calls.some((call) => call[0] === 'cleanup'), false);
  }
};

const testReportValidation = () => {
  const plan = planFor('job-report');
  const valid = parse(plan, splitReport(plan));
  assert.deepEqual(valid.assets.map((asset) => asset.kind), ['still', 'video']);
  assert.equal(valid.assets[0].path, plan.stillJpgPath);
  assert.equal(valid.assets[1].size, VIDEO_BYTES);

  const dualPlan = planFor('job-dual', 2);
  const dualStats = statsFor(dualPlan, { includePrimary: true });
  const dual = parse(dualPlan, splitReport(dualPlan, { dual: true }), dualStats);
  assert.deepEqual(dual.assets.map((asset) => asset.kind), ['still', 'video', 'primary']);
  assert.equal(dual.assets[2].path, dualPlan.primaryPath);
  assert.equal(dual.assets[2].size, PRIMARY_BYTES);

  expectSyncThrow(
    () => parse(plan, { success: false, errorMessage: 'native partial write' }),
    /native partial write/
  );
  expectSyncThrow(
    () => parse(plan, { success: false }),
    /拆分失败/
  );
  expectSyncThrow(
    () => parse(plan, splitReport(plan, { stillPath: '/sandbox/outputs/foreign.still.jpg' })),
    /静态图路径/
  );
  expectSyncThrow(
    () => parse(plan, splitReport(plan, { videoPath: '/sandbox/outputs/foreign.video.mp4' })),
    /视频路径/
  );

  const heicReport = splitReport(plan, { stillPath: plan.stillHeicPath, stillMime: 'image/heic' });
  assert.equal(parse(plan, heicReport, statsFor(plan, { still: 'heic' })).assets[0].suffix, '.heic');
  // A report naming JPG while only the HEIC candidate exists must not be
  // silently accepted by selecting the other candidate from the stats map.
  expectSyncThrow(
    () => parse(plan, splitReport(plan), statsFor(plan, { still: 'heic' })),
    /静态图路径|静态图候选/
  );

  expectSyncThrow(
    () => parse(plan, splitReport(plan), statsFor(plan, { videoSize: VIDEO_BYTES - 1 })),
    /大小与报告范围/
  );
  expectSyncThrow(
    () => parse(plan, splitReport(plan, { primaryVideoPath: plan.primaryPath }), statsFor(plan)),
    /主视频报告声明的主视频不存在|主视频不存在/
  );
  expectSyncThrow(
    () => parse(
      dualPlan,
      splitReport(dualPlan, { dual: true, primaryVideoPath: '/sandbox/outputs/foreign.primary.mp4' }),
      dualStats
    ),
    /主视频路径/
  );
  expectSyncThrow(
    () => parse(
      dualPlan,
      { ...splitReport(dualPlan, { dual: true }), primaryVideoPath: undefined },
      dualStats
    ),
    /未在报告中声明/
  );
  expectSyncThrow(
    () => parse(
      dualPlan,
      splitReport(dualPlan, { dual: true }),
      statsFor(dualPlan, { includePrimary: true, primaryStat: fileStat(VIDEO_BYTES + 1) })
    ),
    /超过完整视频范围/
  );

  const extraOwned = {
    ...plan,
    ownedPaths: [...plan.ownedPaths, '/sandbox/outputs/foreign.heic']
  };
  expectSyncThrow(
    () => parse(extraOwned, splitReport(extraOwned)),
    /归属|预登记/
  );

  const aliased = {
    ...plan,
    stillJpgPath: plan.videoPath,
    ownedPaths: [plan.scratchInputPath, plan.stillHeicPath, plan.videoPath, plan.primaryPath]
  };
  expectSyncThrow(
    () => parse(aliased, splitReport(aliased)),
    /重复|候选|路径/
  );
};

const testPipelineOrderingAndFailureCleanup = async () => {
  const plan = planFor('job-pipeline', 3);
  const successHooks = makeHooks(plan, {
    report: splitReport(plan, { dual: true })
  });
  const success = await runMotionSplitPipeline(optionsFor(plan), successHooks.hooks);
  assert.deepEqual(success.assets.map((asset) => asset.kind), ['still', 'video', 'primary']);
  assert.deepEqual(successHooks.calls.filter((call) => ['register', 'persist', 'copy', 'runSplit', 'cleanup'].includes(call[0])).map((call) => call[0]), [
    'register', 'persist', 'copy', 'runSplit', 'cleanup'
  ]);
  const successCleanup = successHooks.calls.find((call) => call[0] === 'cleanup');
  assert.deepEqual(successCleanup[1], [plan.scratchInputPath]);

  const persistHooks = makeHooks(plan, { persistError: 'journal failed' });
  await expectThrow(
    runMotionSplitPipeline(optionsFor(plan), persistHooks.hooks),
    /journal failed/
  );
  assert.equal(persistHooks.calls.some((call) => call[0] === 'copy'), false);
  assert.equal(persistHooks.calls.some((call) => call[0] === 'runSplit'), false);
  assert.equal(persistHooks.calls.some((call) => call[0] === 'cleanup'), false);

  const partialPlan = planFor('job-partial', 4);
  const outsidePath = '/sandbox/outputs/foreign-existing.heic';
  const partialHooks = makeHooks(partialPlan, {
    report: { success: false, errorMessage: 'native wrote still then failed' },
    writePartial: true
  });
  partialHooks.files.set(outsidePath, fileStat(77));
  await expectThrow(
    runMotionSplitPipeline(optionsFor(partialPlan), partialHooks.hooks),
    /native wrote still then failed/
  );
  const partialCleanup = partialHooks.calls.find((call) => call[0] === 'cleanup');
  assert.deepEqual(partialCleanup[1], partialPlan.ownedPaths);
  assert.equal(partialCleanup[1].includes(outsidePath), false);
  assert.equal(partialHooks.files.has(outsidePath), true);
  assert.equal(partialHooks.calls.some((call) => call[0] === 'copy'), true);
  assert.equal(partialHooks.calls.some((call) => call[0] === 'runSplit'), true);
};

await testSafePlanAndPreflight();
testReportValidation();
await testPipelineOrderingAndFailureCleanup();

console.log('Harmony Motion Photo split edge tests passed: safe-plan/preflight/persist-gate/report-paths/lengths/primary/partial-cleanup');
