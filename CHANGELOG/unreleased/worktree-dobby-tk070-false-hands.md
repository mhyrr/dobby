# Changes on branch `worktree-dobby-tk070-false-hands`
What changed for the house, in the voice of the commit messages. Empty headings are dropped at release.
##### Added
-

##### Changed
-

##### Fixed
- A thermostat asked for a half degree on a house that reports whole degrees no longer says somebody changed it at the thermostat, or that the command never arrived. Its echo is judged within half the step the thermostat reported
- A Z-Wave dimmer set to 50 percent no longer reads NOT KNOWN when it reports 51. Z-Wave keeps brightness on a 0-99 scale, so fifteen of the hundred percentages come back one point off, and the light now accepts one point
- Locking a door that is already locked, or closing a garage that is already closed, no longer hides the next person who locks or closes it by hand. The nightly "lock the doors" does this most nights

##### Removed
-

##### Deprecated
-

##### Security
-

##### Tech-Debt/Refactor
-

##### Upgrade and Migration
-
