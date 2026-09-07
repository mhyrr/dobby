# Changes on branch `tk-025-027-house-memory`

##### Added
- Dobby can answer questions about recorded household events: who changed a device, when something last happened, how many times, and which commands did not arrive. Dates and counts come from the house clock and the record, never from the model.
- The household can ask Dobby to keep watch: a condition that holds for a stated time, or no recorded change for a stated time, all day or in a daily window. Dobby proposes the exact rule in words, waits for agreement in a later message, and only then watches. A breach is said once in the thread and stands above it until acknowledged. Rules only report; they never change a device.
- Standing rules can be added, paused, resumed, and deleted on The House page, with an undo, and no model involved.
- Dobby knows the house's date, time, and clock offset when it answers, so a question about a named day ("what happened on September 1st?") reaches the record as that day.
- The house file can pin the one OpenRouter endpoint that serves the model (`system.provider`), with no fallback to another, so the first word arrives from the same place every time instead of wherever OpenRouter's routing lands that minute. Set it on `/admin` or in the file; it takes effect at the next reply, and a pin the model in force cannot take is refused and named, the way `routing` is.
- A paid eval sweeps every endpoint under a model and times each one to its first token, so the pin is a measurement and not a guess.
- Every request records what it cost: model turns, input, output, cached, and reasoning tokens, and the end to end, on its own row in the record. The activity feed on `/admin` shows them on the request's line, and the eval tier prints the cache read and the thinking beside the tokens it already printed.

##### Changed
- Dobby is told, before every turn, what each device can be watched for and which standing rules and notices exist, so asking for a rule no longer costs a turn spent reading the list first: a proposal is two model turns, and a pause or an acknowledgment is two.
- Dobby remembers what was said in the thread and forgets what it fetched to say it: earlier requests' tool calls and their results leave the conversation it carries to the model, while the words stay. The record still holds every row, and a rule or device proposal awaiting agreement is listed before every turn with the id its confirmation takes, so saying yes a message later still lands.

##### Fixed
- Dobby is shown each device's last known state before every turn. It had been told "state not yet known" for every device since the first release, and asked the device for its status before answering; a question the board could already answer no longer costs that extra round trip.

##### Upgrade and Migration
- Run the database migration for rule proposals and occurrences before starting this version. Rule definitions live under `house.rules` in the house file; the guide's house page shows the shape.

##### Verification
- `mix precommit` on 2026-09-06: compile with warnings as errors, unused deps, format, and 634 tests with 0 failures (the paid eval tests excluded). The runtime tests drive the real watcher through the house writer and were each checked to fail on the regression they name.
- The eval tier ran against a real model (gpt-5.6-luna through OpenRouter) on 2026-09-06: 22 scenarios, 7 for the record and 15 for standing rules, all passing on the final run. The first run failed 6 of 9 on the shape of the tools rather than on judgment, and the tools were reshaped until the model's replies read as the house should: "The vacuum was last recorded starting cleaning Thursday, September 3, at 7:35 AM." and "I can't set that rule as stated: 10pm to 6am is an eight-hour window, so it can't watch for nine hours."
- The same 22 scenarios ran against a second model (z-ai/glm-5.2 through OpenRouter) on 2026-09-06: 21 of 22 on the first run, and the one miss, a door in a house with two locks proposed for the front door, is a question after one doctrine sentence. The replies read the same way in both voices: "Which door, Greg — the front door lock or the side door lock?"
- The provider sweep ran on 2026-09-07 with Greg's authorisation, one run per endpoint: 24 endpoints under GLM 5.3 Flash (15 passed), 31 under GLM 5.2 (29), 7 under Luna (4). Pinned to its fastest endpoint, "set the thermostat to 70" is done in 2.2 s on Flash, 1.1 s on GLM 5.2, and 1.3 s on Luna; on the slowest endpoint of the same model it took four to twelve. The design record carries every row, and the house guide the three pins.
- In the browser, against the rig house at phone and desktop widths: the notice under the board with its acknowledge act, the standing-rule line in the thread, and the rules panel on The House. Console clean on both routes. The rule form was not driven in a browser, because the rig house is read only; the LiveView tests cover it.
