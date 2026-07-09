#!/usr/bin/env bash
# Test stand-in for apfel: echoes stdin unchanged, ignoring -s <prompt>.
# Lets the suite assert exactly what the pipeline sends to (and reassembles
# from) the expander, with no model in the loop.
cat
