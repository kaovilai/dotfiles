import type { Register } from 'claude-code'

import { classify } from './classify'

const COLORS: Record<string, string> = {
  copilot: '#6E40C9',
  openai: '#10A37F',
  enmass: '#EE0000',
  vertex: '#1A73E8',
  'vertex-native-adc': '#0B8043',
  'glm-only': '#3E5FF9',
  'glm-hybrid': '#3E5FF9',
  ollama: '#F0AB00',
  anthropic: '#D97757',
}

export const register: Register = on => {
  // The provider env of a running session cannot change, so resolve it once.
  // session.start fires again on every reload, which refills this.
  let resolved: { mode: string; model: string } | undefined

  on('session.start', async ($, e, next) => {
    const mode = classify({
      useVertex: await $.env.get('CLAUDE_CODE_USE_VERTEX'),
      baseUrl: await $.env.get('ANTHROPIC_BASE_URL'),
      model: await $.env.get('ANTHROPIC_MODEL'),
      sonnetModel: await $.env.get('ANTHROPIC_DEFAULT_SONNET_MODEL'),
      copilotPort: await $.env.get('COPILOT_API_PORT'),
      vertexProxyPort: await $.env.get('CLAUDE_VERTEX_PROXY_PORT'),
      openaiPort: await $.env.get('CLAUDE_OPENAI_PROXY_PORT'),
      enmassPort: await $.env.get('CLAUDE_ENMASS_PROXY_PORT'),
      glmPort: await $.env.get('GLM_HYBRID_CLAUDE_PROXY_PORT'),
      ollamaHost: await $.env.get('OLLAMA_HOST'),
    })
    const model = (await $.env.get('ANTHROPIC_MODEL')) ?? ''
    resolved = { mode, model }

    return next(e)
  })

  // The always-on surface is the bottom statusLine segment
  // (~/.claude/scripts/provider-statusline.sh); $.ui.status is NOT used: the
  // engine renders every plugin status line with a fixed "⚠ <plugin>: "
  // attribution prefix that cannot be styled away. This band is the
  // supplement: drawn only when no other mod holds the AbovePrompt slot, so
  // it never hides (or is hidden by) e.g. review-inbox.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || resolved === undefined) {
      return next(e)
    }
    const below = await next(e)
    if (below) {
      return below
    }

    const { mode, model } = resolved
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
