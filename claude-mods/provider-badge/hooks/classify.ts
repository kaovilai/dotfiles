export type Env = {
  useVertex?: string
  baseUrl?: string
  copilotPort?: string
  vertexProxyPort?: string
  enmassPort?: string
  ollamaHost?: string
}

const LOOPBACK = new Set(['localhost', '127.0.0.1', '::1', '[::1]'])

function hostPort(url: string): { host: string; port: string } | undefined {
  const m = /^[a-z]+:\/\/([^/:]+|\[[^\]]+\])(?::(\d+))?/i.exec(url.trim())
  return m ? { host: m[1].toLowerCase(), port: m[2] ?? '' } : undefined
}

/**
 * Names the provider a session runs on from its own transport env.
 *
 * No single env names the mode, so the whole base URL decides. Each launcher is
 * one daemon on its own fixed port: copilot http://localhost:<4141>, the Vertex
 * proxy http://127.0.0.1:<4142>, the EnMaaS proxy http://127.0.0.1:<4146>,
 * Ollama http://<OLLAMA_HOST>. A match on host and port is certain. Any other
 * loopback URL reads as local (:port): a legacy per-session proxy, or something
 * this table does not know, never guessed to be one of the above.
 */
export function classify(env: Env): string {
  if (env.useVertex === '1') return 'vertex-native-adc'
  if (!env.baseUrl) return 'anthropic'
  const hp = hostPort(env.baseUrl)
  if (!hp) return 'custom'

  const copilot = env.copilotPort || '4141'
  const vertex = env.vertexProxyPort || '4142'
  const enmass = env.enmassPort || '4146'
  const ollama = hostPort(`http://${env.ollamaHost || 'localhost:11434'}`)

  if (ollama && hp.host === ollama.host && hp.port === (ollama.port || '11434')) return 'ollama'

  if (LOOPBACK.has(hp.host)) {
    if (hp.host === 'localhost' && hp.port === copilot) return 'copilot'
    if (hp.host === '127.0.0.1' && hp.port === vertex) return 'vertex'
    if (hp.host === '127.0.0.1' && hp.port === enmass) return 'enmass'
    return `local (:${hp.port || '?'})`
  }
  return `custom (${hp.host})`
}
