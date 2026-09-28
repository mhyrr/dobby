# Changes on branch `claude-agent-programming-ergonomics-a16v14`
What changed for the house, in the voice of the commit messages. Empty headings are dropped at release.
##### Added
- A design note, `docs/design/agent-ergonomics.md`, on what a codebase owes the agents that now write it: orientation and verification over authoring, local convention as executed checks rather than prose, and three tests this repository could add to turn its own doctrine into failures that name the fix

##### Changed
-

##### Fixed
- The schedule form in `/admin` asks for a light's brightness from 1 to 100, which is what a light accepts; it offered 0, and a light refuses 0. A fan's speed, a speaker's volume, and a shade's position are now asked for in words with their range, where the form only named them

##### Removed
-

##### Deprecated
-

##### Security
-

##### Tech-Debt/Refactor
- "The model never touches Home Assistant" is now a failing test rather than a sentence. If a tool, the agent, or the MCP door ever names the Home Assistant client or an HTTP client, `mix test` fails and says which module crossed the line and what it reached for
- A tool and the device action it drives can no longer describe one argument two ways. If the two disagree on whether an argument is required, what type it is, or the numbers its doc gives, or a tool promises a bound its action never states, `mix test` fails naming the key and both files
- Adding a device type is one failing test's worth of instructions. `LibraryContractTest` names whatever a registered type is still missing and where it goes: a tool file under its own name, the tool's line in the agent's list, a status tool, a tool for every command the type routes, a row in the house guide, a device in the example house, a word on the board. A device agent written and never registered fails it too

##### Upgrade and Migration
-
