# GTK4 user interface

const PREVIEW_N = 768                       # preview raster (covers the whole 120 mm disc)
const BURN_DPI = 600
const BURN_N = round(Int, 120 / 25.4 * BURN_DPI)  # 2835 px == 120 mm at 600 dpi
const CACHE_DIR = joinpath(get(ENV, "XDG_CACHE_HOME", joinpath(homedir(), ".cache")), "lightscribe-studio")
const IMAGE_FILTER = "*.png, *.jpg, *.jpeg, *.bmp, *.gif, *.webp, *.tif, *.tiff, *.svg, *.PNG, *.JPG, *.JPEG"

const MODES = ["full", "content", "title"]
const QUALITIES = ["best", "medium", "draft"]
const TINTS = ["LightScribe", "Theme", "Mono"]

mutable struct App
    win::Any
    canvas::Any
    css::Any
    palette::Palette
    theme_stamp::Float64
    src_full::Union{Nothing,Matrix{Float32}}
    src_prev::Union{Nothing,Matrix{Float32}}
    srcpath::String
    adj::Adjustments
    preview::Union{Nothing,Matrix{Float32}}
    drive_preview::Union{Nothing,Matrix{Float32}}
    show_drive_preview::Bool
    surf::Any
    surf_data::Any
    mode::String
    quality::String
    tint::Int
    guides::Bool
    ghost::Bool
    elevate::Bool
    pending::Bool
    syncing::Bool
    sync_pending::Bool
    proc::Any
    started::Float64
    est_seconds::Int
    widgets::Dict{Symbol,Any}
    texts::Vector{TextLayer}
    sel::Int
    drag_text::Bool
    fonts::Vector{String}
    text_sync_pending::Bool
    # document / history
    undo::Vector{Dict{String,Any}}
    redo::Vector{Dict{String,Any}}
    committed::Dict{String,Any}
    saved_snap::Union{Nothing,Dict{String,Any}}
    docpath::String
    restoring::Bool
    commit_pending::Bool
    image_cache::Dict{String,Any}
    closed::Condition
    closing::Bool
    data::Any          # DataState for the DATA DISC page
    page::String
end

App() = App(nothing, nothing, nothing, load_palette(), theme_stamp(), nothing, nothing, "",
            Adjustments(), nothing, nothing, false, nothing, nothing, "full", "best", 1,
            true, true, true, false, false, false, nothing, 0.0, 0, Dict{Symbol,Any}(),
            TextLayer[], 0, false, String[], false,
            Dict{String,Any}[], Dict{String,Any}[], Dict{String,Any}(), nothing, "", false, false,
            Dict{String,Any}(), Condition(), false, nothing, "label")

# ───────────────────────────── image loading ─────────────────────────────

function load_image(path::AbstractString)
    pb = GdkPixbuf(path)
    pb = something(Gtk4.GdkPixbufLib.G_.apply_embedded_orientation(pb), pb)
    w = Gtk4.GdkPixbufLib.G_.get_width(pb); h = Gtk4.GdkPixbufLib.G_.get_height(pb)
    stride = Gtk4.GdkPixbufLib.G_.get_rowstride(pb); nch = Gtk4.GdkPixbufLib.G_.get_n_channels(pb)
    # keep the pixbuf alive while we read its raw buffer
    bytes = GC.@preserve pb begin
        ptr = ccall((:gdk_pixbuf_get_pixels, Gtk4.GdkPixbufLib.libgdkpixbuf), Ptr{UInt8}, (Ptr{Cvoid},), pb.handle)
        copy(unsafe_wrap(Array, ptr, Int(stride * (h - 1) + w * nch)))
    end
    luma_from_bytes(bytes, Int(w), Int(h), Int(stride), Int(nch))
end

# ───────────────────────────── rendering ─────────────────────────────

tint_colors(app::App) = begin
    p = app.palette
    if app.tint == 1
        ((0.84, 0.74, 0.45), (0.17, 0.15, 0.13))      # unburned gold dye, burned umber
    elseif app.tint == 2
        (hex2rgb(p["accent"]), hex2rgb(p["darker_background"]))
    else
        ((0.90, 0.90, 0.90), (0.07, 0.07, 0.07))
    end
end

function to_surface!(app::App, img::Matrix{Float32})
    base, burn = tint_colors(app)
    h, w = size(img)
    data = Matrix{UInt32}(undef, h, w)
    @inbounds for i in eachindex(img)
        v = img[i]
        r = round(UInt32, 255 * (burn[1] + (base[1] - burn[1]) * v))
        g = round(UInt32, 255 * (burn[2] + (base[2] - burn[2]) * v))
        b = round(UInt32, 255 * (burn[3] + (base[3] - burn[3]) * v))
        data[i] = 0xff000000 | (r << 16) | (g << 8) | b
    end
    app.surf_data = data
    app.surf = Cairo.CairoImageSurface(data, Cairo.FORMAT_RGB24)
end

has_text(app::App) = any(t -> !isempty(strip(t.text)), app.texts)
has_content(app::App) = app.src_prev !== nothing || has_text(app)

"Image (if any) with tone adjustments, then text layers on top, as an N×N disc raster."
function compose(app::App, src, N::Int)
    img = src === nothing ? fill(app.adj.background_white ? 1f0 : 0f0, N, N) : render_label(src, N, app.adj)
    draw_text!(img, app.texts)
end

function recompute!(app::App)
    img = if app.show_drive_preview && app.drive_preview !== nothing
        app.drive_preview
    elseif has_content(app)
        app.preview = compose(app, app.src_prev, PREVIEW_N)
    else
        nothing
    end
    img === nothing ? (app.surf = nothing) : to_surface!(app, img)
    app.canvas !== nothing && Gtk4.draw(app.canvas)
end

"Coalesce many slider events into one recompute on the next idle cycle."
function schedule!(app::App)
    touch!(app)
    app.pending && return
    app.pending = true
    Gtk4.GLib.g_idle_add() do
        app.pending = false
        try recompute!(app) catch err; logline(app, "render error: $(sprint(showerror, err))") end
        false
    end
end

setrgb(ctx, hex::AbstractString, a = 1.0) = (c = hex2rgb(hex); Cairo.set_source_rgba(ctx, c[1], c[2], c[3], a))

function annulus(ctx, cx, cy, r1, r2)
    Cairo.new_path(ctx)
    Cairo.arc(ctx, cx, cy, r2, 0, 2π)
    Cairo.new_sub_path(ctx)
    Cairo.arc_negative(ctx, cx, cy, r1, 2π, 0)
end

"Disc centre and radius (px) inside a W×H canvas."
disc_geom(W, H) = (W / 2, H / 2 - 8, 0.44 * min(W, H - 40))

function draw_disc(app::App, ctx, W, H)
    p = app.palette
    setrgb(ctx, p["dark_background"]); Cairo.paint(ctx)

    # faint grid in the stage, terminal style
    setrgb(ctx, p["muted"], 0.18); Cairo.set_line_width(ctx, 1)
    for x in 0:32:W; Cairo.move_to(ctx, x + 0.5, 0); Cairo.line_to(ctx, x + 0.5, H); end
    for y in 0:32:H; Cairo.move_to(ctx, 0, y + 0.5); Cairo.line_to(ctx, W, y + 0.5); end
    Cairo.stroke(ctx)

    cx, cy, R = disc_geom(W, H)
    R < 20 && return
    k = R / DISC_RADIUS_MM
    lo, hi = LABEL_AREAS[app.mode]

    # glow + disc body (clear polycarbonate)
    for (i, a) in enumerate((0.05, 0.08, 0.12))
        setrgb(ctx, p["accent"], a); Cairo.arc(ctx, cx, cy, R + 10 - 3i, 0, 2π); Cairo.fill(ctx)
    end
    setrgb(ctx, p["lighter_background"]); Cairo.arc(ctx, cx, cy, R, 0, 2π); Cairo.fill(ctx)

    # dye layer, unburned
    base, _ = tint_colors(app)
    Cairo.set_source_rgb(ctx, base...)
    annulus(ctx, cx, cy, HUB_RADIUS_MM * k, (DISC_RADIUS_MM - 0.4) * k)
    Cairo.fill(ctx)

    if app.surf !== nothing
        sz = app.surf_data === nothing ? PREVIEW_N : size(app.surf_data, 1)
        paint_img = (alpha) -> begin
            Cairo.save(ctx)
            Cairo.translate(ctx, cx - R, cy - R)
            Cairo.scale(ctx, 2R / sz, 2R / sz)
            Cairo.set_source_surface(ctx, app.surf, 0, 0)
            Cairo.pattern_set_filter(Cairo.get_source(ctx), Cairo.FILTER_GOOD)
            alpha >= 1 ? Cairo.paint(ctx) : Cairo.paint_with_alpha(ctx, alpha)
            Cairo.restore(ctx)
        end
        if app.ghost && !app.show_drive_preview
            Cairo.save(ctx); annulus(ctx, cx, cy, HUB_RADIUS_MM * k, (DISC_RADIUS_MM - 0.4) * k); Cairo.clip(ctx)
            paint_img(0.16); Cairo.restore(ctx)
        end
        Cairo.save(ctx); annulus(ctx, cx, cy, lo * k, hi * k); Cairo.clip(ctx)
        paint_img(1.0); Cairo.restore(ctx)
    end

    # hub: clear plastic with stacking ring
    setrgb(ctx, p["muted"], 0.9); Cairo.set_line_width(ctx, 1)
    for r in (HUB_RADIUS_MM, 17.0, 16.4, 11.0)
        Cairo.arc(ctx, cx, cy, r * k, 0, 2π); Cairo.stroke(ctx)
    end
    setrgb(ctx, p["dark_background"]); Cairo.arc(ctx, cx, cy, HOLE_RADIUS_MM * k, 0, 2π); Cairo.fill(ctx)
    setrgb(ctx, p["accent"], 0.6); Cairo.arc(ctx, cx, cy, HOLE_RADIUS_MM * k, 0, 2π); Cairo.stroke(ctx)
    setrgb(ctx, p["accent"], 0.9); Cairo.set_line_width(ctx, 1.2)
    Cairo.arc(ctx, cx, cy, R, 0, 2π); Cairo.stroke(ctx)

    Cairo.select_font_face(ctx, "Liberation Mono", Cairo.FONT_SLANT_NORMAL, Cairo.FONT_WEIGHT_NORMAL)
    Cairo.set_font_size(ctx, 10)

    if app.guides
        Cairo.set_line_width(ctx, 1); Cairo.set_dash(ctx, [5.0, 4.0])
        setrgb(ctx, p["bright_foreground"], 0.85)
        for r in (lo, hi); Cairo.arc(ctx, cx, cy, r * k, 0, 2π); Cairo.stroke(ctx); end
        Cairo.set_dash(ctx, Float64[])
        # crosshair ticks
        setrgb(ctx, p["accent"], 0.8)
        for (dx, dy) in ((1, 0), (-1, 0), (0, 1), (0, -1))
            Cairo.move_to(ctx, cx + dx * (R + 14), cy + dy * (R + 14))
            Cairo.line_to(ctx, cx + dx * (R + 26), cy + dy * (R + 26))
        end
        Cairo.stroke(ctx)
        # radius labels on a leader to the right
        for r in (lo, hi)
            x = cx + r * k * cos(-π / 5); y = cy + r * k * sin(-π / 5)
            setrgb(ctx, p["bright_foreground"]); Cairo.arc(ctx, x, y, 2.5, 0, 2π); Cairo.fill(ctx)
            Cairo.move_to(ctx, x + 6, y - 4)
            setrgb(ctx, p["darker_background"], 0.85)
            txt = "R$(r)"
            ext = Cairo.text_extents(ctx, txt)
            Cairo.rectangle(ctx, x + 4, y - 15, ext[3] + 6, 14); Cairo.fill(ctx)
            setrgb(ctx, p["accent"]); Cairo.move_to(ctx, x + 7, y - 4); Cairo.show_text(ctx, txt)
        end
    end

    # marker on the selected text layer
    if app.guides && 1 <= app.sel <= length(app.texts) && !app.show_drive_preview
        ax, ay = layer_anchor(app.texts[app.sel])
        mx, my = cx + ax * k, cy + ay * k
        Cairo.new_path(ctx)
        setrgb(ctx, p["bright_foreground"]); Cairo.set_line_width(ctx, 1.5)
        Cairo.arc(ctx, mx, my, 6, 0, 2π); Cairo.stroke(ctx)
        setrgb(ctx, p["accent"])
        for (dx, dy) in ((1, 0), (-1, 0), (0, 1), (0, -1))
            Cairo.move_to(ctx, mx + 8dx, my + 8dy); Cairo.line_to(ctx, mx + 13dx, my + 13dy)
        end
        Cairo.stroke(ctx)
    end

    if app.surf === nothing
        msg = "OPEN AN IMAGE (CTRL+O) OR ADD TEXT"
        Cairo.set_font_size(ctx, 13)
        ext = Cairo.text_extents(ctx, msg)
        setrgb(ctx, p["darker_background"], 0.9)
        Cairo.rectangle(ctx, cx - ext[3] / 2 - 10, cy - (lo + hi) / 2 * k - 14, ext[3] + 20, 22); Cairo.fill(ctx)
        setrgb(ctx, p["accent"]); Cairo.move_to(ctx, cx - ext[3] / 2, cy - (lo + hi) / 2 * k + 2)
        Cairo.show_text(ctx, msg)
    end

    # footer readout
    Cairo.set_font_size(ctx, 10)
    src = app.show_drive_preview && app.drive_preview !== nothing ? "DRIVE PREVIEW" : "SIMULATION"
    foot = "$(src)  ·  MODE $(uppercase(app.mode))  ·  R $(lo)–$(hi) MM  ·  $(uppercase(app.quality))  ·  $(BURN_DPI) DPI"
    setrgb(ctx, p["dark_foreground"]); Cairo.move_to(ctx, 14, H - 12); Cairo.show_text(ctx, foot)
end

# ───────────────────────────── widgets helpers ─────────────────────────────

function section(title::AbstractString)
    box = GtkBox(:v; spacing = 6)
    add_css_class(box, "section")
    l = GtkLabel(uppercase(title); xalign = 0); add_css_class(l, "section-title")
    push!(box, l)
    box
end

function field_label(t)
    l = GtkLabel(uppercase(t); xalign = 0); add_css_class(l, "field-label"); l
end

function slider!(app::App, box, key::Symbol, label, lo, hi, stepv, digits; tip = "")
    push!(box, field_label(label))
    s = GtkScale(:h, lo, hi, stepv; draw_value = true, digits = digits, hexpand = true)
    Gtk4.G_.set_value_pos(s, Gtk4.PositionType_RIGHT)
    Gtk4.G_.set_value(s, getfield(app.adj, key))
    isempty(tip) || (s.tooltip_text = tip)
    signal_connect(s, "value-changed") do w
        app.syncing && return nothing   # widget catching up with app.adj
        setfield!(app.adj, key, Gtk4.G_.get_value(w))
        app.show_drive_preview = false
        schedule!(app)
        nothing
    end
    # double-click resets to default
    g = GtkGestureClick(s)
    signal_connect(g, "pressed") do ctrl, n, x, y
        n == 2 && set_slider(app, key, getfield(Adjustments(), key))
        nothing
    end
    app.widgets[key] = s
    push!(box, s)
    s
end

function check!(app::App, box, key::Symbol, label; tip = "")
    c = GtkCheckButton(label)
    c.active = getfield(app.adj, key)
    isempty(tip) || (c.tooltip_text = tip)
    signal_connect(c, "toggled") do w
        app.syncing && return nothing
        setfield!(app.adj, key, w.active)
        app.show_drive_preview = false
        schedule!(app)
        nothing
    end
    app.widgets[key] = c
    push!(box, c)
    c
end

function dropdown(items, onchange)
    dd = GtkDropDown(items; hexpand = true)
    signal_connect(dd, "notify::selected") do w, _
        onchange(Gtk4.G_.get_selected(w) + 1); nothing
    end
    dd
end

function hrow(widgets...; spacing = 6, homogeneous = false)
    b = GtkBox(:h; spacing, homogeneous)
    for w in widgets; push!(b, w); end
    b
end

"""
Change an adjustment from code (gestures, buttons). Gtk4.jl cannot run a Julia signal
handler from inside another one (it trips an assertion and segfaults), so we never touch
the slider widgets here: update the model now and let `sync_widgets!` move the widgets
on the next idle cycle, which is not inside any signal emission.
"""
function set_slider(app::App, key::Symbol, v)
    setfield!(app.adj, key, v)
    app.show_drive_preview = false
    schedule!(app)
    sync_widgets!(app)
end

function sync_widgets!(app::App)
    app.sync_pending && return
    app.sync_pending = true
    Gtk4.GLib.g_idle_add() do
        app.sync_pending = false
        app.syncing = true
        try
            for k in fieldnames(Adjustments)
                w = get(app.widgets, k, nothing)
                v = getfield(app.adj, k)
                if w isa GtkScale
                    abs(Gtk4.G_.get_value(w) - v) > 1e-9 && Gtk4.G_.set_value(w, v)
                elseif w isa GtkCheckButton
                    w.active != v && (w.active = v)
                end
            end
        finally
            app.syncing = false
        end
        false
    end
    nothing
end

function logline(app::App, s::AbstractString)
    buf = get(app.widgets, :logbuf, nothing)
    buf === nothing && (println(s); return)
    endit = Gtk4.GtkTextIter(buf, length(buf) + 1)
    insert!(buf, endit, rstrip(s) * "\n")
    tv = app.widgets[:logview]
    Gtk4.G_.scroll_to_mark(tv, Gtk4.G_.get_insert(buf), 0.0, false, 0.0, 1.0)
end

function set_status(app::App, text, kind = "idle")
    l = app.widgets[:status]
    l.label = uppercase(text)
    for c in ("idle", "busy", "ok"); Gtk4.remove_css_class(l, c); end
    add_css_class(l, kind)
end

function set_busy(app::App, busy::Bool)
    for k in (:burn, :drivepreview, :eject, :close, :mediainfo, :scan)
        haskey(app.widgets, k) && (app.widgets[k].sensitive = !busy)
    end
    app.widgets[:cancel].visible = busy
    busy || update_actions!(app)
end

"Burn / drive preview need something to print and no job running."
function update_actions!(app::App)
    ok = has_content(app) && app.proc === nothing
    for k in (:burn, :drivepreview)
        haskey(app.widgets, k) && (app.widgets[k].sensitive = ok)
    end
end

# ───────────────────────────── actions ─────────────────────────────

"Run `f` on a later main-loop iteration, outside whatever GTK signal is currently being emitted."
function later(f::Function, app::App)
    Gtk4.GLib.g_idle_add() do
        try
            f()
        catch err
            logline(app, "error: $(sprint(showerror, err))")
        end
        false
    end
    nothing
end
later(app::App, f::Function) = later(f, app)

function open_image!(app::App, path::AbstractString)
    try
        set_image!(app, abspath(path)) || return
        app.show_drive_preview = false
        h, w = size(app.src_full)
        logline(app, "loaded $(path) ($(w)×$(h))")
        update_actions!(app)
        recompute!(app)
        touch!(app)
    catch err
        logline(app, "could not open $(path): $(sprint(showerror, err))")
    end
end

drive(app::App) = String(strip(app.widgets[:drive].text))

function export_bmp(app::App)
    mkpath(CACHE_DIR)
    out = joinpath(CACHE_DIR, "label-$(BURN_N)px-$(BURN_DPI)dpi.bmp")
    write_bmp(out, compose(app, app.src_full, BURN_N))
end

function print_args(app::App, sub::String)
    ["$sub", "-q", app.quality, "-m", app.mode, "-s", string(BURN_DPI)]
end

function run_job!(app::App, args::AbstractVector, title::AbstractString; on_ok = () -> nothing)
    args = String[string(a) for a in args]
    app.proc === nothing || return
    set_busy(app, true); set_status(app, title, "busy")
    pb = app.widgets[:progress]; pb.fraction = 0.0; pb.text = "WAITING FOR AUTH"
    app.started = time(); app.est_seconds = 0
    logline(app, "\$ 4L-cli " * join(args, " "))
    stage = Ref("")
    on_line = line -> begin
        line = strip(line)
        startswith(line, "Using /etc/lightscribe") && return
        m = match(r"^(\w[\w ]*):\s*(\d+)%", line)
        if m !== nothing
            stage[] = m.captures[1]
            pct = parse(Int, m.captures[2])
            pb.fraction = stage[] == "Printing" ? pct / 100 : 0.0
            pb.text = "$(uppercase(stage[])) $(pct)%"
            if stage[] == "Printing" && app.est_seconds > 0
                left = round(Int, app.est_seconds * (1 - pct / 100))
                pb.text *= " · ~$(left ÷ 60)M $(lpad(left % 60, 2, '0'))S LEFT"
            end
            stage[] == "Printing" && pct % 10 != 0 && return  # keep the log terse
        end
        m2 = match(r"Estimated print time:\s*(\d+)", line)
        m2 !== nothing && (app.est_seconds = parse(Int, m2.captures[1]))
        logline(app, line)
    end
    on_done = ok -> begin
        app.proc = nothing
        set_busy(app, false)
        el = round(Int, time() - app.started)
        if ok
            set_status(app, "done", "ok"); pb.fraction = 1.0; pb.text = "COMPLETE · $(el ÷ 60)M $(el % 60)S"
            on_ok()
        else
            set_status(app, "failed", "idle"); pb.text = "FAILED / CANCELLED"
            logline(app, "job ended with an error (see output above)")
        end
    end
    try
        app.proc = cli_spawn(args, on_line, on_done; elevate = app.elevate)
    catch err
        logline(app, "could not start 4L-cli: $(sprint(showerror, err))")
        app.proc = nothing; set_busy(app, false); set_status(app, "error", "idle")
    end
end

function burn!(app::App)
    has_content(app) || return
    d = drive(app)
    isempty(d) && (logline(app, "no drive selected"); return)
    lo, hi = LABEL_AREAS[app.mode]
    q = "Burn label to $(d)?\n\nMode $(app.mode) (R $(lo)–$(hi) mm), quality $(app.quality).\nThe disc must be label-side down. A full-disc best-quality burn can take 20–30 minutes."
    ask_dialog(q, app.win; no_text = "Cancel", yes_text = "Burn") do yes
        yes || return
        later(app) do
            logline(app, "rendering $(BURN_N)×$(BURN_N) BMP …")
            path = export_bmp(app)
            logline(app, "wrote $(path)")
            run_job!(app, vcat(print_args(app, "print"), [d, path]), "burning")
        end
    end
end

function drive_preview!(app::App)
    has_content(app) || return
    d = drive(app)
    isempty(d) && (logline(app, "no drive selected"); return)
    path = export_bmp(app)
    mkpath(CACHE_DIR)
    out = joinpath(CACHE_DIR, "drive-preview.bmp")
    isfile(out) && rm(out)
    run_job!(app, vcat(print_args(app, "preview"), ["-o", out, "-p", string(PREVIEW_N), d, path]), "previewing";
             on_ok = () -> begin
                 if isfile(out)
                     app.drive_preview = read_bmp(out)
                     app.show_drive_preview = true
                     logline(app, "showing 4L's own preview (move any slider to return to the simulation)")
                     recompute!(app)
                 end
             end)
end

function quick!(app::App, sub::String)
    d = drive(app)
    isempty(d) && (logline(app, "no drive selected"); return)
    run_job!(app, [sub, d], sub)
end

function scan!(app::App)
    logline(app, "scanning for LightScribe drives …")
    @async begin
        ds = find_drives(; elevate = false)
        if isempty(ds)
            logline(app, "no optical drives found — connect the drive and press SCAN")
        else
            logline(app, "found: " * join(ds, ", "))
            isempty(drive(app)) && (app.widgets[:drive].text = first(ds))
        end
    end
end

function reset_adjustments!(app::App)
    d = Adjustments()
    for k in fieldnames(Adjustments)
        setfield!(app.adj, k, getfield(d, k))
    end
    app.show_drive_preview = false
    schedule!(app)
    sync_widgets!(app)
end

# ───────────────────────────── text layers ─────────────────────────────

current_text(app::App) = 1 <= app.sel <= length(app.texts) ? app.texts[app.sel] : nothing

function text_changed!(app::App)
    app.show_drive_preview = false
    schedule!(app)
    update_actions!(app)
end

"Change a field of the selected layer from code (drag/scroll/buttons); widgets follow on idle."
function set_text_field!(app::App, key::Symbol, v)
    L = current_text(app)
    L === nothing && return
    setfield!(L, key, v)
    text_changed!(app)
    sync_text_widgets!(app)
end

layer_name(i, L) = (t = replace(strip(L.text), r"\s+" => " "); "$(i) · " * (isempty(t) ? "(empty)" : first(t, 22)))

const TEXT_SLIDERS = (:size, :radius, :angle, :x, :y, :spacing)

"Push the selected layer's values into the Text panel widgets (idle, never inside a signal)."
function sync_text_widgets!(app::App)
    app.text_sync_pending && return
    app.text_sync_pending = true
    Gtk4.GLib.g_idle_add() do
        app.text_sync_pending = false
        app.syncing = true
        try
            W = app.widgets
            names = isempty(app.texts) ? ["no text yet"] : [layer_name(i, L) for (i, L) in enumerate(app.texts)]
            dd = W[:t_layer]
            Gtk4.G_.set_model(dd, Gtk4.GListModel(GtkStringList(names)))
            Gtk4.G_.set_selected(dd, max(app.sel, 1) - 1)
            L = current_text(app)
            for k in (:t_text, :t_font, :t_bold, :t_italic, :t_path, :t_ink, :t_del, :t_dup, (Symbol("t_", k) for k in TEXT_SLIDERS)...)
                W[k].sensitive = L !== nothing
            end
            W[:t_dragmode].active = app.drag_text
            if L !== nothing
                buf = W[:t_buf]
                cur = Gtk4.G_.get_text(buf, Gtk4.GtkTextIter(buf, 1), Gtk4.GtkTextIter(buf, length(buf) + 1), false)
                cur != L.text && (buf[String] = L.text)
                fi = findfirst(==(L.font), app.fonts)
                fi === nothing || Gtk4.G_.set_selected(W[:t_font], fi - 1)
                for k in TEXT_SLIDERS
                    sl = W[Symbol("t_", k)]; v = getfield(L, k)
                    abs(Gtk4.G_.get_value(sl) - v) > 1e-9 && Gtk4.G_.set_value(sl, v)
                end
                W[:t_bold].active = L.bold; W[:t_italic].active = L.italic
                Gtk4.G_.set_selected(W[:t_path], findfirst(==(L.path), TEXT_PATHS) - 1)
                Gtk4.G_.set_selected(W[:t_ink], L.clear ? 1 : 0)
                straight = L.path == "straight"
                W[:t_x].sensitive = straight; W[:t_y].sensitive = straight
                W[:t_radius].sensitive = !straight
                W[:t_anglelbl].label = straight ? "ROTATION °" : "POSITION ON RING ° (0 = TOP)"
            end
        catch err
            logline(app, "text panel error: $(sprint(showerror, err))")
        finally
            app.syncing = false
        end
        Gtk4.draw(app.canvas)
        false
    end
    nothing
end

function add_text!(app::App; duplicate = false)
    L = if duplicate && current_text(app) !== nothing
        c = deepcopy(current_text(app))
        c.path == "straight" ? (c.y += c.size * 1.4) : (c.radius = max(c.radius - c.size * 1.3, 20.0))
        c
    else
        default_layer(length(app.texts) + 1)
    end
    push!(app.texts, L)
    app.sel = length(app.texts)
    app.drag_text = true
    text_changed!(app); sync_text_widgets!(app)
end

function delete_text!(app::App)
    current_text(app) === nothing && return
    deleteat!(app.texts, app.sel)
    app.sel = min(app.sel, length(app.texts))
    isempty(app.texts) && (app.drag_text = false)
    text_changed!(app); sync_text_widgets!(app)
end

function apply_theme!(app::App)
    app.palette = load_palette()
    disp = Gtk4.display(app.win)
    app.css === nothing || delete!(disp, app.css)
    app.css = GtkCssProvider(theme_css(app.palette))
    push!(disp, app.css, 800)
    app.surf_data === nothing || recompute!(app)
    Gtk4.draw(app.canvas)
end

# ───────────────────────────── layout ─────────────────────────────

function tslider!(app::App, box, key::Symbol, label, lo, hi, stepv, digits; tip = "")
    lbl = field_label(label); push!(box, lbl)
    s = GtkScale(:h, lo, hi, stepv; draw_value = true, digits = digits, hexpand = true)
    Gtk4.G_.set_value_pos(s, Gtk4.PositionType_RIGHT)
    Gtk4.G_.set_value(s, getfield(TextLayer(), key))
    isempty(tip) || (s.tooltip_text = tip)
    signal_connect(s, "value-changed") do w
        app.syncing && return nothing
        L = current_text(app); L === nothing && return nothing
        setfield!(L, key, Gtk4.G_.get_value(w))
        text_changed!(app); nothing
    end
    app.widgets[Symbol("t_", key)] = s
    push!(box, s)
    lbl
end

function build_text_panel!(app::App, side)
    s = section("04 · Text")
    W = app.widgets
    app.fonts = font_families()

    layerdd = GtkDropDown(["no text yet"]; hexpand = true)
    W[:t_layer] = layerdd
    signal_connect(layerdd, "notify::selected") do w, _
        app.syncing && return nothing
        i = Gtk4.G_.get_selected(w) + 1
        1 <= i <= length(app.texts) && (app.sel = i; sync_text_widgets!(app))
        nothing
    end
    addb = GtkButton("ADD"); dupb = GtkButton("DUPLICATE"); delb = GtkButton("DELETE")
    W[:t_dup] = dupb; W[:t_del] = delb
    signal_connect(_ -> (add_text!(app); nothing), addb, "clicked")
    signal_connect(_ -> (add_text!(app; duplicate = true); nothing), dupb, "clicked")
    signal_connect(_ -> (delete_text!(app); nothing), delb, "clicked")
    push!(s, layerdd, hrow(addb, dupb, delb; homogeneous = true))

    dm = GtkCheckButton("Drag / scroll on disc edits this text")
    dm.tooltip_text = "On: dragging moves the selected text and scrolling resizes it. Off: they move/zoom the image."
    W[:t_dragmode] = dm
    signal_connect(dm, "toggled") do w
        app.syncing || (app.drag_text = w.active); nothing
    end
    push!(s, dm)

    push!(s, field_label("Text"))
    buf = GtkTextBuffer()
    tv = GtkTextView(; buffer = buf, wrap_mode = Gtk4.WrapMode_WORD_CHAR, left_margin = 6, top_margin = 4,
                     bottom_margin = 4, accepts_tab = false)
    tsw = GtkScrolledWindow(; height_request = 52); tsw[] = tv; add_css_class(tsw, "log")
    tv.tooltip_text = "Enter makes a new line (straight text only)"
    buf.enable_undo = false   # Ctrl+Z is the app-wide undo
    W[:t_buf] = buf; W[:t_text] = tv
    signal_connect(buf, "changed") do b
        app.syncing && return nothing
        L = current_text(app); L === nothing && return nothing
        L.text = Gtk4.G_.get_text(b, Gtk4.GtkTextIter(b, 1), Gtk4.GtkTextIter(b, length(b) + 1), false)
        text_changed!(app)
        sync_text_widgets!(app)   # refresh the layer name in the list
        nothing
    end
    push!(s, tsw)

    fontdd = GtkDropDown(app.fonts; hexpand = true)
    try
        Gtk4.G_.set_expression(fontdd, Gtk4.GtkPropertyExpression(Gtk4.GtkStringObject, "string"))
        fontdd.enable_search = true
    catch
    end
    W[:t_font] = fontdd
    signal_connect(fontdd, "notify::selected") do w, _
        app.syncing && return nothing
        L = current_text(app); L === nothing && return nothing
        i = Gtk4.G_.get_selected(w) + 1
        1 <= i <= length(app.fonts) && (L.font = app.fonts[i]; text_changed!(app))
        nothing
    end
    push!(s, field_label("Font"), fontdd)
    b = GtkCheckButton("Bold"); it = GtkCheckButton("Italic")
    W[:t_bold] = b; W[:t_italic] = it
    for (cb, key) in ((b, :bold), (it, :italic))
        signal_connect(cb, "toggled") do w
            app.syncing && return nothing
            L = current_text(app); L === nothing && return nothing
            setfield!(L, key, w.active); text_changed!(app); nothing
        end
    end
    push!(s, hrow(b, it))

    pathdd = GtkDropDown(["Straight", "Arc · top", "Arc · bottom"]; hexpand = true)
    inkdd = GtkDropDown(["Burn", "Knock out"]; hexpand = true)
    inkdd.tooltip_text = "Knock out = leave the text unburned on top of a dark image"
    W[:t_path] = pathdd; W[:t_ink] = inkdd
    signal_connect(pathdd, "notify::selected") do w, _
        app.syncing && return nothing
        L = current_text(app); L === nothing && return nothing
        np = TEXT_PATHS[Gtk4.G_.get_selected(w) + 1]
        # keep the text upright where it lands: bottom arcs live around 180°
        np == "arc_bottom" && abs(L.angle) < 90 && (L.angle = 180.0)
        np == "arc_top" && abs(L.angle) > 90 && (L.angle = 0.0)
        np == "straight" && L.path != "straight" && (L.angle = 0.0)
        L.path = np
        text_changed!(app); sync_text_widgets!(app); nothing
    end
    signal_connect(inkdd, "notify::selected") do w, _
        app.syncing && return nothing
        L = current_text(app); L === nothing && return nothing
        L.clear = Gtk4.G_.get_selected(w) == 1; text_changed!(app); nothing
    end
    pbox = GtkBox(:v; spacing = 4, hexpand = true); push!(pbox, field_label("Path"), pathdd)
    ibox = GtkBox(:v; spacing = 4, hexpand = true); push!(ibox, field_label("Ink"), inkdd)
    push!(s, hrow(pbox, ibox; homogeneous = true))

    tslider!(app, s, :size, "Size (mm)", 1, 30, 0.1, 1)
    tslider!(app, s, :radius, "Radius (mm)", 10, 60, 0.1, 1; tip = "Distance of the text band from the centre")
    W[:t_anglelbl] = tslider!(app, s, :angle, "Position on ring ° (0 = top)", -180, 180, 0.5, 1)
    tslider!(app, s, :x, "X (mm)", -60, 60, 0.1, 1)
    tslider!(app, s, :y, "Y (mm)", -60, 60, 0.1, 1)
    tslider!(app, s, :spacing, "Letter spacing (mm)", -2, 6, 0.05, 2)
    push!(side, s)
    sync_text_widgets!(app)
end

function build!(app::App)
    win = GtkWindow("LightScribe Studio", 1360, 880)
    app.win = win
    root = GtkBox(:v)
    win[] = root

    # top bar
    brand = GtkLabel("LIGHTSCRIBE"); add_css_class(brand, "brand")
    sub = GtkLabel("LABEL REFINEMENT  //  4L-CLI"); add_css_class(sub, "brand-sub")
    spacer = GtkBox(:h; hexpand = true)
    status = GtkLabel("IDLE"); add_css_class(status, "status-pill"); add_css_class(status, "idle")
    app.widgets[:status] = status
    themelbl = GtkLabel("THEME " * uppercase(app.palette.name)); add_css_class(themelbl, "dim")
    app.widgets[:themelbl] = themelbl
    doct = GtkLabel("UNTITLED"); add_css_class(doct, "doctitle"); app.widgets[:doctitle] = doct
    tools = GtkBox(:h; spacing = 4)
    for (key, label, tip, f) in (
            (:new, "NEW", "New label (Ctrl+N)", () -> confirm_discard(() -> new_label!(app), app, "start a new label")),
            (:open, "OPEN…", "Open a label or an image (Ctrl+O)", () -> open_any_dialog!(app)),
            (:save, "SAVE", "Save label (Ctrl+S)", () -> save_or_ask!(app)),
            (:saveas, "SAVE AS…", "Save label as (Ctrl+Shift+S)", () -> save_as_dialog!(app)),
            (:export, "EXPORT…", "Export the label as a 600 dpi PNG/BMP (Ctrl+E)", () -> export_dialog!(app)),
            (:undo, "↶ UNDO", "Undo (Ctrl+Z)", () -> later(() -> undo!(app), app)),
            (:redo, "↷ REDO", "Redo (Ctrl+Shift+Z / Ctrl+Y)", () -> later(() -> redo!(app), app)))
        b = GtkButton(label); b.tooltip_text = tip; add_css_class(b, "tool")
        signal_connect(_ -> (f(); nothing), b, "clicked")
        app.widgets[key] = b
        key in (:export, :saveas) && push!(tools, GtkSeparator(:v))
        push!(tools, b)
    end
    stack = GtkStack(; vexpand = true, transition_type = Gtk4.StackTransitionType_CROSSFADE, transition_duration = 120)
    app.widgets[:stack] = stack
    switcher = GtkStackSwitcher(; stack = stack); add_css_class(switcher, "pages")
    app.widgets[:tools] = tools; app.widgets[:brandsub] = sub
    top = hrow(brand, switcher, sub, doct, spacer, tools, themelbl, status; spacing = 16)
    add_css_class(top, "topbar")
    push!(root, top)
    push!(root, stack)

    body = GtkBox(:h; vexpand = true)
    push!(stack, body, "label", "LABEL")
    push!(stack, build_data_page!(app), "data", "DATA DISC")
    signal_connect(stack, "notify::visible-child-name") do st, _
        later(app) do
            app.page = something(Gtk4.G_.get_visible_child_name(stack), "label")
            lbl = app.page == "label"
            tools.visible = lbl; doct.visible = lbl
            sub.label = lbl ? "LABEL REFINEMENT  //  4L-CLI" : "PHOTO ARCHIVE  //  XORRISO"
            lbl || data_page_shown!(app)
        end
        nothing
    end

    # stage
    canvas = GtkCanvas(300, 300; hexpand = true, vexpand = true)
    add_css_class(canvas, "stage")
    app.canvas = canvas
    @guarded draw(canvas) do w
        draw_disc(app, getgc(w), width(w), height(w))
    end
    push!(body, canvas)

    # drag to pan, scroll to zoom
    drag = GtkGestureDrag(canvas); app.widgets[:drag] = drag
    start = Ref((0.0, 0.0))
    tstart = Ref((0.0, 0.0, 0.0, 0.0))   # text layer x, y, angle, radius at drag start
    pstart = Ref((0.0, 0.0))             # pointer at drag start, mm from disc centre
    signal_connect(drag, "drag-begin") do g, x, y
        start[] = (app.adj.offset_x, app.adj.offset_y)
        cx, cy, R = disc_geom(width(canvas), height(canvas)); k = R / DISC_RADIUS_MM
        pstart[] = ((x - cx) / k, (y - cy) / k)
        L = current_text(app)
        L === nothing || (tstart[] = (L.x, L.y, L.angle, L.radius))
        nothing
    end
    signal_connect(drag, "drag-update") do g, dx, dy
        cx, cy, R = disc_geom(width(canvas), height(canvas)); k = R / DISC_RADIUS_MM
        L = current_text(app)
        if app.drag_text && L !== nothing
            x0, y0, a0, r0 = tstart[]
            p0x, p0y = pstart[]; p1x, p1y = p0x + dx / k, p0y + dy / k
            if L.path == "straight"
                L.x = clamp(x0 + dx / k, -60.0, 60.0); L.y = clamp(y0 + dy / k, -60.0, 60.0)
            else
                da = rad2deg(atan(p1x, -p1y) - atan(p0x, -p0y))
                L.angle = mod(a0 + da + 180, 360) - 180
                L.radius = clamp(r0 + hypot(p1x, p1y) - hypot(p0x, p0y), 10.0, 60.0)
            end
            text_changed!(app); sync_text_widgets!(app)
        else
            set_slider(app, :offset_x, clamp(start[][1] + dx / (2R), -0.5, 0.5))
            set_slider(app, :offset_y, clamp(start[][2] + dy / (2R), -0.5, 0.5))
        end
        nothing
    end
    scroll = GtkEventControllerScroll(Gtk4.EventControllerScrollFlags_VERTICAL, canvas); app.widgets[:scroll] = scroll
    signal_connect(scroll, "scroll") do c, dx, dy
        L = current_text(app)
        if app.drag_text && L !== nothing
            set_text_field!(app, :size, clamp(L.size * 1.06^(-dy), 1.0, 30.0))
        else
            set_slider(app, :zoom, clamp(app.adj.zoom * 1.06^(-dy), 0.2, 5.0))
        end
        true
    end

    # sidebar
    side = GtkBox(:v; spacing = 0)
    add_css_class(side, "sidebar")
    sw = GtkScrolledWindow(; hscrollbar_policy = Gtk4.PolicyType_NEVER, vexpand = true)
    sw.width_request = 360
    sw[] = side
    push!(body, sw)
    push!(side, GtkBox(:v; height_request = 10))

    # SOURCE
    s = section("01 · Source")
    openb = GtkButton("OPEN IMAGE…"); openb.tooltip_text = "Ctrl+O"
    fname = GtkLabel("—"; xalign = 0, ellipsize = Gtk4.Pango.EllipsizeMode_MIDDLE); add_css_class(fname, "filename")
    info = GtkLabel(""; xalign = 0); add_css_class(info, "dim")
    app.widgets[:filename] = fname; app.widgets[:imginfo] = info
    open_cb = () -> open_dialog("Open label image", win, (IMAGE_FILTER,)) do f
        # the dialog is still mid-signal here; load once it has been torn down
        (f isa AbstractString && !isempty(f)) && later(() -> open_image!(app, f), app)
        nothing
    end
    signal_connect(_ -> (open_cb(); nothing), openb, "clicked")
    push!(s, openb, fname, info)
    push!(side, s)

    # PLACEMENT
    s = section("02 · Placement")
    slider!(app, s, :zoom, "Zoom", 0.2, 5.0, 0.01, 2; tip = "Scroll on the disc to zoom")
    fillb = GtkButton("FILL DISC"); fitb = GtkButton("FIT WHOLE IMAGE"); centerb = GtkButton("CENTER")
    fillb.tooltip_text = "Short side spans the disc (crops the long side)"
    fitb.tooltip_text = "Long side spans the disc (nothing cropped)"
    signal_connect(_ -> (set_slider(app, :zoom, 1.0); nothing), fillb, "clicked")
    signal_connect(fitb, "clicked") do _
        app.src_prev === nothing && return
        h, w = size(app.src_prev)
        set_slider(app, :zoom, min(h, w) / max(h, w)); nothing
    end
    signal_connect(centerb, "clicked") do _
        set_slider(app, :offset_x, 0.0); set_slider(app, :offset_y, 0.0); nothing
    end
    push!(s, hrow(fillb, fitb, centerb; homogeneous = false))
    app.widgets[:fill] = fillb; app.widgets[:fit] = fitb; app.widgets[:center] = centerb
    slider!(app, s, :rotate, "Rotate °", -180, 180, 0.5, 1)
    slider!(app, s, :offset_x, "Offset X", -0.5, 0.5, 0.005, 3; tip = "Drag the disc to move the image")
    slider!(app, s, :offset_y, "Offset Y", -0.5, 0.5, 0.005, 3)
    c1 = check!(app, s, :flip, "Mirror")
    c2 = check!(app, s, :background_white, "Blank outside image"; tip = "Off = burn (black) where the image doesn't reach")
    push!(side, s)

    # ADJUST
    s = section("03 · Tone")
    slider!(app, s, :brightness, "Brightness", -1, 1, 0.01, 2)
    slider!(app, s, :contrast, "Contrast", -1, 1, 0.01, 2)
    slider!(app, s, :gamma, "Gamma", 0.2, 3.0, 0.01, 2)
    slider!(app, s, :sharpen, "Sharpen", 0, 3, 0.05, 2)
    check!(app, s, :invert, "Invert")
    check!(app, s, :threshold, "Threshold (pure black/white)")
    slider!(app, s, :threshold_level, "Threshold level", 0.0, 1.0, 0.01, 2)
    check!(app, s, :dither, "Dither (Floyd–Steinberg)"; tip = "LightScribe already halftones; dithering can give crisper line art")
    autob = GtkButton("AUTO LEVELS"); resetb = GtkButton("RESET")
    signal_connect(autob, "clicked") do _
        app.src_prev === nothing && return
        app.adj.black_point, app.adj.white_point = auto_levels(app.src_prev)
        logline(app, "auto levels: black $(round(app.adj.black_point, digits=3)), white $(round(app.adj.white_point, digits=3))")
        schedule!(app); nothing
    end
    signal_connect(_ -> (reset_adjustments!(app); nothing), resetb, "clicked"); app.widgets[:reset] = resetb
    push!(s, hrow(autob, resetb; homogeneous = true))
    push!(side, s)

    # VIEW
    build_text_panel!(app, side)

    s = section("05 · View")
    tintdd = dropdown(TINTS, i -> (app.tint = i; recompute!(app)))
    push!(s, field_label("Disc simulation"), tintdd)
    g1 = GtkCheckButton("Guides"; active = true)
    g2 = GtkCheckButton("Ghost cropped area"; active = true)
    signal_connect(w -> (app.guides = w.active; Gtk4.draw(canvas); nothing), g1, "toggled")
    signal_connect(w -> (app.ghost = w.active; Gtk4.draw(canvas); nothing), g2, "toggled")
    push!(s, hrow(g1, g2))
    push!(side, s)

    # BURN
    s = section("06 · Burn")
    push!(s, field_label("Drive"))
    de = GtkEntry(; hexpand = true, placeholder_text = "/dev/sr0")
    scanb = GtkButton("SCAN")
    app.widgets[:drive] = de; app.widgets[:scan] = scanb
    signal_connect(_ -> (scan!(app); nothing), scanb, "clicked")
    push!(s, hrow(de, scanb))
    modedd = dropdown(["Full disc", "Content ring", "Title ring"], i -> begin
        app.syncing && return
        app.mode = MODES[i]; app.show_drive_preview = false; recompute!(app); touch!(app)
    end)
    app.widgets[:mode] = modedd
    qdd = dropdown(["Best", "Normal", "Draft"], i -> (app.quality = QUALITIES[i]; Gtk4.draw(canvas)))
    mbox = GtkBox(:v; spacing = 4, hexpand = true); push!(mbox, field_label("Mode"), modedd)
    qbox = GtkBox(:v; spacing = 4, hexpand = true); push!(qbox, field_label("Quality"), qdd)
    push!(s, hrow(mbox, qbox; homogeneous = true))
    el = GtkCheckButton("Run as root via $(ELEVATOR)"; active = true)
    el.tooltip_text = "4L-cli needs root to talk to the drive"
    signal_connect(w -> (app.elevate = w.active; nothing), el, "toggled")
    push!(s, el)
    ejectb = GtkButton("EJECT"); closeb = GtkButton("CLOSE"); infob = GtkButton("MEDIA INFO")
    app.widgets[:eject] = ejectb; app.widgets[:close] = closeb; app.widgets[:mediainfo] = infob
    signal_connect(_ -> (quick!(app, "open"); nothing), ejectb, "clicked")
    signal_connect(_ -> (quick!(app, "close"); nothing), closeb, "clicked")
    signal_connect(_ -> (quick!(app, "mediainfo"); nothing), infob, "clicked")
    push!(s, hrow(ejectb, closeb, infob; homogeneous = true))
    prevb = GtkButton("DRIVE PREVIEW"); prevb.tooltip_text = "Ask 4L-cli to render its own preview for the disc in the drive"
    burnb = GtkButton("BURN LABEL"); add_css_class(burnb, "primary")
    prevb.sensitive = false; burnb.sensitive = false
    app.widgets[:drivepreview] = prevb; app.widgets[:burn] = burnb
    signal_connect(_ -> (drive_preview!(app); nothing), prevb, "clicked")
    signal_connect(_ -> (burn!(app); nothing), burnb, "clicked")
    push!(s, prevb, burnb)
    pb = GtkProgressBar(; show_text = true, text = "READY")
    app.widgets[:progress] = pb
    cancelb = GtkButton("ABORT"); add_css_class(cancelb, "danger"); cancelb.visible = false
    app.widgets[:cancel] = cancelb
    signal_connect(cancelb, "clicked") do _
        app.proc === nothing && return
        logline(app, "abort requested (SIGINT) …")
        cli_interrupt(app.proc); nothing
    end
    push!(s, pb, cancelb)
    push!(side, s)

    # LOG
    s = section("07 · Output")
    buf = GtkTextBuffer()
    tv = GtkTextView(; buffer = buf, editable = false, cursor_visible = false, monospace = true,
                     wrap_mode = Gtk4.WrapMode_WORD_CHAR, left_margin = 6, top_margin = 4)
    lsw = GtkScrolledWindow(; height_request = 150)
    lsw[] = tv; add_css_class(lsw, "log")
    app.widgets[:logbuf] = buf; app.widgets[:logview] = tv
    push!(s, lsw)
    push!(side, s)

    # keyboard shortcuts
    keys = GtkEventControllerKey(win)
    Gtk4.G_.set_propagation_phase(keys, Gtk4.PropagationPhase_CAPTURE)
    app.widgets[:keys] = keys
    signal_connect(keys, "key-pressed") do ctrl, keyval, keycode, state
        st = UInt32(state)
        (st & UInt32(Gtk4.ModifierType_CONTROL_MASK)) == 0 && return false
        shift = (st & UInt32(Gtk4.ModifierType_SHIFT_MASK)) != 0
        keyval > 0x7f && return false
        c = lowercase(Char(keyval))
        if c == 'q'
            later(() -> Gtk4.G_.close(win), app); return true
        elseif app.page == "data"
            c == 'o' || return false
            add_dialog!(app; folders = shift); return true
        end
        if c == 'z'
            later(() -> (shift ? redo!(app) : undo!(app)), app)
        elseif c == 'y'
            later(() -> redo!(app), app)
        elseif c == 's'
            shift ? save_as_dialog!(app) : save_or_ask!(app)
        elseif c == 'o'
            open_any_dialog!(app)
        elseif c == 'n'
            confirm_discard(() -> new_label!(app), app, "start a new label")
        elseif c == 'e'
            export_dialog!(app)
        elseif c == 'q'
            later(() -> Gtk4.G_.close(win), app)
        else
            return false
        end
        true
    end

    # closing with unsaved work asks first
    signal_connect(win, "close-request") do w
        if !app.closing && app.proc !== nothing
            ask_dialog("A disc is being written. Quitting now will most likely ruin it.\n\nQuit anyway?", win; no_text = "Keep going", yes_text = "Quit") do yes
                yes && later(() -> (app.closing = true; app.proc === nothing || cli_interrupt(app.proc); Gtk4.G_.close(win)), app)
            end
            return true
        end
        if !app.closing && is_dirty(app) && !(isempty(app.docpath) && snapshot(app) == blank_snapshot())
            ask_dialog("Quit without saving changes?", win; no_text = "Cancel", yes_text = "Quit") do yes
                yes && later(() -> (app.closing = true; Gtk4.G_.close(win)), app)
            end
            return true
        end
        notify(app.closed)
        false
    end

    apply_theme!(app)
    reset_history!(app)

    # follow Omarchy theme switches live
    Gtk4.GLib.g_timeout_add(2000) do
        st = theme_stamp()
        if st != app.theme_stamp
            app.theme_stamp = st
            apply_theme!(app)
            app.widgets[:themelbl].label = "THEME " * uppercase(app.palette.name)
        end
        true
    end
    win
end

function main(args = ARGS)
    app = App()
    win = build!(app)
    logline(app, "4L-cli: $(CLI_BIN)")
    isfile(CLI_BIN) || logline(app, "warning: $(CLI_BIN) not found")
    scan!(app)
    isempty(args) || open_image!(app, abspath(args[1]))
    show(win)
    if !isinteractive()
        @async Gtk4.GLib.glib_main()
        wait(app.closed)
    end
    app
end
