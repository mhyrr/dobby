# Changes on branch `tk-025-027-house-memory`

##### Added
- Dobby can answer questions about recorded household events, including who changed a device and which commands did not arrive.
- The household can ask Dobby to watch a stated condition or a missing recorded change. Rules wait for agreement, report one notice per occurrence, and can be paused or acknowledged without a model.

##### Upgrade and Migration
- Run the database migration for rule proposals and occurrences before starting this version. Rule definitions live under `house.rules` in the house file.

##### Verification
- Greg reports the tests pass after the fixture, numeric schema, and two-turn replay corrections. The agent's Mix run remains blocked by an environment socket restriction; paid model evals and browser checks have not run.
