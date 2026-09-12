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

interface NativeError {
  message?: string;
  code?: number;
}

@Entry
@Component
struct Index {
  @State private coreVersion: string = 'Loading…';
  @State private operationStatus: string = 'Ready';
  @State private materializedPath: string = '';
  @State private classification: NativeClassificationResult | undefined = undefined;
  @State private busy: boolean = false;

  aboutToAppear(): void {
    this.refreshVersion();
  }

  private async refreshVersion(): Promise<void> {
    this.busy = true;
    this.operationStatus = 'Calling xdremux_version asynchronously…';
    try {
      this.coreVersion = await xdremuxNative.version();
      this.operationStatus = 'Core version loaded';
    } catch (error) {
      this.coreVersion = 'Unavailable';
      this.operationStatus = `Version call failed: ${this.errorMessage(error)}`;
    } finally {
      this.busy = false;
    }
  }

  private async chooseAndClassify(): Promise<void> {
    this.busy = true;
    this.classification = undefined;
    this.operationStatus = 'Opening the system photo picker…';
    try {
      const options: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      // DocumentViewPicker returns the selected document URI without routing
      // it through a gallery preview/transcoding path.
      options.fileSuffixFilters = ['Images|.heic,.heif,.jpg,.jpeg,.png'];
      options.maxSelectNumber = 1;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const selected: Array<string> = await documentPicker.select(options);
      if (selected.length === 0) {
        this.operationStatus = 'No photo selected';
        return;
      }

      // photoUris are capability-bearing URIs. Materialize the bytes into the
      // app sandbox first; Rust receives only this ordinary filesystem path.
      this.operationStatus = 'Copying the selected URI into the app sandbox…';
      this.materializedPath = await this.materializeUri(selected[0]);
      this.operationStatus = 'Calling xdremux_classify asynchronously…';
      this.classification = await xdremuxNative.classify(this.materializedPath) as NativeClassificationResult;
      this.operationStatus = `Classification complete: ${this.classification.status ?? 'unknown status'}`;
    } catch (error) {
      this.operationStatus = `Classification failed: ${this.errorMessage(error)}`;
    } finally {
      this.busy = false;
    }
  }

  private async classifyCurrentPath(): Promise<void> {
    if (this.materializedPath.length === 0) {
      this.operationStatus = 'Choose an image before reclassifying';
      return;
    }
    this.busy = true;
    this.operationStatus = 'Calling xdremux_classify on the retained sandbox copy…';
    try {
      this.classification = await xdremuxNative.classify(this.materializedPath) as NativeClassificationResult;
      this.operationStatus = 'Classification complete: ' + (this.classification.status ?? 'unknown status');
    } catch (error) {
      this.operationStatus = 'Classification failed: ' + this.errorMessage(error);
    } finally {
      this.busy = false;
    }
  }

  private async materializeUri(sourceUri: string): Promise<string> {
    const context = this.getUIContext().getHostContext();
    if (context === undefined) {
      throw new Error('Application context is unavailable');
    }
    const inputDirectory: string = `${context.filesDir}/inputs`;
    const destination: string = `${inputDirectory}/input-${Date.now()}.photo`;
    let sourceFd: number = -1;
    try {
      try {
        await fileIo.mkdir(inputDirectory, true);
      } catch (mkdirError) {
        // Recursive mkdir can report an existing directory as an error. Only
        // continue when an explicit access check confirms it exists.
        let directoryExists: boolean = false;
        try {
          directoryExists = await fileIo.access(inputDirectory);
        } catch (accessError) {
          directoryExists = false;
        }
        if (!directoryExists) {
          throw new Error(this.errorMessage(mkdirError));
        }
      }
      // copyFile accepts an FD and a sandbox path. Opening the URI first
      // preserves the picker grant while ensuring Rust never sees the URI.
      sourceFd = (await fileIo.open(sourceUri, fileIo.OpenMode.READ_ONLY)).fd;
      await fileIo.copyFile(sourceFd, destination);
      const stat = await fileIo.stat(destination);
      if (stat.size <= 0) {
        throw new Error('The materialized photo is empty');
      }
      return destination;
    } catch (error) {
      // Never leave a partial file that could be mistaken for a valid input.
      try {
        await fileIo.unlink(destination);
      } catch (cleanupError) {
        // The destination may not have been created; preserve the original
        // operation error for the user.
      }
      throw new Error(this.errorMessage(error));
    } finally {
      if (sourceFd >= 0) {
        try {
          await fileIo.close(sourceFd);
        } catch (closeError) {
          // Preserve the copy/classification error if one already occurred.
        }
      }
    }
  }

  private errorMessage(error: Object): string {
    const errorObject = error as NativeError;
    if (errorObject.message !== undefined && errorObject.message.length > 0) {
      return errorObject.message;
    }
    if (errorObject.code !== undefined) {
      return `code=${String(errorObject.code)}`;
    }
    return String(error);
  }

  private display(value: string | null | undefined): string {
    return value === null || value === undefined || value.length === 0 ? '—' : value;
  }

  private displayBigInt(value: bigint | undefined): string {
    return value === undefined ? '—' : String(value);
  }

  build() {
    Column() {
      Text('XDRemux Native')
        .fontSize(30)
        .fontWeight(FontWeight.Bold)
        .fontColor('#18202A')
        .margin({ bottom: 6 });
      Text('P0 · Rust ABI and sandbox materialization')
        .fontSize(15)
        .fontColor('#52606D')
        .margin({ bottom: 22 });

      Column() {
        Text('Rust core')
          .fontSize(14)
          .fontColor('#52606D');
        Text(`xdremux ${this.coreVersion}`)
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
      .margin({ bottom: 16 });

      Button('Choose an image and classify')
        .fontSize(17)
        .width('100%')
        .height(52)
        .enabled(!this.busy)
        .onClick(() => {
          this.chooseAndClassify();
        });

      Button('Refresh core version')
        .fontSize(15)
        .width('100%')
        .height(46)
        .margin({ top: 10 })
        .enabled(!this.busy)
        .onClick(() => {
          this.refreshVersion();
        });

      if (this.materializedPath.length > 0) {
        Button('Classify the sandbox copy again')
          .fontSize(15)
          .width('100%')
          .height(46)
          .margin({ top: 10 })
          .enabled(!this.busy)
          .onClick(() => {
            this.classifyCurrentPath();
          });
      }

      Text(this.operationStatus)
        .fontSize(15)
        .fontColor('#52606D')
        .width('100%')
        .margin({ top: 18, bottom: 10 });

      Scroll() {
        Column() {
          if (this.materializedPath.length > 0) {
            Text('Materialized path')
              .fontSize(13)
              .fontColor('#52606D')
              .width('100%');
            Text(this.materializedPath)
              .fontSize(13)
              .fontColor('#18202A')
              .width('100%')
              .margin({ top: 4, bottom: 14 });
          }
          if (this.classification !== undefined) {
            Text('Classification result')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor('#18202A')
              .width('100%')
              .margin({ bottom: 10 });
            Text(`status: ${this.display(this.classification.status)}`)
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
            Text(`modeKey: ${this.display(this.classification.modeKey)}`)
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
            Text(`folderName: ${this.display(this.classification.folderName)}`)
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
            Text(`hdrKind: ${this.display(this.classification.hdrKind)} · family: ${this.display(this.classification.family)}`)
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
            Text(`hasTagFlags: ${String(this.classification.hasTagFlags)} · tagFlags: ${this.displayBigInt(this.classification.tagFlags)}`)
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
            Text(`unknownFlags: ${this.displayBigInt(this.classification.unknownFlags)}`)
              .fontSize(15)
              .fontColor('#18202A')
              .width('100%');
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%');
      }
      .layoutWeight(1)
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .padding({ left: 24, right: 24, top: 32, bottom: 24 })
    .backgroundColor('#F4F7FA');
  }
}
