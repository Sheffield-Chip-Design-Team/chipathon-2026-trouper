# `ol_mimo_rx_top` status

`mimo_rx_top` is deprecated.

This directory is retained only for archived synthesis/P&R experiments that were
run before `trouper_top` became the canonical hardened-macro boundary.

- Do not start new implementation work from `ol_mimo_rx_top`.
- Do not treat `config_current.json` here as tapeout-current.
- Use [`../ol_trouper_top/`](../ol_trouper_top/) for active Trouper P&R work.
- Use [`../rtl/trouper_top.v`](../rtl/trouper_top.v) as the canonical top-level RTL.

The legacy wrapper still exists so old configs and comparison runs can be
reproduced, but its port shape and assumptions are no longer the target chip
boundary.
