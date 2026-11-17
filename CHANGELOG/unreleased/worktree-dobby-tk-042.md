# Changes on branch `worktree-dobby-tk-042`
What changed for the house, in the voice of the commit messages. Empty headings are dropped at release.
##### Added
-

##### Changed
-

##### Fixed
- A connection to Home Assistant that dies without closing, after a router reboot, a paused VM or a host asleep, is noticed within 45 seconds. Dobby pings Home Assistant every 15 seconds. When nothing at all comes back for 45, it logs that the socket is dead, reconnects, and fetches the whole house again. Before, the connection stayed "connected" forever: `/admin` read Awake, every command waited out its ten seconds, and the board slowly went NOT KNOWN. While the reconnect runs, the Home Assistant row on `/admin` reads Quiet

##### Removed
-

##### Deprecated
-

##### Security
-
