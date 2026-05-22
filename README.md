# Bellwether Ingest Action

Forward failed test runs from GitHub Actions to [Bellwether](https://bellwether.run) for classification.

When your CI workflows fail, this action picks up their JUnit + Playwright artifacts and POSTs them to Bellwether's `/v1/events/test-run` ingest endpoint. Bellwether classifies each failure (real regression / likely flake / infra / test bug / unknown) with confidence scores, surfaces them in a triage inbox, and learns from your team's feedback over time.

## Quick start

1. **Install the Bellwether GitHub App** at <https://bellwether.run> and grant access to the repos you want classified.
2. **Generate a per-repo Bellwether token** in your dashboard under *Integrations → Generate token*.
3. **Add the token to your repo's Actions secrets** as `BELLWETHER_TOKEN`.
4. **Drop this workflow file** at `.github/workflows/bellwether-ingest.yml` (Bellwether's onboarding flow opens a PR with this exact file — accept the PR and you're done):

```yaml
name: Bellwether Ingest

on:
  workflow_run:
    workflows: ["*"]
    types: [completed]

permissions:
  contents: read
  actions: read

jobs:
  ingest:
    if: >-
      ${{ github.event.workflow_run.conclusion == 'failure' ||
          github.event.workflow_run.conclusion == 'cancelled' }}
    runs-on: ubuntu-latest
    steps:
      - uses: bellwether-run/ingest-action@v1
        with:
          bellwether_token: ${{ secrets.BELLWETHER_TOKEN }}
```

That's it. The next time your test workflow fails, Bellwether classifies the failures and they show up in your triage inbox at <https://bellwether.run/inbox> within seconds.

## Inputs

| Input | Required | Default | Notes |
|-------|---------:|---------|-------|
| `bellwether_token` | yes | — | Per-repo Bellwether API token. Store as a repo secret. |
| `api_url` | no | `https://api.bellwether.run` | Override only when self-hosting or pointing at a non-prod environment. |
| `github_token` | no | `${{ github.token }}` | Needs `actions: read` to list and download artifacts. Default works when triggered via `workflow_run`. |
| `workflow_run_id` | no | `${{ github.event.workflow_run.id }}` | Override only if invoking the action outside a `workflow_run` trigger. |
| `repo` | no | `${{ github.repository }}` | The `owner/name` slug of the repo whose results are being ingested. |

## Outputs

| Output | Notes |
|--------|-------|
| `uploads` | Number of test reports successfully forwarded to Bellwether. |
| `skipped` | Number of artifacts that contained no recognizable test report. |

## What the action looks for

V1 detects two test-report formats inside artifact zips:

- **JUnit XML** — any file matching `*junit*.xml` or `*-results.xml`. Reported to Bellwether as `cypress-mocha-junit`.
- **Playwright JSON** — any `*.json` file whose body has a top-level `suites` key. Reported as `playwright-json`.

Artifacts that contain neither are silently skipped (logged via `::notice::` so they're visible in your CI log).

## Privacy

Bellwether processes the artifact contents you forward — typically test names, stack traces, and assertion messages — to produce a classification. The full data-handling policy lives at <https://bellwether.run/privacy>. If your artifacts contain content you do **not** want forwarded (production logs, screenshots, secrets), upload them under a different artifact name that this action's detectors won't match (anything other than `*junit*.xml`, `*-results.xml`, or a Playwright JSON shape).

## Local testing

The script is regular bash + curl + jq + unzip. To run it outside Actions, set the env vars from `action.yml`'s `env:` block manually:

```bash
export BELLWETHER_API_URL="https://api.bellwether.run"
export BELLWETHER_TOKEN="bw_..."
export GITHUB_TOKEN="ghp_..."
export WORKFLOW_RUN_ID="123456789"
export BELLWETHER_REPO="owner/name"
./scripts/ingest.sh
```

## Versioning

This repo follows semantic versioning at the `v<N>` ref level — `bellwether-run/ingest-action@v1` always points at the latest non-breaking release. Pin to a specific tag (`@v1.0.0`) if you want to opt out of automatic non-breaking updates.

## License

MIT. See [LICENSE](LICENSE).

## Contributing

Open issues + PRs welcome at <https://github.com/bellwether-run/ingest-action>. The action is intentionally minimal — most ingest logic lives server-side at <https://api.bellwether.run>. If you're adding support for a new test framework (Jest, pytest, Cypress native, …) please open an issue first so we can coordinate the reporter taxonomy with the API.
