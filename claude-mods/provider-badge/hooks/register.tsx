import type { Register } from 'claude-code'

import { classify } from './classify'

const COLORS: Record<string, string> = {
  copilot: '#6E40C9',
  enmass: '#EE0000',
  vertex: '#1A73E8',
  'vertex-native-adc': '#0B8043',
  ollama: '#F0AB00',
  anthropic: '#D97757',
}

export const register: Register = on => {
  // Resolved once per load; a running session's provider env cannot change.
  let resolved: Promise<{ mode: string; model: string }> | undefined

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) {
      return next(e)
    }

    resolved ??= (async () => {
      const mode = classify({
        useVertex: await $.env.get('CLAUDE_CODE_USE_VERTEX'),
        baseUrl: await $.env.get('ANTHROPIC_BASE_URL'),
        copilotPort: await $.env.get('COPILOT_API_PORT'),
        vertexProxyPort: await $.env.get('CLAUDE_VERTEX_PROXY_PORT'),
        ollamaHost: await $.env.get('OLLAMA_HOST'),
      })
      const model = (await $.env.get('ANTHROPIC_MODEL')) ?? ''
      return { mode, model }
    })()

    const { mode, model } = await resolved
    const { Box, Text } = $.ui.resolve(e)
    const base = mode.replace(/\?$/, '')

    return (
      <Box>
        <Text bold color="#FFFFFF" backgroundColor={COLORS[base] ?? '#6A6E73'}>
          {` ${mode.toUpperCase()} `}
        </Text>
        {model ? <Text dimColor>{` ${model}`}</Text> : null}
      </Box>
    )
  })
}
