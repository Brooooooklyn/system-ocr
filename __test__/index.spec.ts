import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

import test, { type ExecutionContext } from 'ava'

import { OcrAccuracy, recognize } from '../index.js'

const __dirname = join(fileURLToPath(import.meta.url), '..')
const lineFixture = join(__dirname, 'line-layout.png')

function assertLineLayout(t: ExecutionContext, result: Awaited<ReturnType<typeof recognize>>) {
  const topIndex = result.lines.findIndex((line) => line.text.includes('TOP'))
  const bottomIndex = result.lines.findIndex((line) => line.text.includes('BOTTOM'))

  t.true(topIndex >= 0, `TOP line missing from ${JSON.stringify(result.lines)}`)
  t.true(bottomIndex >= 0, `BOTTOM line missing from ${JSON.stringify(result.lines)}`)
  t.true(topIndex < bottomIndex, 'lines should preserve the engine reading order')

  const top = result.lines[topIndex]!
  const bottom = result.lines[bottomIndex]!
  t.true(top.boundingBox.y < bottom.boundingBox.y, 'top-origin y should increase down the image')

  for (const line of result.lines) {
    t.truthy(line.text)
    t.true(line.confidence >= 0 && line.confidence <= 1)
    t.true(line.boundingBox.x >= 0 && line.boundingBox.x <= 1)
    t.true(line.boundingBox.y >= 0 && line.boundingBox.y <= 1)
    t.true(line.boundingBox.width > 0 && line.boundingBox.width <= 1)
    t.true(line.boundingBox.height > 0 && line.boundingBox.height <= 1)
    t.true(line.boundingBox.x + line.boundingBox.width <= 1)
    t.true(line.boundingBox.y + line.boundingBox.height <= 1)
  }
}

test('recognize text from image', async (t) => {
  t.is((await recognize(join(__dirname, 'sample.png'), OcrAccuracy.Accurate)).text, 'Sample Text')
})

test('recognize normalized line boxes from image path', async (t) => {
  const result = await recognize(lineFixture, OcrAccuracy.Accurate, ['en-US'])
  assertLineLayout(t, result)
})

test('recognize normalized line boxes from image bytes', async (t) => {
  const result = await recognize(await readFile(lineFixture), OcrAccuracy.Accurate, ['en-US'])
  assertLineLayout(t, result)
})

if (process.platform === 'darwin') {
  test('recognize normalized line boxes with legacy fast mode', async (t) => {
    const result = await recognize(lineFixture, OcrAccuracy.Fast, ['en-US'])
    assertLineLayout(t, result)
  })

  test('recognize multiple semantic lists without crashing', async (t) => {
    const { text } = await recognize(join(__dirname, 'semantic-lists.png'), OcrAccuracy.Accurate, ['zh-Hans'])

    t.true(text.includes('完整命令作用'))
    t.true(text.includes('常见使用场景'))
    t.true(text.includes('GitHub Actions'))
  })
}
