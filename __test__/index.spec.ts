import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

import test from 'ava'

import { OcrAccuracy, recognize } from '../index.js'

const __dirname = join(fileURLToPath(import.meta.url), '..')

test('recognize text from image', async (t) => {
  t.is((await recognize(join(__dirname, 'sample.png'), OcrAccuracy.Accurate)).text, 'Sample Text')
})

if (process.platform === 'darwin') {
  test('recognize multiple semantic lists without crashing', async (t) => {
    const { text } = await recognize(join(__dirname, 'semantic-lists.png'), OcrAccuracy.Accurate, ['zh-Hans'])

    t.true(text.includes('完整命令作用'))
    t.true(text.includes('常见使用场景'))
    t.true(text.includes('GitHub Actions'))
  })
}
