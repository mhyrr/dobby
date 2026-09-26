# Changes on branch `claude-repo-audit-sonos-kkxr0q`
What changed for the house, in the voice of the commit messages. Empty headings are dropped at release.
##### Added
-

##### Changed
-

##### Fixed
- A turn that dies however it dies — an exit, a throw, killed outright — now says "something went wrong answering that" in the thread and closes, where before the person watched it run forever and any HELD or NOT KNOWN it was holding was never told. A turn that hangs is stopped after three minutes (`turn_deadline_ms`), so a provider that never answers can no longer take the floor for good
- `/house`, a card, and a status question no longer crash while Home Assistant is slow. A device busy with a service call reads NOT KNOWN on the board until it answers, and a card or Dobby says it is not answering right now

##### Removed
-

##### Deprecated
-

##### Security
- Dobby answers only to its own names and LAN addresses. A web page somebody in the house opens can no longer point its own domain at the box and drive `/admin`. A name the router's DNS gives the box, or a reverse proxy's, goes in `DOBBY_ALLOWED_HOSTS`

##### Tech-Debt/Refactor
- Every pull request and push to main runs `mix precommit` on GitHub Actions against a Postgres service, and fails if precommit had anything left to rewrite

##### Upgrade and Migration
- If you reach Dobby by a name other than `localhost`, the house file's hostname, `PHX_HOST`, or a LAN address typed as digits, add that name to `DOBBY_ALLOWED_HOSTS` before upgrading, or it will answer 400
