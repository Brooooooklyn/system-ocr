import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

import test from 'ava'

import { OcrAccuracy, recognize } from '../index.js'

const __dirname = join(fileURLToPath(import.meta.url), '..')

if (process.platform === 'darwin') {
  test('recognize text from image', async (t) => {
    t.snapshot((await recognize(join(__dirname, 'small.png'), OcrAccuracy.Accurate)).text)
  })

  test('recognize text from image with fr text', async (t) => {
    t.snapshot((await recognize(join(__dirname, 'fr.png'), OcrAccuracy.Accurate)).text)
  })

  test('recognize text from image with zh text', async (t) => {
    t.snapshot((await recognize(join(__dirname, 'zh.png'), OcrAccuracy.Accurate)).text)
  })

  test('recognize text from image with math', async (t) => {
    t.snapshot((await recognize(join(__dirname, 'math.png'), OcrAccuracy.Accurate)).text)
  })
}

if (process.platform === 'win32') {
  test('recognize text from image', async (t) => {
    t.snapshot((await recognize(join(__dirname, 'small.png'), OcrAccuracy.Accurate)).text)
  })
}
