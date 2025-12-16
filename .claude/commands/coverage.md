---
name: /coverage
description: Run test coverage analysis
---

# Test Coverage Analysis

Generate and view test coverage reports using ExCoveralls.

## Commands

```bash
# Generate HTML coverage report
mix coveralls.html

# View coverage in terminal
mix coveralls

# Detailed coverage with line-by-line breakdown
mix coveralls.detail

# Generate JSON for CI/CD
mix coveralls.json
```

## View HTML Report

After running `mix coveralls.html`:

```bash
open cover/excoveralls.html
```

## Coverage Goals

- **Overall:** >80% coverage
- **Critical modules:** >90% coverage
  - ParrotSip.TransactionStatem
  - ParrotSip.DialogStatem
  - ParrotSip.Parser
  - ParrotSip.Serializer

## Interpreting Results

**Good coverage (>80%):**
- All happy paths tested
- Most error paths covered
- Edge cases included

**Needs improvement (<80%):**
- Missing test cases
- Untested error handling
- Complex branches not covered

## Focus Areas

1. **State machines** - All state transitions
2. **Parsers** - All message types and edge cases
3. **Serialization** - All header types
4. **Error handling** - All rescue/catch blocks

## Excluding Files

Add to mix.exs:
```elixir
test_coverage: [
  tool: ExCoveralls,
  ignore_modules: [
    ~r/\.Mixfile$/,
    ~r/Test$/
  ]
]
```
