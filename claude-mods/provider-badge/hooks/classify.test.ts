import { expect, test } from 'claude-code/testing'

import { classify } from './classify'

test('detects native Vertex ADC', () => {
  expect(classify({ useVertex: '1' })).toBe('vertex-native-adc')
})

test('falls back to anthropic with no base url', () => {
  expect(classify({})).toBe('anthropic')
})

test('maps each launcher by its full base url', () => {
  expect(classify({ baseUrl: 'http://localhost:4141' })).toBe('copilot')
  expect(classify({ baseUrl: 'http://127.0.0.1:4142' })).toBe('vertex')
  expect(classify({ baseUrl: 'http://127.0.0.1:4146' })).toBe('enmass')
  expect(classify({ baseUrl: 'http://localhost:11434' })).toBe('ollama')
})

test('honors overridden ports', () => {
  expect(classify({ baseUrl: 'http://localhost:5555', copilotPort: '5555' })).toBe('copilot')
  expect(classify({ baseUrl: 'http://127.0.0.1:6000', vertexProxyPort: '6000' })).toBe('vertex')
  expect(classify({ baseUrl: 'http://127.0.0.1:7000', enmassPort: '7000' })).toBe('enmass')
})

test('the same port on another host is not a match', () => {
  expect(classify({ baseUrl: 'http://127.0.0.1:4141' })).toBe('local (:4141)')
  expect(classify({ baseUrl: 'http://localhost:4142' })).toBe('local (:4142)')
  expect(classify({ baseUrl: 'http://localhost:4146' })).toBe('local (:4146)')
})

test('an unknown loopback port is named, not guessed', () => {
  expect(classify({ baseUrl: 'http://127.0.0.1:51234' })).toBe('local (:51234)')
})

test('detects a remote ollama host', () => {
  expect(classify({ baseUrl: 'http://gpu-box:11434', ollamaHost: 'gpu-box:11434' })).toBe('ollama')
})
