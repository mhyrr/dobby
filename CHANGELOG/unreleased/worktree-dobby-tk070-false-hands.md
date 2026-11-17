# Changes on branch `worktree-dobby-tk070-false-hands`
What changed for the house, in the voice of the commit messages. Empty headings are dropped at release.
##### Added
- A vacuum can bind its battery sensor (`battery:`), and discovery suggests it. Home Assistant 2026.8 took the battery off the vacuum entity, so a vacuum without the binding reported no battery at all on a current Home Assistant

##### Changed
-

##### Fixed
- A thermostat asked for a half degree on a house that reports whole degrees no longer says somebody changed it at the thermostat, or that the command never arrived. Its echo is judged within half the step the thermostat reported
- A Z-Wave dimmer set to 50 percent no longer reads NOT KNOWN when it reports 51. Z-Wave keeps brightness on a 0-99 scale, so fifteen of the hundred percentages come back one point off, and the light now accepts one point
- Locking a door that is already locked, or closing a garage that is already closed, no longer hides the next person who locks or closes it by hand. The nightly "lock the doors" does this most nights
- A lock that reports locked a few seconds after Dobby asked no longer writes NOT KNOWN. Its deadline was one second, with no reason recorded, and Home Assistant gives a Z-Wave, August or Schlage lock no locking state to answer with sooner. Locks now take the thirty-second default
- A garage door that reports no closing state no longer writes "changed at the garage door" for every report on the way down when Dobby closes it. Its position falling under Dobby's close is that close travelling; a door that goes back up is still somebody's
- A shade Dobby opens, closes or sets no longer writes "changed at the shade" for every report it sends on the way. While the command is in flight, travel toward its end is the command; the flight ends when the shade arrives, turns back, or passes its deadline, so a hand that moves the shade afterwards is listed as it was before
- A shade or garage door that Home Assistant reports as `unknown`, one that cannot say where it is, is no longer treated as unavailable. It takes commands again; its card reads SET or AWAKE with no value until the board learns to say NOT KNOWN for it
- A shade or a switch that somebody puts back where Dobby once sent it is now listed in the thread. Dobby's command is spent when it arrives, as a lock's is, where before it stood forever and read half of all hands as Dobby's. A shade that lands one notch from its target, or settles one notch after arriving, is still Dobby's

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
