/** Platform-neutral file copy contract for batch export. */
export interface BatchExportFileStat {
  size: number;
}

export interface BatchExportFileIo {
  openUri(uri: string): Promise<number>;
  statPath(path: string): Promise<BatchExportFileStat>;
  statFd(fd: number): Promise<BatchExportFileStat>;
  copyPathToFd(path: string, fd: number): Promise<void>;
  close(fd: number): Promise<void>;
}

/**
 * Copy one already-created DocumentViewPicker target. The target is accepted
 * only when empty, the source is non-empty, copy size matches, and close
 * succeeds. A failed copy never unlinks an arbitrary user URI.
 */
export async function copyBatchOutput(
  io: BatchExportFileIo,
  sourcePath: string,
  destinationUri: string,
  sourceUri: string
): Promise<void> {
  if (destinationUri === sourceUri || destinationUri === sourcePath) {
    throw new Error('导出位置不能是原始输入或应用沙盒文件');
  }
  const sourceStat: BatchExportFileStat = await io.statPath(sourcePath);
  if (!Number.isFinite(sourceStat.size) || sourceStat.size <= 0) {
    throw new Error('沙盒转换结果为空或大小无效');
  }

  let fd: number = -1;
  try {
    fd = await io.openUri(destinationUri);
    const existingTarget: BatchExportFileStat = await io.statFd(fd);
    if (!Number.isFinite(existingTarget.size) || existingTarget.size !== 0) {
      throw new Error('导出位置已有内容，请选择新的文件名');
    }
    await io.copyPathToFd(sourcePath, fd);
    const copied: BatchExportFileStat = await io.statFd(fd);
    if (!Number.isFinite(copied.size) || copied.size !== sourceStat.size) {
      throw new Error('导出文件大小校验失败');
    }
    await io.close(fd);
    fd = -1;
  } finally {
    if (fd >= 0) {
      try {
        await io.close(fd);
      } catch (closeError) {
        // Preserve the original copy/stat/close error. A target URI is never
        // unlinked because ownership remains with the document provider.
      }
    }
  }
}