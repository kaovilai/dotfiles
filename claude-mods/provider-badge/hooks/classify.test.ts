import { expect, test } from 'claude-code/testing'

import { classify } from './classify'

test('detects native Vertex ADC', () => {
  expect(classify({ useVertex: '1' })).toBe('vertex-native-adc')
})

test('falls back to anthropic with no base url', () => {
  expect(classify({})).toBe('anthropic')
})

test('maps default ports', () => {
  expect(classify({ baseUrl: 'http://localhost:4141' })).toBe('copilot')
  expect(classify({ baseUrl: 'http://127.0.0.1:4142' })).toBe('vertex')
  expect(classify({ baseUrl: 'http://localhost:11434' })).toBe('ollama')
})

test('honors overridden ports', () => {
  expect(classify({ baseUrl: 'http://localhost:5555', copilotPort: '5555' })).toBe('copilot')
  expect(classify({ baseUrl: 'http://127.0.0.1:6000', vertexProxyPort: '6000' })).toBe('vertex')
})

test('treats other loopback ports as a heuristic enmass match', () => {
  expect(classify({ baseUrl: 'http://127.0.0.1:51234' })).toBe('enmass?')
})

test('detects a remote ollama host', () => {
  expect(classify({ baseUrl: 'http://gpu-box:11434', ollamaHost: 'gpu-box:11434' })).toBe('ollama')
})
