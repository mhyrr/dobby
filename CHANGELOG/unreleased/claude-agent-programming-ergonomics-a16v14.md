# Changes on branch `claude-agent-programming-ergonomics-a16v14`
What changed for the house, in the voice of the commit messages. Empty headings are dropped at release.
##### Added
- A design note, `docs/design/agent-ergonomics.md`, on what a codebase owes the agents that now write it: orientation and verification over authoring, local convention as executed checks rather than prose, and three tests this repository could add to turn its own doctrine into failures that name the fix

##### Changed
-

##### Fixed
-

##### Removed
-

##### Deprecated
-

##### Security
-

##### Tech-Debt/Refactor
- "The model never touches Home Assistant" is now a failing test rather than a sentence. If a tool, the agent, or the MCP door ever names the Home Assistant client or an HTTP client, `mix test` fails and says which module crossed the line and what it reached for

##### Upgrade and Migration
-
