import { fileIo } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import xdremuxNative from 'libentry.so';
import {
  NativeClassificationResult,
  NativeConversionResult,
  NativeConvertConfig,
  NativePhotoDetails,
  NativeProgress
} from '../queue/NativeTypes';
import {
  QueueController,
  QueueItem,
  QueueItemInput,
  QueueModeSnapshot,
  QueuePrepared,
  QueueResult
} from '../queue/QueueController';

interface NativeError {
  message?: string;
  code?: number;
}

@Entry
@Component
struct Index {
  @State private coreVersion: string = '加载中…';
  @State private operationStatus: string = '准备就绪';
  @State private outputMode: string = 'oppo';
  @State private queueItems: Array<QueueItem> = [];
  @State private selectedItemId: string = '';
  @State private queueRunning: boolean = false;
  @State private stopRequested: boolean = false;
  @State private activeItemId: string = '';
  @State private pageBusy: boolean = false;

  private queueController: QueueController | undefined = undefined;
  private inputSerial: number = 0;
  private outputSerial: number = 0;

  aboutToAppear(): void {
    this.attachQueueSession();
    this.refreshVersion();
  }

  onPageShow(): void {
    // Returning to the foreground only reattaches the view. A stopped queue
    // requires an explicit Start/Resume click so a page recreation cannot
    // silently launch additional native work.
    this.attachQueueSession();
  }

  onPageHide(): void {
    this.detachQueueSession();
  }

  aboutToDisappear(): void {
    this.detachQueueSession();
  }

  private attachQueueSession(): void {
    const controller: QueueController = this.getController();
    controller.attach((): void => this.syncQueue());
    this.syncQueue();
  }

  private detachQueueSession(): void {
    // The active Promise still owns its native progress handle until it
    // settles; detach only stops later queued work and UI polling.
    if (this.queueController !== undefined) {
      this.queueController.detach();
    }
  }

  private getController(): QueueController {
    if (this.queueController === undefined) {
      this.queueController = new QueueController({
        captureMode: (): QueueModeSnapshot => this.modeSnapshot(),
        prepare: (item: QueueItem): Promise<QueuePrepared> => this.prepareQueueItem(item),
        execute: (
          item: QueueItem,
          mode: QueueModeSnapshot,
          reportProgress: (progress: NativeProgress) => void
        ): Promise<QueueResult> => this.executeQueueItem(item, mode, reportProgress),
        cleanup: (item: QueueItem): Promise<void> => this.cleanupQueueItem(item),
        errorMessage: (error: Object): string => this.errorMessage(error)
      });
    }
    return this.queueController;
  }

  private syncQueue(): void {
    const controller: QueueController = this.getController();
    this.queueItems = controller.items();
    this.queueRunning = controller.isRunning;
    this.stopRequested = controller.isStopRequested;
    this.activeItemId = controller.activeItemId;
    if (this.selectedItemId.length > 0 &&
      this.queueItems.find((item: QueueItem): boolean => item.id === this.selectedItemId) !== undefined) {
      return;
    }
    this.selectedItemId = this.queueItems.length === 0 ? '' : this.queueItems[0].id;
  }

  private selectedItem(): QueueItem | undefined {
    return this.queueItems.find((item: QueueItem): boolean => item.id === this.selectedItemId);
  }

  private selectedItemRequired(): QueueItem {
    const item: QueueItem | undefined = this.selectedItem();
    if (item === undefined) {
      throw new Error('当前项目不可用');
    }
    return item;
  }

  private async refreshVersion(): Promise<void> {
    this.pageBusy = true;
    this.operationStatus = '正在异步读取 Rust 核心版本…';
    try {
      this.coreVersion = await xdremuxNative.version();
      this.operationStatus = 'Rust 核心已加载；当前队列仅保留在内存';
    } catch (error) {
      this.coreVersion = '不可用';
      this.operationStatus = '读取核心版本失败：' + this.errorMessage(error);
    } finally {
      this.pageBusy = false;
    }
  }

  private async chooseAndImport(): Promise<void> {
    if (this.pageBusy || this.queueRunning) {
      return;
    }
    this.pageBusy = true;
    this.operationStatus = '正在打开系统文件选择器…';
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('应用上下文不可用');
      }
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = ['Images|.heic,.heif,.jpg,.jpeg,.png'];
      options.maxSelectNumber = 500;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const selected: Array<string> = await documentPicker.select(options);
      if (selected.length === 0) {
        this.operationStatus = '未选择照片';
        return;
      }

      let imported: number = 0;
      let failed: number = 0;
      const controller: QueueController = this.getController();
      for (let index: number = 0; index < selected.length; index += 1) {
        const sourceUri: string = selected[index];
        const input: QueueItemInput = {
          displayName: this.displayNameFromUri(sourceUri, index),
          sourceUri: sourceUri
        };
        const added: QueueItem = controller.add(input);
        if (this.selectedItemId.length === 0) {
          this.selectedItemId = added.id;
        }
        controller.beginExternal(added.id);
        try {
          this.operationStatus = '正在准备第 ' + String(index + 1) + ' / ' +
            String(selected.length) + ' 个文件…';
          const prepared: QueuePrepared = await this.prepareQueueItem(added);
          controller.setPrepared(added.id, prepared.inputPath, prepared.details, prepared.classification);
          imported += 1;
        } catch (error) {
          controller.markPreparationFailed(added.id, this.errorMessage(error));
          failed += 1;
        } finally {
          controller.endExternal(added.id);
        }
      }
      this.operationStatus = '已导入 ' + String(imported) + ' 个文件；失败 ' + String(failed) +
        ' 个，失败项目可单独重试';
    } catch (error) {
      this.operationStatus = '导入失败：' + this.errorMessage(error);
    } finally {
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private async prepareQueueItem(item: QueueItem): Promise<QueuePrepared> {
    let newPath: string = '';
    try {
      newPath = await this.materializeUri(item.sourceUri, item.id);
      // Register before metadata/classification so an import failure still
      // leaves an explicit task-owned path for best-effort cleanup.
      this.getController().registerOwnedPath(item.id, newPath);
      const detailsJson: string = await xdremuxNative.inspect(newPath);
      const details: NativePhotoDetails = JSON.parse(detailsJson) as NativePhotoDetails;
      if (!details.success) {
        throw new Error(this.display(details.errorMessage));
      }
      const classification: NativeClassificationResult =
        await xdremuxNative.classify(newPath) as NativeClassificationResult;
      return { inputPath: newPath, details: details, classification: classification };
    } catch (error) {
      if (newPath.length > 0) {
        try {
          await fileIo.unlink(newPath);
        } catch (cleanupError) {
          // Preserve the metadata/classification error.
        }
      }
      throw new Error(this.errorMessage(error));
    }
  }

  private async retrySelected(): Promise<void> {
    const item: QueueItem | undefined = this.selectedItem();
    if (item === undefined) {
      this.operationStatus = '请先选择队列项目';
      return;
    }
    try {
      this.getController().retry(item.id);
      this.operationStatus = '已将失败项目加入待处理队列，请点击开始/继续';
      this.syncQueue();
    } catch (error) {
      this.operationStatus = '重试失败：' + this.errorMessage(error);
    }
  }

  private async reconvertSelected(): Promise<void> {
    const item: QueueItem | undefined = this.selectedItem();
    if (item === undefined) {
      this.operationStatus = '请先选择队列项目';
      return;
    }
    try {
      this.getController().reconvert(item.id);
      this.operationStatus = '已将项目加入重新转换队列；上次成功结果仍保留';
      this.syncQueue();
    } catch (error) {
      this.operationStatus = '重新转换失败：' + this.errorMessage(error);
    }
  }

  private async removeSelected(): Promise<void> {
    const item: QueueItem | undefined = this.selectedItem();
    if (item === undefined) {
      this.operationStatus = '请先选择队列项目';
      return;
    }
    this.pageBusy = true;
    try {
      await this.getController().remove(item.id);
      this.operationStatus = '已删除项目及其沙盒文件';
    } catch (error) {
      this.operationStatus = '删除失败：' + this.errorMessage(error);
    } finally {
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private async startQueue(): Promise<void> {
    if (this.pageBusy) {
      return;
    }
    const controller: QueueController = this.getController();
    if (!controller.hasPendingItems) {
      this.operationStatus = '没有可运行的待处理项目';
      return;
    }
    this.operationStatus = '队列运行中：失败项目不会阻塞后续项目';
    try {
      await controller.start();
      if (controller.isStopRequested) {
        this.operationStatus = '已停止接收新项目；当前结果已完成，可点击开始/继续';
      } else {
        this.operationStatus = '队列处理完成';
      }
    } catch (error) {
      this.operationStatus = '队列运行失败：' + this.errorMessage(error);
    } finally {
      this.syncQueue();
    }
  }

  private stopQueue(): void {
    if (!this.queueRunning) {
      this.operationStatus = '队列当前未运行';
      return;
    }
    this.getController().stop();
    this.operationStatus = '已请求停止：当前项目完成后暂停';
    this.syncQueue();
  }

  private async exportSelected(): Promise<void> {
    const item: QueueItem | undefined = this.selectedItem();
    if (item === undefined || item.result === undefined) {
      this.operationStatus = '请先完成一个项目的转换';
      return;
    }
    this.pageBusy = true;
    let locked: boolean = false;
    try {
      const controller: QueueController = this.getController();
      controller.beginExternal(item.id);
      locked = true;
      this.operationStatus = '正在打开系统保存位置选择器…';
      const destination: string | undefined = await this.exportItem(item);
      if (destination === undefined) {
        this.operationStatus = '未选择导出位置；沙盒结果仍保留';
      } else {
        controller.markExported(item.id, destination);
        this.operationStatus = '导出成功：已关闭目标文件并写入系统位置';
      }
    } catch (error) {
      this.operationStatus = '导出失败：' + this.errorMessage(error) + '；沙盒结果仍保留，可重试';
    } finally {
      if (locked) {
        this.getController().endExternal(item.id);
      }
      this.pageBusy = false;
      this.syncQueue();
    }
  }

  private async exportItem(item: QueueItem): Promise<string | undefined> {
    if (item.result === undefined) {
      throw new Error('转换结果不可用');
    }
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      throw new Error('应用上下文不可用');
    }
    const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
    const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
    options.newFileNames = [this.exportFileName(item)];
    options.fileSuffixChoices = ['HEIF 图像|.heic'];
    const saved: Array<string> = await documentPicker.save(options);
    if (saved.length === 0) {
      return undefined;
    }
    const destinationUri: string = saved[0];
    if (destinationUri === item.sourceUri) {
      throw new Error('导出位置不能是原始输入文件');
    }
    const sourceStat = await fileIo.stat(item.result.outputPath);
    if (sourceStat.size <= 0) {
      throw new Error('沙盒转换结果为空');
    }

    let targetFd: number = -1;
    try {
      // API 18 pre-creates the target. WRITE_ONLY deliberately omits TRUNC;
      // a non-empty target is rejected before copyFile can overwrite it.
      targetFd = (await fileIo.open(destinationUri, fileIo.OpenMode.WRITE_ONLY)).fd;
      const existingTargetStat = await fileIo.stat(targetFd);
      if (existingTargetStat.size !== 0) {
        throw new Error('导出位置已有内容，请选择新的文件名');
      }
      await fileIo.copyFile(item.result.outputPath, targetFd);
      const copiedStat = await fileIo.stat(targetFd);
      if (copiedStat.size !== sourceStat.size) {
        throw new Error('导出文件大小校验失败');
      }
      await fileIo.close(targetFd);
      targetFd = -1;
      return destinationUri;
    } finally {
      if (targetFd >= 0) {
        try {
          await fileIo.close(targetFd);
        } catch (closeError) {
          // Do not report export success if the close path failed.
        }
      }
    }
  }

  private async executeQueueItem(
    item: QueueItem,
    mode: QueueModeSnapshot,
    reportProgress: (progress: NativeProgress) => void
  ): Promise<QueueResult> {
    let temporaryPath: string = '';
    let finalPath: string = '';
    let handle: number = 0;
    let timer: number = -1;
    try {
      const paths: Array<string> = this.nextOutputPaths(item.id);
      temporaryPath = paths[0];
      finalPath = paths[1];
      const controller: QueueController = this.getController();
      controller.registerOwnedPath(item.id, temporaryPath);
      controller.registerOwnedPath(item.id, finalPath);
      if (temporaryPath === item.inputPath || finalPath === item.inputPath) {
        throw new Error('输出路径不能覆盖输入文件');
      }
      await this.ensureDirectory(this.parentDirectory(finalPath));
      handle = xdremuxNative.progressBegin();
      if (handle === 0) {
        throw new Error('无法创建转换进度句柄');
      }
      timer = setInterval(() => {
        try {
          const progress: NativeProgress = xdremuxNative.progressRead(handle) as NativeProgress;
          reportProgress(progress);
        } catch (error) {
          // The Rust registry is cleared immediately before the final result;
          // a late empty poll is expected and does not decide success.
        }
      }, 250);
      const conversion: NativeConversionResult = await xdremuxNative.convert(
        item.inputPath,
        temporaryPath,
        mode.config,
        handle
      ) as NativeConversionResult;
      if (!conversion.success) {
        const message: string = this.display(conversion.errorMessage);
        throw new Error(message === '—' ? 'Rust 转换失败' : message);
      }
      const temporaryStat = await fileIo.stat(temporaryPath);
      if (temporaryStat.size <= 0) {
        throw new Error('转换输出为空');
      }
      await fileIo.rename(temporaryPath, finalPath);
      const finalStat = await fileIo.stat(finalPath);
      if (finalStat.size <= 0) {
        throw new Error('转换输出校验失败');
      }
      return {
        outputPath: finalPath,
        modeKey: mode.modeKey,
        modeLabel: mode.modeLabel,
        conversion: conversion
      };
    } catch (error) {
      // Both names are owned by this item. A rename can fail after creating
      // either side, so best-effort cleanup attempts both; the controller's
      // explicit remove retries any path that remains.
      const cleanupPaths: Array<string> = [temporaryPath, finalPath];
      for (const cleanupPath of cleanupPaths) {
        if (cleanupPath.length === 0) {
          continue;
        }
        try {
          await fileIo.unlink(cleanupPath);
        } catch (cleanupError) {
          // The conversion error remains the item error; removal is explicit.
        }
      }
      throw new Error(this.errorMessage(error));
    } finally {
      if (timer >= 0) {
        clearInterval(timer);
      }
      if (handle !== 0) {
        try {
          // This runs only after xdremuxNative.convert has settled.
          xdremuxNative.progressEnd(handle);
        } catch (endError) {
          // Preserve the settled conversion result/error.
        }
      }
    }
  }

  private modeSnapshot(): QueueModeSnapshot {
    if (this.outputMode === 'apple') {
      return {
        modeKey: 'apple',
        modeLabel: 'Apple 标准',
        config: {
          oppoCompat: 0,
          oppoCameraTail: 0,
          strictTmap: 0,
          applePhotographicStyles: 0,
          applePortrait: 0
        }
      };
    }
    return {
      modeKey: 'oppo',
      modeLabel: 'OPPO 兼容',
      config: {
        oppoCompat: 2,
        oppoCameraTail: 255,
        strictTmap: 0,
        applePhotographicStyles: 0,
        applePortrait: 0
      }
    };
  }

  private async cleanupQueueItem(item: QueueItem): Promise<void> {
    // The controller registers every file allocated for this item before use.
    // Cleanup therefore cannot unlink a caller-owned source path, and it also
    // retries old outputs/temp files left by previous reconversions.
    const paths: Array<string> = item.ownedPaths.slice();
    for (const path of paths) {
      try {
        await fileIo.unlink(path);
      } catch (error) {
        if (!this.isMissingFileError(error)) {
          throw new Error(this.errorMessage(error));
        }
      }
    }
  }

  private isMissingFileError(error: Object): boolean {
    const nativeError = error as NativeError;
    return nativeError.code === 13900002;
  }

  private async materializeUri(sourceUri: string, itemId: string): Promise<string> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      throw new Error('应用上下文不可用');
    }
    this.inputSerial += 1;
    const inputDirectory: string = context.filesDir + '/inputs';
    const destination: string = inputDirectory + '/input-' + itemId + '-' + String(Date.now()) + '-' +
      String(this.inputSerial) + '.photo';
    let sourceFd: number = -1;
    try {
      // Reserve the generated path before any copy operation so a partial
      // destination remains owned by this queue item if a later step fails.
      this.getController().registerOwnedPath(itemId, destination);
      await this.ensureDirectory(inputDirectory);
      sourceFd = (await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY)).fd;
      await fileIo.copyFile(sourceFd, destination);
      const stat = await fileIo.stat(destination);
      if (stat.size <= 0) {
        throw new Error('沙盒照片为空');
      }
      return destination;
    } catch (error) {
      try {
        await fileIo.unlink(destination);
      } catch (cleanupError) {
        // Preserve the source/copy error.
      }
      throw new Error(this.errorMessage(error));
    } finally {
      if (sourceFd >= 0) {
        try {
          await fileIo.close(sourceFd);
        } catch (closeError) {
          // Preserve the copy error if one already occurred.
        }
      }
    }
  }

  private async ensureDirectory(path: string): Promise<void> {
    try {
      await fileIo.mkdir(path, true);
      return;
    } catch (mkdirError) {
      try {
        const exists: boolean = await fileIo.access(path);
        if (exists) {
          return;
        }
      } catch (accessError) {
        // Fall through with the original mkdir error.
      }
      throw new Error(this.errorMessage(mkdirError));
    }
  }

  private nextOutputPaths(itemId: string): Array<string> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      throw new Error('应用上下文不可用');
    }
    this.outputSerial += 1;
    const stem: string = 'xdremux-' + itemId + '-' + String(Date.now()) + '-' + String(this.outputSerial);
    const outputDirectory: string = context.filesDir + '/outputs';
    return [outputDirectory + '/' + stem + '.heic.tmp', outputDirectory + '/' + stem + '.heic'];
  }

  private parentDirectory(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(0, slash);
  }

  private exportFileName(item: QueueItem): string {
    if (item.result === undefined) {
      return 'xdremux-export.heic';
    }
    const path: string = item.result.outputPath;
    const slash: number = path.lastIndexOf('/');
    const baseName: string = slash < 0 ? path : path.substring(slash + 1);
    const dot: number = baseName.lastIndexOf('.');
    const stem: string = dot > 0 ? baseName.substring(0, dot) : baseName;
    return stem + '-' + item.result.modeKey + '.heic';
  }

  private displayNameFromUri(uri: string, index: number): string {
    const slash: number = uri.lastIndexOf('/');
    const name: string = slash < 0 ? uri : uri.substring(slash + 1);
    return name.length === 0 ? '照片 ' + String(index + 1) : name;
  }

  private statusLabel(item: QueueItem): string {
    if (item.status === 'pending') {
      return item.result === undefined ? '待处理' : '待重新转换';
    }
    if (item.status === 'running') {
      return '处理中';
    }
    if (item.status === 'succeeded') {
      return '已完成';
    }
    return '失败';
  }

  private progressStageLabel(stage: number): string {
    if (stage === 1) {
      return '解析元数据';
    }
    if (stage === 2) {
      return '解码 JPEG';
    }
    if (stage === 3) {
      return '编码 HEVC';
    }
    if (stage === 4) {
      return '组装输出';
    }
    return '准备中';
  }

  private errorMessage(error: Object): string {
    try {
      if (error instanceof Error && error.message.length > 0) {
        return error.message;
      }
      const nativeError = error as NativeError;
      if (nativeError.message !== undefined && nativeError.message.length > 0) {
        return nativeError.message;
      }
      if (nativeError.code !== undefined) {
        return '错误码 ' + String(nativeError.code);
      }
      const serialized: string | undefined = JSON.stringify(error);
      if (serialized !== undefined && serialized !== '{}') {
        return serialized;
      }
      return String(error);
    } catch (formatError) {
      return '未知错误';
    }
  }

  private display(value: string | null | undefined): string {
    return value === null || value === undefined || value.length === 0 ? '—' : value;
  }

  private displayNumber(value: number | undefined): string {
    return value === undefined ? '—' : String(value);
  }

  private displayBigInt(value: bigint | undefined): string {
    return value === undefined ? '—' : String(value);
  }

  @Builder
  private selectedDetails(item: QueueItem): void {

            Column() {
              Text('当前项目详情')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
                .fontColor('#18202A')
                .width('100%')
                .margin({ bottom: 8 });
              Text('项目 ID：' + item.id + ' · 文件：' + item.displayName)
                .fontSize(14)
                .fontColor('#18202A')
                .width('100%');
              Text('源 URI：' + this.display(item.sourceUri))
                .fontSize(12)
                .fontColor('#52606D')
                .width('100%')
                .margin({ top: 4 });
              Text('沙盒输入：' + this.display(item.inputPath))
                .fontSize(12)
                .fontColor('#18202A')
                .width('100%')
                .margin({ top: 4, bottom: 10 });

              if (item.details !== undefined) {
                Text('照片详情')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#18202A')
                  .width('100%')
                  .margin({ bottom: 6 });
                Text('厂商：' + this.display(item.details.make) + ' · 型号：' +
                  this.display(item.details.model))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('时间：' + this.display(item.details.dateTime))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('曝光：' + this.display(item.details.exposureTime) + ' · 光圈：' +
                  this.display(item.details.fNumber) + ' · ISO：' + this.display(item.details.iso))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('焦距：' + this.display(item.details.focalLength) + ' · 35mm：' +
                  this.display(item.details.focalLength35mm) + ' · 曝光补偿：' +
                  this.display(item.details.exposureBias))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('尺寸：' + this.displayNumber(item.details.width) + ' × ' +
                  this.displayNumber(item.details.height) + ' · HDR：' +
                  this.display(item.details.hdrKind))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%')
                  .margin({ bottom: 10 });
              }

              if (item.classification !== undefined) {
                Text('分类结果')
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#18202A')
                  .width('100%')
                  .margin({ bottom: 6 });
                Text('状态：' + this.display(item.classification.status))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('模式：' + this.display(item.classification.modeKey) +
                  ' · 目录：' + this.display(item.classification.folderName))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('HDR：' + this.display(item.classification.hdrKind) + ' · 家族：' +
                  this.display(item.classification.family))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                Text('标签：' + String(item.classification.hasTagFlags) + ' · 标志：' +
                  this.displayBigInt(item.classification.tagFlags) + ' · 未知：' +
                  this.displayBigInt(item.classification.unknownFlags))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%')
                  .margin({ bottom: 10 });
              }

              if (item.result !== undefined) {
                Text('上次成功结果：' + item.result.modeLabel)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#18202A')
                  .width('100%')
                  .margin({ bottom: 6 });
                Text('结果路径：' + item.result.outputPath)
                  .fontSize(12)
                  .fontColor('#18202A')
                  .width('100%');
                Text('核心模式：' + this.display(item.result.conversion.mode) +
                  ' · 家族：' + this.display(item.result.conversion.family))
                  .fontSize(14)
                  .fontColor('#18202A')
                  .width('100%');
                if (item.attemptStatus === 'failed' && item.errorMessage.length > 0) {
                  Text('最新重转换失败；上次成功结果仍保留：' + item.errorMessage)
                    .fontSize(13)
                    .fontColor('#B3261E')
                    .width('100%')
                    .margin({ top: 4 });
                }
                if (item.exportedUri.length > 0) {
                  Text('已导出：' + item.exportedUri)
                    .fontSize(12)
                    .fontColor('#16845B')
                    .width('100%')
                    .margin({ top: 4 });
                }
              }

              Row() {
                Button('重试失败项目')
                  .fontSize(14)
                  .fontColor('#18202A')
                  .backgroundColor('#DDE5EE')
                  .layoutWeight(1)
                  .height(44)
                  .enabled(!this.pageBusy && !item.externalBusy && item.status === 'failed')
                  .onClick(() => {
                    this.retrySelected();
                  });
                Button('重新转换')
                  .fontSize(14)
                  .fontColor('#18202A')
                  .backgroundColor('#DDE5EE')
                  .layoutWeight(1)
                  .height(44)
                  .margin({ left: 8 })
                  .enabled(!this.pageBusy && !item.externalBusy && item.status === 'succeeded')
                  .onClick(() => {
                    this.reconvertSelected();
                  });
                Button('删除项目')
                  .fontSize(14)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#B3261E')
                  .layoutWeight(1)
                  .height(44)
                  .margin({ left: 8 })
                  .enabled(!this.pageBusy && !item.externalBusy && item.status !== 'running')
                  .onClick(() => {
                    this.removeSelected();
                  });
              }
              .width('100%')
              .margin({ top: 12 });
              Button('导出上次成功结果')
                .fontSize(15)
                .fontColor('#FFFFFF')
                .backgroundColor('#1F5FBF')
                .width('100%')
                .height(48)
                .margin({ top: 10 })
                .enabled(!this.pageBusy && !item.externalBusy && item.status !== 'running' &&
                  item.cleanupStatus !== 'failed' && item.result !== undefined)
                .onClick(() => {
                  this.exportSelected();
                });
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding(14)
            .backgroundColor('#FFFFFF')
            .borderRadius(12)
            .margin({ top: 8, bottom: 18 });
  }

  build() {
    Column() {
      Scroll() {
        Column() {
          Text('XDRemux 原生版')
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor('#18202A')
            .margin({ bottom: 6 });
          Text('P2 · 多文件队列（当前会话，前台运行）')
            .fontSize(15)
            .fontColor('#52606D')
            .margin({ bottom: 18 });

          Column() {
            Text('Rust 核心')
              .fontSize(14)
              .fontColor('#52606D');
            Text('xdremux ' + this.coreVersion)
              .fontSize(22)
              .fontWeight(FontWeight.Medium)
              .fontColor('#18202A')
              .margin({ top: 4 });
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding(18)
          .backgroundColor('#FFFFFF')
          .borderRadius(14)
          .margin({ bottom: 14 });

          Text('输出模式（每个项目在实际开始时获取设置快照）')
            .fontSize(14)
            .fontColor('#52606D')
            .width('100%');
          Row() {
            Button('OPPO 兼容')
              .fontSize(16)
              .fontColor(this.outputMode === 'oppo' ? '#FFFFFF' : '#18202A')
              .backgroundColor(this.outputMode === 'oppo' ? '#2E6BD6' : '#DDE5EE')
              .layoutWeight(1)
              .height(46)
              .enabled(!this.pageBusy)
              .onClick(() => {
                this.outputMode = 'oppo';
                this.operationStatus = '已选择 OPPO 兼容模式';
              });
            Button('Apple 标准')
              .fontSize(16)
              .fontColor(this.outputMode === 'apple' ? '#FFFFFF' : '#18202A')
              .backgroundColor(this.outputMode === 'apple' ? '#2E6BD6' : '#DDE5EE')
              .layoutWeight(1)
              .height(46)
              .margin({ left: 10 })
              .enabled(!this.pageBusy)
              .onClick(() => {
                this.outputMode = 'apple';
                this.operationStatus = '已选择 Apple 标准模式';
              });
          }
          .width('100%')
          .margin({ top: 8, bottom: 12 });

          Button('选择多个照片并加入队列')
            .fontSize(17)
            .fontColor('#FFFFFF')
            .backgroundColor('#1F5FBF')
            .width('100%')
            .height(52)
            .enabled(!this.pageBusy && !this.queueRunning)
            .onClick(() => {
              this.chooseAndImport();
            });

          Row() {
            Button(this.queueRunning ? '处理中…' : '开始 / 继续队列')
              .fontSize(16)
              .fontColor('#FFFFFF')
              .backgroundColor('#16845B')
              .layoutWeight(1)
              .height(48)
              .enabled(!this.pageBusy && !this.queueRunning && this.queueItems.length > 0)
              .onClick(() => {
                this.startQueue();
              });
            Button('停止（当前完成后）')
              .fontSize(15)
              .fontColor('#18202A')
              .backgroundColor('#DDE5EE')
              .layoutWeight(1)
              .height(48)
              .margin({ left: 10 })
              .enabled(this.queueRunning)
              .onClick(() => {
                this.stopQueue();
              });
          }
          .width('100%')
          .margin({ top: 10 });

          Text(this.operationStatus)
            .fontSize(15)
            .fontColor('#18202A')
            .width('100%')
            .margin({ top: 14, bottom: 8 });
          Text('队列项目：' + String(this.queueItems.length) +
            ' · 当前会话不持久化，重启后不会恢复；请保持应用在前台')
            .fontSize(13)
            .fontColor('#52606D')
            .width('100%')
            .margin({ bottom: 10 });

          if (this.queueItems.length === 0) {
            Text('尚未加入照片')
              .fontSize(16)
              .fontColor('#52606D')
              .width('100%');
          } else {
            Text('项目列表（点击项目查看详情）')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#18202A')
              .width('100%')
              .margin({ bottom: 8 });
            ForEach(this.queueItems, (item: QueueItem) => {
              Row() {
                Column() {
                  Text(item.displayName)
                    .fontSize(15)
                    .fontColor('#18202A')
                    .width('100%');
                  Text(this.statusLabel(item) +
                    (item.lastAttemptModeLabel.length > 0 ? ' · ' + item.lastAttemptModeLabel : ''))
                    .fontSize(13)
                    .fontColor(item.status === 'failed' ? '#B3261E' : '#52606D')
                    .width('100%')
                    .margin({ top: 4 });
                  if (item.status === 'running' || item.progress.current > 0 || item.progress.total > 0) {
                    Text(this.progressStageLabel(item.progress.stage) + '：' +
                      String(item.progress.current) + ' / ' + String(item.progress.total))
                      .fontSize(12)
                      .fontColor('#52606D')
                      .width('100%')
                      .margin({ top: 3 });
                  }
                  if (item.errorMessage.length > 0) {
                    Text(item.errorMessage)
                      .fontSize(12)
                      .fontColor('#B3261E')
                      .width('100%')
                      .margin({ top: 3 });
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1);
                Text(item.id === this.activeItemId ? '当前' : (item.id === this.selectedItemId ? '已选' : ''))
                  .fontSize(13)
                  .fontColor('#2E6BD6');
              }
              .width('100%')
              .padding(12)
              .backgroundColor(item.id === this.selectedItemId ? '#E7F0FF' : '#FFFFFF')
              .borderRadius(10)
              .margin({ bottom: 8 })
              .onClick(() => {
                this.selectedItemId = item.id;
              });
            }, (item: QueueItem) => item.id + '-' + String(item.revision));
          }

          if (this.selectedItem() !== undefined) {
            this.selectedDetails(this.selectedItemRequired());
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: 24, right: 24, top: 28, bottom: 24 });
      }
      .layoutWeight(1)
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F4F7FA');
  }
}
