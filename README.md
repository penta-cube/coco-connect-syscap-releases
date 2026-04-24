# coco-connect-syscap-releases

Release assets and runtime scripts for `coco-connect-syscap`.

## Contents

- Windows executable release asset:
  - `coco-connect-syscap.exe`
- System Capture Tcl runtime:
  - `tcl/coco_syscap_bootstrap.tcl`
  - `tcl/syscap_bootstrap.tcl`
  - `tcl/coco_syscap_bridge_autoload.tcl`
  - `tcl/utils.tcl`
  - `tcl/highlight.tcl`
  - `tcl/property.tcl`

## Bridge Commands

- `ping`
- `highlight_net <NET_NAME>`
- `highlight_part <REFDES>`
- `clear_highlight`
- `part_properties <REFDES>`
- `part_property_get <REFDES>|<PROPERTY_NAME>`
- `part_property_set <REFDES>|<PROPERTY_NAME>|<VALUE>`
- `part_property_delete <REFDES>|<PROPERTY_NAME>`
- `part_property_display_mode <REFDES>|<PROPERTY_NAME>|<hidden|name_only|value_only|name_and_value>`

Property write commands use `|` as the argument separator because the line protocol has a
single argument field. `part_property_set` treats everything after the second `|`
as the value.

## Tcl Usage Examples

Manual Tcl usage in the System Capture command window:

```tcl
::coco_syscap_bridge::start 127.0.0.1 49501 ""
::coco_syscap_bridge::run
```

Autoload usage:

1. Place `tcl/coco_syscap_bridge_autoload.tcl` in the System Capture startup/autoload directory.
2. Ensure the runtime directory containing `coco_syscap_bootstrap.tcl` is reachable.
3. Optionally set `COCO_SYSCAP_BRIDGE_DIR`, `COCO_SYSCAP_BRIDGE_HOST`, and `COCO_SYSCAP_BRIDGE_PORT`.

Bridge command argument examples:

```text
ping
highlight_net AGND
highlight_part U1
clear_highlight
part_properties U1
part_property_get U1|Value
part_property_set U1|COCO_TEST_PROP|hello
part_property_delete U1|COCO_TEST_PROP
part_property_display_mode U1|COCO_TEST_PROP|value_only
```

## Response Format

The line protocol response uses:

- `id<TAB>json`

`json` is always a single-line JSON payload.

Success example:

```json
{"ok":true,"data":{"net":"AGND","selected_type":"SIMPLE_NOTE","x":16500,"y":5100}}
```

Error example:

```json
{"ok":false,"error":{"code":"not_found","message":"Part 'U1' not found on active page","details":{"refdes":"U1"}}}
```
