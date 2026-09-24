/**
 * Platform-neutral pieces of the Harmony Photographic Styles 3 bridge.
 *
 * The seed is deliberately derived from UTF-16 code units, matching the
 * Flutter backend's existing stable path seed. It is a per-input value, not
 * a random process value, so retrying the same queue item produces the same
 * texture metadata.
 */
export function stableGrainSeed(inputPath: string): number {
  let hash: number = 0;
  for (let index = 0; index < inputPath.length; index += 1) {
    hash = (hash * 31 + inputPath.charCodeAt(index)) & 0x7fffffff;
  }
  return hash;
}

export interface NativePs3Options {
  applePhotographicStyles3: boolean;
  grainSeed: number;
}

export function ps3OptionsFor(inputPath: string, enabled: boolean): NativePs3Options {
  return {
    applePhotographicStyles3: enabled,
    grainSeed: stableGrainSeed(inputPath)
  };
}
