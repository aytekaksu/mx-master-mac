# Contributing

Issues and pull requests are welcome. Please keep changes focused and explain the behavior you changed, how you tested it, and any macOS or device assumptions.

Fork the repository, make your change, and open a pull request against `main`. All pull requests need the repository owner's review before merging. Please do not include personal logs, device settings databases, or compiled binaries.

For helper changes, run `make test`. For Lua changes, describe a physical MX Master 4 test when one is needed, especially for trackpad isolation and wheel direction changes. The helper must pass unknown-device input through unchanged and fail open if its permissions or device identity cannot be verified.
