# Cross-account validation example

A self-asserting GitHub Actions workflow an independent developer can copy into their own
repository to verify, end to end, that `Nandini1212/axiom-action@v1.15.1` installs correctly and
produces a real investigation -- with no access of any kind to the private `Nandini1212/axiom`
source repository.

## Use it

1. Copy `axiom-cross-account-check.yml` into your own repository's `.github/workflows/`.
2. Run it from the Actions tab ("Run workflow"), or `gh workflow run axiom-cross-account-check.yml`.
3. Open the run. Two steps are explicitly labeled and separated:
   - **"INSTALLATION VALIDATION"** -- did the real Action install a genuine, checksum-matching
     distribution?
   - **"DIAGNOSTIC VALIDATION"** -- did that binary produce real, schema-correct investigation
     output for the workflow's own deliberately-failing, pinned test?

The pinned fixture supplies no committed source-change evidence, so a `NEEDS_INVESTIGATION`
disposition is an expected, correct result here -- not a diagnostic failure. This workflow
validates that the real pipeline ran end to end with real evidence, not a specific root-cause
verdict.

Requires only `permissions: contents: read` -- no secret, no token, no access to any private
repository.
