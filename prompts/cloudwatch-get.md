Create a new script called `cloudwatch-get` in the project.

Goal
- Fetch AWS CloudWatch Logs for a resolved log group and write plain text files, one per log stream.
- Output format is `timestamp : message`.
- This is a debugging tool. It should be dumb from the user's point of view. The user provides a base name, the script finds the actual log group.

Minimum required usage
- cloudwatch-get my-cool-api --env prod

CLI
cloudwatch-get <base-log-group-name> --env <environment> [--from <datetime>] [--to <datetime>] [--out-dir <dir>] [--profile <profile>] [--region <region>]

Assumptions and behaviour
- The user supplies a base name like `my-cool-api`. The script resolves the real CloudWatch log group name.
- The real log group name is assumed to be constructed like:
  - <optional-prefix>-<base-log-group-name>-<environment>
  - Examples:
    - my-cool-api-prod
    - some-prefix-my-cool-api-prod
- The prefix is optional and unknown. The script must hide this complexity from the user.

Log group resolution rules
1. List log groups and filter for names that end with `<base>-<env>`
   - Example: base `my-cool-api`, env `prod`
   - Match suffix: `my-cool-api-prod`
2. If exactly one match, use it
3. If zero matches, error and show a short hint (include the suffix you tried)
4. If more than one match, error and list the candidates

Environment
- `--env` is required (sit, pre, prod, etc)
- If missing or empty, error

AWS profile selection
- Infer AWS profile using the same heuristics as `ssm-get` based on whether `api` or `service` appears in the base name
- If cannot resolve, error
- Allow explicit override via `--profile`

Region selection
- Use the same config conventions as `ssm-get.yaml.example` where appropriate
- Allow explicit override via `--region`

Time window
- Input datetimes are interpreted in local timezone only for parsing
- Output timestamps have no timezone and stop at seconds
- Output timestamp format is ISO 8601 without timezone: `YYYY-MM-DDTHH:MM:SS`
- Default window is last 12 hours ending now if no `--from` and no `--to`
- If only `--from` is provided, `--to` defaults to now
- If only `--to` is provided, `--from` defaults to 12 hours before `--to`

Datetime parsing
Accept:
- YYYY-MM-DD (treated as YYYY-MM-DDT00:00:00)
- YYYY-MM-DDTHH:MM:SS
Convert the window to epoch milliseconds for AWS API calls.

Fetch behaviour
- For the resolved log group, fetch all log streams that have events in the time window
- For each stream, fetch all events in the window and write them to disk
- Events must be in chronological order with newest at the bottom of each file
- Implementation may paginate internally, but output must be complete and must not mention pagination

Output format
- One event per line:
  - YYYY-MM-DDTHH:MM:SS : <message>
- Single line per event:
  - Replace literal newlines with `\n`
  - Replace carriage returns with `\r`
- UTF-8 safe output, do not crash on invalid sequences

Output files
- One file per log stream
- Output directory is `--out-dir` (default: current directory)
Filename pattern:
- <resolved-log-group-name>_<from>-<to>_<log-stream>.txt

Where:
- from and to use filesystem-safe seconds format: YYYYMMDDTHHMMSS
- log stream is sanitised to filesystem-safe:
  - Replace `/`, `\`, `:`, and whitespace with `_`
  - Strip other unsafe characters
  - Collapse repeated `_`

Non-interactive and debug-friendly
- No prompts
- Useful stderr logging:
  - resolved log group name
  - time window
  - number of streams
  - output directory
- Exit non-zero on error, zero on success (even if no events)

Configuration and standards
- Follow standards in AGENTS.md
- Consider updating AGENTS.md to document shared configuration patterns for AWS interface scripts (`ssm-get`, `cloudwatch-get`) to avoid duplication

Clarify before starting work
- Confirm the suffix matching rule is correct: resolve by log groups that end with `<base>-<env>`
