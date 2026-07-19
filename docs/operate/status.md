# Status HUD

The main screen is a Loop-style heads-up display.

- **Glucose chart** — recent CGM readings (read from the pump), with an in-range band (70–180
  mg/dL) and range-colored points.
- **Status ring** — the current glucose and trend, ringed by a color reflecting
  **connection/activity** state (connected, delivering, scanning, disconnected). This ring is
  *not* a closed-loop indicator — ControlX2iOS does not automate dosing.
- **Status pills**
    - **Active Insulin (IOB)** — insulin on board.
    - **Active Carbs (COB)** — carbohydrates on board.
    - **Reservoir** — units remaining.
    - **Pump** — battery %.
    - **CGM** — sensor status.
- **Last bolus** — amount and time.

Tap **Connect** to scan for and connect to the pump. All values update live while connected.

Terminology (IOB / "Active Insulin", COB / "Active Carbohydrates", correction range) follows
Loop for familiarity.
