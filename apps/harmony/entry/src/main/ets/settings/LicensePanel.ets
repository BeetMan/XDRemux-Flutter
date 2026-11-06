// Open-source notices (same set as the Flutter app's license page): the
// project's GPL-3.0-only license, the statically linked x265 core and the
// vendored LocalSend transfer core. Texts ship in rawfile/licenses/.
import { util } from '@kit.ArkTS';

export const SOURCE_CODE_URL: string = 'https://github.com/BeetMan/XDRemux-Flutter';

interface LicenseEntry {
  name: string;
  license: string;
  file: string;
}

const LICENSES: Array<LicenseEntry> = [
  { name: 'XDRemux', license: 'GPL-3.0-only', file: 'licenses/XDRemux-GPL-3.0.txt' },
  { name: 'x265', license: 'GPL-2.0-or-later', file: 'licenses/x265-GPL-2.0.txt' },
  { name: 'LocalSend', license: 'Apache-2.0', file: 'licenses/LocalSend-Apache-2.0.txt' }
];

@Component
export struct LicensePanel {
  @State private selected: string = '';
  @State private text: string = '';

  private open(entry: LicenseEntry): void {
    try {
      const bytes: Uint8Array = this.getUIContext().getHostContext()!.resourceManager.getRawFileContentSync(entry.file);
      this.text = util.TextDecoder.create('utf-8').decodeToString(bytes);
      this.selected = entry.name;
    } catch (error) {
      this.text = '无法读取许可文本';
      this.selected = entry.name;
    }
  }

  build() {
    Scroll() {
      Column() {
        if (this.selected.length === 0) {
          Text('XDRemux 是自由软件，按 GPL-3.0-only 授权。源代码、历史版本说明，以及移植自上游的代码与第三方组件的许可：')
            .fontSize(14)
            .fontColor($r('sys.color.font_primary'))
            .width('100%');
          Text(SOURCE_CODE_URL)
            .fontSize(14)
            .fontColor($r('sys.color.font_emphasize'))
            .copyOption(CopyOptions.LocalDevice)
            .width('100%')
            .margin({ top: 4, bottom: 12 });
          ForEach(LICENSES, (entry: LicenseEntry) => {
            Row() {
              Column() {
                Text(entry.name)
                  .fontSize(15)
                  .fontColor($r('sys.color.font_primary'))
                  .width('100%');
                Text(entry.license)
                  .fontSize(12)
                  .fontColor($r('sys.color.font_secondary'))
                  .width('100%');
              }
              .layoutWeight(1);
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(18)
                .fontColor([$r('sys.color.font_secondary')]);
            }
            .width('100%')
            .padding({ top: 12, bottom: 12 })
            .onClick((): void => {
              this.open(entry);
            });
          }, (entry: LicenseEntry): string => entry.name);
        } else {
          Text('‹ 返回')
            .fontSize(14)
            .fontColor($r('sys.color.font_emphasize'))
            .padding({ top: 4, bottom: 10 })
            .onClick((): void => {
              this.selected = '';
              this.text = '';
            });
          Text(this.text)
            .fontSize(12)
            .fontColor($r('sys.color.font_primary'))
            .width('100%');
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, bottom: 32 });
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Auto);
  }
}
