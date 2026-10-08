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
 *
 * No single env names the mode, so the whole base URL decides. The launchers
 * use different hosts: copilot is http://localhost:<port>, the Vertex proxy and
 * EnMaaS are http://127.0.0.1:<port>, Ollama is http://<OLLAMA_HOST>. A match on
 * host and port is certain; any other loopback URL reads as enmass? (a
 * trailing "?" marks a guess, by elimination: EnMaaS uses a random port).
 * Known gap: EnMaaS on exactly 127.0.0.1:<vertex port> reads as vertex, as the
 * two share host and port.
 */
export function classify(env: Env): string {
  if (env.useVertex === '1') return 'vertex-native-adc'
  if (!env.baseUrl) return 'anthropic'
  const hp = hostPort(env.baseUrl)
  if (!hp) return 'custom'

  const copilot = env.copilotPort || '4141'
  const vertex = env.vertexProxyPort || '4142'
  const ollama = hostPort(`http://${env.ollamaHost || 'localhost:11434'}`)

  if (ollama && hp.host === ollama.host && hp.port === (ollama.port || '11434')) return 'ollama'

  if (LOOPBACK.has(hp.host)) {
    if (hp.host === 'localhost' && hp.port === copilot) return 'copilot'
    if (hp.host === '127.0.0.1' && hp.port === vertex) return 'vertex'
    return 'enmass?'
  }
  return `custom (${hp.host})`
}
