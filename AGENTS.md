# AGENTS.md

## Solidity style

Follow the official Solidity style guide: https://docs.soliditylang.org/en/stable/style-guide.html

Key points:

- **Layout within a file:** pragma, imports, events, errors, interfaces, libraries, contracts.
- **Layout within a contract:** type declarations, state variables, events, errors, modifiers, functions.
- **Function order:** constructor, receive, fallback, external, public, internal, private. Within each group, put `view` and `pure` functions last.
- **Naming:** `CapWords` for contracts, structs, events and enums; `mixedCase` for functions, variables and modifiers; `UPPER_CASE_WITH_UNDERSCORES` for constants.
- **NatSpec:** document contracts and public/external functions with NatSpec comments (`@title`, `@notice`, `@param`, `@return`, ...).
- **Formatting:** 4-space indentation, max line length of 120 characters. Run `forge fmt` before committing; `forge fmt --check` must pass.
