# Prompt: Implement sm-get (AWS SSM comparison utility)

## Goal
Create a Unix-only utility script called ssm-get in the bin/ folder.
It queries AWS SSM Parameter Store for a configured service across one or more environments
(dev, sit, preprod, prod) and prints a comparison table where rows are parameter keys and
columns are environments.

This is a pragmatic internal utility. Optimise for usefulness and readability, not rigidity.

## Repository constraints
- Use Python.
- Use a local .venv in the repo (create if missing).
- Use requirements.txt for dependencies (boto3, pyyaml, tabulate are sufficient).
- YAML configuration is mandatory.
- Configuration file must live next to the script in the repo and be gitignored.
- Unix-only. No Windows support required.

## CLI
Command:
  ssm-get SERVICE_NAME [--env dev|sit|preprod|prod] [--with-decryption]

Rules:
- SERVICE_NAME is required and must exist in the YAML config.
- If the config file is missing or the service is unknown, exit with an error.
- --env limits retrieval to a single environment.
- If --env is not provided, query environments in this order: dev, sit, preprod, prod.
- --with-decryption must be explicitly provided to enable decryption of SecureString parameters.

## AWS and account conventions
- Environments map to account types:
  - dev, sit, preprod -> nonprod
  - prod -> prod
- Services live in corp-enterprise-services-nonprod (nonprod) and corp-enterprise-services-prod (prod).
- APIs live in a different AWS account but follow the same nonprod/prod split.
- Configuration must support selecting an account/profile group per service (for example: services vs apis).
- AWS authentication uses existing AWS SSO profiles. Assume they are already configured.
- Use boto3 sessions with profile_name.
- If authentication fails, exit with a helpful error suggesting aws sso login for the relevant profile.

## Configuration
- Config file path: ssm-get/ssm-get.yaml
- This file must be added to .gitignore.
- Provide a checked-in example file: ssm-get/ssm-get.yaml.example
- No secrets should be required in the config.

Configuration requirements:
- aws.profile_groups defines named profile groups.
- Each profile group defines:
  - nonprod AWS CLI profile
  - prod AWS CLI profile
- services defines named services.
- Each service:
  - must define group (which profile group to use)
  - may define match_path_prefixes
  - may define envs

Example configuration for the example file (do not add any extra formatting around this in the output file; it should be valid YAML exactly as written):

```yaml
  aws:
    profile_groups:
      services:
        nonprod: es-nonprod
        prod: es-prod
      apis:
        nonprod: api-nonprod
        prod: api-prod

  services:
    my-service:
      group: services
```

## Optional configuration behaviour
- match_path_prefixes:
  - optional
  - if omitted or empty, default to a single prefix derived from the service name:
    - forward slash + service name + trailing hyphen
    - example: for service "my-service" the default prefix is "/my-service-"
- envs:
  - optional
  - if omitted, all environments are eligible
  - treated as a soft allow-list, not a hard requirement


## Environment selection rules
- Canonical environment order is: dev, sit, preprod, prod.
- If --env is provided:
  - only query that environment
  - do not error if it is not listed in envs
- If --env is not provided:
  - if envs is present, query only those environments (in canonical order)
  - if envs is absent, query all environments

## Path matching logic (keep it simple)
For each environment being queried:
- Determine account type (nonprod for dev/sit/preprod, prod for prod).
- Select AWS profile using:
  - service.group chooses the profile group
  - account type chooses nonprod or prod profile within that group
- Determine prefixes to try:
  - if match_path_prefixes exists and is non-empty, use it
  - otherwise use the derived default prefix
- For each prefix in order:
  - candidate base path is prefix + env (example: "/my-service-" + "sit" -> "/my-service-sit")
  - query SSM by path using that candidate base path
  - the first prefix that yields any parameters wins for that env
- If no prefix yields any parameters, treat that environment as having no values.

## SSM retrieval rules
- Use GetParametersByPath with recursive enabled.
- Pagination is explicitly not required; ignore NextToken if present.
- Extract only Name, Value, and Type.
- Trim the base path from the displayed key:
  - Example: "/my-service-sit/database/url" -> "database/url"

## Decryption rules
- By default, call SSM with WithDecryption set to false.
- Only set WithDecryption to true when --with-decryption is provided.
- When not decrypting:
  - If a parameter Type is SecureString, display REDACTED (or leave the value empty).
- When decrypting:
  - Display the decrypted value as returned by SSM.

## Data model
- Internally store results as data[env][key] = value.
- Build the final table using the union of all keys across environments.
- Keep the structure simple so output transposition later is easy.

## Output format
- Print a single comparison table.
- Rows: parameter keys (sorted).
- Columns: environments in fixed order (dev, sit, preprod, prod), filtered to those actually queried.
- Cells: value, REDACTED, or blank.
- If an environment has no parameters, still include the column.

## Error handling / exit codes
- Missing or invalid config file: exit code 2.
- Unknown service: exit code 2.
- Invalid environment value: exit code 2.
- AWS authentication or profile errors: exit code 3 with a helpful message.
- No parameters found anywhere: exit code 0, still print an empty table.

## Repo changes to make
1. Add executable script ssm-get/ssm-get.
2. Add or update requirements.txt with required dependencies.
3. Add ssm-get/ssm-get.yaml.example with the example YAML above.
4. Add ssm-get/ssm-get.yaml to .gitignore.
5. If this repo has a README or bin-level docs, add a short usage note.

## Quality bar
- Keep the implementation straightforward and readable.
- Avoid unnecessary abstraction or complexity.
- Deterministic ordering.
- No pagination or implicit service inference in this version.
