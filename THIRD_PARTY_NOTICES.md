# Third-party notices

## lobehub/lobe-icons (menubar logos)

- Source: https://github.com/lobehub/lobe-icons
- Pinned commit: `ab8cbcc6ce806b923c547628132957c8a8b61509`
- License: MIT (full text below, copied verbatim from the `LICENSE` file at that commit)
- Used by: `scripts/llm-usage-menubar/main.swift` (status item image), downloaded by `llm-usage menubar logos fetch`.
- Files (all under `packages/static-png/light/`, PNG): `claude-color`, `anthropic`, `openai`, `zai`, `deepseek-color`, `gemini-color`, `githubcopilot`, `vertexai-color`. Each is pinned by sha256 in `scripts/llm-usage`.

The logos are **not distributed with these dotfiles**: `llm-usage menubar logos fetch`
downloads them on the user's machine into `~/.local/share/llm-usage/logos/` (with a copy of
the upstream `LICENSE` and a `SOURCES.md`). The logos are trademarks of their respective
owners (Anthropic, OpenAI, Z.ai / Zhipu AI, DeepSeek, Google, GitHub / Microsoft) and are used
only for personal status-bar display; the MIT license covers the icon set's code and artwork
packaging, not the vendors' trademarks.

```
MIT License

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
