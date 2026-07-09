# Security Policy

## Supported versions

The latest release (and `main`) only.

## Reporting a vulnerability

Please use GitHub's **private vulnerability reporting** on this repository
(Security tab → "Report a vulnerability") rather than a public issue. You
should get a response within a few days.

## Scope notes for researchers

This plugin registers a **Stop hook that executes a bash script after every
Claude response** in sessions where it's installed, parses the session
transcript with `jq`/`awk`, and pipes response text into a local on-device
model (`apfel`). Interesting areas:

- Shell handling of transcript-controlled text (the hook treats all of it as
  data — quoting/injection findings are in scope and taken seriously)
- The hook's exit-code contract (it must never exit 2 — that would block the
  user's session)
- Content shown to the user via `systemMessage` (expansion output is
  model-generated from response text; spoofing/abuse angles welcome)

Everything runs locally; the plugin makes no network calls of its own.
