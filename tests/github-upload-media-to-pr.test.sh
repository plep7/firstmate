#!/usr/bin/env bash
# Content-contract tests for the github-upload-media-to-pr skill.
# Mirrors tests/fm-stow-contract.test.sh: assert_grep/assert_no_grep against
# the skill's own prose rather than executing it, since the skill itself
# drives a live authenticated browser session and a real GitHub PR - not
# something this suite can safely or deterministically exercise in CI.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/skills/github-upload-media-to-pr/SKILL.md"

test_skill_file_exists_and_has_frontmatter() {
  assert_grep 'name: github-upload-media-to-pr' "$SKILL" "skill frontmatter missing name"
  assert_grep 'user-invocable: true' "$SKILL" "skill frontmatter missing user-invocable"
  pass "skill file has expected frontmatter"
}

test_never_uses_cookie_auth() {
  # shellcheck disable=SC2016  # Literal backticks in the pattern, not command substitution.
  assert_grep 'never reads, stores, or logs a `user_session` cookie' "$SKILL" \
    "skill does not state the user_session cookie prohibition"
  assert_grep 'not implemented here' "$SKILL" \
    "skill does not explicitly reject the cookie-auth alternative"
  pass "skill states the cookie-auth prohibition"
}

test_handles_both_url_forms() {
  assert_grep '<img' "$SKILL" "skill does not document the image <img> tag form"
  assert_grep 'bare URL' "$SKILL" "skill does not document the bare-URL video form"
  pass "skill documents both harvested URL forms"
}

test_clean_failure_and_fallback_documented() {
  assert_grep 'Clean failure and fallback' "$SKILL" "skill has no clean-failure section"
  assert_grep 'Never produce a silent half-upload' "$SKILL" \
    "skill does not forbid silent half-uploads"
  assert_grep 'committed-file floor' "$SKILL" \
    "skill does not name the committed-file floor as the fallback"
  pass "skill documents a clean failure and fallback contract"
}

test_dom_churn_and_recovery_documented() {
  assert_grep 'DOM churn and recovery' "$SKILL" "skill has no DOM-churn section"
  assert_grep 'Re-inspect before anything else' "$SKILL" \
    "skill does not document the re-inspect-on-failure recovery step"
  pass "skill documents the DOM-churn maintenance expectation and recovery step"
}

test_does_not_attempt_login() {
  assert_grep 'Do not attempt to log in yourself' "$SKILL" \
    "skill does not forbid attempting its own login"
  pass "skill refuses to attempt its own login"
}

test_playwright_primary_chrome_devtools_axi_alternative() {
  assert_grep 'Playwright is v1' "$SKILL" \
    "skill does not state Playwright as the primary backend"
  assert_grep 'chrome-devtools-axi' "$SKILL" \
    "skill does not mention chrome-devtools-axi as the documented alternative"
  assert_grep 'succeeded exactly once' "$SKILL" \
    "skill does not record the observed chrome-devtools-axi upload flake"
  assert_grep 'is **not** proof of success' "$SKILL" \
    "skill does not warn that exit 0 is not proof of a successful upload"
  pass "skill documents Playwright as primary and the chrome-devtools-axi flake as the reason"
}

test_skill_file_exists_and_has_frontmatter
test_never_uses_cookie_auth
test_handles_both_url_forms
test_clean_failure_and_fallback_documented
test_dom_churn_and_recovery_documented
test_does_not_attempt_login
test_playwright_primary_chrome_devtools_axi_alternative
