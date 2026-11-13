# Exports

Server-side exports for other resources, such as housing or MLO armouries. Run exports that write to the database from an event handler or thread.

## GetRacks()

Returns all racks as detached copies, including stored guns and metadata. The result is sorted by rack ID.

## GetRack(id)

Returns a detached copy of the rack with the given ID, or `nil` if it does not exist.

## CreateRack(model, coords, heading, opts)

Creates a rack without an item and returns its integer ID on success, or `nil, error` on failure.

- `model`: rack model name (for example, a supported `sd_gunrack_*` model).
- `coords`: world position with numeric `x`, `y`, and `z` fields.
- `heading`: heading in degrees.
- `opts` (optional): `bucket`, `owner`, `ownerName`, `locked`, `access`, and `ignoreSpacing`.

Possible errors: `bad_model`, `bad_coords`, `too_close`, `overlap`, `save_failed`.

## DeleteRack(id, giveTo)

Deletes a rack and returns `true, guns` on success, or `false, error` on failure.

- Without `giveTo`, the rack's guns are returned to the caller as records containing `name`, `item`, `metadata`, `by`, and `at`; the caller chooses where to put them.
- With `giveTo` (a player server ID), the guns are given to that player's inventory before the rack is deleted. If they cannot carry all guns, the rack remains and the export returns `false, 'cannot_carry'`.

Possible errors include `no_rack`, `busy`, `cannot_carry`, and `save_failed`.
