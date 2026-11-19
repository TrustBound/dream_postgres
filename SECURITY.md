# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 2.x     | ✅ Active support  |
| < 2.0   | ❌ Not supported   |

## What dream_postgres Is Responsible For

dream_postgres is a library that provides:
- **Connection config builders** - `new`, `host`, `port`, `database`, `user`, `password`, `pool_size`
- **Connection URL parsing** - `parse_config` and `from_url`
- **Query result helpers** - `query.first_row` and `query.all_rows`

dream_postgres is **not a framework** and **not an ORM**. You write the SQL. [Pog](https://hex.pm/packages/pog) runs it.

This means dream_postgres's security surface is small:
- URL parsing bugs (a URL read into the wrong host, user, database or SSL mode)
- Leaks of the password from a connection URL (for example in an error value)
- Config builders that set a different value than the one you gave

## What You're Responsible For

Your application code handles:
- **SQL injection** - You write queries (use parameterized queries with `pog.parameter`)
- **Credentials** - Keep connection URLs and passwords out of your logs and your repository
- **TLS** - Choose the `sslmode` your deployment needs
- **Authentication** - You implement it
- **Authorization** - You control access
- **Input validation** - Check values before you put them in a query

## Reporting a Vulnerability

**Do not report security vulnerabilities through public GitHub issues.**

Email: **engineering@trustbound.ai**

### What to Include

- **Type of vulnerability** (e.g., password leak in an error, wrong host from a URL)
- **Location** in dream_postgres's code (file/function)
- **Steps to reproduce** with minimal example
- **Impact** - What can an attacker do?
- **Proof-of-concept** if you have one

Focus on vulnerabilities in **dream_postgres's code**, not in your application code.

### What to Expect

1. **Acknowledgment** within 48 hours
2. **Assessment** within 7 days
3. **Fix** coordinated with you on timing
4. **Release** with security advisory
5. **Credit** in the advisory (if desired)

## Security in dream_postgres

### Type Safety

Gleam's type system prevents many vulnerabilities:
- ✅ No null pointer exceptions
- ✅ No buffer overflows
- ✅ Exhaustive pattern matching
- ✅ Immutable data structures

### What dream_postgres Validates

`parse_config` and `from_url` check the whole connection URL and return a `UrlError` for each problem. No `UrlError` or `FromUrlError` value holds the password, so you can log an error with `string.inspect`.

### What dream_postgres Doesn't Do

dream_postgres provides no built-in:
- ❌ SQL query builders (use Squirrel or raw SQL)
- ❌ Input sanitization
- ❌ Secret storage
- ❌ Migrations

This is intentional. dream_postgres provides building blocks. You compose them.

## Known Non-Issues

These are not dream_postgres vulnerabilities (they're your application's responsibility):

- SQL injection from unparameterized queries
- A password in a log line that your code wrote
- `sslmode=disable` or `sslmode=require` on a network you do not trust
- Missing authentication or authorization checks

## Dependencies

dream_postgres's dependencies:
- **Pog** - PostgreSQL client (wraps the Erlang `pgo` library)
- **Gleam stdlib** - Type-safe, battle-tested
- **BEAM/OTP** - 30+ years of production use

We monitor dependencies and update promptly for security issues.

## Questions?

- **Security questions**: engineering@trustbound.ai
- **Non-security issues**: [GitHub Issues](https://github.com/TrustBound/dream_postgres/issues)
- **General discussion**: [GitHub Discussions](https://github.com/TrustBound/dream/discussions)

---

**Remember:** dream_postgres is a library. It provides tools. You write the application. You're responsible for your application's security.
