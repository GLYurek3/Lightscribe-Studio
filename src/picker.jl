# In-app photo picker: a thumbnail grid where a click picks/unpicks, Shift+click picks a range.

const PICK_W, PICK_H = 168, 120

mutable struct Picker
    win::Any
    dir::String
    entries::Vector{Tuple{String,Bool}}     # (path, isdir), folders first
    picked::Set{String}
    tiles::Vector{Any}                      # FlowBoxChild per entry
    last::Int                               # last clicked index (for Shift ranges)
    shift::Bool
    queue::Vector{Tuple{String,Any,Any}}    # (path, picture, placeholder label)
    loading::Bool
    gen::Int                                # bumps on every folder change (stale thumbnail jobs stop)
    w::Dict{Symbol,Any}
end

const PICKER_THUMBS = Dict{String,Any}()

function start_folder(app::App)
    d = get(app.widgets, :picker_last, "")
    isdir(d) && return d
    p = try strip(read(`xdg-user-dir PICTURES`, String)) catch; "" end
    isdir(p) ? p : homedir()
end

function list_folder(dir::AbstractString)
    names = try readdir(dir) catch; String[] end
    dirs = String[]; files = String[]
    for n in names
        (startswith(n, ".") || n in JUNK_NAMES || n == "@eaDir") && continue
        p = joinpath(dir, n)
        if isdir(p)
            push!(dirs, p)
        elseif isfile(p) && (is_photo(p) || ext(p) in VIDEO_EXTS)
            push!(files, p)
        end
    end
    by = p -> lowercase(basename(p))
    vcat([(p, true) for p in sort!(dirs; by)], [(p, false) for p in sort!(files; by)])
end

function picker_summary!(P::Picker)
    n = length(P.picked)
    bytes = sum(p -> (isfile(p) ? filesize(p) : 0), P.picked; init = 0)
    P.w[:count].label = n == 0 ? "CLICK PHOTOS TO PICK THEM · SHIFT+CLICK PICKS A RANGE" :
                        "$(n) PICKED · $(human(bytes))" * (any(p -> dirname(p) != P.dir, P.picked) ? " · INCLUDING OTHER FOLDERS" : "")
    P.w[:add].label = n == 0 ? "ADD PHOTOS" : "ADD $(n) " * (n == 1 ? "PHOTO" : "PHOTOS")
    P.w[:add].sensitive = n > 0
    P.w[:none].sensitive = n > 0
end

function set_tile_picked!(P::Picker, i::Int, on::Bool)
    path, isdir_ = P.entries[i]
    isdir_ && return
    t = P.tiles[i]
    if on
        push!(P.picked, path); add_css_class(t, "picked")
    else
        delete!(P.picked, path); Gtk4.remove_css_class(t, "picked")
    end
end

function navigate!(app::App, P::Picker, dir::AbstractString)
    isdir(dir) || return
    P.dir = rstrip(abspath(dir), '/'); isempty(P.dir) && (P.dir = "/")
    app.widgets[:picker_last] = P.dir
    P.gen += 1; empty!(P.queue)
    P.entries = list_folder(P.dir)
    fb = P.w[:grid]
    while (c = Gtk4.G_.get_child_at_index(fb, 0)) !== nothing
        Gtk4.G_.remove(fb, c)
    end
    P.tiles = Any[]; P.last = 0
    ondisc = Set(f[1] for it in app.data.items for f in it.files)
    for (path, isdir_) in P.entries
        pic = GtkPicture(; can_shrink = true, width_request = PICK_W, height_request = PICK_H)
        Gtk4.G_.set_content_fit(pic, Gtk4.ContentFit_COVER); add_css_class(pic, "thumb")
        ph = GtkLabel(isdir_ ? "▤" : uppercase(ext(path))); add_css_class(ph, isdir_ ? "folder-glyph" : "thumb-icon")
        ov = GtkOverlay(); ov[] = pic; Gtk4.G_.add_overlay(ov, ph)
        if !isdir_
            tick = GtkLabel("✓"); add_css_class(tick, "tick")
            tick.halign = Gtk4.Align_END; tick.valign = Gtk4.Align_START
            Gtk4.G_.add_overlay(ov, tick)
            if path in ondisc
                badge = GtkLabel("ON DISC"); add_css_class(badge, "badge")
                badge.halign = Gtk4.Align_START; badge.valign = Gtk4.Align_END
                Gtk4.G_.add_overlay(ov, badge)
            end
        end
        name = GtkLabel(basename(path); ellipsize = Gtk4.Pango.EllipsizeMode_MIDDLE, max_width_chars = 18)
        add_css_class(name, isdir_ ? "filename" : "field-label")
        box = GtkBox(:v; spacing = 4); push!(box, ov, name)
        child = GtkFlowBoxChild(); Gtk4.G_.set_child(child, box)
        add_css_class(child, isdir_ ? "folder-tile" : "photo-tile")
        path in P.picked && add_css_class(child, "picked")
        push!(fb, child); push!(P.tiles, child)
        if isdir_
            inside = try sort(readdir(path); by = lowercase) catch; String[] end
            k = findfirst(n -> !startswith(n, ".") && thumbable(n), inside)
            k === nothing || push!(P.queue, (joinpath(path, inside[k]), pic, nothing))
        elseif thumbable(path)
            push!(P.queue, (path, pic, ph))
        end
    end
    nphotos = count(e -> !e[2], P.entries); ndirs = length(P.entries) - nphotos
    P.w[:path].text = P.dir
    P.w[:here].label = "$(nphotos) PHOTO" * (nphotos == 1 ? "" : "S") * (ndirs > 0 ? " · $(ndirs) FOLDER" * (ndirs == 1 ? "" : "S") : "")
    P.w[:empty].visible = isempty(P.entries)
    P.w[:all].sensitive = nphotos > 0
    P.w[:album].sensitive = P.dir != homedir() && P.dir != "/"
    P.w[:up].sensitive = P.dir != "/"
    picker_summary!(P)
    picker_thumbs!(P)
end

function picker_thumbs!(P::Picker)
    P.loading && return
    P.loading = true
    gen = P.gen
    Gtk4.GLib.g_idle_add() do
        if gen != P.gen || isempty(P.queue)
            P.loading = false
            gen != P.gen && picker_thumbs!(P)   # a new folder was opened meanwhile
            return false
        end
        path, pic, ph = popfirst!(P.queue)
        pb = get(PICKER_THUMBS, path, missing)
        if pb === missing
            pb = try cover_thumb(path, PICK_W, PICK_H) catch; nothing end
            length(PICKER_THUMBS) > 3000 && empty!(PICKER_THUMBS)
            PICKER_THUMBS[path] = pb
        end
        if pb !== nothing
            Gtk4.G_.set_pixbuf(pic, pb)
            ph === nothing || (ph.visible = false)
        end
        true
    end
end

function tile_clicked!(app::App, P::Picker, i::Int)
    path, isdir_ = P.entries[i]
    if isdir_
        later(() -> navigate!(app, P, path), app); return
    end
    if P.shift && P.last > 0
        for j in min(P.last, i):max(P.last, i)
            set_tile_picked!(P, j, true)
        end
    else
        set_tile_picked!(P, i, !(path in P.picked))
    end
    P.last = i
    picker_summary!(P)
end

function open_picker!(app::App)
    if haskey(app.widgets, :picker) && app.widgets[:picker].win !== nothing
        Gtk4.G_.present(app.widgets[:picker].win); return
    end
    win = GtkWindow("Add photos — LightScribe Studio", 1120, 760)
    Gtk4.G_.set_transient_for(win, app.win); Gtk4.G_.set_modal(win, true)
    add_css_class(win, "picker")
    P = Picker(win, "", Tuple{String,Bool}[], Set{String}(), Any[], 0, false, Tuple{String,Any,Any}[], false, 0, Dict{Symbol,Any}())
    app.widgets[:picker] = P
    W = P.w
    root = GtkBox(:v); win[] = root

    # navigation bar
    up = GtkButton("↑ UP"); home = GtkButton("HOME"); pics = GtkButton("PICTURES"); other = GtkButton("OTHER LOCATION…")
    for b in (up, home, pics, other); add_css_class(b, "tool"); end
    other.tooltip_text = "Use the system file dialog (Ctrl+click / Shift+click to pick several)"
    W[:up] = up
    pe = GtkEntry(; hexpand = true); W[:path] = pe
    here = GtkLabel(""; xalign = 1); add_css_class(here, "dim"); W[:here] = here
    signal_connect(_ -> (later(() -> navigate!(app, P, dirname(P.dir)), app); nothing), up, "clicked")
    signal_connect(_ -> (later(() -> navigate!(app, P, homedir()), app); nothing), home, "clicked")
    signal_connect(pics, "clicked") do _
        p = try strip(read(`xdg-user-dir PICTURES`, String)) catch; homedir() end
        later(() -> navigate!(app, P, p), app); nothing
    end
    signal_connect(other, "clicked") do _
        later(() -> Gtk4.G_.close(win), app); add_dialog!(app; system = true); nothing
    end
    signal_connect(pe, "activate") do e
        p = expanduser(strip(Gtk4.G_.get_text(e)))
        later(() -> (isdir(p) ? navigate!(app, P, p) : dlog(app, "not a folder: $(p)")), app); nothing
    end
    nav = hrow(up, home, pics, pe, here, other; spacing = 8); add_css_class(nav, "topbar")
    push!(root, nav)

    # grid
    fb = GtkFlowBox(; selection_mode = Gtk4.SelectionMode_NONE, homogeneous = true, valign = Gtk4.Align_START,
                    column_spacing = 10, row_spacing = 10, max_children_per_line = 30, activate_on_single_click = true)
    add_css_class(fb, "pickgrid"); W[:grid] = fb
    signal_connect(fb, "child-activated") do box, child
        i = Gtk4.G_.get_index(child) + 1
        tile_clicked!(app, P, i); nothing
    end
    empty_ = GtkLabel("NO PHOTOS OR FOLDERS HERE"; vexpand = true); add_css_class(empty_, "dim"); W[:empty] = empty_
    col = GtkBox(:v; vexpand = true); push!(col, fb, empty_)
    sw = GtkScrolledWindow(; hscrollbar_policy = Gtk4.PolicyType_NEVER, vexpand = true); sw[] = col
    add_css_class(sw, "stage")
    push!(root, sw)

    # action bar
    allb = GtkButton("SELECT ALL"); noneb = GtkButton("SELECT NONE"); albb = GtkButton("ADD THIS FOLDER AS ALBUM")
    W[:all] = allb; W[:none] = noneb; W[:album] = albb
    albb.tooltip_text = "Adds the whole folder (with sub-folders) as one album on the disc"
    cnt = GtkLabel(""; hexpand = true, xalign = 0); add_css_class(cnt, "doctitle"); W[:count] = cnt
    cancel = GtkButton("CANCEL"); addb = GtkButton("ADD PHOTOS"); add_css_class(addb, "primary"); W[:add] = addb
    signal_connect(allb, "clicked") do _
        for i in eachindex(P.entries); set_tile_picked!(P, i, true); end
        picker_summary!(P); nothing
    end
    signal_connect(noneb, "clicked") do _
        for i in eachindex(P.entries); set_tile_picked!(P, i, false); end
        empty!(P.picked); picker_summary!(P); nothing
    end
    signal_connect(albb, "clicked") do _
        d = P.dir
        later(() -> (Gtk4.G_.close(win); add_paths!(app, [d])), app); nothing
    end
    signal_connect(_ -> (later(() -> Gtk4.G_.close(win), app); nothing), cancel, "clicked")
    signal_connect(addb, "clicked") do _
        ps = sort!(collect(P.picked); by = p -> (dirname(p), lowercase(basename(p))))
        later(() -> (Gtk4.G_.close(win); add_paths!(app, ps)), app); nothing
    end
    bar = hrow(allb, noneb, albb, cnt, cancel, addb; spacing = 8); add_css_class(bar, "pickbar")
    push!(root, bar)

    # Shift tracking for range picks, Esc to cancel, Ctrl+A to pick everything here
    keys = GtkEventControllerKey(win); W[:keys] = keys
    Gtk4.G_.set_propagation_phase(keys, Gtk4.PropagationPhase_CAPTURE)
    signal_connect(keys, "key-pressed") do c, keyval, keycode, state
        keyval in (0xffe1, 0xffe2) && (P.shift = true)
        if keyval == 0xff1b
            later(() -> Gtk4.G_.close(win), app); return true
        end
        if keyval in (UInt32('a'), UInt32('A')) && (UInt32(state) & UInt32(Gtk4.ModifierType_CONTROL_MASK)) != 0 && !Gtk4.G_.has_focus(pe)
            for i in eachindex(P.entries); set_tile_picked!(P, i, true); end
            picker_summary!(P); return true
        end
        false
    end
    signal_connect(keys, "key-released") do c, keyval, keycode, state
        keyval in (0xffe1, 0xffe2) && (P.shift = false); nothing
    end
    signal_connect(win, "close-request") do w
        P.gen += 1; empty!(P.queue); P.win = nothing
        false
    end

    navigate!(app, P, start_folder(app))
    show(win)
    P
end
