/*
 * Copyright (c) 2025 Huawei Device Co., Ltd. All rights reserved.
 * Use of this source code is governed by a BSD-style license that can be
 * found in the LICENSE_HW file.
 */

/**
 * JSON5-style comment stripping for embedding configuration and similar text.
 * Use {@link json5Tojson} to remove comments before strict JSON parsing.
 */

/**
 * Strips JSON5-style line comments and C-style block comments from the input.
 * String literals are preserved (handles escaped quotes).
 * @param input - Raw text that may contain JSON5 comments
 * @returns Text with comments removed
 */
function stripComments(input: string) {
  //Return value
  let out = '';
  let i = 0;

  const len = input.length;
  let inString = false;
  let stringQuote = '';
  //Whether it is in an escape state (the previous character is \), 
  //used to handle \" or \' etc.
  let escaped = false;

  //Loop through each character
  while (i < len) {
    const ch = input[i];
    const next = i + 1 < len ? input[i + 1] : '';

    //If currently inside a string, output everything exactly as it is
    if (inString) {
      out += ch;
      //If the previous character is a backslash causing this character to be escaped, 
      //then clear the escape state
      if (escaped) {
        escaped = false;
      //When encountering a backslash, enter escape mode
      } else if (ch === '\\') {
        escaped = true;
      } else if (ch === stringQuote) {
        inString = false;
        stringQuote = '';
      }
      i++;
      continue;
    }
    //Not inside a string; 
    //enter string mode when encountering a quotation mark
    if (ch === '"' || ch === "'") {
      inString = true;
      stringQuote = ch;
      out += ch;
      i++;
      continue;
    }
    //Detect and skip single-line comments
    if (ch === '/' && next === '/') {
      i += 2;
      while (i < len && input[i] !== '\n' && input[i] !== '\r') i++;
      continue;
    }
    //Detect and skip block comments
    if (ch === '/' && next === '*') {
      i += 2;
      while (i < len) {
        if (input[i] === '*' && i + 1 < len && input[i + 1] === '/') {
          i += 2;
          break;
        }
        i++;
      }
      continue;
    }
    out += ch;
    i++;
  }
  return out;
}

/**
 * Normalizes JSON5-like text to strict JSON by removing comments only (does not parse or validate JSON).
 * @param json5Text - Source text that may include `//` or block comments
 * @returns The same logical content with comments stripped; suitable for `JSON.parse` if the remainder is valid JSON
 */
export function json5Tojson(json5Text: string): string {
  const noComments = stripComments(json5Text);
  return noComments;
}