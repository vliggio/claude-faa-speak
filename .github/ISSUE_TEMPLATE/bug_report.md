---
name: Bug report
about: Something broke — compression, expansion, the hook, or the wrapper
title: ''
labels: bug
assignees: ''

---

**What happened**
A clear description of the bug, and what you expected instead.

**To reproduce**
The prompt / command you ran and what came back. If the problem is in the
expansion, include the compressed text (the part ending in `<!-- faa -->`).

**Environment**
- macOS version:
- `claude --version`:
- apfel: [ ] on PATH  [ ] `~/git/apfel/.build/release/apfel`  [ ] `APFEL=` override  [ ] not installed
- How the plugin is loaded: [ ] `--plugin-dir`  [ ] marketplace install

**Debug output**
Re-run with the hook's debug flag and paste the `faa-speak:` lines
(they explain every silent no-op):

```
FAA_DEBUG=1 claude --debug ...
```

**Does the test suite pass on your machine?**
```
bash test/run.sh
```
