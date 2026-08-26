# 上游 issue 草稿：macOS 27 私有 API 适配

> 草稿，待你确认后再发到 21Z121Z1/XDRemux。补丁目前在本机克隆
> `../XDRemux-upstream` 工作区（`learnnode_coefficient_probe.m`，未提交）。

---

**Title: macOS 27 (Tahoe successor) breaks key-1 calibration: PLPhotoEditSource init & _NUStyleTransferApplyProcessor signatures changed**

## Summary

On macOS 27 (current developer beta), both the constrained-solver key-1 path and the ReverseKey1 fast path's admission proxy fail hard, because two private PhotoKit/Neutrino APIs changed shape:

1. `PLPhotoEditSource` no longer responds to `initWithURL:type:image:useEmbeddedPreview:` — the only remaining initializer is `initWithURL:type:useEmbeddedPreview:` (the `image:` parameter was dropped). The unguarded `objc_msgSend` in `learnnode_coefficient_probe.m` (`RunNeutrinoStyleRender`) throws `NSInvalidArgumentException`, which aborts the whole conversion with `complete-Neutrino key-1 calibration render batch failed`.
2. `+[_NUStyleTransferApplyProcessor applyStyle:toImage:thumbnail:target:deltaMap:colorSpace:configuration:tuningParameters:noiseModel:error:]` gained a `displacement:` parameter between `deltaMap:` and `colorSpace:`. The old selector is gone, so the semantic-proxy admission helper crashes the same way and the fast path always falls back to identity.

## Repro

```
xdremux convert --input <any ProXDR heic> --output out.heic \
  --apple-photographic-styles --apple-style-data-producer constrained-solver
```

on macOS 27 → `NSInvalidArgumentException` from `learnnode-coefficient-probe`.

With `XDREMUX_RESEARCH_REVERSE_KEY1_COREML_MODEL` set, conversion succeeds but `fast-path-result.json` shows `status: identity-fallback, fallbackKind: semantic-proxy-helper-failed` — the model prediction is computed but never admitted.

## Fix approach (verified locally)

Runtime selector probing keeps one binary compatible with both old and new OS versions:

```objc
// 1. PLPhotoEditSource init
SEL initFour = NSSelectorFromString(@"initWithURL:type:image:useEmbeddedPreview:");
SEL initThree = NSSelectorFromString(@"initWithURL:type:useEmbeddedPreview:");
if ([sourceClass instancesRespondToSelector:initFour]) {
    // existing 4-arg call
} else if ([sourceClass instancesRespondToSelector:initThree]) {
    // 3-arg call without image:
}

// 2. SendClassApply: if the 10-arg selector is absent, call
//    applyStyle:…deltaMap:displacement:colorSpace:… with displacement=nil
```

With both guards, the solver path completes (≈20s) and the model fast path is admitted correctly (proxy evaluates both candidates instead of crashing).

## Environment

- macOS 27.0 (26A5416b), arm64
- Xcode 27.0 (27A5218g)

Happy to open a PR with the patched `learnnode_coefficient_probe.m` if that helps.
