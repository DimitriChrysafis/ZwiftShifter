# Working on ZwiftShift

Read [HANDOFF.md](HANDOFF.md) first. It is the entry point for the findings,
verified implementation, evidence, operating procedures, and unfinished work.
Use [README.md](README.md) for normal build/run instructions.

- The working backend is native LAN / DirCon / Zwift Protocol. Keep shifting
  serialization and scheduling in `ZwiftShiftCore`, shared by the app and CLI.
- Success means a change in the actual Zwift game. Advertisement, packet writes,
  and an app-local counter do not establish success. The gear display reads
  Zwift's log; never replace it with optimistic increments.
- Controller connectivity, game gear feedback, and trainer readiness are
  separate facts. Pedaling resistance has **not** been verified. Read the
  acceptance record before making claims.
- The user explicitly wants a **very minimal native UI**. Preserve the small
  window, plain system appearance, two equal shift buttons, and secondary panels.
  See [Documentation/UI.md](Documentation/UI.md).
- Preserve personal controls and the stable controller identity. `build/runtime/`
  contains persistent settings; do not delete it as a routine build cleanup.
- Back up Zwift configuration before changing it. Preserve the installed game,
  account state, and macOS security settings. Keep experiments isolated.
- Keep this repository **private**. Raw logs, configuration backups, binary
  extracts, reference checkouts, and credentials stay in ignored local storage.
- Never print full Zwift process arguments: its launcher can put authentication
  tokens on the command line. Use PID/executable-name-only process inspection.
- Run checks appropriate to the change. Live tests change gears; use them when
  the task calls for it, with the actual ride/device state checked first. A
  documentation-only task does not require opening Zwift or shifting.
- Update the handoff and evidence when facts change. Label historical snapshots,
  actual observations, inferences, and remaining physical tests clearly.

Current user instructions and higher-priority agent instructions take precedence
over this file. Do not treat historical setup authorization as blanket approval
for unrelated future actions.
