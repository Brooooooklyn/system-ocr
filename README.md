# `@napi-rs/system-ocr`

![https://github.com/Brooooooklyn/system-ocr/actions](https://github.com/Brooooooklyn/system-ocr/workflows/CI/badge.svg)

> OCR library that uses system provided API. `VisionKit` on macOS, `Media OCR` on Windows.

## Example

```js
node example/index.js
```

| Example                      | Result                      |
| ---------------------------- | --------------------------- |
| ![example](./example/zh.png) | ![result](./example.png)    |
| ![example](./example/fr.png) | ![result](./example_fr.png) |

## Usage

### Install

```
pnpm add @napi-rs/system-ocr
yarn install @napi-rs/system-ocr
npm install @napi-rs/system-ocr
```

### API

```ts
import { recognize } from '@napi-rs/system-ocr'

const result = await recognize('path/to/image.png')

for (const line of result.lines) {
  console.log(line.text, line.confidence, line.boundingBox)
}
```

`result.lines` follows the system OCR engine's reading order. Each bounding box
uses normalized input-image coordinates (`0` to `1`) with its origin at the
top-left. The formatted `result.text` is preserved for compatibility and is not
guaranteed to equal the line texts joined together. Line confidence is `1.0` on
Windows, matching the existing result confidence convention.

```ts
import { recognize, OcrAccuracy } from '@napi-rs/system-ocr'

const image = await fetch('https://example.com/image.png')

const result = await recognize(image, OcrAccuracy.Accurate, ['fr', 'zh-cn'])
```

## Credits

Huge thanks to:

- [win-ocr-rs](https://github.com/JichouP/win-ocr-rs)
- [mac-system-ocr](https://github.com/DeJeune/mac-system-ocr)
