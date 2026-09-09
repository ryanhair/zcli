Review this Zig 0.16 repository. Review the whole repository by default; if
the user explicitly names a diff, branch, commit, or files, honor that scope.
Read `CONTRIBUTING.md` and any ADRs relevant to the code being evaluated.

Check that the change matches its stated intent and the repository's actual
behavior, public contracts, error model, ownership rules, and package
boundaries. Look for correctness, security, resource-lifetime, portability,
and performance regressions. Confirm that tests exercise observable behavior
and meaningful failure modes, and identify missing focused coverage where it
would catch a plausible regression.

Report only issues supported by the code. Order findings by severity and give
each one an exact file and line, the triggering case, its impact, and a concise
fix. Do not include speculative or stylistic findings without a repository
rule. If there are no findings, say so and mention any remaining validation
gap. Review only; do not edit files.
