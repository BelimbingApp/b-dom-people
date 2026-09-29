# Settings

Module ID: `people/settings`. People operator settings and navigation anchor.

This module contributes the `People` navigation anchor and its shared
`people.my_work` (My work) and `people.settings` (Settings) groups. Modules that
place leaves under these groups depend on `people/settings` rather than
defining the groups themselves. Base Menu hides a node while it has no visible
children. It owns no table or route; reference
records and the operator page live in `people/reference_data`.
