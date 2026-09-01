/*
* Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd. All rights reserved.
* Use of this source code is governed by a BSD-style license that can be
* found in the LICENSE_KHZG file.
*
* Based on FlutterMutatorsStack.java originally written by
* Copyright (C) 2013 The Flutter Authors.
*
*/

import matrix4 from '@ohos.matrix4'
import List from '@ohos.util.List';

/**
 * Types of mutators that can be applied to Flutter views.
 */
export enum FlutterMutatorType {
  CLIP_RECT,
  CLIP_PATH,
  TRANSFORM,
  OPACITY
}

/**
 * Represents a rectangular clipping region.
 */
class Rect {
  width: number;
  height: number;
  radius: string | number | Array<string | number>;

  /**
   * Constructs a new Rect instance.
   * @param width - The width of the rectangle
   * @param height - The height of the rectangle
   * @param radius - Optional corner radius for rounded rectangles
   */
  constructor(width: number, height: number, radius?: string | number | Array<string | number>) {
    this.width = width;
    this.height = height;
    this.radius = radius ?? 0;
  }
}

/**
 * Represents a path-based clipping region.
 */
class Path {
  width: number | string;
  height: number | string;
  commands: string;

  /**
   * Constructs a new Path instance.
   * @param width - The width of the path
   * @param height - The height of the path
   * @param commands - Optional SVG path commands
   */
  constructor(width: number | string, height: number | string, commands?: string) {
    this.width = width;
    this.height = height;
    this.commands = commands ?? '';
  }
}

/**
 * Represents a single mutator operation (transform, clip rect, or clip path).
 */
export class FlutterMutator {
  private matrix: matrix4.Matrix4Transit | null = null;
  private rect: Rect = new Rect(0, 0);
  private path: Path = new Path(0, 0);

  /**
   * Constructs a new FlutterMutator instance.
   * @param args - Either a transformation matrix, a clipping rectangle, or a clipping path
   */
  constructor(args: matrix4.Matrix4Transit | Rect | Path) {
    if (args instanceof Rect) {
      this.rect = args;
    } else if (args instanceof Path) {
      this.path = args;
    } else {
      this.matrix = args;
    }
  }

  /**
   * Gets the transformation matrix, if this mutator is a transform.
   * @returns The transformation matrix, or null if not a transform
   */
  public getMatrix(): matrix4.Matrix4Transit | null {
    return this.matrix;
  }

  /**
   * Gets the clipping rectangle, if this mutator is a clip rect.
   * @returns The clipping rectangle
   */
  public getRect() {
    return this.rect;
  }

  /**
   * Gets the clipping path, if this mutator is a clip path.
   * @returns The clipping path
   */
  public getPath() {
    return this.path;
  }
}

/**
 * Stack of mutators that can be applied to Flutter views.
 * This class manages transformations, clipping rectangles, and clipping paths
 * that are applied in sequence to create the final view appearance.
 */
export class FlutterMutatorsStack {
  private mutators: List<FlutterMutator>;
  private finalClippingPaths: List<Path>;
  private finalClippingRects: List<Rect>;
  private finalMatrix: matrix4.Matrix4Transit;

  /**
   * Constructs a new FlutterMutatorsStack instance.
   */
  constructor() {
    this.mutators = new List();
    this.finalClippingPaths = new List();
    this.finalClippingRects = new List();
    this.finalMatrix = matrix4.identity();
  }

  /**
   * Pushes a transformation matrix onto the mutators stack.
   * @param values - Array of 16 numbers representing a 4x4 transformation matrix
   */
  public pushTransform(values: Array<number>): void {
    if (values.length != 16) {
      return;
    }
    let index = 0;
    let matrix = matrix4.init(
      [values[index++], values[index++], values[index++], values[index++],
        values[index++], values[index++], values[index++], values[index++],
        values[index++], values[index++], values[index++], values[index++],
        values[index++], values[index++], values[index++], values[index++]]);
    let mutator = new FlutterMutator(matrix);
    this.mutators.add(mutator);
    this.finalMatrix.combine(matrix);
  }

  /**
   * Pushes a rectangular clipping region onto the mutators stack.
   * @param width - The width of the clipping rectangle
   * @param height - The height of the clipping rectangle
   * @param radius - Optional corner radius for rounded rectangles
   */
  public pushClipRect(width: number, height: number, radius?: number) {
    let rect = new Rect(width, height, radius);
    let mutator = new FlutterMutator(rect);
    this.mutators.add(mutator);
    this.finalClippingRects.add(rect);
  }

  /**
   * Pushes a path-based clipping region onto the mutators stack.
   * @param width - The width of the clipping path
   * @param height - The height of the clipping path
   * @param command - Optional SVG path commands
   */
  public pushClipPath(width: number, height: number, command?: string) {
    let path = new Path(width, height, command);
    let mutator = new FlutterMutator(path);
    this.mutators.add(mutator);
    this.finalClippingPaths.add(path);
  }

  /**
   * Gets all mutators in the stack.
   * @returns List of all mutators
   */
  public getMutators() {
    return this.mutators;
  }

  /**
   * Gets all final clipping paths.
   * @returns List of all clipping paths
   */
  public getFinalClippingPaths() {
    return this.finalClippingPaths;
  }

  /**
   * Gets all final clipping rectangles.
   * @returns List of all clipping rectangles
   */
  public getFinalClippingRects() {
    return this.finalClippingRects;
  }

  /**
   * Gets the final combined transformation matrix.
   * @returns The combined transformation matrix from all transforms
   */
  public getFinalMatrix() {
    return this.finalMatrix;
  }
}