# Changes on branch `claude-repo-audit-sonos-kkxr0q`
What changed for the house, in the voice of the commit messages. Empty headings are dropped at release.
##### Added
-

##### Changed
-

##### Fixed
-

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
