# Python overlay renders

The 1445 PNGs here are the Python app's golden images, mirrored unchanged
from `tests/fixtures/overlay_golden/` of the Python repo at commit `7e62799`
(release 0.8.2) on 2026-11-15, from a `git archive` of that commit (0.8.2:
the X50i pages fitted to the watch's display, the Mk3i alerts, the
Shearwater warning row, reserve box and BAR/PSI, the Perdix 3 safety timer,
the X50i triangle's "!": 703 files changed, none added or removed). They
are the reference the Dart HUD renderer (spec §5) is compared with. Earlier
copies: 252 PNGs (2026-10-17, Python `b145e5a`), 1231 PNGs (2026-11-12,
Python `0fdefd8`, 0.7.20, regenerated in `9faf8f5`), 1421 PNGs (2026-11-14,
Python `d033961`, 0.8.0, the Suunto goldens added), 1445 PNGs (2026-11-14,
Python `d3ecc09`, after 0.8.1: the Shearwater text at the manuals' sizes,
942 files changed and 24 added).

How they are made (`tests/test_template_golden.py` in the Python repo):
every bundled template page and variant (115 combinations) is rendered by
`draw_hud` on a black 1920x1080 frame at a waypoint forced into one of nine
states (`normal`, `ndl_low`, `deco_at_stop`, `deco_violation`, `clear`,
`safety_stop`, `safety_paused`, `fast_ascent`, `critical_gas`) with the
dummy dive from `utils/dummy_telemetry.py`; three of the states (`normal`,
`deco_at_stop`, `critical_gas`) are also rendered in imperial units
(`__imperial` suffix: feet, a 10/20 ft stop ladder, psi). The 13 rebreather
pages and variants are also rendered on the CCR dummy dive at five moments
(`ccr@20`, `ccr@600`, `ccr@930`, `ccr@1300`, `ccr@1580`, seconds into the
dive; metric only). 115 x 12 + 13 x 5 = 1445. The frame is cropped to the
overlay's own pixels and halved.
File name: `<brand>__<computer>__<page>[__<variant>]__<state>[__imperial].png`.

The Python test accepts a mean absolute difference of 2.0 over the crop and
at most 0.5 % of pixels differing by more than 40. The Dart parity test
should start from the same thresholds and state its own.

The renders depend on fonts: they were made on the owner's Mac, where
"Arial" is the platform Arial; the port bundles Liberation Sans for all
platforms (spec §5.6), so a small, uniform glyph difference is expected and
must be judged by eye once, then fixed as a tolerance, not by regenerating.
The Descent X50i pages are set in the bundled Roboto Condensed bold and do
not depend on the platform.

Refresh: the owner regenerates in the Python repo (`pytest
tests/test_template_golden.py -m golden --update-golden`) and reviews the
diff there; an agent never runs that, it writes into the Python repo. Once
the Python tree is clean, mirror the folder here (PNGs added, changed and
removed) and update the commit and the count above.
