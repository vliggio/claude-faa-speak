# faa-speak

Claude Code plugin that makes Claude respond in FAA-inspired compressed format to reduce output tokens, then transparently expands the compressed text back to readable English using Apple's on-device LLM ([apfel](https://github.com/vliggio/apfel)) at zero additional API cost.

## How It Works

```
You (normal English)
    → Claude API → Compressed response (fewer tokens, cheaper)
                        ↓
              Stop hook detects <!-- faa --> marker
                        ↓
              apfel expands locally (free on-device inference)
                        ↓
              Expanded English printed below
```

1. **You write normally.** No changes to your input.
2. **Claude responds compressed** using ~40 standard abbreviations, structural prefixes (`DX:` for diagnosis, `EX:` for explanation, `ARCH:` for architecture), and telegraphic style. Output tokens reduced ~70-80%.
3. **The Stop hook fires**, extracts the compressed text, pipes it through apfel (Apple's on-device LLM), and prints the expanded English to stderr.

## Prerequisites

- **macOS 26+** with Apple Intelligence enabled
- **apfel** built and available:
  ```bash
  cd ~/git/apfel && swift build -c release
  # Either add to PATH or the hook will find it at ~/git/apfel/.build/release/apfel
  ```
- **jq** installed (`brew install jq`)

## Installation

```bash
# From the plugin directory
claude plugin install /path/to/claude-faa-speak

# Or use --plugin-dir for testing
claude --plugin-dir /path/to/claude-faa-speak
```

## Usage

### Interactive (Claude Code)

Activate with any of:
- `/faa-speak`
- "faa mode"
- "tower mode"
- "compressed mode"

Deactivate with:
- "stop faa"
- "normal mode"

### Non-interactive (claude --print)

Use the wrapper script:

```bash
./scripts/faa-wrap.sh "explain database connection pooling"
```

## Compression Examples

**Error diagnosis:**
```
DX: auth mw reject valid tokens | expiry chk uses < not <= | fix: change to <= in token_validator.rs:47
```

**Code explanation:**
```
EX: fn filter active users → extract emails | need clean mailing list from user db | filter where active=true, map to .email, ret str arr
```

**Architecture advice:**
```
ARCH: db conn pooling | more mem vs reduced latency | rec for high-load srv, skip for low-traffic
```

## Abbreviation Reference

| Abbr | Meaning | | Abbr | Meaning |
|------|---------|---|------|---------|
| fn | function | | env | environment |
| ret | return | | srv | server |
| impl | implementation | | param | parameter |
| cfg | configuration | | val | value |
| db | database | | var | variable |
| auth | authentication | | obj | object |
| req | request | | arr | array |
| res | response | | str | string |
| err | error | | mw | middleware |
| dep | dependency | | endpt | endpoint |
| pkg | package | | hdr | header |
| idx | index | | cmp | component |
| init | initialize | | rdr | render |
| del | delete | | cb | callback |
| upd | update | | evnt | event |
| chk | check | | sig | signal |
| vld | validate | | async | asynchronous |
| msg | message | | bool | boolean |

## Safety

Compression automatically disengages for:
- Security warnings
- Irreversible operation confirmations
- Multi-step sequences where abbreviation could cause misreading

Code blocks, file paths, error messages, and commands are never abbreviated.

## License

MIT
