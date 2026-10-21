#!/usr/bin/env python3
"""SVG chart primitives for the volucer benchmark reports.

Pure-Python SVG generation. No third-party dependency, no build step.

**Everything is expressed with SVG *presentation attributes* — never ``<style>``
blocks or CSS classes.** A ``<style>`` block is stripped by any Markdown
renderer that sanitises HTML, so class-based styling silently disappears in a
published page. Presentation attributes survive, and they also survive when the
``.svg`` is embedded with ``<img src="...">``.

**Because an ``<img>``-embedded SVG cannot depend on the host page's theme, each
chart paints its own card background and uses fixed ink colours** that read on
both a light and a dark page.

Usage:

    from svgchart import grouped_bars, single_bars, range_bars

    svg = grouped_bars(
        categories=["c=1", "c=4", "c=8"],
        series={"volucer": [3268, 12970, 23278], "php-fpm": [1823, 6504, 11638]},
        colors={"volucer": "#2563eb", "php-fpm": "#94a3b8"},
        labels={"volucer": "volucer (worker)", "php-fpm": "nginx + php-fpm"},
        title="Throughput",
    )
"""

from __future__ import annotations

import math
from typing import Iterable, Mapping, Sequence

# Ink + surface colours (fixed, theme-independent).
CARD_BG = "#ffffff"
CARD_EDGE = "#e2e8f0"
INK = "#1e293b"
INK_SOFT = "#64748b"
FACTOR_INK = "#94a3b8"
AXIS = "#cbd5e1"
GRID = "#f1f5f9"
FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"

LEGEND_TOP = 74
LEGEND_ROW_H = 17


def _escape(text: str) -> str:
    """XML-escape a string for an attribute or a text node."""
    return (
        str(text)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def _text(x: float, y: float, content: str, *, size: int = 12, fill: str = INK,
          anchor: str = "start", weight: str = "normal") -> str:
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-family="{FONT}" font-size="{size}" '
        f'fill="{fill}" text-anchor="{anchor}" font-weight="{weight}">{_escape(content)}</text>'
    )


def _fmt(value: float) -> str:
    """A number, formatted the way a chart axis wants it.

    Thousands get a separator, and a value that is not whole keeps up to two
    decimals — enough to tell 12,970 from 12,974 without a wall of digits.
    """
    if value is None or not math.isfinite(value):
        return "-"
    if abs(value) >= 1000:
        return f"{value:,.0f}"
    if abs(value) >= 100:
        return f"{value:,.1f}"
    if abs(value) >= 1:
        return f"{value:,.2f}".rstrip("0").rstrip(".")
    return f"{value:.3f}".rstrip("0").rstrip(".")


def _fmt_tick(value: float) -> str:
    """A tick label with the trailing zeros trimmed: ``300.0`` becomes ``300``.

    Only fractional zeros are trimmed — ``120`` must stay ``120``, and trimming
    a whole number's trailing zero would print ``12``.
    """
    if abs(value) < 1e-12:
        return "0"
    decimals = 0 if value >= 100 else (1 if value >= 10 else (2 if value >= 1 else 3))
    text = f"{value:.{decimals}f}"
    if "." not in text:
        return text
    return text.rstrip("0").rstrip(".")


def _nice_ticks(maximum: float, count: int = 5) -> list[float]:
    """Axis ticks at round numbers, so the grid reads as a scale.

    A "nice" step is one of 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8 or 10 times a power of
    ten. The step is chosen so the *whole* range is covered by at most ``count``
    intervals. The longer list of multiples matters: with only 1/2/2.5/5/10, a
    maximum of 313 picks a step of 100 and the axis tops out at 400 — a third of
    the plot empty. With 8 in the list it picks 80 and tops out at 320.
    """
    if maximum <= 0:
        return [0.0, 1.0]

    raw_step = maximum / max(count - 1, 1)
    magnitude = 10 ** math.floor(math.log10(raw_step))
    for multiple in (1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10):
        step = multiple * magnitude
        if step >= raw_step:
            break
    else:  # pragma: no cover - the loop always breaks
        step = 10 * magnitude

    ticks = []
    value = 0.0
    # The LAST tick must be at or above the maximum, or every value past it
    # draws beyond the plot's right edge — caps and bars outside the axis.
    while value < maximum - 1e-9:
        ticks.append(round(value, 10))
        value += step
    ticks.append(round(value, 10))
    return ticks


def _layout_legend(series: Mapping[str, Sequence[float]], colors: Mapping[str, str],
                    labels: Mapping[str, str], pad_left: float, right_edge: float
                    ) -> tuple[list[tuple[str, str, float, float]], int]:
    """Lay the legend out up-front, so the plot area can shrink to fit it.

    Returns ``(colour, label, x, y)`` for every entry plus the number of rows
    they occupy. **The placement computed here is the placement that gets
    drawn** — laying the legend out twice, once to count rows and once to draw,
    is how a legend silently runs off the right edge: the second pass has no
    idea a wrap happened.
    """
    items: list[tuple[str, str, float, float]] = []
    x = pad_left
    y = LEGEND_TOP - 22
    rows = 1

    for key in series:
        colour = colors.get(key, FACTOR_INK)
        label = labels.get(key, key)
        width = 12 + 6 + _approx_text_width(label, 12)
        if x + width > right_edge and x > pad_left:
            x = pad_left
            y += LEGEND_ROW_H
            rows += 1
        items.append((colour, label, x, y))
        x += width + 18

    return items, rows


def _legend_svg(items: Sequence[tuple[str, str, float, float]]) -> str:
    """The legend, drawn from the placements ``_layout_legend`` already made."""
    parts = []
    for colour, label, x, y in items:
        parts.append(
            f'<rect x="{x:.1f}" y="{y - 9:.1f}" width="12" height="12" rx="3" fill="{colour}"/>'
        )
        parts.append(_text(x + 18, y + 1, label, size=12, fill=INK_SOFT))
    return "".join(parts)


def _chart_open(width: int, height: int, title: str) -> str:
    """The card, the title and the subtitle line."""
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" '
        f'aria-label="{_escape(title)}">',
        f'<rect x="0.5" y="0.5" width="{width - 1}" height="{height - 1}" rx="8" '
        f'fill="{CARD_BG}" stroke="{CARD_EDGE}"/>',
    ]
    if title:
        parts.append(_text(64, 34, title, size=15, fill=INK, weight="600"))
    return "".join(parts)


def _chart_close() -> str:
    return "</svg>"


def grouped_bars(categories: Sequence[str],
                 series: Mapping[str, Sequence[float]],
                 colors: Mapping[str, str],
                 labels: Mapping[str, str],
                 title: str = "",
                 value_suffix: str = "",
                 width: int = 960,
                 height: int = 400,
                 log_scale: bool = False,
                 note: str = "") -> str:
    """Grouped vertical bar chart: one group per category, one bar per series.

    ``series`` maps a series key to one value per category. A value that is
    ``None`` is drawn as *nothing at all* — not as zero — because a zero reads
    as "measured, and it was terrible" rather than "not measured". The category
    label says so where it matters.

    ``note`` is stamped under the title: the host and the method the numbers
    were measured on. A throughput figure with no host beside it is not a
    measurement a reader can weigh.
    """
    pad_left, pad_right, pad_bottom = 74, 16, 74
    note_lines = _wrap(note, width - pad_left - pad_right, 11.5) if note else []
    legend_items, legend_rows = _layout_legend(series, colors, labels, pad_left,
                                               width - pad_right)
    pad_top = LEGEND_TOP + (legend_rows - 1) * LEGEND_ROW_H + 18 + len(note_lines) * 18
    plot_width = width - pad_left - pad_right
    plot_height = height - pad_top - pad_bottom
    if plot_height < 40:
        plot_height = 40
        height = pad_top + plot_height + pad_bottom

    values = [v for row in series.values() for v in row if v is not None and math.isfinite(v)]
    maximum = max(values) if values else 1.0
    minimum = min((v for v in values if v > 0), default=0.0)

    if log_scale:
        # A log axis draws a *ratio* as a length, so the fastest thing looks
        # the most volatile. It is only offered where a caller asks for it.
        low = max(minimum, maximum / 1000) if minimum > 0 else maximum / 1000
        ticks = [low * (10 ** i) for i in range(4)]
        ticks = [t for t in ticks if t <= maximum * 1.05]
        if not ticks:
            ticks = [maximum]
        floor = math.log10(low)
        ceiling = math.log10(max(maximum * 1.05, low * 10))
        span = max(ceiling - floor, 1e-9)

        def to_y(value: float) -> float:
            return pad_top + plot_height * (1 - (math.log10(value) - floor) / span)
    else:
        ticks = _nice_ticks(maximum)
        top = ticks[-1] if ticks else 1.0
        span = max(top, 1e-9)

        def to_y(value: float) -> float:
            return pad_top + plot_height * (1 - value / span)

    parts = [_chart_open(width, height, title)]
    parts.append(_legend_svg(legend_items))

    # The provenance line, under the legend: what and how, never a datum.
    note_y = LEGEND_TOP + (legend_rows - 1) * LEGEND_ROW_H + 26
    for line in note_lines:
        parts.append(_text(pad_left, note_y, line, size=11.5, fill=INK_SOFT))
        note_y += 15

    # Grid and the value axis.
    for tick in ticks:
        y = to_y(tick)
        if y < pad_top - 1 or y > pad_top + plot_height + 1:
            continue
        parts.append(
            f'<line x1="{pad_left}" y1="{y:.1f}" x2="{width - pad_right}" y2="{y:.1f}" '
            f'stroke="{GRID}" stroke-width="1"/>'
        )
        parts.append(_text(pad_left - 8, y + 4, _fmt_tick(tick), size=11, fill=INK_SOFT, anchor="end"))

    parts.append(
        f'<line x1="{pad_left}" y1="{pad_top + plot_height}" x2="{width - pad_right}" '
        f'y2="{pad_top + plot_height}" stroke="{AXIS}" stroke-width="1"/>'
    )

    group_width = plot_width / max(len(categories), 1)
    bar_gap = 4
    bar_width = max((group_width * 0.78) / max(len(series), 1) - bar_gap, 3)

    for index, category in enumerate(categories):
        group_x = pad_left + group_width * index
        for series_index, (key, row) in enumerate(series.items()):
            if index >= len(row):
                continue
            value = row[index]
            if value is None or not math.isfinite(value):
                # Not measured. Drawn as nothing, and the legend says so.
                continue
            x = group_x + group_width * 0.11 + series_index * (bar_width + bar_gap)
            y = to_y(value)
            bar_height = max(pad_top + plot_height - y, 0.5)
            colour = colors.get(key, FACTOR_INK)
            parts.append(
                f'<rect x="{x:.1f}" y="{y:.1f}" width="{bar_width:.1f}" '
                f'height="{bar_height:.1f}" rx="2" fill="{colour}"/>'
            )
        parts.append(
            _text(group_x + group_width / 2, pad_top + plot_height + 20, category,
                  size=12, fill=INK, anchor="middle")
        )

    if value_suffix:
        parts.append(_text(width - 16, 34, value_suffix, size=11,
                           fill=INK_SOFT, anchor="end"))

    parts.append(_chart_close())
    return "".join(parts)


def single_bars(categories: Sequence[str], values: Sequence[float], colour: str,
                title: str = "", value_suffix: str = "", width: int = 960,
                height: int = 400, highlight: int | None = None) -> str:
    """One bar per category, in one colour.

    ``highlight`` marks one index with a second colour — the arm the page is
    about, in a chart that compares several.
    """
    series = {"value": list(values)}
    colors = {"value": colour}
    if highlight is not None:
        series = {}
        colors = {}
        for index in range(len(categories)):
            key = f"v{index}"
            series[key] = [values[index] if index == 0 else None]
            colors[key] = colour
    return grouped_bars(categories, series, colors,
                        {k: "" for k in series}, title=title,
                        value_suffix=value_suffix, width=width, height=height)


def _approx_text_width(text: str, size: float) -> float:
    """An approximation of the rendered width of a string.

    Good enough to size a gutter, and much better than a fixed constant: a
    fixed reserve clips the column the moment a label grows past what it was
    sized for. The factor is the average advance width of the system font at
    this size, which is close enough for a gutter and never the thing being
    read.
    """
    return len(str(text)) * size * 0.56


def range_bars(categories: Sequence[str], low: Sequence[float], high: Sequence[float],
               centre: Sequence[float], colour: str, title: str = "",
               value_suffix: str = "", width: int = 960, height: int | None = None,
               note: str = "", value_header: str = "low \u00b7 median \u00b7 high",
               show_factor: bool = False, factor_note: str = "") -> str:
    """A horizontal range chart: a bar from ``low`` to ``high`` with a dot at ``centre``.

    Horizontal, not vertical. A range chart is read as "how much", so the length
    that carries the answer has to be the long axis of the card; and the labels
    that name each row have to sit beside it, where a wide label costs a wider
    gutter rather than a taller one.

    Two left-hand columns ? the row name, then its three readings ? are **both
    sized from the strings that will actually be printed**. A fixed reserve
    clips the moment a label outgrows it, and the clipped column is the one
    holding the numbers.

    A ``None`` reading is drawn as nothing and printed as ``-``. Drawing it as
    zero would say "measured, and it was nothing" instead of "not measured".
    """
    if not categories:
        return ""

    rows = len(categories)
    pad_right = 40.0

    # Both left-hand columns, measured from the exact strings drawn below.
    value_strings: list[str] = []
    for index in range(rows):
        parts = []
        for series in (low, centre, high):
            value = series[index] if index < len(series) else None
            parts.append(_fmt(value) if value is not None else "-")
        value_strings.append(" \u00b7 ".join(parts))

    name_width = max((_approx_text_width(name, 12.5) for name in categories), default=0.0)
    value_width = max(
        [_approx_text_width(value_header, 11)] +
        [_approx_text_width(text, 12.5) for text in value_strings]
    )

    name_right = 16.0 + name_width
    value_right = name_right + 18.0 + value_width
    pad_left = value_right + 16.0

    # The factor column, when asked for: a row's centre against the lightest
    # centre. Its gutter is sized from the widest label it will print, and it
    # is only drawn when at least two rows can be told apart ? a column of
    # identical labels says nothing.
    factors: list[str] = [""] * rows
    if show_factor:
        mids = [centre[i] for i in range(rows)
                if i < len(centre) and centre[i] is not None]
        if mids:
            lightest = max(min(mids), 1e-9)
            for index in range(rows):
                mid = centre[index] if index < len(centre) else None
                if mid is None or abs(mid - lightest) < 1e-9:
                    continue
                factors[index] = _fmt_factor(mid / lightest)
        if not any(factors):
            show_factor = False
    if show_factor and factors:
        widest = max((_approx_text_width("x" + f, 12.5) for f in factors if f), default=0.0)
        pad_right = 12.0 + widest + 16.0

    # Header block: title, then the note line, wrapped to the card.
    notes = [line for line in (note, factor_note) if line]
    note_lines: list[str] = []
    note_width = width - pad_left - 12.0
    for line in notes:
        note_lines.extend(_wrap(line, note_width, 11.5))

    title_y = 34.0
    pad_top = (title_y + 24.0) if title else 18.0
    for _line in note_lines:
        pad_top += 20.0
    pad_top += 14.0

    row_height = 34.0
    grid_bottom = pad_top + rows * row_height + 12.0
    if height is None:
        height = int(round(grid_bottom + 62.0))

    values = [v for row in (low, high, centre, ) for v in row
              if v is not None and math.isfinite(v)]
    maximum = max(values) if values else 1.0
    ticks = _nice_ticks(maximum, 5)
    top = ticks[-1] if ticks else 1.0
    span = max(top, 1e-9)
    plot_width = width - pad_left - pad_right

    def to_x(value: float) -> float:
        return pad_left + plot_width * (value / span)

    parts = [_chart_open(width, height, title)]

    y = title_y + 22.0
    for line in note_lines:
        parts.append(_text(64.0, y, line, size=11.5, fill=INK_SOFT))
        y += 20.0

    parts.append(_text(value_right, pad_top - 12, value_header, size=11,
                       fill=INK_SOFT, weight="600", anchor="end"))

    for tick in ticks:
        x = to_x(tick)
        if x < pad_left - 0.5 or x > width - pad_right + 0.5:
            continue
        parts.append(
            f'<line x1="{x:.1f}" y1="{pad_top - 6:.1f}" x2="{x:.1f}" '
            f'y2="{grid_bottom:.1f}" stroke="{GRID}" stroke-width="1"/>'
        )
        parts.append(_text(x, grid_bottom + 18, _fmt_tick(tick), size=11,
                            fill=INK_SOFT, anchor="middle"))

    if value_suffix:
        parts.append(_text(width - 16, 34, value_suffix, size=11,
                           fill=INK_SOFT, anchor="end"))

    parts.append(
        f'<line x1="{pad_left:.1f}" y1="{grid_bottom:.1f}" '
        f'x2="{width - pad_right:.1f}" y2="{grid_bottom:.1f}" '
        f'stroke="{AXIS}" stroke-width="1"/>'
    )

    cap_height = 7.0
    for index, name in enumerate(categories):
        centre_y = pad_top + row_height * index + row_height / 2
        low_value = low[index] if index < len(low) else None
        high_value = high[index] if index < len(high) else None
        mid_value = centre[index] if index < len(centre) else None

        if mid_value is not None:
            parts.append(
                f'<rect x="{pad_left:.1f}" y="{centre_y - cap_height:.1f}" '
                f'width="{max(to_x(mid_value) - pad_left, 0.5):.1f}" '
                f'height="{cap_height * 2:.1f}" fill="{colour}" fill-opacity="0.12"/>'
            )

        if low_value is not None and high_value is not None:
            x_low, x_high = to_x(low_value), to_x(high_value)
            parts.append(
                f'<line x1="{min(x_low, x_high):.1f}" y1="{centre_y:.1f}" '
                f'x2="{max(x_low, x_high):.1f}" y2="{centre_y:.1f}" '
                f'stroke="{colour}" stroke-width="2.5" stroke-linecap="round" '
                f'opacity="0.45"/>'
            )
            for x_cap in (x_low, x_high):
                parts.append(
                    f'<line x1="{x_cap:.1f}" y1="{centre_y - cap_height:.1f}" '
                    f'x2="{x_cap:.1f}" y2="{centre_y + cap_height:.1f}" '
                    f'stroke="{colour}" stroke-width="2.5" stroke-linecap="round"/>'
                )

        if mid_value is not None:
            parts.append(
                f'<circle cx="{to_x(mid_value):.1f}" cy="{centre_y:.1f}" r="5.2" '
                f'fill="{colour}" stroke="{CARD_BG}" stroke-width="2"/>'
            )

        parts.append(_text(name_right, centre_y + 4.5, name, size=12.5,
                           fill=colour, weight="700", anchor="end"))
        parts.append(_text(value_right, centre_y + 4.5, value_strings[index],
                           size=12.5, fill=INK, weight="700", anchor="end"))

        if show_factor and factors[index]:
            anchor = max(to_x(low_value) if low_value is not None else pad_left,
                         to_x(high_value) if high_value is not None else pad_left)
            parts.append(_text(anchor + 9, centre_y + 4.5, f"x{factors[index]}",
                               size=12.5, fill=FACTOR_INK))

    parts.append(_chart_close())
    return "".join(parts)


def _fmt_rps(value: float | None) -> str:
    """A request rate, with a thousands separator.

    A rate is a count per second, so it is printed whole: 26,009 rps, and
    never 26,009.4 - the measurement does not support the decimal.
    """
    if value is None or not math.isfinite(value):
        return "-"
    if abs(value) >= 100:
        return f"{value:,.0f}"
    if abs(value) >= 1:
        return f"{value:,.2f}".rstrip("0").rstrip(".")
    return f"{value:.3f}".rstrip("0").rstrip(".")


def _fmt_factor(value: float | None) -> str:
    """A factor, to one decimal place: ``2.3``.

    One decimal, always - so a column of factors scans as a scale rather
    than as mixed precision. Clipped at 1000 so a runaway value cannot
    print a label long enough to run off the card.
    """
    if value is None or not math.isfinite(value):
        return "-"
    if value >= 1000:
        return "1000+"
    return f"{value:.1f}"


def throughput_dots(rows: Sequence[Mapping], title: str = "", note: str = "",
                     unit: str = "requests per second", width: int = 960,
                     height: int | None = None, reference_label: str = "") -> str:
    """A bar chart of throughput, every bar labelled with how much slower it is.

    The chart this replaces plotted *ratios* against a fixed reference arm.
    That answered the comparison well, but it buried the number a reader
    actually wants - how many requests per second the server did - in a
    table beside the chart. This chart puts the rate on the axis, where a
    chart of throughput belongs, and gives every bar a **floating label**: the
    factor, printed behind the bar.

    The **factor** is how many times slower the bar is than the reference -
    ``x 2.3`` for a server at 43% of the reference's rate. It is the
    reciprocal of the share, and the reciprocal is the direction a reader
    thinks in: "twice as slow" is a thing people say, "half the share" is
    not. The same number also describes a comparison of times rather than
    rates, so it reads the same way whichever way the axis happens to run.

    The **reference** is the row marked ``reference`` - the one every other
    bar is measured against. A vertical line marks where it sits, and it
    carries no factor of its own: a reference that said "x 1.0" would be a
    yardstick measuring itself. The same rule skips any other bar whose
    factor rounds to x 1.0, because a label that says nothing is noise.

    The bars start at zero. A bar that starts anywhere else is a bar that
    exaggerates, and the near-ties at the top of the chart are the ones a
    reader most needs to see honestly. What makes them readable is the
    floating label, not a truncated axis.

    The **range on each bar is the range of the round-paired ratios**, scaled
    back into requests per second. For each round both arms were measured,
    the ratio of that round's two numbers was taken, and the extremes of
    those ratios are the range. Pairing by round is what makes it honest: a
    host that drifts over the run moves both arms in the same round, so the
    ratio inside a round is far steadier than either arm's own spread. A
    range drawn from an arm's own minimum and maximum would instead charge
    the whole of the host's drift to one arm, and would be wide for the
    wrong reason.

    The reference has no range of its own: it is the yardstick every other
    bar is measured against, and a yardstick with a range on it is not a
    yardstick.

    The factor is an annotation, not a datum, so it is drawn in the faded
    slate of the scale rather than the ink of the measurement - the numbers
    whisper, and the bars carry the claim.
    """
    if not rows:
        return ""

    ordered = sorted(rows, key=lambda row: -(row.get("rps") or 0.0))

    # The left-hand columns. The name and the model are stacked, because a
    # chart row has room for a name and a model, not a sentence: the table
    # beside the chart keeps the full description of each arm.
    label_width = 0.0
    for row in ordered:
        label_width = max(label_width,
                          _approx_text_width(row.get("name", ""), 12.5),
                          _approx_text_width(row.get("model", ""), 11))
    rps_texts = [_fmt_rps(row.get("rps")) for row in ordered]
    rps_width = max((_approx_text_width(text, 12.5) for text in rps_texts),
                    default=0.0)

    label_x = 16.0
    rps_right = label_x + label_width + 22.0 + rps_width
    pad_left = rps_right + 22.0

    # The gutter on the right holds the floating labels. It is reserved
    # rather than improvised per row, so a label never lands on the axis, and
    # it is sized from the labels that will actually be printed - a fixed
    # reserve is a reserve that is either wasted or too small.
    factor_texts = [
        _fmt_factor(row.get("factor")) if row.get("factor") is not None else ""
        for row in ordered
    ]
    widest_factor = max(
        (_approx_text_width("x" + text, 12.5) for text in factor_texts if text),
        default=0.0,
    )
    gutter = max(56.0, widest_factor + 22.0)
    plot_width = max(width - 16.0 - gutter - pad_left, 80.0)

    # The axis. The bars start at zero, and the top tick is the first nice
    # number at or above the fastest bar, which leaves the fastest bar a
    # little room to the right of the last gridline.
    values: list[float] = []
    for row in ordered:
        for key in ("rps", "low", "high"):
            value = row.get(key)
            if value is None or not math.isfinite(value) or value < 0:
                continue
            values.append(value)
    data_max = max(values) if values else 0.0
    if data_max <= 0:
        data_max = 1.0
    ticks = _nice_ticks(data_max, 6)
    axis_max = ticks[-1] if ticks else data_max
    if axis_max <= 0:
        axis_max = 1.0

    def to_x(value: float) -> float:
        return pad_left + plot_width * (value / axis_max)

    # The note block, wrapped to the card.
    note_lines: list[str] = []
    if note:
        note_lines = _wrap(note, width - 64.0 - 12.0, 11.5)

    title_y = 34.0
    pad_top = (title_y + 24.0) if title else 18.0
    pad_top += 20.0 * len(note_lines)
    pad_top += 14.0

    row_height = 40.0
    grid_bottom = pad_top + len(ordered) * row_height + 8.0
    if height is None:
        height = int(round(grid_bottom + 58.0))

    # The baseline: the fastest arm in the chart.
    reference_row = None
    for row in ordered:
        if row.get("reference"):
            reference_row = row
            break
    if reference_row is None:
        reference_row = ordered[0]

    parts = [_chart_open(width, height, title)]

    y = title_y + 22.0
    for line in note_lines:
        parts.append(_text(64.0, y, line, size=11.5, fill=INK_SOFT))
        y += 20.0

    if unit:
        parts.append(_text(width - 16, 34, unit, size=11, fill=INK_SOFT,
                           anchor="end"))

    # The grid and its ticks.
    for tick in ticks:
        x = to_x(tick)
        if x < pad_left - 0.5 or x > pad_left + plot_width + 0.5:
            continue
        parts.append(
            f'<line x1="{x:.1f}" y1="{pad_top - 6:.1f}" x2="{x:.1f}" '
            f'y2="{grid_bottom:.1f}" stroke="{GRID}" stroke-width="1"/>'
        )
        parts.append(_text(x, grid_bottom + 18, _fmt(tick), size=11,
                            fill=INK_SOFT, anchor="middle"))

    # The baseline line, drawn under the bars: it is a ruler, not a
    # measurement, and a ruler that cuts through a label is a ruler in the
    # wrong place.
    x_reference = to_x(reference_row.get("rps") or 0.0)
    parts.append(
        f'<line x1="{x_reference:.1f}" y1="{pad_top - 14:.1f}" '
        f'x2="{x_reference:.1f}" y2="{grid_bottom:.1f}" '
        f'stroke="{AXIS}" stroke-width="1.5" stroke-dasharray="4 3"/>'
    )
    # The baseline is named just to the left of the line it marks, so the
    # caption and the line it names are a reader's eye apart rather than a
    # screen apart. It is right-aligned against the line and never centred
    # on it, because the line sits at the fastest bar - near the right-hand
    # end of the plot - and a caption centred there would run off the card.
    if reference_label:
        caption = f"\u25c4 {reference_label}"
        caption_width = _approx_text_width(caption, 11)
        x_caption = max(x_reference - 8.0, caption_width + 16.0)
        parts.append(_text(x_caption, pad_top - 20, caption, size=11,
                            fill=INK_SOFT, anchor="end"))

    parts.append(
        f'<line x1="{pad_left:.1f}" y1="{grid_bottom:.1f}" '
        f'x2="{pad_left + plot_width:.1f}" y2="{grid_bottom:.1f}" '
        f'stroke="{AXIS}" stroke-width="1"/>'
    )

    cap_height = 6.0
    bar_height = 9.0
    for position, row in enumerate(ordered):
        name = row.get("name", "")
        model = row.get("model", "")
        colour = row.get("color", FACTOR_INK)
        rps = row.get("rps")
        low = row.get("low")
        high = row.get("high")
        factor = row.get("factor")

        row_y = pad_top + row_height * position + row_height * 0.40

        if rps is None:
            parts.append(_text(label_x, row_y + 4.5, name, size=12.5,
                               fill=INK_SOFT, weight="700"))
            parts.append(_text(rps_right, row_y + 4.5, "-", size=12.5,
                               fill=INK_SOFT, weight="700", anchor="end"))
            continue

        x_end = to_x(rps)

        # The bar, from zero. It is the throughput, drawn as a length.
        parts.append(
            f'<rect x="{pad_left:.1f}" y="{row_y - bar_height / 2:.1f}" '
            f'width="{max(x_end - pad_left, 1.0):.1f}" height="{bar_height:.1f}" '
            f'rx="3" fill="{colour}" fill-opacity="0.16"/>'
        )

        # The range, in requests per second. It is the range of the
        # round-paired ratios, scaled back onto the rate axis, and it is
        # widened to contain the bar's end: a range that did not contain the
        # number beside it would contradict the table.
        if low is not None and high is not None:
            whisker_lo = min(low, rps)
            whisker_hi = max(high, rps)
            x_low, x_high = to_x(whisker_lo), to_x(whisker_hi)
            parts.append(
                f'<line x1="{x_low:.1f}" y1="{row_y:.1f}" x2="{x_high:.1f}" '
                f'y2="{row_y:.1f}" stroke="{colour}" stroke-width="2.5" '
                f'stroke-linecap="round" opacity="0.6"/>'
            )
            for x_cap in (x_low, x_high):
                parts.append(
                    f'<line x1="{x_cap:.1f}" y1="{row_y - cap_height:.1f}" '
                    f'x2="{x_cap:.1f}" y2="{row_y + cap_height:.1f}" '
                    f'stroke="{colour}" stroke-width="2.5" stroke-linecap="round"/>'
                )

        parts.append(
            f'<circle cx="{x_end:.1f}" cy="{row_y:.1f}" r="5.2" '
            f'fill="{colour}" stroke="{CARD_BG}" stroke-width="2"/>'
        )

        parts.append(_text(label_x, row_y + 4.5, name, size=12.5,
                           fill=colour, weight="700"))
        if model:
            parts.append(_text(label_x, row_y + 17.5, model, size=11,
                               fill=INK_SOFT))
        parts.append(_text(rps_right, row_y + 4.5, rps_texts[position],
                           size=12.5, fill=INK, weight="700", anchor="end"))

        # The floating label behind the bar: how many times slower this
        # server is than the reference in the same chart.
        #
        # The label follows the bar, so it lands where the reader is already
        # looking rather than in a column of its own. The variable is named
        # apart from the left-hand column's position on purpose: reusing
        # that name put the row names in the gutter.
        if factor is not None:
            factor_text = _fmt_factor(factor)
            # A factor of one says nothing: the bar is level with the
            # reference, and the label would be a word spent on saying so.
            # The reference row itself is always skipped for the same
            # reason - it is the yardstick, not a measurement against one.
            if factor_text not in ("", "1.0"):
                mark_x = x_end
                if high is not None:
                    mark_x = max(mark_x, to_x(high))
                factor_x = mark_x + 9.0
                # The factor is an annotation rather than a datum, so it is
                # drawn in the faded slate of the scale. The bar carries the
                # claim; the factor annotates it.
                parts.append(_text(factor_x, row_y + 4.5, f"x{factor_text}",
                                   size=12.5, fill=FACTOR_INK))

    parts.append(_chart_close())
    return "".join(parts)


def _wrap(text: str, max_width: float, size: float) -> list[str]:
    """Break a sentence into lines the card can hold.

    A single ``<text>`` element does not wrap, so an unwrapped note is silently
    clipped at the card edge ? the sentence just stops. Breaking on spaces at
    a measured width is the only way a note stays readable.
    """
    words = str(text).split()
    if not words:
        return []
    lines: list[str] = []
    current = words[0]
    for word in words[1:]:
        candidate = current + " " + word
        if _approx_text_width(candidate, size) <= max_width:
            current = candidate
        else:
            lines.append(current)
            current = word
    lines.append(current)
    return lines


def write(path, svg: str) -> None:
    """Write a chart to disk, UTF-8, with a trailing newline."""
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(svg)
        handle.write("\n")


if __name__ == "__main__":  # pragma: no cover - a smoke test
    demo = grouped_bars(
        categories=["c=1", "c=4", "c=8", "c=16", "c=32"],
        series={
            "volucer": [3268, 12970, 23278, 34394, 36008],
            "roadrunner": [2999, 11143, 19730, 33462, 35513],
            "fpm": [1823, 6504, 11638, 18365, 17960],
        },
        colors={"volucer": "#2563eb", "roadrunner": "#0d9488", "fpm": "#94a3b8"},
        labels={
            "volucer": "volucer (worker, warm)",
            "roadrunner": "RoadRunner (worker, warm)",
            "fpm": "nginx + php-fpm (cold)",
        },
        title="Throughput — requests per second",
        value_suffix="rps",
    )
    print(demo[:400])
