module WeatherHelper
  def weather_stat_card(label, value, caption)
    tag.div(class: "border-2 border-dotted border-sky-200/35 bg-sky-950/25 p-4") do
      safe_join([
        tag.p(label, class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-sky-100"),
        tag.strong(number_with_delimiter(value.to_i), class: "mt-2 block font-mono text-3xl font-black tracking-[-0.06em] text-white"),
        tag.span(caption, class: "mt-1 block font-mono text-xs uppercase tracking-[0.08em] text-sky-50/70")
      ])
    end
  end

  def weather_accuracy_card(label, value, caption, tone: "cyan")
    tones = {
      "cyan" => "border-cyan-200/35 bg-cyan-950/25 text-cyan-100",
      "green" => "border-emerald-200/45 bg-emerald-950/25 text-emerald-100",
      "pink" => "border-fuchsia-200/40 bg-fuchsia-950/25 text-fuchsia-100",
      "yellow" => "border-yellow-200/45 bg-yellow-950/25 text-yellow-100"
    }
    tag.div(class: "border-2 border-dotted #{tones.fetch(tone, tones['cyan'])} p-4") do
      safe_join([
        tag.p(label, class: "font-mono text-xs font-black uppercase tracking-[0.14em]"),
        tag.strong(value.to_s.presence || "n/a", class: "mt-2 block font-mono text-3xl font-black tracking-[-0.06em] text-white"),
        tag.span(caption, class: "mt-1 block text-sm leading-5 text-white/70")
      ])
    end
  end

  def weather_trading_kpi_strip(summary, performance, live_dashboard)
    summary = summary.to_h
    performance = performance.to_h
    live_dashboard = live_dashboard.to_h
    bankroll = live_dashboard[:bankroll].to_h.presence || performance[:bankroll].to_h
    today_profit = live_dashboard[:today_live_profit].to_f
    overall_profit = live_dashboard[:overall_live_profit].to_f
    source_label = live_dashboard[:position_source].to_s == "live_orders" ? "live" : "paper"

    tag.div(class: "grid gap-3 md:grid-cols-2 xl:grid-cols-6") do
      safe_join([
        weather_trading_kpi_card("open wagers", number_with_delimiter(live_dashboard[:open_contracts].to_i), "#{number_with_delimiter(live_dashboard[:open_positions].to_a.length)} #{source_label} outcome rows", tone: "emerald"),
        weather_trading_kpi_card("open exposure", number_to_currency(live_dashboard[:open_stake].to_f), "open cost // today left #{number_to_currency(bankroll[:reserve_balance].to_f)}", tone: "cyan"),
        weather_trading_kpi_card("today P/L", number_to_currency(today_profit), "settled + open mark", tone: weather_money_tone(today_profit)),
        weather_trading_kpi_card("overall P/L", number_to_currency(overall_profit), "post-reset tracker only", tone: weather_money_tone(overall_profit)),
        weather_trading_kpi_card("daily budget", number_to_currency(bankroll[:daily_budget].to_f), "today left #{number_to_currency(bankroll[:reserve_balance].to_f)} // no rollover", tone: "yellow"),
        weather_trading_kpi_card("weather feed", number_with_delimiter(summary[:actionable].to_i), "#{number_with_delimiter(summary[:alerts].to_i)} alerts // #{number_with_delimiter(summary[:forecasts].to_i)} forecasts", tone: "violet")
      ])
    end
  end

  def weather_trading_kpi_card(label, value, caption, tone: "cyan")
    tones = {
      "cyan" => "border-cyan-200/35 bg-cyan-950/20 text-cyan-100",
      "emerald" => "border-emerald-200/40 bg-emerald-950/20 text-emerald-100",
      "rose" => "border-teal-200/45 bg-teal-950/25 text-teal-100",
      "yellow" => "border-yellow-200/45 bg-yellow-950/20 text-yellow-100",
      "violet" => "border-violet-200/35 bg-violet-950/20 text-violet-100",
      "zinc" => "border-white/20 bg-zinc-950 text-zinc-100"
    }

    tag.div(class: "border-2 border-dotted #{tones.fetch(tone, tones['cyan'])} p-4") do
      safe_join([
        tag.p(label, class: "font-mono text-[10px] font-black uppercase tracking-[0.16em] opacity-80"),
        tag.strong(value, class: "mt-2 block font-mono text-2xl font-black tracking-[-0.05em] text-white md:text-3xl"),
        tag.span(caption, class: "mt-1 block font-mono text-[10px] uppercase leading-4 tracking-[0.08em] text-white/62")
      ])
    end
  end

  def weather_command_metric(label, value, caption, tone: "cyan")
    tones = {
      "cyan" => "border-cyan-200/35 bg-cyan-950/20 text-cyan-100",
      "emerald" => "border-emerald-200/40 bg-emerald-950/20 text-emerald-100",
      "rose" => "border-teal-200/45 bg-teal-950/25 text-teal-100",
      "yellow" => "border-yellow-200/45 bg-yellow-950/20 text-yellow-100",
      "zinc" => "border-white/20 bg-zinc-950 text-zinc-100"
    }

    tag.div(class: "border border-dotted #{tones.fetch(tone, tones['cyan'])} bg-black/35 p-3") do
      safe_join([
        tag.p(label, class: "font-mono text-[10px] font-black uppercase tracking-[0.14em] opacity-80"),
        tag.strong(value, class: "mt-2 block font-mono text-2xl font-black tracking-[-0.04em] text-white"),
        tag.span(caption, class: "mt-1 block font-mono text-[10px] uppercase leading-4 tracking-[0.08em] text-white/60")
      ])
    end
  end

  def weather_strategy_health_panel(summary)
    summary = summary.to_h
    guard = summary[:guard].to_h
    live = summary[:live].to_h
    paper = summary[:paper].to_h
    review_auto = summary[:review_auto].to_h
    guard_allowed = guard.fetch(:allowed, false)

    tag.section(class: "weather-panel weather-strategy-health") do
      safe_join([
        tag.div(class: "weather-section-header") do
          safe_join([
            tag.div do
              safe_join([
                tag.p("Portfolio diagnostics", class: "weather-eyebrow"),
                tag.h2("Strategy health", class: "weather-panel-title")
              ])
            end,
            tag.span(
              guard_allowed ? "Automatic entries available" : "Automatic entries paused",
              class: "weather-status-chip #{guard_allowed ? 'is-safe' : 'is-paused'}"
            )
          ])
        end,
        tag.div(class: "weather-health-grid") do
          safe_join([
            weather_health_metric("Live realized ROI", live[:realized_roi].present? ? number_to_percentage(live[:realized_roi], precision: 1) : "n/a", "#{number_with_delimiter(live[:decided].to_i)} settled", tone: weather_value_tone(live[:realized_roi])),
            weather_health_metric("Live realized P/L", number_to_currency(live[:realized_profit].to_f), "fees included", tone: weather_value_tone(live[:realized_profit])),
            weather_health_metric("Live hit rate", live[:hit_rate].present? ? number_to_percentage(live[:hit_rate], precision: 1) : "n/a", "#{number_with_delimiter(live[:wins].to_i)} wins / #{number_with_delimiter(live[:losses].to_i)} losses", tone: "neutral"),
            weather_health_metric("Calibration gap", paper[:calibration_gap].present? ? "#{paper[:calibration_gap].positive? ? '+' : ''}#{paper[:calibration_gap]} pt" : "n/a", "#{paper[:average_confidence] || 'n/a'}% model vs #{paper[:hit_rate] || 'n/a'}% actual", tone: paper[:calibration_gap].to_f > 10 ? "negative" : "neutral"),
            weather_health_metric("Loss streak", guard[:consecutive_losses].present? ? number_with_delimiter(guard[:consecutive_losses]) : "n/a", "pause threshold #{guard[:max_consecutive_losses] || 'n/a'}", tone: guard_allowed ? "neutral" : "negative"),
            weather_health_metric("Review-auto cohort", review_auto[:realized_roi].present? ? number_to_percentage(review_auto[:realized_roi], precision: 1) : "n/a", "#{number_with_delimiter(review_auto[:decided].to_i)} settled", tone: weather_value_tone(review_auto[:realized_roi]))
          ])
        end,
        tag.p(guard[:reason].presence || "Portfolio safety status unavailable.", class: "weather-guard-reason")
      ])
    end
  end

  def weather_health_metric(label, value, caption, tone: "neutral")
    tag.div(class: "weather-health-metric is-#{tone}") do
      safe_join([
        tag.span(label),
        tag.strong(value),
        tag.small(caption)
      ])
    end
  end

  def weather_calibration_harness_panel(summary, paper_strategies)
    summary = summary.to_h
    walk = summary[:walk_forward].to_h
    gate = summary[:live_gate].to_h
    calibrated = walk[:calibrated].to_h
    market = walk[:market].to_h
    challenger = walk[:challenger].to_h
    active = walk[:active_shadow].to_h
    prospective = summary[:prospective_active_shadow].to_h
    gate_clear = gate[:clear] == true

    tag.section(class: "weather-panel border-cyan-200/35 bg-cyan-950/10") do
      safe_join([
        tag.div(class: "weather-section-header") do
          safe_join([
            tag.div do
              safe_join([
                tag.p("AUTOS calibration harness", class: "weather-eyebrow"),
                tag.h2("Paper beside live", class: "weather-panel-title"),
                tag.p("Immutable snapshots, chronological walk-forward tests, market-price baseline, and fee-correct $5 tickets. Qwen may explain outcomes; it cannot promote or place a trade.", class: "mt-2 max-w-4xl text-sm leading-5 text-white/66")
              ])
            end,
            tag.span(gate_clear ? "Live gate clear" : "Live gate blocked", class: "weather-status-chip #{gate_clear ? 'is-safe' : 'is-paused'}")
          ])
        end,
        tag.div(class: "weather-health-grid") do
          safe_join([
            weather_health_metric("Immutable training", number_with_delimiter(summary[:training_events].to_i), "#{number_with_delimiter(summary[:training_dates].to_i)} independent dates", tone: "neutral"),
            weather_health_metric("Walk-forward sample", number_with_delimiter(walk[:events].to_i), "#{number_with_delimiter(walk[:dates].to_i)} held-forward dates", tone: "neutral"),
            weather_health_metric("Calibrated Brier", calibrated[:brier].present? ? number_with_precision(calibrated[:brier], precision: 4) : "n/a", "lower is better", tone: "neutral"),
            weather_health_metric("Market Brier", market[:brier].present? ? number_with_precision(market[:brier], precision: 4) : "n/a", "must be beaten out of sample", tone: "neutral"),
            weather_health_metric("Paper challenger", challenger[:roi_percent].present? ? number_to_percentage(challenger[:roi_percent], precision: 1) : "n/a", "#{number_with_delimiter(challenger[:trades].to_i)} walk-forward trades", tone: weather_value_tone(challenger[:profit])),
            weather_health_metric("Active backtest", active[:roi_percent].present? ? number_to_percentage(active[:roi_percent], precision: 1) : "n/a", "#{number_with_delimiter(active[:trades].to_i)} walk-forward days", tone: weather_value_tone(active[:profit])),
            weather_health_metric("Prospective shadow", prospective[:roi_percent].present? ? number_to_percentage(prospective[:roi_percent], precision: 1) : "n/a", "#{number_with_delimiter(prospective[:trades].to_i)} settled $5 paper days", tone: weather_value_tone(prospective[:profit]))
          ])
        end,
        tag.div(class: "mt-4 grid gap-3 lg:grid-cols-[1.15fr_0.85fr]") do
          safe_join([
            tag.div(class: "border border-dotted border-cyan-200/20 bg-black/35 p-4") do
              safe_join([
                tag.strong("Why live remains blocked", class: "font-mono text-xs uppercase tracking-[0.12em] text-cyan-100"),
                tag.ul(class: "mt-3 space-y-2 text-sm leading-5 text-white/68") do
                  safe_join(Array(gate[:reasons]).first(6).map { |reason| tag.li("• #{reason}") })
                end,
                tag.p("Promotion always requires a manual decision even after every statistical gate clears.", class: "mt-3 font-mono text-[10px] uppercase tracking-[0.08em] text-zinc-500")
              ])
            end,
            weather_paper_strategy_cards(paper_strategies)
          ])
        end
      ])
    end
  end

  def weather_paper_strategy_cards(rows)
    rows = Array(rows)
    return tag.div("Paper strategies will appear after the next weather tick.", class: "border border-dotted border-yellow-200/20 bg-black/35 p-4 text-sm text-white/60") if rows.blank?

    tag.div(class: "space-y-2") do
      safe_join(rows.map do |row|
        tag.div(class: "border border-dotted border-yellow-200/20 bg-black/35 p-3 font-mono text-xs uppercase tracking-[0.06em]") do
          safe_join([
            tag.div(class: "flex items-center justify-between gap-3") do
              safe_join([
                tag.strong(row[:label].to_s, class: "text-yellow-100"),
                tag.span("#{number_with_delimiter(row[:open].to_i)} open", class: "text-cyan-100")
              ])
            end,
            tag.p("#{number_with_delimiter(row[:decided].to_i)} settled // #{number_with_delimiter(row[:wins].to_i)}W #{number_with_delimiter(row[:losses].to_i)}L // #{row[:roi_percent].present? ? number_to_percentage(row[:roi_percent], precision: 1) : 'ROI n/a'}", class: "mt-2 text-white/62"),
            tag.p(row[:strategy_version].presence || "strategy version pending", class: "mt-1 text-[10px] text-zinc-500")
          ])
        end
      end)
    end
  end

  def weather_value_tone(value)
    return "neutral" if value.blank? || value.to_f.zero?

    value.to_f.positive? ? "positive" : "negative"
  end

  def weather_win_celebration(live_dashboard)
    live_dashboard = live_dashboard.to_h
    return nil unless live_dashboard[:position_source].to_s == "live_orders"

    closed_rows = Array(live_dashboard[:recent_closed]).map { |row| row.to_h.symbolize_keys }
    today = Time.zone.today
    winning_row = closed_rows.find { |row| row[:result].to_s == "won" && weather_date_value(row[:date]) == today }
    winning_row ||= closed_rows.find { |row| row[:result].to_s == "won" } if live_dashboard[:today_settled_profit].to_f.positive?
    return nil if winning_row.blank?

    city = [winning_row[:city], winning_row[:state]].compact_blank.join(", ").presence || "Weather"
    outcome = winning_row[:outcome].to_s.presence || "daily high"
    profit = winning_row[:profit].to_f
    contracts = winning_row[:contracts].to_i

    {
      headline: "#{city} cashed",
      detail: "#{outcome} settled as a win#{profit.nonzero? ? " with #{number_to_currency(profit)} realized P/L after fees" : ""}.",
      profit: profit.nonzero? ? number_to_currency(profit) : "win posted",
      contracts: contracts.positive? ? "#{number_with_delimiter(contracts)} contracts" : "settled win"
    }
  end

  def weather_timer_metric(label, value, caption: nil, empty: "waiting", tone: "yellow")
    display = value.present? ? weather_timeout_tag(value, compact: true) : tag.span(empty, class: "text-zinc-500")
    weather_command_metric(label, display, caption.presence || empty, tone: tone)
  end

  def weather_status_metric(label, value, value_class: "text-white", caption: nil)
    tag.div(class: "border border-dotted border-white/15 bg-black/35 px-3 py-2 font-mono text-[10px] uppercase tracking-[0.1em]") do
      safe_join([
        tag.span(label, class: "block text-zinc-500"),
        tag.strong(value, class: "mt-1 block text-sm #{value_class}"),
        (tag.span(caption, class: "mt-1 block text-zinc-500") if caption.present?)
      ].compact)
    end
  end

  def weather_live_pnl_panel(performance, live_dashboard)
    performance = performance.to_h
    live_dashboard = live_dashboard.to_h
    bankroll = live_dashboard[:bankroll].to_h.presence || performance[:bankroll].to_h
    today_profit = live_dashboard[:today_live_profit].to_f
    overall_profit = live_dashboard[:overall_live_profit].to_f
    source_label = live_dashboard[:position_source].to_s == "live_orders" ? "Actual Kalshi order tracker" : "Post-reset paper tracker"

    tag.div(class: "border-2 border-dotted border-emerald-200/35 bg-emerald-950/10 p-4") do
      safe_join([
        tag.div(class: "flex flex-wrap items-start justify-between gap-3") do
          safe_join([
            tag.div do
              safe_join([
                tag.p("weather P/L", class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-emerald-100"),
                tag.p("#{source_label}: #{number_to_currency(bankroll[:daily_budget].to_f)} is available each day, with no rollover. The buy journal is the source of truth for actual tickets.", class: "mt-1 text-sm leading-5 text-white/66")
              ])
            end,
            tag.div(class: "grid gap-2 font-mono text-xs uppercase tracking-[0.08em] sm:grid-cols-3") do
              safe_join([
                tag.div(class: "border border-dotted border-emerald-200/25 bg-black/40 px-4 py-3") do
                  safe_join([
                    tag.span("today", class: "block text-emerald-100/70"),
                    tag.strong(number_to_currency(today_profit), class: "mt-1 block text-2xl #{weather_money_class(today_profit)}")
                  ])
                end,
                tag.div(class: "border border-dotted border-white/15 bg-black/40 px-4 py-3") do
                  safe_join([
                    tag.span("overall", class: "block text-white/55"),
                    tag.strong(number_to_currency(overall_profit), class: "mt-1 block text-2xl #{weather_money_class(overall_profit)}")
                  ])
                end,
                tag.div(class: "border border-dotted border-cyan-200/20 bg-black/40 px-4 py-3") do
                  safe_join([
                    tag.span("today left", class: "block text-cyan-100/65"),
                    tag.strong(number_to_currency(bankroll[:reserve_balance].to_f), class: "mt-1 block text-2xl text-cyan-100")
                  ])
                end
              ])
            end
          ])
        end,
        weather_live_pnl_chart(performance, live_dashboard)
      ])
    end
  end

  def weather_live_pnl_chart(performance, live_dashboard)
    performance = performance.to_h
    live_dashboard = live_dashboard.to_h

    today = Time.zone.today
    live_orders = live_dashboard[:position_source].to_s == "live_orders"
    source_rows = live_orders ? live_dashboard[:daily] : performance[:daily]
    rows = Array(source_rows).map { |row| row.to_h.symbolize_keys }.last(29)
    today_index = rows.index { |row| row[:date] == today }
    live_today_row = {
      date: today,
      daily_profit: live_dashboard[:today_live_profit].to_f.round(2),
      cumulative_profit: live_dashboard[:overall_live_profit].to_f.round(2),
      stake: live_dashboard[:open_stake].to_f.round(2),
      count: live_dashboard[:open_contracts].to_i
    }
    if today_index
      rows[today_index] = rows[today_index].merge(live_today_row)
    else
      rows << live_today_row
    end
    rows = rows.last(30)

    width = 920.0
    height = 330.0
    left = 70.0
    right = 34.0
    top = 34.0
    bottom = 56.0
    plot_width = width - left - right
    plot_height = height - top - bottom
    values = rows.flat_map { |row| [row[:daily_profit].to_f, row[:cumulative_profit].to_f] } + [0.0]
    min_value = (values.min * 1.18).floor
    max_value = (values.max * 1.18).ceil
    min_value = -1 if min_value.zero? && max_value.zero?
    max_value = 1 if min_value == max_value
    span = [max_value - min_value, 1].max
    x_for = lambda do |index|
      return left + (plot_width / 2.0) if rows.length == 1

      left + ((plot_width / (rows.length - 1)) * index)
    end
    y_for = lambda do |value|
      top + ((max_value - value.to_f) / span * plot_height)
    end
    zero_y = y_for.call(0)
    daily_points = rows.each_with_index.map { |row, index| { x: x_for.call(index), y: y_for.call(row[:daily_profit]), row: row } }
    overall_points = rows.each_with_index.map { |row, index| { x: x_for.call(index), y: y_for.call(row[:cumulative_profit]), row: row } }
    daily_path = weather_svg_curve_path(daily_points)
    overall_path = weather_svg_curve_path(overall_points)
    grid_values = (0..4).map { |index| max_value - ((span / 4.0) * index) }.map { |value| value.round(2) }.uniq
    grid = grid_values.map do |value|
      y = y_for.call(value)
      safe_join([
        tag.line(x1: left, y1: y, x2: width - right, y2: y, stroke: "rgba(255,255,255,0.12)", "stroke-dasharray": "2 8"),
        tag.text(number_to_currency(value, precision: value.abs < 10 ? 2 : 0), x: 12, y: y + 4, fill: "rgba(255,255,255,0.58)", "font-size": 10, "font-family": "monospace")
      ])
    end
    dots = daily_points.map do |point|
      value = point[:row][:daily_profit].to_f
      color = value.negative? ? "#5eead4" : value.positive? ? "#34d399" : "#a1a1aa"
      tag.g do
        safe_join([
          tag.circle(cx: point[:x], cy: point[:y], r: 5, fill: color, stroke: "rgba(0,0,0,0.75)", "stroke-width": 2),
          tag.title("#{point[:row][:date]&.strftime('%b %-d') || 'day'} daily #{number_to_currency(value)} // overall #{number_to_currency(point[:row][:cumulative_profit].to_f)}")
        ])
      end
    end
    label_step = [(rows.length / 6.0).ceil, 1].max
    date_labels = rows.each_with_index.filter_map do |row, index|
      next unless index.zero? || index == rows.length - 1 || (index % label_step).zero?

      tag.text(row[:date]&.strftime("%m/%d") || "day", x: x_for.call(index), y: height - 22, fill: "rgba(255,255,255,0.48)", "font-size": 10, "font-family": "monospace", "text-anchor": "middle")
    end

    tag.div(class: "mt-4 border border-dotted border-emerald-200/20 bg-black/45 p-3") do
      safe_join([
        tag.div(class: "mb-2 flex flex-wrap items-center justify-between gap-3 font-mono text-xs uppercase tracking-[0.08em]") do
          safe_join([
            tag.span("today line + overall background line", class: "text-emerald-100"),
            tag.span(class: "flex flex-wrap gap-3 text-zinc-300") do
              safe_join([
                weather_chart_key("daily/today P/L", "green"),
                weather_chart_key("overall P/L", "cyan"),
                weather_chart_key("zero", "axis")
              ])
            end
          ])
        end,
        tag.svg(viewBox: "0 0 #{width.to_i} #{height.to_i}", class: "h-auto w-full", role: "img", "aria-label": "Live weather paper profit and loss chart") do
          safe_join([
            tag.rect(x: left, y: top, width: plot_width, height: plot_height, rx: 8, fill: "rgba(6,78,59,0.12)", stroke: "rgba(52,211,153,0.18)"),
            safe_join(grid),
            tag.line(x1: left, y1: zero_y, x2: width - right, y2: zero_y, stroke: "rgba(255,255,255,0.30)", "stroke-width": 1.5),
            (tag.path(d: overall_path, fill: "none", stroke: "rgba(34,211,238,0.18)", "stroke-width": 14, "stroke-linecap": "round", "stroke-linejoin": "round") if overall_path.present?),
            (tag.path(d: overall_path, fill: "none", stroke: "rgba(34,211,238,0.62)", "stroke-width": 3, "stroke-linecap": "round", "stroke-linejoin": "round", "stroke-dasharray": "6 8") if overall_path.present?),
            (tag.path(d: daily_path, fill: "none", stroke: "rgba(52,211,153,0.22)", "stroke-width": 12, "stroke-linecap": "round", "stroke-linejoin": "round") if daily_path.present?),
            (tag.path(d: daily_path, fill: "none", stroke: "#34d399", "stroke-width": 4.5, "stroke-linecap": "round", "stroke-linejoin": "round") if daily_path.present?),
            safe_join(dots),
            weather_chart_endpoint_label("today #{number_to_currency(live_dashboard[:today_live_profit].to_f)}", daily_points.last, "#34d399", -26, width, right),
            weather_chart_endpoint_label("overall #{number_to_currency(live_dashboard[:overall_live_profit].to_f)}", overall_points.last, "#67e8f9", 10, width, right),
            safe_join(date_labels),
            tag.text(live_orders ? "actual ticket dollars" : "paper dollars", x: left, y: 18, fill: "rgba(255,255,255,0.62)", "font-size": 11, "font-family": "monospace"),
            tag.text("settlement / live-mark day", x: left + (plot_width / 2.0), y: height - 2, fill: "rgba(255,255,255,0.46)", "font-size": 10, "font-family": "monospace", "text-anchor": "middle")
          ].compact)
        end
      ])
    end
  end

  def weather_open_positions_panel(live_dashboard, compact: false)
    live_dashboard = live_dashboard.to_h
    positions = Array(live_dashboard[:open_positions])
    exposure = Array(live_dashboard[:outcome_exposure])
    live_orders = live_dashboard[:position_source].to_s == "live_orders"
    source_label = live_orders ? "actual live Kalshi orders" : "open paper wagers"
    empty_message = live_orders ? "No open live Kalshi orders right now. Closed tickets still count in the buy journal and P/L." : nil

    tag.div(class: "border-2 border-dotted border-cyan-200/35 bg-cyan-950/10 p-4 #{compact ? 'h-full' : ''}") do
      safe_join([
        tag.div(class: "flex flex-wrap items-start justify-between gap-3") do
          safe_join([
            tag.div do
              safe_join([
                tag.p("open outcome exposure", class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-cyan-100"),
                tag.p(compact ? source_label.to_s : "Every #{source_label} grouped by outcome, with contract count, cost, live mark, and close countdown.", class: "mt-1 text-sm leading-5 text-white/66")
              ])
            end,
            tag.div(class: "border border-dotted border-cyan-200/25 bg-black/40 px-4 py-3 font-mono text-xs uppercase tracking-[0.08em] text-cyan-100") do
              safe_join([
                tag.span("refreshed", class: "block text-cyan-100/65"),
                tag.strong(live_dashboard[:refreshed_at] ? "#{time_ago_in_words(live_dashboard[:refreshed_at])} ago" : "now", class: "mt-1 block text-white")
              ])
            end
          ])
        end,
        weather_outcome_exposure_cards(exposure, limit: compact ? 4 : 12, compact: compact, empty_message: empty_message),
        (weather_position_table(positions) unless compact)
      ])
    end
  end

  def weather_buy_journal_panel(wagers, autopilot_status = {}, compact: false)
    rows = Array(wagers)
    status = autopilot_status.to_h
    live_enabled = status[:execution_allowed] == true
    remaining = status[:remaining_today].to_f

    tag.div(class: "border-2 border-dotted border-yellow-200/35 bg-yellow-950/10 p-4 #{compact ? 'h-full' : ''}") do
      safe_join([
        tag.div(class: "flex flex-wrap items-start justify-between gap-3") do
          safe_join([
            tag.div do
              safe_join([
                tag.p("autopilot buy journal", class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-yellow-100"),
                tag.p(compact ? "Latest live and paper tickets with the $5 risk ceiling." : "Complete wager ledger. Live and paper are isolated strategy lanes; every displayed risk includes the rounded fee estimate or actual fee.", class: "mt-1 text-sm leading-5 text-white/66")
              ])
            end,
            tag.div(class: "grid gap-2 font-mono text-xs uppercase tracking-[0.08em] #{compact ? 'grid-cols-3' : 'sm:grid-cols-3'}") do
              safe_join([
                weather_buy_journal_metric("live gate", live_enabled ? "enabled" : "blocked", live_enabled ? "text-emerald-100" : "text-yellow-100"),
                weather_buy_journal_metric("today left", number_to_currency(remaining), remaining.positive? ? "text-cyan-100" : "text-zinc-400"),
                weather_buy_journal_metric("qwen", status[:qwen_ready] ? "ready" : "waiting", status[:qwen_ready] ? "text-emerald-100" : "text-yellow-100")
              ])
            end
          ])
        end,
        compact ? weather_buy_journal_mini_list(rows) : weather_buy_journal_table(rows)
      ])
    end
  end

  def weather_buy_journal_metric(label, value, value_class = "text-white")
    tag.div(class: "border border-dotted border-yellow-200/25 bg-black/40 px-4 py-3") do
      safe_join([
        tag.span(label, class: "block text-yellow-100/65"),
        tag.strong(value, class: "mt-1 block text-lg #{value_class}")
      ])
    end
  end

  def weather_buy_journal_table(wagers)
    rows = Array(wagers)
    return tag.p("No buy journal rows yet. The calibration policies are waiting for a date-aligned, fee-adjusted paper opportunity.", class: "mt-4 font-mono text-xs uppercase tracking-[0.1em] text-zinc-500") if rows.blank?

    tag.div(class: "mt-4 max-h-[38rem] overflow-auto border border-dotted border-yellow-200/15") do
      tag.table(class: "min-w-full border-collapse font-mono text-xs uppercase tracking-[0.04em]") do
        safe_join([
          tag.thead(class: "sticky top-0 z-10 bg-zinc-950 text-yellow-100/75") do
            tag.tr(class: "border-b border-dotted border-yellow-200/20") do
              safe_join([
                tag.th("", class: "w-10 px-3 py-2 text-left"),
                tag.th("market", class: "px-3 py-2 text-left"),
                tag.th("mode", class: "px-3 py-2 text-left"),
                tag.th("strategy", class: "px-3 py-2 text-left"),
                tag.th("contracts", class: "px-3 py-2 text-right"),
                tag.th("cost", class: "px-3 py-2 text-right"),
                tag.th("P/L", class: "px-3 py-2 text-right"),
                tag.th("why", class: "px-3 py-2 text-left")
              ])
            end
          end,
          tag.tbody(class: "text-white/86") do
            safe_join(rows.map { |wager| weather_buy_journal_row(wager) })
          end
        ])
      end
    end
  end

  def weather_buy_journal_mini_list(wagers)
    rows = Array(wagers).first(8)
    return tag.p("No buy journal rows yet. Autopilot is watching for a clean edge.", class: "mt-4 font-mono text-xs uppercase tracking-[0.1em] text-zinc-500") if rows.blank?

    tag.div(class: "mt-4 space-y-2") do
      safe_join(rows.map do |wager|
        prediction = wager.kalshi_weather_prediction
        profit = wager.realized_profit
        city = [prediction&.city, prediction&.state].compact_blank.join(", ")
        display_status = weather_buy_journal_status(wager)
        symbol = wager.respond_to?(:result_symbol) ? wager.result_symbol : weather_buy_journal_symbol(display_status)
        symbol_class = case display_status
        when "won" then "text-emerald-300"
        when "lost" then "text-teal-300"
        when "error" then "text-orange-300"
        else
          "text-fuchsia-200"
        end

        tag.div(class: "grid grid-cols-[2rem_minmax(0,1fr)_auto] items-center gap-3 border border-dotted border-yellow-200/15 bg-black/35 px-3 py-2 font-mono text-xs") do
          safe_join([
            tag.strong(symbol, class: "text-lg #{symbol_class}"),
            tag.div(class: "min-w-0") do
              safe_join([
                tag.strong(city.presence || wager.market_ticker, class: "block truncate text-white"),
                tag.span("#{wager.execution_label} // #{display_status || wager.status} // #{prediction&.market_band_label || 'range pending'}", class: "mt-1 block truncate text-[10px] uppercase tracking-[0.1em] text-yellow-100/68")
              ])
            end,
            tag.div(class: "text-right") do
              safe_join([
                tag.strong(number_to_currency(weather_wager_total_risk(wager)), class: "block text-cyan-100"),
                tag.span(profit.present? ? number_to_currency(profit.to_f) : "#{number_with_delimiter(wager.contracts.to_i)}x", class: "mt-1 block #{profit.present? ? weather_money_class(profit.to_f) : 'text-zinc-300'}")
              ])
            end
          ])
        end
      end)
    end
  end

  def weather_buy_journal_row(wager)
    prediction = wager.kalshi_weather_prediction
    profit = wager.realized_profit
    city = [prediction&.city, prediction&.state].compact_blank.join(", ")
    display_status = weather_buy_journal_status(wager)
    symbol = wager.respond_to?(:result_symbol) ? wager.result_symbol : weather_buy_journal_symbol(display_status)
    symbol_class = case display_status
    when "won" then "text-emerald-300"
    when "lost" then "text-teal-300"
    when "error" then "text-orange-300"
    else
      "text-fuchsia-200"
    end

    tag.tr(class: "border-b border-dotted border-white/10") do
      safe_join([
        tag.td(tag.strong(symbol, class: "text-lg #{symbol_class}"), class: "px-3 py-3"),
        tag.td(class: "max-w-96 px-3 py-3 normal-case tracking-normal") do
          safe_join([
            tag.strong(city.presence || wager.market_ticker, class: "block truncate text-white"),
            tag.span("#{wager.market_ticker} // #{prediction&.market_band_label || 'range pending'}", class: "mt-1 block truncate font-mono text-[10px] uppercase tracking-[0.1em] text-yellow-100/70")
          ])
        end,
        tag.td("#{wager.execution_label} // #{display_status || wager.status}", class: "px-3 py-3 text-yellow-100"),
        tag.td(class: "px-3 py-3 text-zinc-300") do
          safe_join([
            tag.span(wager.strategy_key.to_s.tr("_", " "), class: "block"),
            tag.span(wager.strategy_version.to_s.presence || "legacy", class: "mt-1 block text-[9px] text-zinc-500")
          ])
        end,
        tag.td(number_with_delimiter(wager.contracts.to_i), class: "px-3 py-3 text-right text-zinc-200"),
        tag.td("#{weather_price_cents(wager.price)} / #{number_to_currency(weather_wager_total_risk(wager))}", class: "px-3 py-3 text-right text-cyan-100"),
        tag.td(profit.present? ? number_to_currency(profit.to_f) : "pending", class: "px-3 py-3 text-right #{profit.present? ? weather_money_class(profit.to_f) : 'text-fuchsia-100'}"),
        tag.td(wager.reason.to_s.truncate(92), class: "max-w-96 px-3 py-3 normal-case tracking-normal text-zinc-300")
      ])
    end
  end

  def weather_buy_journal_symbol(status)
    case status.to_s
    when "won" then "+"
    when "lost" then "-"
    when "pushed", "void" then "0"
    else
      "🪄"
    end
  end

  def weather_wager_total_risk(wager)
    metadata = wager.metadata.to_h
    metadata["total_risk"].presence&.to_f || begin
      fee = metadata["live_fees_paid"].presence || metadata["account_settlement_fee_dollars"].presence || metadata["estimated_taker_fee"].presence
      (wager.max_cost.to_f + fee.to_f).round(2)
    end
  end

  def weather_buy_journal_status(wager)
    if wager.respond_to?(:display_result_status) && wager.display_result_status.present?
      wager.display_result_status
    else
      wager.status
    end
  end

  def weather_outcome_exposure_cards(exposure, limit: 12, compact: false, empty_message: nil)
    rows = Array(exposure).first(limit)
    return tag.p(empty_message.presence || "No open paper wagers right now. AUTOS is still watching live Kalshi weather markets.", class: "mt-4 font-mono text-xs uppercase tracking-[0.1em] text-zinc-500") if rows.blank?

    tag.div(class: "mt-4 grid gap-3 #{compact ? 'md:grid-cols-2' : 'md:grid-cols-2 xl:grid-cols-4'}") do
      safe_join(rows.map do |row|
        city = [row[:city], row[:state]].compact_blank.join(", ")
        pnl = row[:unrealized_profit].to_f
        tag.article(class: "border border-dotted #{pnl.negative? ? 'border-teal-200/40 bg-teal-950/10' : 'border-emerald-200/35 bg-black/35'} p-3") do
          safe_join([
            tag.div(class: "flex items-start justify-between gap-3") do
              safe_join([
                tag.div do
                  safe_join([
                    tag.p(city.presence || "Weather market", class: "font-mono text-xs font-black uppercase tracking-[0.08em] text-white"),
                    tag.p("#{row[:side]} // #{row[:outcome]}", class: "mt-1 font-mono text-[10px] uppercase leading-4 tracking-[0.1em] text-cyan-100/78")
                  ])
                end,
                tag.strong("#{number_with_delimiter(row[:contracts].to_i)}x", class: "font-mono text-xl text-white")
              ])
            end,
            tag.div(class: "mt-3 grid grid-cols-2 gap-2 font-mono text-[10px] uppercase tracking-[0.08em]") do
              safe_join([
                weather_compact_market_metric("stake", number_to_currency(row[:stake].to_f)),
                weather_compact_market_metric("live P/L", number_to_currency(pnl), weather_money_class(pnl)),
                weather_compact_market_metric("closes", weather_timeout_tag(row[:next_close_at], compact: true), "text-yellow-100"),
                weather_compact_market_metric("rows", number_with_delimiter(row[:rows].to_i))
              ])
            end
          ])
        end
      end)
    end
  end

  def weather_position_table(positions)
    rows = Array(positions).first(18)
    return "".html_safe if rows.blank?

    tag.div(class: "mt-4 overflow-x-auto") do
      tag.table(class: "min-w-full border-collapse font-mono text-xs uppercase tracking-[0.04em]") do
        safe_join([
          tag.thead(class: "text-cyan-100/65") do
            tag.tr(class: "border-b border-dotted border-cyan-200/20") do
              safe_join([
                tag.th("outcome", class: "px-3 py-2 text-left"),
                tag.th("contracts", class: "px-3 py-2 text-right"),
                tag.th("entry / now", class: "px-3 py-2 text-right"),
                tag.th("stake", class: "px-3 py-2 text-right"),
                tag.th("live P/L", class: "px-3 py-2 text-right"),
                tag.th("AUTOS", class: "px-3 py-2 text-right"),
                tag.th("timeout", class: "px-3 py-2 text-right")
              ])
            end
          end,
          tag.tbody(class: "text-white/86") do
            safe_join(rows.map do |row|
              pnl = row[:unrealized_profit].to_f
              city = [row[:city], row[:state]].compact_blank.join(", ")
              tag.tr(class: "border-b border-dotted border-white/10") do
                safe_join([
                  tag.td(class: "max-w-96 px-3 py-3 normal-case tracking-normal") do
                    safe_join([
                      tag.strong(city.presence || row[:market_ticker], class: "block truncate text-white"),
                      tag.span("#{row[:side]} // #{row[:outcome]}", class: "mt-1 block truncate font-mono text-[10px] uppercase tracking-[0.1em] text-cyan-100/72")
                    ])
                  end,
                  tag.td("#{number_with_delimiter(row[:contracts].to_i)} contracts", class: "px-3 py-3 text-right text-emerald-100"),
                  tag.td("#{weather_price_cents(row[:entry_price])} / #{weather_price_cents(row[:current_price])}", class: "px-3 py-3 text-right text-yellow-100"),
                  tag.td(number_to_currency(row[:stake].to_f), class: "px-3 py-3 text-right text-zinc-200"),
                  tag.td(number_to_currency(pnl), class: "px-3 py-3 text-right #{weather_money_class(pnl)}"),
                  tag.td(weather_autos_temperature_line(row), class: "px-3 py-3 text-right text-fuchsia-100"),
                  tag.td(weather_timeout_tag(row[:close_time]), class: "px-3 py-3 text-right text-yellow-100")
                ])
              end
            end)
          end
        ])
      end
    end
  end

  def weather_compact_market_metric(label, value, value_class = "text-white")
    tag.div(class: "border border-dotted border-white/10 bg-black/35 px-2 py-2") do
      safe_join([
        tag.span(label, class: "block text-zinc-500"),
        tag.strong(value, class: "mt-1 block #{value_class}")
      ])
    end
  end

  def weather_autos_temperature_line(row)
    forecast = row[:forecast_high_f].present? ? "#{row[:forecast_high_f]}F" : "n/a"
    adjusted = row[:adjusted_high_f].present? ? "#{row[:adjusted_high_f]}F" : "n/a"
    "#{forecast} -> #{adjusted}"
  end

  def weather_timeout_tag(value, compact: false)
    time = weather_time_value(value)
    return tag.span("no close", class: "text-zinc-500") if time.blank?

    classes = compact ? "text-yellow-100" : "text-yellow-100 whitespace-nowrap"
    tag.span(
      weather_timeout_label(time, compact: compact),
      class: classes,
      data: {
        weather_timeout_at: time.iso8601,
        weather_timeout_compact: compact ? "true" : "false"
      }
    )
  end

  def weather_timeout_label(value, compact: false)
    time = weather_time_value(value)
    return "no close" if time.blank?

    if time.future?
      distance = distance_of_time_in_words(Time.current, time)
      compact ? distance : "#{distance} left"
    else
      distance = time_ago_in_words(time)
      compact ? "closed" : "closed #{distance} ago"
    end
  end

  def weather_time_value(value)
    return value.in_time_zone if value.respond_to?(:in_time_zone)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def weather_date_value(value)
    return value if value.is_a?(Date)
    return value.to_date if value.respond_to?(:to_date)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def weather_money_tone(value)
    number = value.to_f
    return "rose" if number.negative?
    return "emerald" if number.positive?

    "zinc"
  end

  def weather_money_class(value)
    number = value.to_f
    return "text-teal-100" if number.negative?
    return "text-emerald-100" if number.positive?

    "text-zinc-100"
  end

  def weather_price_cents(value)
    return "n/a" if value.blank?

    "#{(value.to_f * 100).round}c"
  end

  def weather_svg_curve_path(points)
    points = Array(points)
    return "" if points.blank?

    first = points.first
    path = +"M #{first[:x].round(2)} #{first[:y].round(2)}"
    return path if points.length == 1

    points.each_cons(2) do |previous, current|
      control_x = ((previous[:x] + current[:x]) / 2.0).round(2)
      path << " C #{control_x} #{previous[:y].round(2)} #{control_x} #{current[:y].round(2)} #{current[:x].round(2)} #{current[:y].round(2)}"
    end
    path
  end

  def weather_chart_endpoint_label(text, point, color, vertical_offset, width, right)
    return nil if point.blank?

    label_width = [text.length * 6.4 + 18, 88].max
    x = [[point[:x] + 10, 70].max, width - right - label_width].min
    y = [[point[:y] + vertical_offset, 40].max, 252].min
    tag.g do
      safe_join([
        tag.rect(x: x.round(2), y: y.round(2), width: label_width.round(2), height: 20, rx: 4, fill: "rgba(0,0,0,0.76)", stroke: color, "stroke-width": 1),
        tag.text(text, x: (x + 9).round(2), y: (y + 14).round(2), fill: color, "font-size": 10, "font-family": "monospace", "font-weight": 700)
      ])
    end
  end

  def weather_settlement_status_line(status)
    status = status.to_h
    return tag.span("settlement scorer waiting", class: "text-zinc-500") if status.blank?

    parts = [
      "checked #{number_with_delimiter(status[:checked].to_i)}",
      "settled #{number_with_delimiter(status[:settled].to_i)}",
      "waiting #{number_with_delimiter(status[:waiting].to_i)}"
    ]
    parts << "errors #{Array(status[:errors]).length}" if Array(status[:errors]).present?
    tag.span(parts.join(" // "), class: "text-cyan-100")
  end

  def weather_backfill_status_line(status)
    status = status.to_h
    return tag.span("actual high backfill waiting", class: "text-zinc-500") if status.blank?

    parts = [
      "checked #{number_with_delimiter(status[:checked].to_i)}",
      "backfilled #{number_with_delimiter(status[:backfilled].to_i)}",
      "waiting #{number_with_delimiter(status[:waiting].to_i)}"
    ]
    sources = status[:sources].to_h
    parts << "source #{sources.keys.first.to_s.presence || 'pending'}" if sources.present?
    parts << "errors #{Array(status[:errors]).length}" if Array(status[:errors]).present?
    tag.span(parts.join(" // "), class: "text-emerald-100")
  end

  def weather_outcome_analysis_status_line(status, latest_question)
    status = status.to_h
    if latest_question&.answer_ready?
      return tag.span("Qwen reviewed #{time_ago_in_words(latest_question.updated_at)} ago", class: "text-fuchsia-100")
    end
    if latest_question&.pending_answer?
      return tag.span("Qwen review queued", class: "text-yellow-100")
    end

    tag.span(status[:reason].presence || "Qwen review waiting for scored outcomes", class: "text-zinc-500")
  end

  def weather_pattern_table(label, rows)
    tag.div(class: "border border-dotted border-white/15 bg-black/45 p-3") do
      content = [tag.h3(label, class: "font-mono text-[10px] font-black uppercase tracking-[0.18em] text-white")]
      content << if rows.present?
        tag.div(class: "mt-3 space-y-2") do
          safe_join(rows.map do |name, count|
            tag.div(class: "grid grid-cols-[minmax(0,1fr)_3rem] items-center gap-2 font-mono text-[10px] uppercase tracking-[0.08em]") do
              safe_join([
                tag.span(name.to_s, class: "truncate text-zinc-300"),
                tag.strong(number_with_delimiter(count.to_i), class: "text-right text-fuchsia-200")
              ])
            end
          end)
        end
      else
        tag.p("waiting", class: "mt-3 font-mono text-[10px] uppercase tracking-[0.12em] text-zinc-500")
      end
      safe_join(content)
    end
  end

  def weather_opportunity_chart(opportunities)
    rows = Array(opportunities).first(6)
    return tag.p("waiting for Kalshi weather series", class: "mt-3 font-mono text-[10px] uppercase tracking-[0.12em] text-zinc-500") if rows.blank?

    tag.div(class: "mt-5 space-y-3") do
      safe_join(rows.map do |row|
        score = row[:score].to_i.clamp(0, 100)
        tag.div(class: "border border-dotted border-yellow-200/25 bg-black/45 p-3") do
          safe_join([
            tag.div(class: "flex items-center justify-between gap-3 font-mono text-[10px] uppercase tracking-[0.12em]") do
              safe_join([
                tag.span(row[:label], class: "font-black text-white"),
                tag.span("#{score}% // #{row[:verdict]}", class: weather_score_class(score))
              ])
            end,
            tag.div(class: "mt-2 h-2 overflow-hidden border border-dotted border-white/20 bg-zinc-950") do
              tag.span("", class: "block h-full bg-gradient-to-r from-cyan-300 via-fuchsia-300 to-yellow-200", style: "width: #{score}%")
            end,
            tag.div(class: "mt-2 grid gap-2 font-mono text-[9px] uppercase tracking-[0.1em] text-yellow-50/65 sm:grid-cols-3") do
              safe_join([
                tag.span("signals #{number_with_delimiter(row[:signal_count].to_i)}"),
                tag.span("series #{number_with_delimiter(row[:series_count].to_i)}"),
                tag.span("forecast #{number_with_delimiter(row[:forecast_count].to_i)}")
              ])
            end
          ])
        end
      end)
    end
  end

  def weather_study_series_cards(series)
    rows = Array(series).first(8)
    return tag.p("Kalshi Weather Study 8 is waiting for live series data.", class: "mt-4 font-mono text-[10px] uppercase tracking-[0.12em] text-cyan-100/60") if rows.blank?

    tag.div(class: "mt-5 grid gap-3 xl:grid-cols-2") do
      safe_join(rows.map do |row|
        best_market = row[:best_market].to_h
        pick = row[:paper_pick].to_h
        pick_yes = pick[:action].to_s == "paper yes"
        tag.article(class: "border-2 border-dotted #{pick_yes ? 'border-emerald-300/70 shadow-[0_0_28px_rgba(16,185,129,0.18)]' : 'border-cyan-200/30 shadow-[0_0_22px_rgba(34,211,238,0.10)]'} bg-black/65 p-4") do
          safe_join([
            tag.div(class: "flex flex-wrap items-start justify-between gap-3") do
              safe_join([
                tag.div do
                  safe_join([
                    tag.p("##{row[:rank]} // #{row[:ticker]}", class: "font-mono text-xs font-black uppercase tracking-[0.14em] text-cyan-100/80"),
                    tag.h3(row[:label].to_s, class: "mt-1 font-mono text-lg font-black uppercase tracking-[-0.04em] text-white"),
                    tag.p(row[:city].to_s, class: "mt-1 font-mono text-xs uppercase tracking-[0.12em] text-fuchsia-200")
                  ])
                end,
                tag.div(class: "text-right font-mono text-xs uppercase tracking-[0.08em] text-yellow-100/85") do
                  safe_join([
                    tag.div(row.dig(:forecast, :high_f).present? ? "forecast #{row.dig(:forecast, :high_f)}F" : "forecast pending"),
                    tag.div(row[:frequency].to_s)
                  ])
                end
              ])
            end,
            tag.div(class: "mt-4 grid gap-3 sm:grid-cols-[0.9fr_1.1fr]") do
              safe_join([
                tag.div(class: "#{pick_yes ? 'border-emerald-200/70 bg-emerald-950/70 text-emerald-50 shadow-[0_0_18px_rgba(16,185,129,0.18)]' : 'border-cyan-200/35 bg-zinc-950 text-cyan-50'} border border-dotted p-3") do
                  safe_join([
                    tag.p("AUTOS PAPER THESIS", class: "font-mono text-xs font-black uppercase tracking-[0.12em] #{pick_yes ? 'text-emerald-100' : 'text-cyan-100'}"),
                    tag.strong(pick_yes ? "YES // #{pick[:size]}" : "WATCH // #{pick[:size]}", class: "mt-2 block font-mono text-2xl font-black uppercase tracking-[-0.06em] #{pick_yes ? 'text-white' : 'text-cyan-50'}"),
                    tag.p(pick[:market_range].presence || "range pending", class: "mt-1 font-mono text-xs font-black uppercase tracking-[0.08em] #{pick_yes ? 'text-emerald-100' : 'text-cyan-100'}")
                  ])
                end,
                tag.div(class: "grid gap-2 font-mono text-xs uppercase tracking-[0.06em] text-zinc-200 sm:grid-cols-2") do
                  safe_join([
                    weather_pick_metric("confidence", pick[:confidence] ? "#{(pick[:confidence].to_f * 100).round}%" : "n/a"),
                    weather_pick_metric("ask", pick[:ask] ? "#{(pick[:ask].to_f * 100).round}c" : "n/a"),
                    weather_pick_metric("edge", pick[:edge] ? "#{(pick[:edge].to_f * 100).round} pts" : "n/a"),
                    weather_pick_metric("contracts", Array(row[:markets]).length)
                  ])
                end
              ])
            end,
            weather_forecast_source_strip(row[:forecast]),
            tag.p(pick[:rationale].presence || row[:study_focus].to_s, class: "mt-3 text-sm leading-6 text-cyan-50/82"),
            tag.p(best_market[:title].to_s.presence || "No live contract loaded yet.", class: "mt-3 text-xs leading-5 text-white/72"),
            tag.div(class: "mt-3 overflow-x-auto") do
              tag.table(class: "min-w-full border-collapse font-mono text-xs uppercase tracking-[0.04em]") do
                safe_join([
                  tag.thead(class: "text-cyan-100/55") do
                    tag.tr(class: "border-b border-dotted border-cyan-200/20") do
                      safe_join([
                        tag.th("range", class: "px-2 py-2 text-left"),
                        tag.th("bid / ask", class: "px-2 py-2 text-left"),
                        tag.th("vol", class: "px-2 py-2 text-right")
                      ])
                    end
                  end,
                  tag.tbody(class: "text-cyan-50/85") do
                    safe_join(Array(row[:markets]).first(4).map do |market|
                      tag.tr(class: "border-b border-dotted border-white/10") do
                        safe_join([
                          tag.td((market[:subtitle].presence || market[:title]).to_s.truncate(38), class: "px-2 py-2 normal-case tracking-normal"),
                          tag.td(weather_price_label(market), class: "px-2 py-2 text-yellow-100"),
                          tag.td(number_with_delimiter(market[:volume].to_f.round), class: "px-2 py-2 text-right text-zinc-400")
                        ])
                      end
                    end)
                  end
                ])
              end
            end
          ])
        end
      end)
    end
  end

  def weather_pick_metric(label, value)
    tag.div(class: "border border-dotted border-white/15 bg-black/35 px-2 py-2") do
      safe_join([
        tag.span(label.to_s, class: "block text-zinc-400"),
        tag.strong(value.to_s, class: "mt-1 block text-sm text-white")
      ])
    end
  end

  def weather_forecast_source_strip(forecast)
    forecast = forecast.to_h
    sources = Array(forecast[:sources])
    unavailable = Array(forecast[:unavailable_sources])
    source_count = forecast[:source_count].to_i
    source_total = forecast[:source_total].presence || (source_count + unavailable.length)
    spread = forecast[:source_spread_f]
    label = forecast[:agreement_label].presence || "pending"

    tag.div(class: "mt-3 border border-dotted border-white/15 bg-black/45 p-3") do
      safe_join([
        tag.div(class: "flex flex-wrap items-center justify-between gap-2 font-mono text-[10px] font-black uppercase tracking-[0.12em]") do
          safe_join([
            tag.span("forecast stack // #{source_count}/#{source_total} live // #{label}", class: weather_source_agreement_class(label)),
            tag.span("spread #{weather_temperature_label(spread)}", class: spread.to_f > 4.0 ? "text-teal-200" : "text-cyan-100")
          ])
        end,
        tag.div(class: "mt-2 grid gap-2 md:grid-cols-3") do
          rows = sources.map { |source| weather_source_badge(source, live: true) } +
            unavailable.first([3 - sources.length, 0].max).map { |source| weather_source_badge(source, live: false) }
          safe_join(rows.presence || [tag.span("sources pending", class: "font-mono text-[10px] uppercase tracking-[0.12em] text-zinc-500")])
        end
      ])
    end
  end

  def weather_source_badge(source, live:)
    source = source.to_h
    tag.div(class: "border border-dotted #{live ? 'border-cyan-200/25 bg-cyan-950/20' : 'border-zinc-500/25 bg-zinc-950/45'} px-2 py-2 font-mono uppercase tracking-[0.07em]") do
      safe_join([
        tag.span(source[:label].to_s.presence || source["label"].to_s.presence || "source", class: "block text-[10px] #{live ? 'text-cyan-100' : 'text-zinc-500'}"),
        tag.strong(live ? weather_temperature_label(source[:high_f] || source["high_f"]) : "offline", class: "mt-1 block text-sm #{live ? 'text-white' : 'text-zinc-500'}"),
        tag.span((source[:summary] || source["summary"] || source[:reason] || source["reason"]).to_s.truncate(54), class: "mt-1 block text-[9px] leading-4 #{live ? 'text-white/58' : 'text-zinc-500'}")
      ])
    end
  end

  def weather_source_agreement_class(label)
    case label.to_s
    when /tight/
      "text-emerald-200"
    when /watch/
      "text-yellow-100"
    when /conflict/
      "text-teal-200"
    else
      "text-zinc-300"
    end
  end

  def weather_temperature_label(value)
    return "n/a" if value.blank?

    number = value.to_f
    "#{number == number.round ? number.round : number.round(1)}F"
  end

  def weather_probability_line_chart(predictions)
    all_rows = Array(predictions)
    scored_rows = all_rows.select do |row|
      row.result_status.to_s != "pending" || row.observed_high_f.present? || row.market_distance_f.present?
    end
    rows = (scored_rows.presence || all_rows).first(18).reverse
    return tag.p("No persisted Probability Lab predictions yet.", class: "mt-4 font-mono text-[10px] uppercase tracking-[0.12em] text-zinc-500") if rows.blank?

    width = 900.0
    height = 330.0
    left = 58.0
    right = 28.0
    top = 34.0
    bottom = 58.0
    plot_width = width - left - right
    plot_height = height - top - bottom
    values = rows.flat_map do |row|
      [
        row.adjusted_high_f,
        row.market_floor_strike,
        row.market_cap_strike,
        row.observed_high_f,
        row.forecast_high_f
      ]
    end.compact.map(&:to_f)
    min_value = ((((values.min || 50) - 3) / 2.0).floor * 2)
    max_value = ((((values.max || 100) + 3) / 2.0).ceil * 2)
    span = [max_value - min_value, 1].max
    x_for = lambda do |index|
      return left + (plot_width / 2.0) if rows.length == 1

      left + ((plot_width / (rows.length - 1)) * index)
    end
    y_for = lambda do |value|
      top + ((max_value - value.to_f) / span * plot_height)
    end
    point_rows = lambda do |method, fallback_method = nil|
      rows.each_with_index.filter_map do |row, index|
        value = row.public_send(method)
        value = row.public_send(fallback_method) if value.blank? && fallback_method.present?
        next if value.blank?

        {
          x: x_for.call(index),
          y: y_for.call(value),
          value: value.to_f,
          row: row,
          index: index
        }
      end
    end
    curve_path = lambda do |points|
      points = Array(points)
      return "" if points.blank?

      first = points.first
      path = +"M #{first[:x].round(2)} #{first[:y].round(2)}"
      return path if points.length == 1

      points.each_cons(2) do |previous, current|
        control_x = ((previous[:x] + current[:x]) / 2.0).round(2)
        path << " C #{control_x} #{previous[:y].round(2)} #{control_x} #{current[:y].round(2)} #{current[:x].round(2)} #{current[:y].round(2)}"
      end
      path
    end
    autos_points = point_rows.call(:adjusted_high_f, :forecast_high_f)
    actual_points = point_rows.call(:observed_high_f)
    autos_path = curve_path.call(autos_points)
    actual_path = curve_path.call(actual_points)
    grid_values = (0..4).map { |index| (max_value - ((span / 4.0) * index)).round }
    grid = grid_values.uniq.map do |value|
      y = y_for.call(value)
      safe_join([
        tag.line(x1: left, y1: y, x2: width - right, y2: y, stroke: "rgba(125,249,255,0.13)", "stroke-dasharray": "2 10"),
        tag.text(weather_temperature_label(value), x: 10, y: y + 4, fill: "rgba(255,255,255,0.55)", "font-size": 10, "font-family": "monospace")
      ])
    end
    beam_nodes = rows.each_with_index.map do |_row, index|
      opacity = index.even? ? "0.18" : "0.08"
      tag.line(
        x1: x_for.call(index),
        y1: top,
        x2: x_for.call(index),
        y2: height - bottom,
        stroke: "url(#weatherBeamGradient)",
        "stroke-width": 1,
        opacity: opacity
      )
    end
    marker_nodes = actual_points.filter_map do |point|
      row = point[:row]
      next if row.result_status.to_s == "pending"

      won = row.result_status.to_s == "won"
      lost = row.result_status.to_s == "lost"
      color = won ? "#34d399" : lost ? "#5eead4" : "#facc15"
      node = if lost
        safe_join([
          tag.circle(cx: point[:x], cy: point[:y], r: 7, fill: "rgba(94,234,212,0.13)", stroke: color, "stroke-width": 2),
          tag.line(x1: point[:x] - 4, y1: point[:y] - 4, x2: point[:x] + 4, y2: point[:y] + 4, stroke: color, "stroke-width": 2, "stroke-linecap": "round"),
          tag.line(x1: point[:x] + 4, y1: point[:y] - 4, x2: point[:x] - 4, y2: point[:y] + 4, stroke: color, "stroke-width": 2, "stroke-linecap": "round")
        ])
      else
        tag.circle(cx: point[:x], cy: point[:y], r: 5.5, fill: color, stroke: "rgba(0,0,0,0.65)", "stroke-width": 2)
      end
      tag.g do
        safe_join([
          node,
          tag.title("#{row.city} #{row.prediction_date}: #{row.result_status} // actual #{row.observed_high_f || 'n/a'}F // Kalshi #{row.market_band_label}")
        ])
      end
    end
    band_points = rows.each_with_index.filter_map do |row, index|
      next unless row.market_floor_strike.present? && row.market_cap_strike.present?

      {
        x: x_for.call(index),
        row: row,
        top_y: y_for.call(row.market_cap_strike),
        bottom_y: y_for.call(row.market_floor_strike)
      }
    end
    band_path = if band_points.present?
      top_path = band_points.map { |point| "#{point[:x].round(2)} #{point[:top_y].round(2)}" }
      bottom_path = band_points.reverse.map { |point| "#{point[:x].round(2)} #{point[:bottom_y].round(2)}" }
      "M #{top_path.join(' L ')} L #{bottom_path.join(' L ')} Z"
    end
    miss_breach_nodes = rows.each_with_index.filter_map do |row, index|
      next unless row.result_status.to_s == "lost"

      actual = row.observed_high_f.presence || row.adjusted_high_f.presence || row.forecast_high_f.presence
      next if actual.blank?

      band_edge = if row.market_cap_strike.present? && actual.to_f > row.market_cap_strike.to_f
        row.market_cap_strike
      elsif row.market_floor_strike.present? && actual.to_f < row.market_floor_strike.to_f
        row.market_floor_strike
      else
        row.market_cap_strike.presence || row.market_floor_strike.presence || row.adjusted_high_f.presence
      end
      next if band_edge.blank?

      x = x_for.call(index)
      y_actual = y_for.call(actual)
      y_edge = y_for.call(band_edge)
      label_y = [[y_actual, y_edge].min - 26, top + 6].max
      label_x = [[x + 10, left].max, width - right - 56].min
      safe_join([
        tag.line(x1: x, y1: y_edge, x2: x, y2: y_actual, stroke: "#5eead4", "stroke-width": 3.5, "stroke-linecap": "round"),
        tag.circle(cx: x, cy: y_actual, r: 12, fill: "rgba(94,234,212,0.16)", stroke: "#5eead4", "stroke-width": 2.5),
        tag.line(x1: x - 6, y1: y_actual - 6, x2: x + 6, y2: y_actual + 6, stroke: "#5eead4", "stroke-width": 3, "stroke-linecap": "round"),
        tag.line(x1: x + 6, y1: y_actual - 6, x2: x - 6, y2: y_actual + 6, stroke: "#5eead4", "stroke-width": 3, "stroke-linecap": "round"),
        tag.rect(x: label_x.round(2), y: label_y.round(2), width: 48, height: 19, rx: 4, fill: "rgba(17,94,89,0.82)", stroke: "#5eead4", "stroke-width": 1),
        tag.text("miss", x: (label_x + 24).round(2), y: (label_y + 13).round(2), fill: "#ccfbf1", "font-size": 10, "font-family": "monospace", "font-weight": 800, "text-anchor": "middle"),
        tag.title("#{row.city} #{row.prediction_date}: missed Kalshi #{row.market_band_label} // actual #{row.observed_high_f || 'n/a'}F")
      ])
    end
    label_step = [(rows.length / 6.0).ceil, 1].max
    date_labels = rows.each_with_index.filter_map do |row, index|
      next unless index.zero? || index == rows.length - 1 || (index % label_step).zero?

      city_label = row.city.to_s.squish.presence || "city"
      city_label = city_label.split(/\s+/).first if city_label.length > 10
      date_label = row.prediction_date ? row.prediction_date.strftime("%m/%d") : "date"

      tag.g do
        safe_join([
          tag.text(
            city_label.truncate(9),
            x: x_for.call(index),
            y: height - 32,
            fill: "rgba(255,255,255,0.62)",
            "font-size": 10,
            "font-family": "monospace",
            "text-anchor": "middle"
          ),
          tag.text(
            date_label,
            x: x_for.call(index),
            y: height - 17,
            fill: "rgba(255,255,255,0.38)",
            "font-size": 9,
            "font-family": "monospace",
            "text-anchor": "middle"
          )
        ])
      end
    end
    endpoint_label = lambda do |text, point, color, vertical_offset|
      return if point.blank?

      label_width = [text.length * 6.8 + 18, 84].max
      x = [[point[:x] + 10, left].max, width - right - label_width].min
      y = [[point[:y] + vertical_offset, top + 6].max, height - bottom - 24].min
      tag.g do
        safe_join([
          tag.rect(x: x.round(2), y: y.round(2), width: label_width.round(2), height: 20, rx: 4, fill: "rgba(0,0,0,0.72)", stroke: color, "stroke-width": 1),
          tag.text(text, x: (x + 9).round(2), y: (y + 14).round(2), fill: color, "font-size": 10, "font-family": "monospace", "font-weight": 700)
        ])
      end
    end
    band_label = if band_points.present?
      middle = band_points[band_points.length / 2]
      label_y = ((middle[:top_y] + middle[:bottom_y]) / 2.0) - 10
      tag.g do
        safe_join([
          tag.rect(x: (middle[:x] - 46).round(2), y: label_y.round(2), width: 92, height: 20, rx: 4, fill: "rgba(8,47,73,0.78)", stroke: "rgba(34,211,238,0.75)", "stroke-width": 1),
          tag.text("Kalshi range", x: middle[:x].round(2), y: (label_y + 14).round(2), fill: "#67e8f9", "font-size": 10, "font-family": "monospace", "font-weight": 700, "text-anchor": "middle")
        ])
      end
    end
    endpoint_labels = [
      endpoint_label.call("AUTOS estimate", autos_points.last, "#f0abfc", -24),
      endpoint_label.call("actual high", actual_points.last, "#34d399", 10)
    ].compact

    tag.div(class: "mt-4 border-2 border-dotted border-white/20 bg-black/55 p-4") do
      safe_join([
        tag.div(class: "mb-3 flex flex-wrap items-center justify-between gap-3") do
          safe_join([
            tag.div do
              safe_join([
                tag.p("prediction vs actual high", class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-cyan-100"),
                tag.p("Blue band is the Kalshi temperature range. Pink is AUTOS's estimated high. Green is the observed high after close. Red breach marks a miss outside the band.", class: "mt-1 text-sm leading-5 text-white/68")
              ])
            end,
            tag.div(class: "flex flex-wrap gap-3 font-mono text-xs uppercase tracking-[0.08em] text-zinc-200") do
              safe_join([
                weather_chart_key("Kalshi range", "band"),
                weather_chart_key("AUTOS estimate", "fuchsia"),
                weather_chart_key("actual high", "green"),
                weather_chart_key("miss marker", "rose")
              ])
            end
          ])
        end,
        tag.svg(viewBox: "0 0 #{width.to_i} #{height.to_i}", class: "h-auto w-full", role: "img", "aria-label": "Probability Lab weather prediction accuracy chart") do
          safe_join([
            tag.defs do
              safe_join([
                tag.linearGradient(id: "weatherBandGradient", x1: "0%", y1: "0%", x2: "100%", y2: "0%") do
                  safe_join([
                    tag.stop(offset: "0%", "stop-color": "#22d3ee", "stop-opacity": "0.08"),
                    tag.stop(offset: "45%", "stop-color": "#a78bfa", "stop-opacity": "0.22"),
                    tag.stop(offset: "100%", "stop-color": "#f0abfc", "stop-opacity": "0.10")
                  ])
                end,
                tag.linearGradient(id: "weatherBeamGradient", x1: "0%", y1: "0%", x2: "0%", y2: "100%") do
                  safe_join([
                    tag.stop(offset: "0%", "stop-color": "#22d3ee", "stop-opacity": "0"),
                    tag.stop(offset: "50%", "stop-color": "#22d3ee", "stop-opacity": "0.65"),
                    tag.stop(offset: "100%", "stop-color": "#22d3ee", "stop-opacity": "0")
                  ])
                end
              ])
            end,
            tag.rect(x: left, y: top, width: plot_width, height: plot_height, rx: 10, fill: "rgba(8,47,73,0.16)", stroke: "rgba(125,249,255,0.18)"),
            safe_join(beam_nodes),
            tag.text("temperature F", x: left, y: 18, fill: "rgba(255,255,255,0.62)", "font-size": 11, "font-family": "monospace"),
            safe_join(grid),
            (tag.path(d: band_path, fill: "url(#weatherBandGradient)", stroke: "rgba(34,211,238,0.32)", "stroke-width": 1.5, "stroke-dasharray": "2 7") if band_path.present?),
            (tag.path(d: autos_path, fill: "none", stroke: "rgba(240,171,252,0.20)", "stroke-width": 13, "stroke-linecap": "round", "stroke-linejoin": "round") if autos_path.present?),
            (tag.path(d: autos_path, fill: "none", stroke: "#f0abfc", "stroke-width": 4.5, "stroke-linecap": "round", "stroke-linejoin": "round") if autos_path.present?),
            (tag.path(d: actual_path, fill: "none", stroke: "rgba(52,211,153,0.22)", "stroke-width": 11, "stroke-linecap": "round", "stroke-linejoin": "round") if actual_path.present?),
            (tag.path(d: actual_path, fill: "none", stroke: "#34d399", "stroke-width": 3.5, "stroke-linecap": "round", "stroke-linejoin": "round") if actual_path.present?),
            safe_join(miss_breach_nodes),
            safe_join(marker_nodes),
            band_label,
            safe_join(endpoint_labels),
            safe_join(date_labels),
            tag.line(x1: left, y1: height - bottom, x2: width - right, y2: height - bottom, stroke: "rgba(255,255,255,0.22)"),
            tag.text("recent city/day predictions", x: left + (plot_width / 2.0), y: height - 2, fill: "rgba(255,255,255,0.46)", "font-size": 10, "font-family": "monospace", "text-anchor": "middle")
          ].compact)
        end,
        weather_prediction_score_table(rows.last(10).reverse)
      ])
    end
  end

  def weather_paper_performance_panel(performance)
    performance = performance.to_h
    daily = Array(performance[:daily])
    bankroll = performance[:bankroll].to_h
    total_profit = performance[:total_profit].to_f
    tone = total_profit.negative? ? "text-teal-100" : total_profit.positive? ? "text-emerald-100" : "text-zinc-100"
    tracking_started_at = bankroll[:tracking_started_at].presence
    tracking_label = begin
      tracking_started_at.present? ? Time.zone.parse(tracking_started_at.to_s).strftime("%b %-d, %-l:%M%P %Z") : "all tracked history"
    rescue ArgumentError, TypeError
      tracking_started_at.presence || "all tracked history"
    end
    seed_caption = bankroll[:seed_bankroll].present? ? " of #{number_to_currency(bankroll[:seed_bankroll].to_f)} seed" : ""

    tag.div(class: "mt-4 border-2 border-dotted border-yellow-200/35 bg-yellow-950/10 p-4") do
      safe_join([
        tag.div(class: "flex flex-wrap items-start justify-between gap-3") do
          safe_join([
            tag.div do
              safe_join([
                tag.p("paper bankroll ledger", class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-yellow-100"),
                tag.p("Tracking starts #{tracking_label}. #{number_to_currency(bankroll[:daily_budget].to_f)} is released per day#{seed_caption}; simulated P/L includes estimated taker fees.", class: "mt-1 text-sm leading-5 text-white/66")
              ])
            end,
            tag.div(class: "grid gap-1 border border-dotted border-yellow-200/25 bg-black/40 px-4 py-3 font-mono text-xs uppercase tracking-[0.08em]") do
              safe_join([
                tag.span("paper P/L", class: "text-yellow-100/70"),
                tag.strong(number_to_currency(total_profit), class: "text-2xl #{tone}")
              ])
            end
          ])
        end,
        tag.div(class: "mt-3 grid gap-3 md:grid-cols-4") do
          safe_join([
            weather_paper_stat("decided", number_with_delimiter(performance[:decided].to_i), "#{number_with_delimiter(performance[:wins].to_i)}W // #{number_with_delimiter(performance[:losses].to_i)}L"),
            weather_paper_stat("hit rate", performance[:hit_rate] ? "#{performance[:hit_rate]}%" : "n/a", "settled paper yes picks"),
            weather_paper_stat("at risk", number_to_currency(performance[:total_staked].to_f), "premium + #{number_to_currency(performance[:total_fees].to_f)} est. fees"),
            weather_paper_stat("reserve", number_to_currency(bankroll[:reserve_balance].to_f), "#{number_to_currency(bankroll[:total_credited].to_f)} credited")
          ])
        end,
        weather_paper_profit_chart(daily),
        weather_daily_extremes(performance)
      ])
    end
  end

  def weather_paper_stat(label, value, caption)
    tag.div(class: "border border-dotted border-yellow-200/20 bg-black/35 p-3 font-mono uppercase tracking-[0.08em]") do
      safe_join([
        tag.span(label, class: "block text-[10px] text-yellow-100/60"),
        tag.strong(value.to_s, class: "mt-1 block text-xl text-white"),
        tag.span(caption.to_s, class: "mt-1 block text-[10px] text-zinc-400")
      ])
    end
  end

  def weather_paper_profit_chart(daily)
    rows = Array(daily).last(30)
    return tag.p("Bankroll P/L chart is blank until a post-reset wager settles.", class: "mt-4 font-mono text-xs uppercase tracking-[0.1em] text-zinc-500") if rows.blank?

    width = 900.0
    height = 320.0
    left = 66.0
    right = 34.0
    top = 34.0
    bottom = 56.0
    plot_width = width - left - right
    plot_height = height - top - bottom
    values = rows.flat_map { |row| [row[:daily_profit].to_f, row[:cumulative_profit].to_f] } + [0.0]
    min_value = (values.min * 1.15).floor
    max_value = (values.max * 1.15).ceil
    min_value = -1 if min_value.zero? && max_value.zero?
    max_value = 1 if min_value == max_value
    span = [max_value - min_value, 1].max
    x_for = lambda do |index|
      return left + (plot_width / 2.0) if rows.length == 1

      left + ((plot_width / (rows.length - 1)) * index)
    end
    y_for = lambda do |value|
      top + ((max_value - value.to_f) / span * plot_height)
    end
    zero_y = y_for.call(0)
    bar_width = [[plot_width / [rows.length, 1].max * 0.48, 28].min, 8].max
    cumulative_points = rows.each_with_index.map do |row, index|
      { x: x_for.call(index), y: y_for.call(row[:cumulative_profit]), row: row }
    end
    cumulative_path = if cumulative_points.present?
      first = cumulative_points.first
      path = +"M #{first[:x].round(2)} #{first[:y].round(2)}"
      cumulative_points.each_cons(2) do |previous, current|
        control_x = ((previous[:x] + current[:x]) / 2.0).round(2)
        path << " C #{control_x} #{previous[:y].round(2)} #{control_x} #{current[:y].round(2)} #{current[:x].round(2)} #{current[:y].round(2)}"
      end
      path
    end
    grid_values = (0..4).map { |index| max_value - ((span / 4.0) * index) }.map { |value| value.round(2) }.uniq
    grid = grid_values.map do |value|
      y = y_for.call(value)
      safe_join([
        tag.line(x1: left, y1: y, x2: width - right, y2: y, stroke: "rgba(255,255,255,0.12)", "stroke-dasharray": "2 8"),
        tag.text(number_to_currency(value, precision: value.abs < 10 ? 2 : 0), x: 12, y: y + 4, fill: "rgba(255,255,255,0.58)", "font-size": 10, "font-family": "monospace")
      ])
    end
    bars = rows.each_with_index.map do |row, index|
      value = row[:daily_profit].to_f
      x = x_for.call(index) - (bar_width / 2.0)
      y = value.negative? ? zero_y : y_for.call(value)
      bar_height = (zero_y - y_for.call(value)).abs
      color = value.negative? ? "#5eead4" : value.positive? ? "#34d399" : "#a1a1aa"
      tag.g do
        safe_join([
          tag.rect(x: x.round(2), y: y.round(2), width: bar_width.round(2), height: [bar_height, 2].max.round(2), rx: 3, fill: color, opacity: 0.72),
          tag.title("#{row[:date]&.strftime('%b %-d') || 'day'} daily #{number_to_currency(value)} // cumulative #{number_to_currency(row[:cumulative_profit].to_f)}")
        ])
      end
    end
    line_dots = cumulative_points.map do |point|
      value = point[:row][:cumulative_profit].to_f
      color = value.negative? ? "#5eead4" : "#facc15"
      tag.circle(cx: point[:x], cy: point[:y], r: 4.5, fill: color, stroke: "rgba(0,0,0,0.7)", "stroke-width": 2)
    end
    label_step = [(rows.length / 6.0).ceil, 1].max
    date_labels = rows.each_with_index.filter_map do |row, index|
      next unless index.zero? || index == rows.length - 1 || (index % label_step).zero?

      tag.text(row[:date]&.strftime("%m/%d") || "day", x: x_for.call(index), y: height - 22, fill: "rgba(255,255,255,0.46)", "font-size": 10, "font-family": "monospace", "text-anchor": "middle")
    end

    tag.div(class: "mt-4 border border-dotted border-yellow-200/20 bg-black/45 p-3") do
      safe_join([
        tag.div(class: "mb-2 flex flex-wrap items-center justify-between gap-3 font-mono text-xs uppercase tracking-[0.08em]") do
          safe_join([
            tag.span("daily P/L bars + cumulative revenue line", class: "text-yellow-100"),
            tag.span(class: "flex flex-wrap gap-3 text-zinc-300") do
              safe_join([
                weather_chart_key("daily gain", "green"),
                weather_chart_key("daily loss", "rose"),
                weather_chart_key("cumulative revenue", "yellow")
              ])
            end
          ])
        end,
        tag.svg(viewBox: "0 0 #{width.to_i} #{height.to_i}", class: "h-auto w-full", role: "img", "aria-label": "Weather paper profit and loss chart") do
          safe_join([
            tag.rect(x: left, y: top, width: plot_width, height: plot_height, rx: 10, fill: "rgba(113,63,18,0.12)", stroke: "rgba(250,204,21,0.20)"),
            safe_join(grid),
            tag.line(x1: left, y1: zero_y, x2: width - right, y2: zero_y, stroke: "rgba(255,255,255,0.28)", "stroke-width": 1.5),
            safe_join(bars),
            (tag.path(d: cumulative_path, fill: "none", stroke: "rgba(250,204,21,0.28)", "stroke-width": 12, "stroke-linecap": "round", "stroke-linejoin": "round") if cumulative_path.present?),
            (tag.path(d: cumulative_path, fill: "none", stroke: "#facc15", "stroke-width": 4, "stroke-linecap": "round", "stroke-linejoin": "round") if cumulative_path.present?),
            safe_join(line_dots),
            safe_join(date_labels),
            tag.text("paper dollars", x: left, y: 18, fill: "rgba(255,255,255,0.62)", "font-size": 11, "font-family": "monospace"),
            tag.text("settlement date", x: left + (plot_width / 2.0), y: height - 2, fill: "rgba(255,255,255,0.46)", "font-size": 10, "font-family": "monospace", "text-anchor": "middle")
          ].compact)
        end
      ])
    end
  end

  def weather_daily_extremes(performance)
    best_day = performance.to_h[:best_day]
    worst_day = performance.to_h[:worst_day]
    return "".html_safe if best_day.blank? && worst_day.blank?

    tag.div(class: "mt-3 grid gap-3 md:grid-cols-2") do
      safe_join([
        weather_extreme_day("best day", best_day, "text-emerald-100"),
        weather_extreme_day("roughest day", worst_day, "text-teal-100")
      ].compact)
    end
  end

  def weather_extreme_day(label, row, value_class)
    return nil if row.blank?

    tag.div(class: "border border-dotted border-white/15 bg-black/30 px-3 py-2 font-mono text-xs uppercase tracking-[0.08em]") do
      safe_join([
        tag.span("#{label} // #{row[:date]&.strftime('%b %-d') || 'n/a'}", class: "text-zinc-400"),
        tag.strong(number_to_currency(row[:daily_profit].to_f), class: "float-right #{value_class}")
      ])
    end
  end

  def weather_source_learning_panel(learning)
    learning = learning.to_h
    tag.div(class: "mt-4 grid gap-3 xl:grid-cols-[1.1fr_0.9fr]") do
      safe_join([
        weather_source_learning_table("forecast source trust", Array(learning[:sources]), "Average source error is measured against observed highs when available."),
        tag.div(class: "grid gap-3") do
          safe_join([
            weather_source_learning_table("source agreement", Array(learning[:agreements]), "Which agreement labels are winning or losing."),
            weather_source_learning_table("live source count", Array(learning[:source_counts]), "Whether more live sources improves the paper edge.")
          ])
        end
      ])
    end
  end

  def weather_source_learning_table(title, rows, caption)
    tag.div(class: "border-2 border-dotted border-cyan-200/25 bg-cyan-950/10 p-4") do
      content = [
        tag.p(title, class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-cyan-100"),
        tag.p(caption, class: "mt-1 text-sm leading-5 text-white/62")
      ]
      content << if rows.present?
        tag.div(class: "mt-3 overflow-x-auto") do
          tag.table(class: "min-w-full border-collapse font-mono text-xs uppercase tracking-[0.04em]") do
            safe_join([
              tag.thead(class: "text-cyan-100/65") do
                tag.tr(class: "border-b border-dotted border-white/15") do
                  safe_join([
                    tag.th("signal", class: "px-2 py-2 text-left"),
                    tag.th("seen", class: "px-2 py-2 text-right"),
                    tag.th("W/L", class: "px-2 py-2 text-right"),
                    tag.th("hit", class: "px-2 py-2 text-right"),
                    tag.th("avg err", class: "px-2 py-2 text-right")
                  ])
                end
              end,
              tag.tbody(class: "text-white/82") do
                safe_join(rows.map do |row|
                  tag.tr(class: "border-b border-dotted border-white/10") do
                    safe_join([
                      tag.td(row[:label].to_s, class: "max-w-48 truncate px-2 py-2 normal-case tracking-normal text-white"),
                      tag.td(number_with_delimiter(row[:seen].to_i), class: "px-2 py-2 text-right text-zinc-300"),
                      tag.td("#{row[:wins].to_i}/#{row[:losses].to_i}", class: "px-2 py-2 text-right text-emerald-100"),
                      tag.td(row[:hit_rate] ? "#{row[:hit_rate]}%" : "n/a", class: "px-2 py-2 text-right text-yellow-100"),
                      tag.td(row[:avg_abs_error_f] ? "#{row[:avg_abs_error_f]}F" : "n/a", class: "px-2 py-2 text-right text-cyan-100")
                    ])
                  end
                end)
              end
            ])
          end
        end
      else
        tag.p("Waiting for settled predictions with source metadata.", class: "mt-3 font-mono text-xs uppercase tracking-[0.1em] text-zinc-500")
      end
      safe_join(content)
    end
  end

  def weather_divergence_watch_panel(watch)
    watch = watch.to_h
    rows = Array(watch[:rows] || watch["rows"])
    source_weights = Array(watch[:source_weights] || watch["source_weights"])
    alert_count = rows.count { |row| row[:market_closer_to_weaker_source] || row["market_closer_to_weaker_source"] }

    tag.div(class: "mt-4 border-2 border-dotted border-violet-200/35 bg-violet-950/10 p-4") do
      safe_join([
        tag.div(class: "flex flex-wrap items-start justify-between gap-3") do
          safe_join([
            tag.div do
              safe_join([
                tag.p("live divergence engine", class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-violet-100"),
                tag.p("AUTOS weights each date-aligned forecast source by scored history, builds a consensus high, then checks whether Kalshi is leaning closer to the weaker live source. Paper-only until the edge survives chronological walk-forward tests.", class: "mt-1 max-w-4xl text-sm leading-5 text-white/66")
              ])
            end,
            tag.div(class: "grid gap-1 border border-dotted border-violet-200/25 bg-black/40 px-4 py-3 font-mono text-xs uppercase tracking-[0.08em]") do
              safe_join([
                tag.span("weak-source alerts", class: "text-violet-100/70"),
                tag.strong(number_with_delimiter(alert_count), class: alert_count.positive? ? "text-2xl text-yellow-100" : "text-2xl text-zinc-200")
              ])
            end
          ])
        end,
        weather_divergence_rows(rows),
        weather_source_weight_strip(source_weights)
      ])
    end
  end

  def weather_divergence_rows(rows)
    return tag.p("No live weak-source divergence yet. The engine is watching open markets with at least two forecast sources.", class: "mt-4 font-mono text-xs uppercase tracking-[0.1em] text-zinc-500") if rows.blank?

    tag.div(class: "mt-4 grid gap-3") do
      safe_join(rows.first(8).map do |row|
        alert = row[:market_closer_to_weaker_source] || row["market_closer_to_weaker_source"]
        city = [row[:city] || row["city"], row[:state] || row["state"]].compact_blank.join(", ")
        direction = row[:direction] || row["direction"]
        signal = row[:paper_signal] || row["paper_signal"]
        explanation = row[:explanation] || row["explanation"]
        strongest = row[:strongest_source] || row["strongest_source"] || {}
        closest = row[:closest_market_source] || row["closest_market_source"] || {}
        weakest = row[:weakest_outlier_source] || row["weakest_outlier_source"] || {}
        tag.article(class: "border border-dotted #{alert ? 'border-yellow-200/55 bg-yellow-950/12' : 'border-violet-200/20 bg-black/35'} p-3") do
          safe_join([
            tag.div(class: "flex flex-wrap items-start justify-between gap-3") do
              safe_join([
                tag.div do
                  safe_join([
                    tag.p(city.presence || "Open market", class: "font-mono text-sm font-black uppercase tracking-[0.08em] text-white"),
                    tag.p("#{row[:market] || row['market']} // #{row[:prediction_date] || row['prediction_date']}", class: "mt-1 font-mono text-[10px] uppercase tracking-[0.12em] text-zinc-400")
                  ])
                end,
                tag.div(class: "text-right font-mono uppercase tracking-[0.08em]") do
                  safe_join([
                    tag.strong(signal.to_s, class: alert ? "block text-sm text-yellow-100" : "block text-sm text-violet-100"),
                    tag.span("score #{row[:alert_score] || row['alert_score']}", class: "block text-[10px] text-zinc-400")
                  ])
                end
              ])
            end,
            tag.div(class: "mt-3 grid gap-2 md:grid-cols-4") do
              safe_join([
                weather_divergence_metric("Kalshi midpoint", "#{row[:market_midpoint_f] || row['market_midpoint_f']}F", "text-cyan-100"),
                weather_divergence_metric("weighted consensus", "#{row[:consensus_high_f] || row['consensus_high_f']}F", "text-yellow-100"),
                weather_divergence_metric("source spread", "#{row[:source_spread_f] || row['source_spread_f']}F", "text-violet-100"),
                weather_divergence_metric("market gap", "#{row[:market_gap_f] || row['market_gap_f']}F", "text-emerald-100")
              ])
            end,
            tag.div(class: "mt-3 grid gap-2 md:grid-cols-3") do
              safe_join([
                weather_source_chip("strongest source", strongest, "text-emerald-100"),
                weather_source_chip("market closest to", closest, alert ? "text-yellow-100" : "text-cyan-100"),
                weather_source_chip("largest outlier", weakest, "text-teal-100")
              ])
            end,
            tag.p("#{direction}. #{explanation}", class: "mt-3 text-sm leading-5 text-white/70")
          ])
        end
      end)
    end
  end

  def weather_divergence_metric(label, value, value_class)
    tag.div(class: "border border-dotted border-white/10 bg-black/35 px-3 py-2 font-mono uppercase tracking-[0.08em]") do
      safe_join([
        tag.span(label, class: "block text-[10px] text-zinc-500"),
        tag.strong(value.to_s, class: "mt-1 block text-lg #{value_class}")
      ])
    end
  end

  def weather_source_chip(label, source, value_class)
    source = source.to_h
    name = source[:label] || source["label"] || "n/a"
    high = source[:high_f] || source["high_f"]
    error = source[:avg_abs_error_f] || source["avg_abs_error_f"]
    sample = source[:sample_size] || source["sample_size"]
    score = source[:reliability_score] || source["reliability_score"]
    detail = [
      high.present? ? "#{high}F" : nil,
      error.present? ? "err #{error}F" : nil,
      sample.present? ? "n=#{sample}" : nil,
      score.present? ? "score #{score}" : nil
    ].compact.join(" // ")

    tag.div(class: "border border-dotted border-white/10 bg-black/30 px-3 py-2 font-mono uppercase tracking-[0.08em]") do
      safe_join([
        tag.span(label, class: "block text-[10px] text-zinc-500"),
        tag.strong(name.to_s, class: "mt-1 block truncate text-sm #{value_class}"),
        tag.span(detail.presence || "no history yet", class: "mt-1 block text-[10px] text-zinc-400")
      ])
    end
  end

  def weather_source_weight_strip(source_weights)
    return "".html_safe if source_weights.blank?

    tag.div(class: "mt-4 border border-dotted border-violet-200/20 bg-black/25 p-3") do
      safe_join([
        tag.p("current source weights", class: "font-mono text-[10px] font-black uppercase tracking-[0.16em] text-violet-100/80"),
        tag.div(class: "mt-2 flex flex-wrap gap-2") do
          safe_join(source_weights.first(8).map do |source|
            label = source[:label] || source["label"]
            score = source[:reliability_score] || source["reliability_score"]
            error = source[:avg_abs_error_f] || source["avg_abs_error_f"]
            tag.span("#{label}: #{score}#{error ? " // #{error}F" : ""}", class: "border border-dotted border-white/15 bg-black/35 px-2 py-1 font-mono text-[10px] uppercase tracking-[0.08em] text-zinc-300")
          end)
        end
      ])
    end
  end

  def weather_prediction_score_table(rows)
    rows = Array(rows)
    tag.div(class: "mt-4 overflow-x-auto") do
      tag.table(class: "min-w-full border-collapse font-mono text-xs uppercase tracking-[0.04em]") do
        safe_join([
          tag.thead(class: "text-cyan-100/70") do
            tag.tr(class: "border-b border-dotted border-white/20") do
              safe_join([
                tag.th("city", class: "px-3 py-2 text-left"),
                tag.th("Kalshi band", class: "px-3 py-2 text-left"),
                tag.th("AUTOS adjusted", class: "px-3 py-2 text-right"),
                tag.th("actual high", class: "px-3 py-2 text-right"),
                tag.th("outside band", class: "px-3 py-2 text-right"),
                tag.th("cause", class: "px-3 py-2 text-left"),
                tag.th("result", class: "px-3 py-2 text-right")
              ])
            end
          end,
          tag.tbody(class: "text-white/85") do
            safe_join(rows.map do |row|
              result_class = row.result_status == "won" ? "text-emerald-200" : row.result_status == "lost" ? "text-teal-200" : "text-zinc-400"
              tag.tr(class: "border-b border-dotted border-white/10") do
                safe_join([
                  tag.td(row.city, class: "px-3 py-3 normal-case tracking-normal text-white"),
                  tag.td(row.market_band_label, class: "px-3 py-3 text-cyan-100"),
                  tag.td(row.adjusted_high_f.present? ? "#{row.adjusted_high_f}F" : "n/a", class: "px-3 py-3 text-right text-fuchsia-100"),
                  tag.td(row.observed_high_f.present? ? "#{row.observed_high_f}F" : "pending", class: "px-3 py-3 text-right text-emerald-100"),
                  tag.td(row.market_distance_f.present? ? "#{row.market_distance_f}F" : "n/a", class: "px-3 py-3 text-right text-yellow-100"),
                  tag.td(row.miss_cause_label, class: "px-3 py-3 normal-case tracking-normal text-zinc-300"),
                  tag.td(row.result_status, class: "px-3 py-3 text-right #{result_class}")
                ])
              end
            end)
          end
        ])
      end
    end
  end

  def weather_miss_cause_panel(miss_summary, source_counts)
    miss_summary = miss_summary.to_h
    source_counts = Array(source_counts)
    tag.div(class: "mt-4 grid gap-3 lg:grid-cols-2") do
      safe_join([
        tag.div(class: "border-2 border-dotted border-teal-200/30 bg-teal-950/10 p-4") do
          safe_join([
            tag.p("miss cause ledger", class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-teal-100"),
            tag.div(class: "mt-3 grid gap-2") do
              if miss_summary.present?
                safe_join(miss_summary.first(6).map do |label, count|
                  weather_small_row(label, number_with_delimiter(count.to_i), "text-teal-100")
                end)
              else
                tag.p("No classified misses yet.", class: "font-mono text-xs uppercase tracking-[0.1em] text-zinc-500")
              end
            end
          ])
        end,
        tag.div(class: "border-2 border-dotted border-emerald-200/30 bg-emerald-950/10 p-4") do
          safe_join([
            tag.p("actual high sources", class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-emerald-100"),
            tag.div(class: "mt-3 grid gap-2") do
              if source_counts.present?
                safe_join(source_counts.map do |source, count|
                  weather_small_row(source.to_s.tr("_", " "), number_with_delimiter(count.to_i), "text-emerald-100")
                end)
              else
                tag.p("Actual highs are not populated yet.", class: "font-mono text-xs uppercase tracking-[0.1em] text-zinc-500")
              end
            end
          ])
        end
      ])
    end
  end

  def weather_qwen_analysis_panel(question)
    tag.div(class: "mt-4 border-2 border-dotted border-fuchsia-200/35 bg-fuchsia-950/10 p-4") do
      header = safe_join([
        tag.p("Qwen after-action review", class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-fuchsia-100"),
        tag.p("Qwen reviews scored outcomes, saves an AUTOS calibration note, and never places, sizes, promotes, or approves wagers.", class: "mt-1 text-sm leading-5 text-white/64")
      ])
      body = if question&.answer_ready?
        tag.div(simple_format(question.answer), class: "mt-3 text-sm leading-6 text-fuchsia-50/88")
      elsif question&.pending_answer?
        tag.p("Outcome review is queued on the local worker.", class: "mt-3 font-mono text-xs uppercase tracking-[0.1em] text-yellow-100")
      else
        tag.p("Waiting for enough scored predictions to queue a review.", class: "mt-3 font-mono text-xs uppercase tracking-[0.1em] text-zinc-500")
      end
      safe_join([header, body])
    end
  end

  def weather_market_station_panel(station)
    station = station.to_h
    rows = Array(station[:rows])
    summary = station[:summary].to_h

    tag.div(class: "border-2 border-dotted border-fuchsia-300/55 bg-black p-4 shadow-2xl shadow-fuchsia-950/25") do
      safe_join([
        weather_station_runtime_styles,
        tag.div(class: "flex flex-wrap items-start justify-between gap-3") do
          safe_join([
            tag.div do
              safe_join([
                tag.p("live weather show // synth wavemap", class: "font-mono text-xs font-black uppercase tracking-[0.18em] text-fuchsia-200"),
                tag.h2("WIZWIKI WeatherCast", class: "mt-1 font-mono text-5xl font-black text-white"),
                tag.p(station[:callsign].presence || "cyborg forecasting by Alice of Qwen", class: "mt-2 font-mono text-xs font-black uppercase tracking-[0.14em] text-cyan-100")
              ])
            end,
            tag.div(class: "grid grid-cols-2 gap-2 font-mono text-xs uppercase tracking-[0.08em] sm:grid-cols-4") do
              safe_join([
                weather_station_metric("cities", number_with_delimiter(summary[:cities].to_i), "text-cyan-100"),
                weather_station_metric("avg high", weather_station_average_high_label(rows), "text-yellow-100"),
                weather_station_metric("hot spot", weather_station_hot_spot_label(rows), "text-teal-100"),
                weather_station_metric("open", number_with_delimiter(summary[:open].to_i), "text-emerald-100")
              ])
            end
          ])
        end,
        tag.div(class: "mt-4 space-y-3") do
          safe_join([
            tag.div(class: "weathercast-map-frame relative overflow-hidden border border-dotted border-fuchsia-200/35 bg-black shadow-[inset_0_0_42px_rgba(217,70,239,0.18)]") do
              safe_join([
                weather_station_map_svg,
                tag.div(class: "absolute right-3 top-3 flex flex-wrap justify-end gap-2 font-mono text-[10px] font-black uppercase tracking-[0.12em] text-cyan-100/80") do
                  safe_join([
                    tag.span("AUTOS highs", class: "border border-dotted border-cyan-200/25 bg-black/60 px-2 py-1"),
                    tag.span(weather_station_refresh_badge(station[:generated_at]), class: "border border-dotted border-fuchsia-200/25 bg-black/60 px-2 py-1 text-fuchsia-100")
                  ])
                end,
                safe_join(rows.map { |row| weather_station_marker(row) }),
                weather_station_legend
              ])
            end,
            weather_station_forecast_strip(rows, station[:error])
          ])
        end
      ])
    end
  end

  def weather_station_metric(label, value, value_class)
    tag.div(class: "border border-dotted border-white/15 bg-black/45 px-3 py-2") do
      safe_join([
        tag.span(label, class: "block text-zinc-500"),
        tag.strong(value, class: "mt-1 block text-lg #{value_class}")
      ])
    end
  end

  def weather_station_refresh_badge(value)
    time = weather_time_value(value)
    return "live" if time.blank?

    age = [Time.current - time, 0].max
    return "now" if age < 90.seconds
    return "#{(age / 60).round}m" if age < 90.minutes
    return "#{(age / 1.hour).round}h" if age < 36.hours

    "#{(age / 1.day).round}d"
  end

  def weather_station_runtime_styles
    tag.style(<<~CSS)
      .weathercast-map-frame {
        position: relative;
        min-height: 520px;
        height: 72vh;
        max-height: 760px;
        overflow: hidden;
        background: #000;
      }
      .weathercast-map-layer,
      .weathercast-map-layer img,
      .weathercast-map-overlay,
      .weathercast-map-vignette,
      .weathercast-map-svg {
        position: absolute;
        inset: 0;
      }
      .weathercast-map-layer img {
        width: 100%;
        height: 100%;
        object-fit: cover;
        opacity: .95;
        filter: saturate(1.25);
      }
      .weathercast-map-overlay {
        background: linear-gradient(to bottom, rgba(0,0,0,.10), rgba(0,0,0,0), rgba(0,0,0,.45));
      }
      .weathercast-map-vignette {
        box-shadow: inset 0 0 70px rgba(217,70,239,.22), inset 0 0 120px rgba(34,211,238,.12);
      }
      .weathercast-map-svg {
        width: 100%;
        height: 100%;
      }
      .weathercast-city {
        position: absolute;
        z-index: 10;
        transform: translate(-50%, -50%);
      }
      .weathercast-city-detail {
        display: none;
      }
      .weathercast-city:hover .weathercast-city-detail,
      .weathercast-city:focus-within .weathercast-city-detail {
        display: block;
      }
      @media (max-width: 700px) {
        .weathercast-map-frame {
          min-height: 420px;
          height: 68vh;
        }
      }
    CSS
  end

  def weather_station_map_svg
    width = 1000
    height = 620
    horizon_lines = (0..8).map do |index|
      y = 382 + (index * 28)
      tag.path(
        d: "M20 #{y} C196 #{y - 34} 366 #{y - 22} 500 #{y} C647 #{y + 26} 792 #{y + 12} 980 #{y - 32}",
        fill: "none",
        stroke: index.even? ? "rgba(236,72,153,0.22)" : "rgba(34,211,238,0.18)",
        "stroke-width": 1.5,
        "stroke-dasharray": "12 18"
      )
    end
    perspective_lines = (0..14).map do |index|
      x = 20 + (index * 70)
      tag.path(
        d: "M#{x} #{height} L500 390",
        fill: "none",
        stroke: "rgba(250,204,21,0.10)",
        "stroke-width": 1
      )
    end

    tag.div(class: "weathercast-map-layer absolute inset-0 bg-black", role: "img", "aria-label": "Hyperrealistic lunar United States weather wager map") do
      safe_join([
        image_tag(
          "/images/weather/us-moon-wavemap.png",
          alt: "",
          class: "absolute inset-0 h-full w-full object-cover opacity-95 saturate-125",
          loading: "eager"
        ),
        tag.div(class: "weathercast-map-overlay absolute inset-0 bg-gradient-to-b from-black/10 via-transparent to-black/45"),
        tag.div(class: "weathercast-map-vignette absolute inset-0 shadow-[inset_0_0_70px_rgba(217,70,239,0.22),inset_0_0_120px_rgba(34,211,238,0.12)]"),
        tag.svg(viewBox: "0 0 #{width} #{height}", class: "weathercast-map-svg absolute inset-0 h-full w-full", "aria-hidden": "true") do
          safe_join([
            tag.defs do
              tag.pattern(id: "weather-station-scanline", width: 8, height: 8, patternUnits: "userSpaceOnUse") do
                safe_join([
                  tag.rect(x: 0, y: 0, width: 8, height: 8, fill: "rgba(0,0,0,0)"),
                  tag.rect(x: 0, y: 0, width: 8, height: 1, fill: "rgba(255,255,255,0.07)")
                ])
              end
            end,
            tag.rect(x: 0, y: 0, width: width, height: height, fill: "url(#weather-station-scanline)", opacity: 0.32),
            tag.path(d: "M0 382 L1000 382", stroke: "rgba(236,72,153,0.38)", "stroke-width": 2),
            safe_join(horizon_lines),
            safe_join(perspective_lines),
            tag.path(d: "M104 152 L287 115 L471 130", fill: "none", stroke: "rgba(236,72,153,0.24)", "stroke-width": 3, "stroke-dasharray": "24 18"),
            tag.path(d: "M604 130 L762 170 L908 236", fill: "none", stroke: "rgba(34,211,238,0.24)", "stroke-width": 3, "stroke-dasharray": "18 20"),
            tag.text("LUNAR CONUS WX GRID", x: 646, y: 544, fill: "rgba(34,211,238,0.52)", "font-size": 12, "font-family": "monospace", "font-weight": 800, "letter-spacing": 2.2),
            tag.text("ALICE / QWEN EDGE LAYER", x: 646, y: 566, fill: "rgba(240,171,252,0.52)", "font-size": 10, "font-family": "monospace", "font-weight": 800, "letter-spacing": 1.6)
          ])
        end
      ])
    end
  end

  def weather_station_marker(row)
    row = row.to_h
    classes = weather_station_status_classes(row[:status])
    left = row[:x].to_f.clamp(5.0, 95.0)
    top = row[:y].to_f.clamp(8.0, 92.0)
    label = row[:label].presence || [row[:city], row[:state]].compact_blank.join(", ")
    predicted_high = weather_station_temperature_label(row[:predicted_high_f] || row[:adjusted_high_f] || row[:forecast_high_f])

    tag.div(class: "weathercast-city group absolute z-10 -translate-x-1/2 -translate-y-1/2", style: "left: #{left}%; top: #{top}%;") do
      safe_join([
        tag.div(class: "min-w-[4.6rem] border border-white/25 bg-black/70 px-2 py-1.5 text-center shadow-xl shadow-black/60 backdrop-blur-sm #{classes[:ring]}") do
          safe_join([
            tag.strong(predicted_high, class: "block font-mono text-2xl font-black leading-none text-white"),
            tag.span(row[:code].to_s, class: "mt-1 block font-mono text-[10px] font-black uppercase tracking-[0.12em] #{classes[:text]}")
          ])
        end,
        tag.div(class: "weathercast-city-detail pointer-events-none absolute left-1/2 top-14 hidden w-72 -translate-x-1/2 border border-dotted border-cyan-200/35 bg-black/95 p-3 text-left shadow-xl shadow-black/70 group-hover:block") do
          safe_join([
            tag.p(label.presence || "Weather city", class: "font-mono text-xs font-black uppercase tracking-[0.1em] text-white"),
            tag.p("Predicted high #{predicted_high}", class: "mt-1 font-mono text-sm font-black uppercase tracking-[0.08em] text-yellow-100"),
            tag.p("AUTOS #{weather_temperature_label(row[:adjusted_high_f])} // forecast #{weather_temperature_label(row[:forecast_high_f])} // sources #{row[:source_count].presence || 'n/a'} // spread #{weather_temperature_label(row[:source_spread_f])}", class: "mt-2 font-mono text-[10px] uppercase leading-4 tracking-[0.07em] text-zinc-300"),
            tag.p("Market #{row[:market]} // #{weather_station_status_label(row[:status])} // ask #{weather_price_cents(row[:ask])} // edge #{weather_station_percent(row[:edge])}", class: "mt-2 font-mono text-[10px] uppercase leading-4 tracking-[0.07em] #{classes[:text]}"),
            tag.p(weather_station_close_label(row), class: "mt-2 font-mono text-[10px] uppercase leading-4 tracking-[0.07em] text-zinc-500")
          ])
        end
      ])
    end
  end

  def weather_station_legend
    tag.div(class: "absolute bottom-3 left-3 right-3 border border-dotted border-white/10 bg-black/68 p-2 font-mono text-[10px] font-black uppercase tracking-[0.1em] text-zinc-300") do
      safe_join([
        tag.span("hover city markers for market detail", class: "text-cyan-100/80")
      ])
    end
  end

  def weather_station_forecast_strip(rows, error)
    rows = Array(rows)
    return tag.p(error.presence || "No Kalshi weather city rows stored yet.", class: "font-mono text-xs uppercase tracking-[0.1em] text-zinc-500") if rows.blank?

    tag.div(class: "grid gap-2 sm:grid-cols-2 lg:grid-cols-4") do
      safe_join(rows.map do |row|
        row = row.to_h
        classes = weather_station_status_classes(row[:status])
        tag.div(class: "border border-dotted #{classes[:border]} bg-black/55 px-3 py-2 font-mono uppercase tracking-[0.08em]") do
          safe_join([
            tag.div(class: "flex items-center justify-between gap-3") do
              safe_join([
                tag.span(row[:label].to_s, class: "truncate text-[10px] text-zinc-300"),
                tag.strong(weather_station_temperature_label(row[:predicted_high_f] || row[:adjusted_high_f] || row[:forecast_high_f]), class: "text-lg text-white")
              ])
            end,
            tag.div("#{weather_station_status_label(row[:status])} // #{row[:market]}", class: "mt-1 truncate text-[10px] #{classes[:text]}")
          ])
        end
      end)
    end
  end

  def weather_station_predicted_high(row)
    row = row.to_h
    row[:predicted_high_f].presence || row[:adjusted_high_f].presence || row[:forecast_high_f].presence
  end

  def weather_station_temperature_label(value)
    weather_temperature_label(value)
  end

  def weather_station_average_high_label(rows)
    values = Array(rows).filter_map { |row| weather_station_predicted_high(row) }.map(&:to_f)
    return "n/a" if values.blank?

    weather_station_temperature_label(values.sum / values.length)
  end

  def weather_station_hot_spot_label(rows)
    row = Array(rows).max_by { |item| weather_station_predicted_high(item).to_f }
    return "n/a" if row.blank? || weather_station_predicted_high(row).blank?

    "#{row[:code]} #{weather_station_temperature_label(weather_station_predicted_high(row))}"
  end

  def weather_station_city_board(rows, error)
    rows = Array(rows)
    tag.div(class: "border border-dotted border-white/15 bg-black/45 p-3") do
      content = [
        tag.div(class: "flex items-start justify-between gap-3") do
          safe_join([
            tag.div do
              safe_join([
                tag.p("city board", class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-cyan-100"),
                tag.p("Latest market per city, biased toward open predictions.", class: "mt-1 text-sm leading-5 text-white/60")
              ])
            end,
            tag.span("#{number_with_delimiter(rows.length)} stations", class: "font-mono text-[10px] font-black uppercase tracking-[0.1em] text-zinc-400")
          ])
        end
      ]
      content << if rows.present?
        tag.div(class: "mt-3 grid max-h-[420px] gap-2 overflow-y-auto pr-1") do
          safe_join(rows.map { |row| weather_station_city_card(row) })
        end
      else
        tag.p(error.presence || "No Kalshi weather city rows stored yet.", class: "mt-4 font-mono text-xs uppercase tracking-[0.1em] text-zinc-500")
      end
      safe_join(content)
    end
  end

  def weather_station_city_card(row)
    row = row.to_h
    classes = weather_station_status_classes(row[:status])
    rec = row[:recommendation].to_h
    sizing = rec[:amount].to_f.positive? ? "#{number_to_currency(rec[:amount], precision: 0)} rec" : weather_station_status_label(row[:status])
    temperature = row[:observed_high_f].present? ? "actual #{weather_temperature_label(row[:observed_high_f])}" : "AUTOS #{weather_temperature_label(row[:adjusted_high_f])}"

    tag.article(class: "border border-dotted #{classes[:border]} bg-zinc-950/75 p-3") do
      safe_join([
        tag.div(class: "flex items-start justify-between gap-3") do
          safe_join([
            tag.div(class: "min-w-0") do
              safe_join([
                tag.p(row[:label].presence || "Weather city", class: "truncate font-mono text-sm font-black uppercase tracking-[0.06em] text-white"),
                tag.p(row[:market_ticker].to_s, class: "mt-1 truncate font-mono text-[10px] uppercase tracking-[0.08em] text-zinc-500")
              ])
            end,
            tag.span(sizing, class: "shrink-0 border border-dotted border-white/15 bg-black/45 px-2 py-1 font-mono text-[10px] font-black uppercase tracking-[0.08em] #{classes[:text]}")
          ])
        end,
        tag.div(class: "mt-3 grid grid-cols-4 gap-2 font-mono text-[10px] uppercase tracking-[0.08em]") do
          safe_join([
            weather_station_chip("conf", weather_station_percent(row[:confidence]), "text-cyan-100"),
            weather_station_chip("edge", weather_station_percent(row[:edge]), row[:edge].to_f.positive? ? "text-emerald-100" : "text-teal-100"),
            weather_station_chip("ask", weather_price_cents(row[:ask]), "text-yellow-100"),
            weather_station_chip("src", row[:source_count].presence || "n/a", "text-white")
          ])
        end,
        tag.p("#{temperature} // band #{row[:market]} // #{weather_station_close_label(row)}", class: "mt-3 font-mono text-[10px] uppercase leading-4 tracking-[0.07em] text-zinc-300"),
        (tag.p(rec[:reason].to_s.truncate(110), class: "mt-2 text-xs leading-4 text-white/56") if rec[:reason].present?)
      ].compact)
    end
  end

  def weather_station_chip(label, value, value_class)
    tag.div(class: "border border-dotted border-white/10 bg-black/35 px-2 py-1.5") do
      safe_join([
        tag.span(label, class: "block text-zinc-500"),
        tag.strong(value.to_s, class: "mt-1 block #{value_class}")
      ])
    end
  end

  def weather_station_percent(value)
    return "n/a" if value.blank?

    number_to_percentage(value.to_f * 100, precision: 0)
  end

  def weather_station_close_label(row)
    row = row.to_h
    date = row[:prediction_date]
    close_time = row[:close_time]
    close_label = close_time.present? ? weather_timeout_tag(close_time, compact: true) : "close pending"
    [date&.strftime("%b %-d"), close_label].compact.join(" // ")
  end

  def weather_station_status_label(status)
    {
      "live" => "live order",
      "ticket" => "ticketed",
      "candidate" => "candidate",
      "watch" => "watch",
      "won" => "won",
      "lost" => "lost",
      "pushed" => "pushed",
      "void" => "void",
      "settled" => "settled"
    }.fetch(status.to_s, status.to_s.presence || "watch")
  end

  def weather_station_status_classes(status)
    case status.to_s
    when "live"
      { dot: "border-emerald-50 bg-emerald-300 shadow-[0_0_20px_rgba(52,211,153,0.85)]", text: "text-emerald-100", border: "border-emerald-200/50", ring: "ring-2 ring-emerald-300/70 shadow-[0_0_24px_rgba(52,211,153,0.68)]" }
    when "ticket"
      { dot: "border-cyan-50 bg-cyan-300 shadow-[0_0_18px_rgba(34,211,238,0.72)]", text: "text-cyan-100", border: "border-cyan-200/45", ring: "ring-2 ring-cyan-300/70 shadow-[0_0_24px_rgba(34,211,238,0.62)]" }
    when "candidate"
      { dot: "border-yellow-50 bg-yellow-300 shadow-[0_0_18px_rgba(250,204,21,0.78)]", text: "text-yellow-100", border: "border-yellow-200/55", ring: "ring-2 ring-yellow-300/70 shadow-[0_0_24px_rgba(250,204,21,0.62)]" }
    when "won"
      { dot: "border-emerald-50 bg-emerald-500 shadow-[0_0_14px_rgba(16,185,129,0.65)]", text: "text-emerald-100", border: "border-emerald-200/40", ring: "ring-1 ring-emerald-300/45" }
    when "lost"
      { dot: "border-teal-50 bg-teal-400 shadow-[0_0_14px_rgba(94,234,212,0.65)]", text: "text-teal-100", border: "border-teal-200/45", ring: "ring-1 ring-teal-300/45" }
    else
      { dot: "border-fuchsia-50 bg-fuchsia-300 shadow-[0_0_14px_rgba(217,70,239,0.56)]", text: "text-fuchsia-100", border: "border-fuchsia-200/35", ring: "ring-1 ring-fuchsia-300/55 shadow-[0_0_18px_rgba(217,70,239,0.38)]" }
    end
  end

  def weather_winning_cities_panel(rows)
    rows = Array(rows)
    tag.div(class: "mt-4 border-2 border-dotted border-emerald-200/35 bg-emerald-950/10 p-4") do
      content = [
        tag.p("winning cities", class: "font-mono text-xs font-black uppercase tracking-[0.16em] text-emerald-100"),
        tag.p("Settled paper predictions ranked by wins, then hit rate. This keeps the lab focused on cities where AUTOS is actually scoring.", class: "mt-1 text-sm leading-5 text-white/64")
      ]
      content << if rows.present?
        tag.div(class: "mt-3 grid gap-2 lg:grid-cols-2") do
          safe_join(rows.map do |row|
            label = [row[:city], row[:state]].compact_blank.join(", ")
            stat = "#{number_with_delimiter(row[:wins].to_i)}W / #{number_with_delimiter(row[:losses].to_i)}L"
            rate = row[:hit_rate] ? "#{row[:hit_rate]}%" : "n/a"
            tag.div(class: "grid grid-cols-[minmax(0,1fr)_7rem_4rem] items-center gap-3 border border-dotted border-emerald-200/20 bg-black/35 px-3 py-2 font-mono text-xs uppercase tracking-[0.08em]") do
              safe_join([
                tag.span(label.presence || "Unknown", class: "truncate text-white/76"),
                tag.strong(stat, class: "text-right text-emerald-100"),
                tag.span(rate, class: "text-right text-emerald-200")
              ])
            end
          end)
        end
      else
        tag.p("No settled city wins yet.", class: "mt-3 font-mono text-xs uppercase tracking-[0.1em] text-zinc-500")
      end
      safe_join(content)
    end
  end

  def weather_small_row(label, value, value_class)
    tag.div(class: "grid grid-cols-[minmax(0,1fr)_5rem] items-center gap-3 border border-dotted border-white/10 bg-black/35 px-3 py-2 font-mono text-xs uppercase tracking-[0.08em]") do
      safe_join([
        tag.span(label.to_s, class: "truncate text-white/72"),
        tag.strong(value.to_s, class: "text-right #{value_class}")
      ])
    end
  end

  def weather_chart_key(label, color)
    colors = {
      "white" => "bg-white",
      "fuchsia" => "bg-fuchsia-300",
      "cyan" => "bg-cyan-300",
      "yellow" => "bg-yellow-300",
      "green" => "bg-emerald-400",
      "rose" => "bg-teal-400",
      "amber" => "bg-amber-300",
      "grid" => "border border-white/30 bg-zinc-500/40",
      "axis" => "bg-zinc-300",
      "band" => "border border-cyan-200/60 bg-cyan-300/20"
    }
    tag.span(class: "inline-flex items-center gap-2") do
      safe_join([
        tag.span("", class: "h-2.5 w-6 #{colors.fetch(color)}"),
        tag.span(label)
      ])
    end
  end

  def weather_market_series_list(series)
    rows = Array(series).first(4)
    return tag.p("No matching Kalshi series found yet.", class: "mt-3 text-xs leading-5 text-yellow-50/60") if rows.blank?

    tag.div(class: "mt-3 grid gap-2") do
      safe_join(rows.map do |item|
        tag.div(class: "border border-dotted border-white/15 bg-black/35 p-3") do
          safe_join([
            tag.div(class: "flex flex-wrap items-center justify-between gap-2") do
              safe_join([
                tag.strong(item[:title].to_s.presence || item[:ticker], class: "font-mono text-[10px] uppercase tracking-[0.12em] text-white"),
                tag.span(item[:frequency].to_s, class: "font-mono text-[9px] uppercase tracking-[0.12em] text-cyan-200")
              ])
            end,
            tag.p(item[:ticker].to_s, class: "mt-1 font-mono text-[9px] uppercase tracking-[0.12em] text-zinc-500")
          ])
        end
      end)
    end
  end

  def weather_market_rows(markets)
    rows = Array(markets).first(5)
    return tag.p("Live contract rows are rate-limited or closed right now.", class: "mt-3 text-xs leading-5 text-yellow-50/55") if rows.blank?

    tag.div(class: "mt-3 overflow-x-auto") do
      tag.table(class: "min-w-full border-collapse font-mono text-[9px] uppercase tracking-[0.08em]") do
        safe_join([
          tag.thead(class: "text-yellow-100/60") do
            tag.tr(class: "border-b border-dotted border-yellow-200/20") do
              safe_join([
                tag.th("contract", class: "px-2 py-2 text-left"),
                tag.th("bid/ask", class: "px-2 py-2 text-left"),
                tag.th("close", class: "px-2 py-2 text-left")
              ])
            end
          end,
          tag.tbody(class: "text-yellow-50/85") do
            safe_join(rows.map do |market|
              tag.tr(class: "border-b border-dotted border-white/10") do
                safe_join([
                  tag.td(market[:title].to_s.truncate(74), class: "px-2 py-2 normal-case tracking-normal"),
                  tag.td(weather_price_label(market), class: "px-2 py-2 text-cyan-200"),
                  tag.td(weather_close_label(market), class: "px-2 py-2 text-zinc-400")
                ])
              end
            end)
          end
        ])
      end
    end
  end

  def weather_score_class(score)
    base = "font-black "
    return "#{base}text-emerald-300" if score >= 70
    return "#{base}text-yellow-200" if score >= 45
    return "#{base}text-orange-200" if score >= 25

    "#{base}text-zinc-400"
  end

  def weather_price_label(market)
    bid = market[:yes_bid].presence
    ask = market[:yes_ask].presence
    last = market[:last_price].presence
    return ["bid #{bid || 'n/a'}", "ask #{ask || 'n/a'}"].join(" // ") if bid || ask
    return "last #{last}" if last

    "n/a"
  end

  def weather_close_label(market)
    value = market[:close_time].presence
    return "n/a" if value.blank?

    time = Time.zone.parse(value.to_s)
    time ? time.strftime("%b %-d %l:%M%p") : value.to_s
  rescue ArgumentError
    value.to_s
  end
end
