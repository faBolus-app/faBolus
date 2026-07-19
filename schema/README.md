# schema

Single source of truth for the phone↔watch/garmin command contract: `command.schema.json`.

Both the Swift host (`ios/`, `watch/`) and the Monkey C remote (`garmin/`) validate and generate messages against this file so the two sides never drift. DRAFT — finalize during Milestone 2.
