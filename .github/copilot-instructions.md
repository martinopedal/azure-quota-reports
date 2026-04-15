This is a Python repository for Azure quota reporting.
It queries Azure Resource Manager APIs to generate quota and usage reports.
Follow Python best practices (PEP 8, type hints, docstrings).

## Code change workflow
- **Always validate** after changes
- **Never remove features** unless explicitly asked to

### Validation checklist
| Check | How |
|---|---|
| Tests | python -m pytest --tb=short -q - all must pass |
| Lint | python -m ruff check . - all clean |
| Security Scan | Review for secrets, PII, hardcoded creds |

## Security rules
- No secrets in code - use environment variables or GitHub Secrets
- SHA-pin all GitHub Actions to commit SHAs
- Use actions/checkout@v6 and actions/setup-python@v6 (Node.js 24 compatible)
- No enforce_admins on branch protection
- CodeQL enabled for code scanning

## GitHub-first principle
Validate changes in GitHub Actions, not locally. Push, trigger workflow, check logs, iterate.