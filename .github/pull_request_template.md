## What & why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `bash test/run.sh` passes (112 checks; no login or model needed — apfel is stubbed)
- [ ] `shellcheck` is clean on any touched scripts (CI enforces this)
- [ ] Bash 3.2 compatible — no `mapfile`, no associative arrays (macOS default bash)
- [ ] Dictionary changes follow the measurement gate in [docs/custom-dictionary.md](../docs/custom-dictionary.md) and pass the drift test (lib + SKILL.md + README tables must agree)
- [ ] Docs updated if behavior changed (README / CLAUDE.md)
