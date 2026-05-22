#!/usr/bin/env bash
# Bellwether Ingest — composite-action runtime.
#
# Walks the artifacts attached to a completed workflow run, finds any that
# look like a test report (JUnit XML or Playwright JSON), and POSTs each to
# Bellwether's /v1/events/test-run endpoint with the required X-Bellwether-*
# metadata. Failing fast on auth errors is intentional — a misconfigured
# token should surface in the user's CI logs, not silently swallow data.
#
# Detection (V1, conservative):
#   - filename matches `*junit*.xml`   → reporter=cypress-mocha-junit
#   - filename matches `*-results.xml` → reporter=cypress-mocha-junit
#   - filename matches `*.json` AND content has a top-level `suites:` key
#                                      → reporter=playwright-json
#   - everything else                  → skipped, counted in `skipped` output
#
# Future V2 work (not blocking V1):
#   - tar.gz multi-spec form (cypress-mocha-junit-targz)
#   - native cypress JSON (cypress-native)
#   - magic-byte sniffing instead of filename heuristics
#   - GitHub OIDC swap for the static bellwether_token

set -euo pipefail

: "${BELLWETHER_API_URL:?required}"
: "${BELLWETHER_TOKEN:?required (set inputs.bellwether_token)}"
: "${GITHUB_TOKEN:?required}"
: "${WORKFLOW_RUN_ID:?required}"
: "${BELLWETHER_REPO:?required}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT INT TERM

uploads=0
skipped=0

# Defined before first call (avoids bash's lexical-order trip on functions
# referenced inside loops). Returns 0 on 200/202, 1 otherwise.
post_report() {
  local file="$1"
  local reporter="$2"
  local http_status

  http_status=$(curl --silent --show-error --output "${workdir}/last_post.body" --write-out '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer ${BELLWETHER_TOKEN}" \
    -H "X-Bellwether-Reporter: ${reporter}" \
    -H "X-Bellwether-Repo: ${BELLWETHER_REPO}" \
    -H "X-Bellwether-Run-Id: ${WORKFLOW_RUN_ID}" \
    -H "X-Bellwether-Run-Attempt: 1" \
    ${HEAD_SHA:+-H "X-Bellwether-Commit: ${HEAD_SHA}"} \
    ${HEAD_BRANCH:+-H "X-Bellwether-Branch: ${HEAD_BRANCH}"} \
    -F "file=@${file}" \
    "${BELLWETHER_API_URL}/v1/events/test-run")

  if [[ "${http_status}" == "200" || "${http_status}" == "202" ]]; then
    echo "OK (HTTP ${http_status})"
    return 0
  fi

  echo "::warning::Bellwether returned HTTP ${http_status} for ${file}. Response:"
  cat "${workdir}/last_post.body" >&2 || true
  return 1
}

echo "::group::Bellwether ingest — listing artifacts for run ${WORKFLOW_RUN_ID}"
artifacts_json="${workdir}/artifacts.json"
http_status=$(curl --silent --show-error --output "${artifacts_json}" --write-out '%{http_code}' \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${BELLWETHER_REPO}/actions/runs/${WORKFLOW_RUN_ID}/artifacts?per_page=100")

if [[ "${http_status}" != "200" ]]; then
  echo "::error::GitHub artifacts API returned HTTP ${http_status}"
  cat "${artifacts_json}" >&2 || true
  exit 1
fi

artifact_count=$(jq -r '.total_count // 0' "${artifacts_json}")
echo "Found ${artifact_count} artifact(s)."
echo "::endgroup::"

if [[ "${artifact_count}" == "0" ]]; then
  echo "::notice::No artifacts attached to workflow run ${WORKFLOW_RUN_ID}. Nothing to forward."
  {
    echo "uploads=0"
    echo "skipped=0"
  } >> "${GITHUB_OUTPUT:-/dev/null}" || true
  exit 0
fi

# Process-substitute the jq output instead of piping into the loop so the
# while body runs in THIS shell (the `uploads`/`skipped` counters survive
# loop exit). The classic `jq ... | while` form puts the loop body in a
# subshell and silently drops every counter increment.
while IFS= read -r entry; do
  artifact_id=$(echo "${entry}"   | jq -r '.id')
  artifact_name=$(echo "${entry}" | jq -r '.name')

  zip_path="${workdir}/${artifact_id}.zip"
  extract_dir="${workdir}/${artifact_id}"
  mkdir -p "${extract_dir}"

  echo "::group::Downloading artifact: ${artifact_name} (#${artifact_id})"
  http_status=$(curl --silent --show-error --location --output "${zip_path}" --write-out '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${BELLWETHER_REPO}/actions/artifacts/${artifact_id}/zip")

  if [[ "${http_status}" != "200" ]]; then
    echo "::warning::skipping ${artifact_name}: download returned HTTP ${http_status}"
    skipped=$((skipped + 1))
    echo "::endgroup::"
    continue
  fi

  if ! unzip -q "${zip_path}" -d "${extract_dir}"; then
    echo "::warning::skipping ${artifact_name}: unzip failed"
    skipped=$((skipped + 1))
    echo "::endgroup::"
    continue
  fi
  echo "::endgroup::"

  matched_any=0
  while IFS= read -r -d '' file; do
    matched_any=1
    echo "::group::Uploading JUnit report: ${file#"${extract_dir}/"}"
    if post_report "${file}" "cypress-mocha-junit"; then
      uploads=$((uploads + 1))
    else
      skipped=$((skipped + 1))
    fi
    echo "::endgroup::"
  done < <(find "${extract_dir}" -type f \( -iname '*junit*.xml' -o -iname '*-results.xml' \) -print0)

  while IFS= read -r -d '' file; do
    if jq -e '.suites' "${file}" > /dev/null 2>&1; then
      matched_any=1
      echo "::group::Uploading Playwright JSON report: ${file#"${extract_dir}/"}"
      if post_report "${file}" "playwright-json"; then
        uploads=$((uploads + 1))
      else
        skipped=$((skipped + 1))
      fi
      echo "::endgroup::"
    fi
  done < <(find "${extract_dir}" -type f -iname '*.json' -print0)

  if [[ "${matched_any}" == "0" ]]; then
    echo "::notice::${artifact_name}: no recognized test report inside (looked for *junit*.xml, *-results.xml, Playwright JSON). Skipping."
    skipped=$((skipped + 1))
  fi
done < <(jq -c '.artifacts[]' "${artifacts_json}")

echo "::notice::Bellwether ingest complete: ${uploads} uploaded, ${skipped} skipped."
{
  echo "uploads=${uploads}"
  echo "skipped=${skipped}"
} >> "${GITHUB_OUTPUT:-/dev/null}" || true
