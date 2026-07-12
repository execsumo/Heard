#!/bin/sh
export DELEGATE_LABEL="agy-enroll"
exec 'agy' '-i' 'First run: cat .delegate/spec.md — if it does not exist yet, wait 10 seconds and retry. Then execute that spec exactly; it is your full task contract including how to reach me.' '--model' 'Gemini 3.1 Pro (High)' '--add-dir' '/Users/hgill/projects/Heard-worktrees/agy-enroll' '--dangerously-skip-permissions'
