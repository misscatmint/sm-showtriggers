# sm-showtriggers

A SourceMod plugin that lets players see the map's trigger brushes, drawn with
the texture the mapper gave them (usually the "TRIGGER" tool texture).

## Usage

`sm_showtriggers` toggles the view for the player who runs it.

## Requirements

- SourceMod 1.12 with SDKHooks and SDKTools.
- Tested on CS:GO only. Nothing in it is CS:GO-specific, so it should work in
  other Source 1 games.

Don't run it next to another plugin that registers `sm_showtriggers`, and
don't use the engine's `showtriggers_toggle` while anyone has the view on: it
flips every trigger for everyone and leaves them mixed up until the map
reloads.

## Technical details

While nobody has it on, the plugin changes nothing: no entity is touched and
no hook is kept. When the last player turns it off or leaves, every trigger is
put back as it was and every stand-in (see below) is removed.

### What gets shown

A brush entity is shown when it:

- is a trigger (has the `FSOLID_TRIGGER` solid flag, or is a disabled
  `CBaseTrigger`),
- collides with its own brush (solid type BSP or VPhysics),
- is hidden from clients by default (`EF_NODRAW`).

It isn't shown when:

- it uses box collision. Plugin-made zones that borrow a map brush and set
  their own bounds fall in here, since the brush isn't their real shape.
- its brush has no visible faces, for example a trigger built from a texture
  the compiler strips.

Shown triggers are tinted black. Drawn as is, the trigger texture's orange
changes with the surroundings and the viewpoint, and glows in some spots. In
black, every trigger draws the same way: a dark translucent box with readable
"TRIGGER" text.

### Triggers clients already receive

Some hidden triggers are sent to every client anyway, for example a trigger
something is parented to, or CS:GO's client-predicted `trigger_playermovement`
(auto-duck, auto-walk or disable jump). Showing one only to some players would
break it for the others, so the plugin leaves it untouched and draws a
stand-in in its place: a `func_illusionary` with the trigger's brush, tinted
black and sent only to players with the view on.

- Each stand-in takes one edict while the view is on.
- A stand-in for a trigger that moves with a parent is parented to the trigger
  so it follows. That's the one change to a map entity: the trigger has the
  stand-in as a child until the stand-in is removed.
- A stand-in is removed with its trigger, so a round restart that rebuilds the
  triggers leaves one stand-in per trigger.

### Entity limit

A Source server crashes when it runs out of edicts, so stand-ins never take
the last ones. While the view is on, the plugin keeps a live count of edicts
in use (player slots included) and:

- creates a stand-in only while at least `STANDIN_CREATE_MARGIN` (288) edicts
  would stay free,
- removes every stand-in once fewer than `STANDIN_RELEASE_MARGIN` (192) are
  free, for example when players join or the map spawns entities, and keeps
  them off until the view is next turned on by the first viewer,
- tells viewers once: "Some triggers aren't shown: the server is near its
  entity limit."

Both are margins below the engine's edict limit (`GetMaxEntities()`, 2048 in
CS:GO), set as constants at the top of `showtriggers.sp`. The gap between them
has to stay at least 96, which the compiler checks. Triggers shown without a
stand-in take no edicts and aren't affected.

## License

AGPL-3.0, see `LICENSE.txt`.
