---
name: make-go-tests
description: Generate Go tests for a source file using project conventions
argument-hint: <file-path>
context: fork
agent: go-test-writer
---

Generate tests for the Go source file at: $ARGUMENTS

Steps:
1. Read the file at `$ARGUMENTS` thoroughly — understand every exported type, function, error variable, and interface.
2. Determine the test type from the file's layer:
   - `internal/domain/` → unit tests with mocks
   - `internal/application/` → unit tests with mocks
   - `internal/infrastructure/` → integration tests with testcontainers
   - `pkg/` → unit tests and benchmarks
3. Check adjacent `*_test.go` files in the same package for existing fixture names, mock types, and `Base*` variables to reuse.
4. Apply all 13 rules without exception and write the complete `_test.go` file.
5. Output only the test file contents — no explanations, no summary.
