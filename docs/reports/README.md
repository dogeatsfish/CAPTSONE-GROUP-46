# Reports

Point-in-time investigation write-ups from one specific build/synthesis run
— not living reference docs. For current guidance on building, testing, or
running anything, see the parent [`docs/`](..) directory instead.

- [`timing_closure.md`](timing_closure.md) — analysis of the first full
  synthesis/implementation run.
- [`order_book_pipelining.md`](order_book_pipelining.md) — the RTL change
  made to fix the timing failure `timing_closure.md` found.
- [`pin_constraints_verification.md`](pin_constraints_verification.md) —
  audit of the pin constraints against the board's user manual.
- [`DRC_fix.md`](DRC_fix.md) — DRC warnings cleared alongside the timing fix.
