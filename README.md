# postgres-mae

Custom Postgres image for Mae-Technologies, with schema migrations and [pgTAP](https://pgtap.org/) tests.

## Purpose

This repo focuses on **build and test correctness** — schema migrations are verified via pgTAP. The git hook runs pgTAP tests locally before commits are accepted.

## Publishing

Image publishing is handled by the [`Mae-Technologies/concourse_ci`](https://github.com/Mae-Technologies/concourse_ci) pipeline (see [concourse_ci#51](https://github.com/Mae-Technologies/concourse_ci/issues/51)). This repo does **not** manage image publishing or GHCR automation.

## Sources

- https://pgtap.org/documentation.html#has_column
- https://pgpedia.info/search.html
