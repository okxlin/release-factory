#!/usr/bin/env python3
from pathlib import Path
import sys

TARGET = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('/opt/gemini-skill/src/gemini-ops.js')

if not TARGET.exists():
    raise SystemExit(f'target not found: {TARGET}')

s = TARGET.read_text()

anchor1 = "      const start = Date.now();\n      let lastStatus = null;\n"
insert1 = "      const start = Date.now();\n      let lastStatus = null;\n      let lastText = '';\n      let stableTextRounds = 0;\n"

if "let stableTextRounds = 0;" not in s:
    if anchor1 not in s:
        raise SystemExit('anchor1 not found in gemini-ops.js')
    s = s.replace(anchor1, insert1, 1)

old_block = """        if (poll.status === 'mic') {
          // 回复完成，自动提取最新文字回复
          const textResp = await this.getLatestTextResponse();
          return {
            ok: true,
            elapsed: Date.now() - start,
            finalStatus: poll,
            text: textResp.ok ? textResp.text : null,
            textIndex: textResp.ok ? textResp.index : null,
          };
        }
        if (poll.status === 'unknown') {
          console.warn('[ops] unknown status, may need screenshot to debug');
        }
"""

new_block = """        const textResp = await this.getLatestTextResponse();
        const currentText = textResp.ok ? String(textResp.text || '').trim() : '';

        if (currentText && currentText === lastText) {
          stableTextRounds += 1;
        } else {
          stableTextRounds = 0;
          lastText = currentText;
        }

        const streamSeemsDone = poll.status === 'stop' && !!currentText && stableTextRounds >= 2;

        if (poll.status === 'mic' || streamSeemsDone) {
          return {
            ok: true,
            elapsed: Date.now() - start,
            finalStatus: poll,
            text: textResp.ok ? textResp.text : null,
            textIndex: textResp.ok ? textResp.index : null,
          };
        }

        if (poll.status === 'unknown') {
          console.warn('[ops] unknown status, may need screenshot to debug');
        }
"""

if "streamSeemsDone" not in s:
    if old_block not in s:
        raise SystemExit('sendAndWait block not found in gemini-ops.js')
    s = s.replace(old_block, new_block, 1)

TARGET.write_text(s)
print(f'patched {TARGET}')
