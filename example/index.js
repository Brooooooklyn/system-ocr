import { parseArgs } from 'node:util'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'

import { select } from '@inquirer/prompts'

import { recognize } from '../index.js'

const __dirname = join(fileURLToPath(import.meta.url), '..')

const { image, accuracy, preferredLangs } = parseArgs({
  options: {
    image: { type: 'string', short: 'i' },
    accuracy: { type: 'string', short: 'a' },
    preferredLangs: { type: 'string', short: 'l' },
  },
})

let imagePath

if (!image) {
  const choice = await select({
    message: 'Select an image',
    choices: [
      {
        name: 'small',
        value: 'small.png',
      },
      {
        name: 'fr',
        value: 'fr.png',
      },
      {
        name: 'math',
        value: 'math.png',
      },
      {
        name: 'zh',
        value: 'zh.png',
      },
    ],
  })
  imagePath = join(__dirname, choice)
} else {
  if (image.endsWith('.png')) {
    imagePath = join(__dirname, image)
  } else {
    imagePath = join(__dirname, `${image}.png`)
  }
}

const result = await recognize(imagePath, accuracy, preferredLangs)

console.log(result)

