# Real Claude Code 2.1.296 runs inside a throwaway self-contained firstmate home (FM_HOME == code root)

| Command | Control: no rules (tracked `{}` settings.local.json, dontAsk) | Treatment: rules written by the session's own SessionStart bootstrap (dontAsk) |
|---|---|---|
| `bin/fm-tasks-axi.sh --help` | DENIED | ALLOWED |
| `FM_HOME=<home> bin/fm-claude-permissions.sh print` | DENIED | ALLOWED |
| `<home>/bin/fm-claude-permissions.sh print` | DENIED | ALLOWED |
| `bin/fm-pr-merge.sh --help` (merge command, excluded) | DENIED | DENIED |
| `FM_HOME=/tmp/some-other-home bin/...` (another home) | DENIED | DENIED |

Auto mode, `FM_HOME=<home> bin/fm-brief.sh fix-header-k1 demo-repo --mode local-only`: ran with the rules (no denials, brief.md written).
The no-rules control also ran: the classifier did not reproduce the incident's Self-Modification block here.

Raw outputs: claude-dontask-control-no-rules.json, claude-dontask-session-start-writes-rules.json, claude-auto-fm-brief-*.json
