export type Env = {
  useVertex?: string
  baseUrl?: string
  copilotPort?: string
  vertexProxyPort?: string
  ollamaHost?: string
}

const LOOPBACK = new Set(['localhost', '127.0.0.1', '::1', '[::1]'])

function hostPort(url: string): { host: string; port: string } | undefined {
  const m = /^[a-z]+:\/\/([^/:]+|\[[^\]]+\])(?::(\d+))?/i.exec(url.trim())
  return m ? { host: m[1].toLowerCase(), port: m[2] ?? '' } : undefined
}

/**
 * Names the provider a session runs on from its own transport env.
 * No single env names the mode; a trailing "?" marks a heuristic match
 * (EnMaaS and the Vertex proxy are both loopback, so port decides).
 */
export function classify(env: Env): string {
  if (env.useVertex === '1') return 'vertex-native-adc'
  if (!env.baseUrl) return 'anthropic'
  const hp = hostPort(env.baseUrl)
  if (!hp) return 'custom'

  const copilot = env.copilotPort || '4141'
  const vertex = env.vertexProxyPort || '4142'
  const ollama = hostPort(`http://${env.ollamaHost || 'localhost:11434'}`)

  if (LOOPBACK.has(hp.host)) {
    if (hp.port === copilot) return 'copilot'
    if (hp.port === vertex) return 'vertex'
    if (ollama && hp.port === (ollama.port || '11434')) return 'ollama'
    return 'enmass?'
  }
  if (ollama && hp.host === ollama.host && hp.port === ollama.port) return 'ollama'
  return `custom (${hp.host})`
}
