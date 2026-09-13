import { fileIo } from '@kit.CoreFileKit';
import { picker } from '@kit.CoreFileKit';
import xdremuxNative from 'libentry.so';

interface NativeClassificationResult {
  modeKey: string | null;
  folderName: string | null;
  status: string | null;
  rawUserComment: string | null;
  hasTagFlags: boolean;
  tagFlags: bigint;
  unknownFlags: bigint;
  hdrKind: string | null;
  family: string | null;
}

interface NativePhotoDetails {
  success: boolean;
  errorMessage?: string;
  make?: string;
  model?: string;
  dateTime?: string;
  exposureTime?: string;
  fNumber?: string;
  iso?: string;
  focalLength?: string;
  focalLength35mm?: string;
  exposureBias?: string;
  width?: number;
  height?: number;
  hdrKind?: string;
  edrScale?: number;
  gainMapMax?: number;
}

interface NativeConversionResult {
  success: boolean;
  mode: string | null;
  family: string | null;
  edrScale: number;
  gainMapMax: number;
  errorMessage: string | null;
}

interface NativeConvertConfig {
  oppoCompat: number;
  oppoCameraTail: number;
  strictTmap: number;
  applePhotographicStyles: number;
  applePortrait: number;
}

interface NativeProgress {
  stage: number;
  current: number;
  total: number;
}

interface NativeError {
  message?: string;
  code?: number;
}

@Entry
@Component
struct Index {
  @State private coreVersion: string = '加载中…';
  @State private operationStatus: string = '准备就绪';
  @State private materializedPath: string = '';
  @State private sourceUri: string = '';
  @State private classification: NativeClassificationResult | undefined = undefined;
  @State private details: NativePhotoDetails | undefined = undefined;
  @State private conversion: NativeConversionResult | undefined = undefined;
  @State private convertedPath: string = '';
  @State private convertedModeKey: string = '';
  @State private convertedMode: string = '';
  @State private exportedUri: string = '';
  @State private outputMode: string = 'oppo';
  @State private busy: boolean = false;
  @State private progressHandle: number = 0;
  @State private progressStage: number = 0;
  @State private progressCurrent: number = 0;
  @State private progressTotal: number = 0;

  private progressTimer: number = -1;
  private inputSerial: number = 0;
  private outputSerial: number = 0;

  aboutToAppear(): void {
    this.refreshVersion();
  }

  aboutToDisappear(): void {
    // The conversion Promise owns the progress handle until it settles. The
    // page lifecycle only stops UI polling; it must not release a live Rust job.
    this.stopProgressPolling();
  }

  private async refreshVersion(): Promise<void> {
    this.busy = true;
    this.operationStatus = '正在异步读取 Rust 核心版本…';
    try {
      this.coreVersion = await xdremuxNative.version();
      this.operationStatus = 'Rust 核心已加载';
    } catch (error) {
      this.coreVersion = '不可用';
      this.operationStatus = '读取核心版本失败：' + this.errorMessage(error);
    } finally {
      this.busy = false;
    }
  }

  private async chooseAndPrepare(): Promise<void> {
    this.busy = true;
    this.operationStatus = '正在打开系统文件选择器…';
    let newMaterializedPath: string = '';
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('应用上下文不可用');
      }
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      options.fileSuffixFilters = ['Images|.heic,.heif,.jpg,.jpeg,.png'];
      options.maxSelectNumber = 1;
      // DocumentViewPicker keeps the original document URI path. The bytes
      // are copied into the sandbox before either Rust call receives a path.
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const selected: Array<string> = await documentPicker.select(options);
      if (selected.length === 0) {
        this.operationStatus = '未选择照片';
        return;
      }

      const newSourceUri: string = selected[0];
      this.operationStatus = '正在把原始文件复制到应用沙盒…';
      newMaterializedPath = await this.materializeUri(newSourceUri);
      this.operationStatus = '正在读取照片详情…';
      const detailsJson: string = await xdremuxNative.inspect(newMaterializedPath);
      const parsed: NativePhotoDetails = JSON.parse(detailsJson) as NativePhotoDetails;
      if (!parsed.success) {
        throw new Error(this.display(parsed.errorMessage));
      }
      this.operationStatus = '正在异步读取分类…';
      const newClassification: NativeClassificationResult =
        await xdremuxNative.classify(newMaterializedPath) as NativeClassificationResult;

      // Commit the new task only after materialization, details, and classify
      // all succeed. A picker cancel or a bad new file keeps the prior result
      // available for retry/export.
      this.sourceUri = newSourceUri;
      this.materializedPath = newMaterializedPath;
      this.details = parsed;
      this.classification = newClassification;
      this.conversion = undefined;
      this.convertedPath = '';
      this.convertedModeKey = '';
      this.convertedMode = '';
      this.exportedUri = '';
      this.operationStatus = '照片已准备：' + this.display(newClassification.status);
    } catch (error) {
      if (newMaterializedPath.length > 0 && newMaterializedPath !== this.materializedPath) {
        try {
          await fileIo.unlink(newMaterializedPath);
        } catch (cleanupError) {
          // Preserve the new-file error and the prior task state.
        }
      }
      this.operationStatus = '准备照片失败：' + this.errorMessage(error);
    } finally {
      this.busy = false;
    }
  }

  private async classifyCurrentPath(): Promise<void> {
    if (this.materializedPath.length === 0) {
      this.operationStatus = '请先选择照片';
      return;
    }
    this.busy = true;
    this.operationStatus = '正在重新读取沙盒副本的分类…';
    try {
      this.classification = await xdremuxNative.classify(this.materializedPath) as NativeClassificationResult;
      this.operationStatus = '分类完成：' + this.display(this.classification.status);
    } catch (error) {
      this.operationStatus = '分类失败：' + this.errorMessage(error);
    } finally {
      this.busy = false;
    }
  }

  private settingsForMode(): NativeConvertConfig {
    if (this.outputMode === 'apple') {
      // Flutter's Apple standard semantic mapping: OPPO compatibility and
      // automatic camera-tail metadata are both disabled.
      return {
        oppoCompat: 0,
        oppoCameraTail: 0,
        strictTmap: 0,
        applePhotographicStyles: 0,
        applePortrait: 0
      };
    }
    // Flutter's OPPO compatible mapping: compatibility mode 2 and automatic
    // camera tail 255. The deferred style/portrait switches remain disabled.
    return {
      oppoCompat: 2,
      oppoCameraTail: 255,
      strictTmap: 0,
      applePhotographicStyles: 0,
      applePortrait: 0
    };
  }

  private modeLabel(mode: string): string {
    return mode === 'apple' ? 'Apple 标准' : 'OPPO 兼容';
  }

  private async startConversion(): Promise<void> {
    if (this.materializedPath.length === 0) {
      this.operationStatus = '请先选择照片';
      return;
    }
    if (this.busy) {
      return;
    }

    // Snapshot the selected mode/config before any asynchronous boundary.
    const selectedMode: string = this.outputMode;
    const config: NativeConvertConfig = this.settingsForMode();
    let temporaryPath: string = '';
    let finalPath: string = '';
    let handle: number = 0;
    let promoted: boolean = false;

    this.busy = true;
    this.conversion = undefined;
    this.convertedPath = '';
    this.convertedModeKey = '';
    this.convertedMode = '';
    this.exportedUri = '';
    this.progressStage = 0;
    this.progressCurrent = 0;
    this.progressTotal = 0;
    this.operationStatus = '正在准备转换：' + this.modeLabel(selectedMode);
    try {
      const paths: Array<string> = this.nextOutputPaths();
      temporaryPath = paths[0];
      finalPath = paths[1];
      if (temporaryPath === this.materializedPath || finalPath === this.materializedPath) {
        throw new Error('输出路径不能覆盖输入文件');
      }
      await this.ensureDirectory(this.parentDirectory(finalPath));
      handle = xdremuxNative.progressBegin();
      if (handle === 0) {
        throw new Error('无法创建转换进度句柄');
      }
      this.progressHandle = handle;
      this.startProgressPolling(handle);
      this.operationStatus = '正在转换，请保持应用打开…';
      const result: NativeConversionResult = await xdremuxNative.convert(
        this.materializedPath,
        temporaryPath,
        config,
        handle
      ) as NativeConversionResult;
      this.conversion = result;
      // Rust clears the progress registry before returning its result. The
      // result ABI, rather than a final 100% poll, determines completion.
      if (!result.success) {
        throw new Error(this.display(result.errorMessage));
      }
      const temporaryStat = await fileIo.stat(temporaryPath);
      if (temporaryStat.size <= 0) {
        throw new Error('转换输出为空');
      }
      await fileIo.rename(temporaryPath, finalPath);
      promoted = true;
      const finalStat = await fileIo.stat(finalPath);
      if (finalStat.size <= 0) {
        throw new Error('转换输出校验失败');
      }
      this.convertedPath = finalPath;
      this.convertedModeKey = selectedMode;
      this.convertedMode = this.modeLabel(selectedMode);
      this.operationStatus = '转换成功：结果已保留在沙盒，可继续导出';
    } catch (error) {
      this.operationStatus = '转换失败：' + this.errorMessage(error);
      // These are unique paths created by this operation, so cleanup cannot
      // remove an existing user file. The original input is never touched.
      try {
        await fileIo.unlink(promoted ? finalPath : temporaryPath);
      } catch (cleanupError) {
        // Keep the original conversion error visible.
      }
      this.convertedPath = '';
      this.convertedModeKey = '';
      this.convertedMode = '';
      this.conversion = undefined;
    } finally {
      this.stopProgressPolling();
      if (handle !== 0) {
        try {
          // Release only after the native Promise has actually settled.
          xdremuxNative.progressEnd(handle);
        } catch (endError) {
          // The Rust operation has already settled; no UI action can recover
          // a failed best-effort registry cleanup here.
        }
      }
      this.progressHandle = 0;
      this.busy = false;
    }
  }

  private startProgressPolling(handle: number): void {
    this.stopProgressPolling();
    this.progressTimer = setInterval(() => {
      if (this.progressHandle !== handle) {
        return;
      }
      try {
        const progress: NativeProgress = xdremuxNative.progressRead(handle) as NativeProgress;
        this.progressStage = progress.stage;
        this.progressCurrent = progress.current;
        this.progressTotal = progress.total;
      } catch (error) {
        // The Rust call clears the registry immediately before returning the
        // final ConversionResult, so a late zero/empty read is expected.
      }
    }, 250);
  }

  private stopProgressPolling(): void {
    if (this.progressTimer >= 0) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
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

  private nextOutputPaths(): Array<string> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      throw new Error('应用上下文不可用');
    }
    this.outputSerial += 1;
    const stem: string = 'xdremux-' + String(Date.now()) + '-' + String(this.outputSerial);
    const outputDirectory: string = context.filesDir + '/outputs';
    return [outputDirectory + '/' + stem + '.heic.tmp', outputDirectory + '/' + stem + '.heic'];
  }

  private parentDirectory(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(0, slash);
  }

  private async ensureDirectory(path: string): Promise<void> {
    try {
      await fileIo.mkdir(path, true);
      return;
    } catch (mkdirError) {
      // A recursive mkdir may report an existing directory. Continue only if
      // the explicit access check proves that this exact directory exists.
      try {
        const exists: boolean = await fileIo.access(path);
        if (exists) {
          return;
        }
      } catch (accessError) {
        // Fall through with the original mkdir failure.
      }
      throw new Error(this.errorMessage(mkdirError));
    }
  }

  private async materializeUri(sourceUri: string): Promise<string> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      throw new Error('应用上下文不可用');
    }
    this.inputSerial += 1;
    const inputDirectory: string = context.filesDir + '/inputs';
    const destination: string = inputDirectory + '/input-' + String(Date.now()) + '-' +
      String(this.inputSerial) + '.photo';
    let sourceFd: number = -1;
    try {
      await this.ensureDirectory(inputDirectory);
      // Open the capability-bearing URI, then copy its FD into the sandbox.
      // Rust receives only the ordinary destination path.
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
        // The destination may not have been created. Preserve the source error.
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

  private async exportConverted(): Promise<void> {
    if (this.convertedPath.length === 0) {
      this.operationStatus = '请先完成一次转换';
      return;
    }
    if (this.busy) {
      return;
    }

    this.busy = true;
    this.operationStatus = '正在打开系统保存位置选择器…';
    let targetFd: number = -1;
    try {
      const context = this.getUIContext().getHostContext();
      if (context === undefined) {
        throw new Error('应用上下文不可用');
      }
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      options.newFileNames = [this.exportFileName()];
      options.fileSuffixChoices = ['HEIF 图像|.heic'];
      const saved: Array<string> = await documentPicker.save(options);
      if (saved.length === 0) {
        this.operationStatus = '未选择导出位置，沙盒结果仍保留';
        return;
      }
      const destinationUri: string = saved[0];
      if (destinationUri === this.sourceUri) {
        throw new Error('导出位置不能是原始输入文件');
      }
      const sourceStat = await fileIo.stat(this.convertedPath);
      if (sourceStat.size <= 0) {
        throw new Error('沙盒转换结果为空');
      }

      // DocumentSaveOptions on API 18 pre-creates the target. Open it without
      // TRUNC, reject a non-empty target, then copy through its FD.
      targetFd = (await fileIo.open(destinationUri, fileIo.OpenMode.WRITE_ONLY)).fd;
      const existingTargetStat = await fileIo.stat(targetFd);
      if (existingTargetStat.size !== 0) {
        throw new Error('导出位置已有内容，请选择新的文件名');
      }
      await fileIo.copyFile(this.convertedPath, targetFd);
      const copiedStat = await fileIo.stat(targetFd);
      if (copiedStat.size !== sourceStat.size) {
        throw new Error('导出文件大小校验失败');
      }
      await fileIo.close(targetFd);
      targetFd = -1;
      this.exportedUri = destinationUri;
      this.operationStatus = '导出成功：已写入系统文件位置';
    } catch (error) {
      this.operationStatus = '导出失败：' + this.errorMessage(error) + '；沙盒结果仍保留，可重试';
    } finally {
      if (targetFd >= 0) {
        try {
          await fileIo.close(targetFd);
        } catch (closeError) {
          // Do not claim export success when close failed; the URI remains
          // unreported and the sandbox result remains available.
        }
      }
      this.busy = false;
    }
  }

  private exportFileName(): string {
    const slash: number = this.convertedPath.lastIndexOf('/');
    const baseName: string = slash < 0 ? this.convertedPath : this.convertedPath.substring(slash + 1);
    const dot: number = baseName.lastIndexOf('.');
    const stem: string = dot > 0 ? baseName.substring(0, dot) : baseName;
    const mode: string = this.convertedModeKey === 'apple' ? 'apple' : 'oppo';
    return stem + '-' + mode + '.heic';
  }

  private errorMessage(error: Object): string {
    try {
      if (error instanceof Error && error.message.length > 0) {
        return error.message;
      }
      const errorObject = error as NativeError;
      if (errorObject.message !== undefined && errorObject.message.length > 0) {
        return errorObject.message;
      }
      if (errorObject.code !== undefined) {
        return '错误码 ' + String(errorObject.code);
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

  build() {
    Column() {
      Scroll() {
        Column() {
          Text('XDRemux 原生版')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor('#18202A')
        .margin({ bottom: 6 });
      Text('P1 · 单文件读取、转换与导出')
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

      Text('输出模式')
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
          .enabled(!this.busy)
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
          .enabled(!this.busy)
          .onClick(() => {
            this.outputMode = 'apple';
            this.operationStatus = '已选择 Apple 标准模式';
          });
      }
      .width('100%')
      .margin({ top: 8, bottom: 12 });

      Button('选择照片并读取详情')
        .fontSize(17)
        .fontColor('#FFFFFF')
        .backgroundColor('#1F5FBF')
        .width('100%')
        .height(52)
        .enabled(!this.busy)
        .onClick(() => {
          this.chooseAndPrepare();
        });

      if (this.materializedPath.length > 0) {
        Button('重新读取沙盒副本分类')
          .fontSize(15)
          .fontColor('#18202A')
          .backgroundColor('#DDE5EE')
          .width('100%')
          .height(44)
          .margin({ top: 10 })
          .enabled(!this.busy)
          .onClick(() => {
            this.classifyCurrentPath();
          });
      }

      Button('开始转换')
        .fontSize(17)
        .fontColor('#FFFFFF')
        .backgroundColor('#16845B')
        .width('100%')
        .height(52)
        .margin({ top: 10 })
        .enabled(!this.busy && this.materializedPath.length > 0)
        .onClick(() => {
          this.startConversion();
        });

      Text(this.operationStatus)
        .fontSize(15)
        .fontColor('#18202A')
        .width('100%')
        .margin({ top: 14, bottom: 8 });

      Column() {
          if (this.progressHandle !== 0 || this.progressCurrent !== 0 || this.progressTotal !== 0) {
            Text('转换进度：' + this.progressStageLabel(this.progressStage) + '，' +
              String(this.progressCurrent) + ' / ' + String(this.progressTotal))
              .fontSize(14)
              .fontColor('#18202A')
              .width('100%')
              .margin({ bottom: 12 });
          }

          if (this.materializedPath.length > 0) {
            Text('沙盒输入路径')
              .fontSize(13)
              .fontColor('#52606D')
              .width('100%');
            Text(this.materializedPath)
              .fontSize(13)
              .fontColor('#18202A')
              .width('100%')
              .margin({ top: 4, bottom: 12 });
          }

          if (this.details !== undefined) {
            Text('照片详情')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#18202A')
              .width('100%')
              .margin({ bottom: 8 });
            Text('厂商：' + this.display(this.details.make) + ' · 型号：' + this.display(this.details.model))
              .fontSize(14)
              .fontColor('#18202A')
              .width('100%');
            Text('时间：' + this.display(this.details.dateTime))
              .fontSize(14)
              .fontColor('#18202A')
              .width('100%');
            Text('曝光：' + this.display(this.details.exposureTime) + ' · 光圈：' +
              this.display(this.details.fNumber) + ' · ISO：' + this.display(this.details.iso))
              .fontSize(14)
              .fontColor('#18202A')
              .width('100%');
            Text('焦距：' + this.display(this.details.focalLength) + ' · 35mm：' +
              this.display(this.details.focalLength35mm) + ' · 曝光补偿：' +
              this.display(this.details.exposureBias))
              .fontSize(14)
              .fontColor('#18202A')
              .width('100%');
            Text('尺寸：' + this.displayNumber(this.details.width) + ' × ' +
              this.displayNumber(this.details.height) + ' · HDR：' + this.display(this.details.hdrKind))
              .fontSize(14)
              .fontColor('#18202A')
              .width('100%')
              .margin({ bottom: 12 });
          }

          if (this.classification !== undefined) {
            Text('分类结果')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#18202A')
              .width('100%')
              .margin({ bottom: 8 });
            Text('状态：' + this.display(this.classification.status))
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
            Text('模式：' + this.display(this.classification.modeKey))
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
            Text('目录：' + this.display(this.classification.folderName))
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
            Text('HDR：' + this.display(this.classification.hdrKind) + ' · 家族：' +
              this.display(this.classification.family))
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
            Text('标签：' + String(this.classification.hasTagFlags) + ' · 标志：' +
              this.displayBigInt(this.classification.tagFlags))
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
            Text('未知标志：' + this.displayBigInt(this.classification.unknownFlags))
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%')
              .margin({ bottom: 12 });
          }

          if (this.conversion !== undefined && this.convertedPath.length > 0) {
            Text('转换结果')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#18202A')
              .width('100%')
              .margin({ bottom: 8 });
            Text('模式：' + this.convertedMode + ' · 家族：' + this.display(this.conversion.family))
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
            Text('结果路径：' + this.convertedPath)
              .fontSize(13)
              .fontColor('#18202A')
              .width('100%')
              .margin({ bottom: 8 });
            Button('导出到系统文件位置')
              .fontSize(16)
              .fontColor('#FFFFFF')
              .backgroundColor('#1F5FBF')
              .width('100%')
              .height(48)
              .enabled(!this.busy)
              .onClick(() => {
                this.exportConverted();
              });
            if (this.exportedUri.length > 0) {
              Text('已导出：' + this.exportedUri)
                .fontSize(13)
                .fontColor('#16845B')
                .width('100%')
                .margin({ top: 8 });
            }
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%');
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%');
      }
      .layoutWeight(1)
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 28, bottom: 24 })
    .backgroundColor('#F4F7FA');
  }
}
