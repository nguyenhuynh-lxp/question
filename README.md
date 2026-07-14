# question

My own agent corner — quick terminal Q&A powered by [pi](https://pi.dev).

## Commands

| Command | What it does |
|---------|--------------|
| `q <question>` | Ask a new question (creates a new session, no memory involved) |
| `q -m <question>` | Same, but inject relevant sections of `~/.q/memory.md` into the prompt |
| `fq <question>` | Follow up on the most recent session |
| `fq <session-id> <question>` | Follow up on a specific session (partial id ok) |
| `lq` | List the 10 newest sessions and stay interactive: press `0`-`9` to copy that session's full id to the clipboard (for `fq <id> ...`), `q` to quit |
| `lq --flush [days]` | Distill sessions older than N days (default 30) into `~/.q/memory.md`, then delete them |

`fq` and `lq` are symlinks to `q`; the script dispatches on its invoked name.

## How it works

- Questions run via `pi -p` with the system prompt in `SYSTEM-PROMPT.md`,
  always from `$HOME`, so behavior is identical regardless of cwd.
- Sessions are stored in an isolated directory (`~/.q/sessions`, override with
  `Q_HOME`), completely separate from pi's own `~/.pi/agent/sessions`.
- Stdin is merged into the prompt, so piping works: `git diff | q "review this"`.
- `q -m` picks memory by keyword match: words of 4+ letters from your question
  are matched (case-insensitively) against the `##` sections of `memory.md`;
  only matching sections are injected. No match → the question is asked
  without memory, with a note on stderr.

## Setup

Add the repo to `PATH`, or symlink `q`, `fq`, `mq` into a bin directory:

```bash
ln -s "$PWD/q" "$PWD/fq" "$PWD/lq" ~/.local/bin/
```
