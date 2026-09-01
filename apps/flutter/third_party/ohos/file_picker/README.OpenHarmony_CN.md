> 模板版本: v0.4.1

<p align="center">
  <h1 align="center"> <code>file_picker</code> </h1>
</p>

本项目基于 [file_picker](https://pub.dev/packages/file_picker) 开发。

## 简介

一个允许使用原生文件资源管理器选择单个或多个文件的包，并支持扩展名过滤功能。

## 下载安装

进入到工程目录并在 pubspec.yaml 中添加以下依赖：

```yaml
dependencies:
  file_picker:
    git:
      url: https://gitcode.com/CPF-Flutter/fluttertpc_file_picker.git
      ref: br_v8.0.7_ohos
```

执行命令：

```bash
flutter pub get
```

## 约束与限制

### 兼容性

已在以下环境验证通过：

1. Flutter: 3.7.12-ohos-1.0.6; DevEco Studio: 5.0.13.200; SDK: 5.0.0(12); ROM: 5.1.0.120 SP3;
2. Flutter: 3.22.1-ohos-1.0.1; DevEco Studio: 5.0.13.200; SDK: 5.0.0(12); ROM: 5.1.0.120 SP3。

### 权限要求

无。

## 使用示例

```dart
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

Future<void> pickSingleImage() async {
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    allowMultiple: false,
    type: FileType.custom,
    allowedExtensions: ['jpg', 'png'],
  );

  if (result == null) {
    return; // 用户取消选择
  }

  final PlatformFile pickedFile = result.files.single;
  debugPrint('Selected file => \'${pickedFile.name}\'');
}
```
更多用法可参考 [ohos/example](/example/lib/main.dart)。

## 使用说明

**单文件**
```dart
FilePickerResult? result = await FilePicker.platform.pickFiles();

if (result != null) {
  File file = File(result.files.single.path!);
} else {
  // User canceled the picker
}
```

**多文件**
```dart
FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);

if (result != null) {
  List<File> files = result.paths.map((path) => File(path!)).toList();
} else {
  // User canceled the picker
}
```

**带有扩展名过滤器的多文件**
```dart
FilePickerResult? result = await FilePicker.platform.pickFiles(
  allowMultiple: true,
  type: FileType.custom,
  allowedExtensions: ['jpg', 'pdf', 'doc'],
);
```

**选择目录**
```dart
String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

if (selectedDirectory == null) {
  // User canceled the picker
}
```

**保存文件 / 保存为新格式对话框**

```dart
String? outputFile = await FilePicker.platform.saveFile(
  dialogTitle: 'Please select an output file:',
  fileName: 'output-file.pdf',
);

if (outputFile == null) {
  // User canceled the picker
}
```

**加载结果和文件详情**
```dart
FilePickerResult? result = await FilePicker.platform.pickFiles();

if (result != null) {
  PlatformFile file = result.files.first;

  print(file.name);
  print(file.bytes);
  print(file.size);
  print(file.extension);
  print(file.path);
} else {
  // User canceled the picker
}
```

**以 XFile 形式或单独检索所有文件**
```dart
FilePickerResult? result = await FilePicker.platform.pickFiles();

if (result != null) {
  // All files
  List<XFile> xFiles = result.xFiles;

  // Individually
  XFile xFile = result.files.first.xFile;
} else {
  // User canceled the picker
}
```

**清除临时文件**

```dart
final bool? cleaned = await FilePicker.platform.clearTemporaryFiles();
```

## 接口说明

> [!TIP] "OpenHarmony 平台支持"列为 yes 表示 ohos 平台支持该属性；no 则表示不支持；partially 表示部分支持。使用方法跨平台一致，效果对标 iOS 或 Android 的效果。

### API

| 名称                  | 描述                         | 类型       | 参数类型                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | 返回值                    | OpenHarmony 平台支持 |
|---------------------|-------------------------------------|----------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------|------------------|
| pickFiles           | 这是选择文件的主要方法，并提供之前提到的所有属性            | function | String ?   dialogTitle , String ?   initialDirectory ,      FileType   type   =   FileType . any ,      List < String > ?   allowedExtensions ,      Function ( FilePickerStatus ) ?   onFileLoading ,      bool   allowCompression   =   true ,      int   compressionQuality   =   30 ,      bool   allowMultiple   =   false ,      bool   withData   =   false ,      bool   withReadStream   =   false ,      bool   lockParentWindow   =   false ,      bool   readSequential   =   false | Future<FilePickerResult?> | yes              |
| getDirectoryPath    | 打开文件夹选择器对话框，让用户选择目录路径。返回所选目录路径      | function | String ?   dialogTitle ,      bool   lockParentWindow   =   false ,      String ?   initialDirectory                                                                                                                                                                                                                                                                                                                                                                                            | Future<String?>           | yes              |
| clearTemporaryFiles | 一个实用方法，用于从选择器中显式删除缓存文件              | function | /                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Future<bool?>             | yes              |
| saveFile            | 打开“保存文件/另存为”对话框，允许用户选择文件路径和文件名以保存文件 | function | String ?   dialogTitle ,      String ?   fileName ,      String ?   initialDirectory ,      FileType   type   =   FileType . any ,      List < String > ?   allowedExtensions ,      Uint8List ?   bytes ,      bool   lockParentWindow   =   false                                                                                                                                                                                                                                             | Future<String?>           | yes              |


### Parameters

#### FileType

| 名称            | 描述        | 类型 | 参数类型 | 返回值 | OpenHarmony 平台支持 |
|-----------------|--------------------|------|-------|--------|--------------|
| FileType.any    | 选择所有可用的文件          | enum | /     | /      | yes          |
| FileType.custom | 选择与提供的允许扩展相匹配的扩展路径 | enum | /     | /      | yes          |
| FileType.image  | 选择图像文件             | enum | /     | /      | yes          |
| FileType.video  | 选择视频文件             | enum | /     | /      | yes          |
| FileType.media  | 选择视频或图像文件          | enum | /     | /      | yes          |
| FileType.audio  | 选择音频文件             | enum | /     | /      | yes          |

#### PickFilesOptions

| 名称               | 描述                                                       | 类型                        | 参数类型             | 返回值  | OpenHarmony 平台支持 |
|--------------------|----------------------------------------------------------|-----------------------------|------------------|------|--------------|
| allowedExtensions  | 接受允许过滤的扩展列表                                              | List?                       | /                | /    | yes          |
| dialogTitle        | 桌面平台模态对话框的标题设置                                           | String?                     | /                | /    | no           |
| initialDirectory   | 可以设置路径来指定对话框应该打开的位置                                      | String?                     | /                | /    | no           |
| withData           | 设置文件是否应立即加载到内存中并在其 PlatformFile 实例上作为 Uint8List 提供       | bool?                       | /                | /    | yes          |
| compressionQuality | 定义压缩图像时使用的压缩质量百分比。此值的范围是 0（无压缩）到 100                     | int?                        | /                | /    | no           |
| withReadStream     | 允许将文件读入 Stream 而不是立即将其加载到内存中，以防止高使用率，特别是对于较大的文件          | bool?                       | /                | /    | no           |
| lockParentWindow   | 如果为 true，则子窗口（文件选择器窗口）将停留在 Flutter 窗口前面，直到它被关闭（就像模态窗口一样） | bool?                       | /                | /    | no           |
| type               | 定义过滤文件的类型                                                | FileType                    | /                | /    | yes          |
| onFileLoading      | 提供后，将接收所选文件的处理状态                                         | Function(FilePickerStatus)? | FilePickerStatus | void | no           |


## 遗留问题

- [ ]  ohos 端 file picker selectMode
  设置选文件夹无效: [issue#14](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/14)

## 常见问题

1. 出现 `The current platform "ohos" is not supported by this plugin`。
   - 请确认引入的是 `file_picker`，并使用 `import 'package:file_picker/file_picker.dart';`。
   - 参考 issue: [#23](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/23)。
2. 不清楚如何在多平台工程中引入。
   - 建议先验证 OpenHarmony 端依赖是否指向本仓库 `ohos` 子目录，再统一整理多平台依赖版本。
   - 参考 issue: [#16](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/16), [#26](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/26)。
3. 目录选择能力与预期不一致。
   - 部分目录模式能力受设备形态限制，请先在目标设备上验证。
   - 参考 issue: [#14](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/14)。
4. `saveFile` 报错 `PlatformException(13900019, Is a directory, null, null)`。
   - 请确认传入了有效文件名，不要将目录路径当作文件路径使用；必要时去掉 `initialDirectory` 后重试。
   - 参考 issue: [#33](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues/33)。

## 目录结构

```text
fluttertpc_file_picker/
|- lib/                       # 插件公共实现与平台通用接口
|- ohos/                      # OpenHarmony原生侧实现
|- example/                   # 多平台示例应用
|  |- lib/                    # 应用 Dart 代码
|  |- ohos/                   # OpenHarmony工程
|- android/                   # Android 原生实现
|- ios/                       # iOS 原生实现
|- test/                      # Dart 单元测试
|- README.OpenHarmony_CN.md   # 中文文档
|- README.OpenHarmony.md      # 英文文档
```

## 贡献代码

使用过程中发现任何问题都可以提 [Issue](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/issues) ，当然，也非常欢迎发 [PR](https://gitcode.com/CPF-Flutter/fluttertpc_file_picker/pulls) 共建。

## 开源协议

本项目基于 [The MIT License](/LICENSE)，请自由地享受和参与开源。
