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
```

```ts
import { recognize, OcrAccuracy } from '@napi-rs/system-ocr'

const image = await fetch('https://example.com/image.png')

const result = await recognize(image, OcrAccuracy.Accurate, ['fr', 'zh-cn'])
```

## Credits

Huge thanks to:

- [win-ocr-rs](https://github.com/JichouP/win-ocr-rs)
- [mac-system-ocr](https://github.com/DeJeune/mac-system-ocr)
