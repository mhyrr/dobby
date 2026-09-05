defmodule Dobby.Tools.History do
  @moduledoc """
  Past-tense questions share one deterministic query with the house's other
  callers. The language layer extracts filters and calendar words; the query
  owns dates, counts, and the limits of what its evidence can establish.
  """

  use Jido.Action,
    name: "history",
    description:
      "Read Dobby's recorded history, including removed devices. Code resolves dates and counts records. Choose kind(s) to avoid counting a command and its echo twice. Pass calendar words unchanged; never calculate dates or durations. No entries does not prove nothing happened. Duration is unknown without continuous observation coverage.",
    schema: [
      device: [type: :string, doc: "Exact device id, including a former device"],
      action: [
        type: :string,
        doc:
          "Exact recorded action: tool_call uses the full tool name; control/schedule_fired use the device action; device_changed uses state_changed. Omit when unsure."
      ],
      actor: [type: :string, doc: "Exact recorded actor; unknown attribution stays unknown"],
      kind: [
        type: :string,
        doc:
          "request, tool_call, control, device_changed, schedule_fired, command_refused, command_never_arrived, rule_breached, rule_resolved, rule_acknowledged, rule_saved, rule_confirmed, rule_paused, rule_resumed, rule_deleted"
      ],
      kinds: [
        type: {:list, :string},
        doc:
          "Several kinds; for failed confirmations use command_refused and command_never_arrived"
      ],
      period: [
        type: :string,
        doc: "today (default), yesterday, this_week, last_week, last_night (18:00–06:00), weekday"
      ],
      weekday: [
        type: :integer,
        doc: "For period weekday: 1 Monday to 7 Sunday, most recent including today"
      ],
      since: [
        type: :string,
        doc:
          "Explicit ISO 8601 instant with offset, only when user supplies a date; exclusive of period"
      ],
      until: [type: :string, doc: "Exclusive end instant with offset; defaults now"],
      mode: [
        type: :string,
        doc:
          "events, count, latest (defaults all recorded history), duration (reports unknown coverage)"
      ],
      limit: [
        type: :integer,
        doc: "Evidence rows 1–100, default 50; count always covers full window"
      ]
    ]

  @behaviour Dobby.Tools
  @impl Dobby.Tools
  def label(_), do: "reading the house's record"
  @impl true
  def run(params, _context), do: Dobby.History.query(params)
end
