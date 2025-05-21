import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

import test from 'ava'

import { OcrAccuracy, recognize } from '../index.js'

const __dirname = join(fileURLToPath(import.meta.url), '..')

test('recognize text from image', async (t) => {
  t.is((await recognize(join(__dirname, 'sample.png'), OcrAccuracy.Accurate)).text, 'Sample Text')
})
