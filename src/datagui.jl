# "DATA DISC" page: build a compilation of photos / album folders and write it with xorriso.

const THUMB_W, THUMB_H = 72, 54

default_volid() = "PHOTOS " * Libc.strftime("%Y-%m-%d", time())

Base.@kwdef mutable struct DataState
    items::Vector{DiscItem} = DiscItem[]
    filter::String = "media"
    size_idx::Int = 1
    media::Dict{String,Any} = Dict{String,Any}()
    media_drive::String = ""
    opts::BurnOptions = BurnOptions(volid = default_volid())
    thumbs::Dict{String,Any} = Dict{String,Any}()
    thumb_queue::Vector{Tuple{String,Any}} = Tuple{String,Any}[]
    thumb_running::Bool = false
    rebuild_pending::Bool = false
    verify_total::Float64 = 0.0
    adding::Int = 0
    w::Dict{Symbol,Any} = Dict{Symbol,Any}()
end

function dlog(app::App, s::AbstractString)
    D = app.data
    buf = get(D.w, :logbuf, nothing)
    buf === nothing && (println(s); return)
    insert!(buf, Gtk4.GtkTextIter(buf, length(buf) + 1), rstrip(s) * "\n")
    Gtk4.G_.scroll_to_mark(D.w[:logview], Gtk4.G_.get_insert(buf), 0.0, false, 0.0, 1.0)
end

# ───────────────────────────── model ─────────────────────────────

function add_paths!(app::App, paths)
    D = app.data
    have = Set(it.path for it in D.items)
    n0 = length(D.items)
    for p in paths
        p = rstrip(abspath(String(p)), '/')
        (isfile(p) || isdir(p)) || (dlog(app, "not found: $(p)"); continue)
        p in have && (dlog(app, "already added: $(basename(p))"); continue)
        if any(it -> it.isdir && startswith(p, it.path * "/"), D.items)
            dlog(app, "$(basename(p)) is already inside an added album"); continue
        end
        it = new_item(p, D.filter)
        if it.isdir && isempty(it.files)
            dlog(app, "$(basename(p)): no $(lowercase(DATA_FILTER_LABELS[findfirst(==(D.filter), DATA_FILTERS)])) found — skipped")
            continue
        end
        push!(D.items, it); push!(have, p)
        dlog(app, it.isdir ? "album $(it.name): $(length(it.files)) files, $(human(it.bytes))" : "file $(it.name) ($(human(it.bytes)))")
    end
    unique_names!(D.items)
    length(D.items) > n0 && (rebuild_list!(app); update_summary!(app))
end

function remove_item!(app::App, it::DiscItem)
    D = app.data
    filter!(x -> x !== it, D.items)
    rebuild_list!(app); update_summary!(app)
end

function clear_items!(app::App)
    empty!(app.data.items)
    rebuild_list!(app); update_summary!(app)
end

function rescan_all!(app::App)
    D = app.data
    for it in D.items; it.isdir && scan_item!(it, D.filter); end
    n = count(it -> it.isdir && isempty(it.files), D.items)
    n > 0 && dlog(app, "$(n) album(s) now have no matching files and will be left out")
    dlog(app, "filter: $(DATA_FILTER_LABELS[findfirst(==(D.filter), DATA_FILTERS)]) — $(total_files(D.items)) files")
    rebuild_list!(app); update_summary!(app)
end

"Capacity in sectors for the current choice, or 0 if unknown."
function capacity(app::App)
    D = app.data
    D.size_idx > 1 && return DISC_SIZES[D.size_idx][2]
    m = D.media
    isempty(m) && return 0
    (get(m, "rewritable", false) && D.opts.blank) && return get(m, "overall", 0)
    get(m, "writable", 0)
end

item_info(it::DiscItem) = if it.isdir
    parts = String[]
    it.photos > 0 && push!(parts, "$(it.photos) PHOTO" * (it.photos == 1 ? "" : "S"))
    it.videos > 0 && push!(parts, "$(it.videos) VIDEO" * (it.videos == 1 ? "" : "S"))
    other = length(it.files) - it.photos - it.videos
    other > 0 && push!(parts, "$(other) OTHER")
    isempty(parts) && push!(parts, "EMPTY")
    it.dirs > 0 && push!(parts, "$(it.dirs) SUBFOLDER" * (it.dirs == 1 ? "" : "S"))
    "ALBUM · " * join(parts, " · ") * " · " * human(it.bytes)
else
    (is_photo(it.path) ? "PHOTO" : ext(it.path) in VIDEO_EXTS ? "VIDEO" : "FILE") * " · " * human(it.bytes)
end

# ───────────────────────────── list + thumbnails ─────────────────────────────

function rebuild_list!(app::App)
    D = app.data
    D.rebuild_pending && return
    D.rebuild_pending = true
    Gtk4.GLib.g_idle_add() do
        D.rebuild_pending = false
        try build_rows!(app) catch err; dlog(app, "list error: $(sprint(showerror, err))") end
        false
    end
    nothing
end

function build_rows!(app::App)
    D = app.data; lb = D.w[:list]
    while (r = Gtk4.G_.get_row_at_index(lb, 0)) !== nothing
        Gtk4.G_.remove(lb, r)
    end
    empty!(D.thumb_queue)
    D.w[:empty].visible = isempty(D.items)
    for it in D.items
        pic = GtkPicture(; can_shrink = true, width_request = THUMB_W, height_request = THUMB_H)
        Gtk4.G_.set_content_fit(pic, Gtk4.ContentFit_COVER)
        add_css_class(pic, "thumb")
        icon = GtkLabel(it.isdir ? "▤" : "▢"); add_css_class(icon, "thumb-icon")
        thumbbox = GtkOverlay(); thumbbox[] = pic
        Gtk4.G_.add_overlay(thumbbox, icon)
        if !isempty(it.thumb)
            t = get(D.thumbs, it.thumb, missing)
            if t === missing
                push!(D.thumb_queue, (it.thumb, (pic, icon)))
            elseif t !== nothing
                Gtk4.G_.set_pixbuf(pic, t); icon.visible = it.isdir
            end
        end
        name = GtkEntry(; text = it.name, hexpand = true)
        add_css_class(name, "flat"); name.tooltip_text = "Name on the disc"
        signal_connect(name, "changed") do e
            it.name = Gtk4.G_.get_text(e); nothing
        end
        info = GtkLabel(item_info(it); xalign = 0, ellipsize = Gtk4.Pango.EllipsizeMode_END)
        add_css_class(info, "field-label")
        src = GtkLabel(it.path; xalign = 0, ellipsize = Gtk4.Pango.EllipsizeMode_MIDDLE)
        add_css_class(src, "dim"); add_css_class(src, "small")
        col = GtkBox(:v; spacing = 2, hexpand = true); push!(col, name, info, src)
        rm = GtkButton("✕"); rm.tooltip_text = "Remove from the disc"; add_css_class(rm, "tool")
        rm.valign = Gtk4.Align_CENTER
        signal_connect(_ -> (later(() -> remove_item!(app, it), app); nothing), rm, "clicked")
        row = hrow(thumbbox, col, rm; spacing = 12)
        push!(lb, row)
    end
    load_thumbs!(app)
end

"Load a photo scaled and centre-cropped to exactly w×h (like CSS object-fit: cover)."
function cover_thumb(path, w, h)
    fw, fh = Ref{Cint}(0), Ref{Cint}(0)
    ccall((:gdk_pixbuf_get_file_info, Gtk4.GdkPixbufLib.libgdkpixbuf), Ptr{Cvoid}, (Cstring, Ref{Cint}, Ref{Cint}), path, fw, fh)
    (fw[] > 0 && fh[] > 0) || return nothing
    # EXIF-rotated photos swap their sides after orientation is applied; load generously, then crop
    k = max(w / fw[], h / fh[], w / fh[], h / fw[])
    p = GdkPixbuf(path, ceil(Int, fw[] * k), ceil(Int, fh[] * k), true)
    p = something(Gtk4.GdkPixbufLib.G_.apply_embedded_orientation(p), p)
    pw, ph = Gtk4.GdkPixbufLib.G_.get_width(p), Gtk4.GdkPixbufLib.G_.get_height(p)
    k2 = max(w / pw, h / ph)
    sw, sh = max(w, round(Int, pw * k2)), max(h, round(Int, ph * k2))
    q = Gtk4.GdkPixbufLib.G_.scale_simple(p, sw, sh, Gtk4.GdkPixbufLib.InterpType_BILINEAR)
    Gtk4.GdkPixbufLib.G_.new_subpixbuf(q, (sw - w) ÷ 2, (sh - h) ÷ 2, w, h)
end

"Decode thumbnails one per idle tick so a big album never freezes the window."
function load_thumbs!(app::App)
    D = app.data
    D.thumb_running && return
    D.thumb_running = true
    Gtk4.GLib.g_idle_add() do
        if isempty(D.thumb_queue)
            D.thumb_running = false
            return false
        end
        path, (pic, icon) = popfirst!(D.thumb_queue)
        pb = get(D.thumbs, path, missing)
        if pb === missing
            pb = try
                cover_thumb(path, THUMB_W, THUMB_H)
            catch
                nothing
            end
            length(D.thumbs) > 2000 && empty!(D.thumbs)
            D.thumbs[path] = pb
        end
        if pb !== nothing
            Gtk4.G_.set_pixbuf(pic, pb)
            icon.visible = any(it -> it.isdir && it.thumb == path, D.items)
        end
        true
    end
    nothing
end

# ───────────────────────────── summary + disc ring ─────────────────────────────

function update_summary!(app::App)
    D = app.data; W = D.w
    haskey(W, :sum) || return
    nf = total_files(D.items); est = estimate_sectors(D.items) * SECTOR
    cap = capacity(app) * SECTOR
    W[:sum].label = nf == 0 ? "NOTHING ADDED YET" :
        "$(nf) FILE" * (nf == 1 ? "" : "S") * " · $(length(D.items)) ITEM" * (length(D.items) == 1 ? "" : "S")
    W[:size].label = human(est) * (cap > 0 ? " OF " * human(cap) : "")
    over = cap > 0 && est > cap
    W[:fit].label = nf == 0 ? "" :
        cap == 0 ? "CHECK THE DISC OR PICK A SIZE TO SEE IF IT FITS" :
        over ? "TOO BIG BY $(human(est - cap)) — REMOVE SOMETHING OR USE A BIGGER DISC" :
               "FITS · $(human(cap - est)) LEFT"
    for c in ("warn", "ok"); Gtk4.remove_css_class(W[:fit], c); end
    add_css_class(W[:fit], over ? "warn" : "ok")
    m = D.media
    W[:mediainfo].label = isempty(m) ? "NOT CHECKED" :
        get(m, "none", false) ? "NO DISC IN DRIVE" :
        uppercase(get(m, "kind", "?")) * " · " * (get(m, "blank", false) ? "BLANK" :
            get(m, "appendable", false) ? "HAS DATA, CAN ADD MORE" : get(m, "closed", false) ? "FINALIZED (FULL)" : uppercase(get(m, "status", ""))) *
        (get(m, "writable", 0) > 0 ? " · $(human(get(m, "writable", 0) * SECTOR)) FREE" : "")
    W[:appendnote].visible = get(m, "appendable", false) && !get(m, "blank", false) && !D.opts.blank
    Gtk4.draw(W[:ring])
    update_data_actions!(app)
end

function update_data_actions!(app::App)
    D = app.data; W = D.w
    haskey(W, :write) || return
    idle = app.proc === nothing
    has = total_files(D.items) > 0
    cap = capacity(app)
    fits = cap == 0 || estimate_sectors(D.items) <= cap
    m = D.media
    blocked = get(m, "none", false) || (get(m, "closed", false) && !(get(m, "rewritable", false) && D.opts.blank))
    W[:write].sensitive = idle && has && have_xorriso() && !isempty(ddrive(app)) && fits && !blocked
    W[:iso].sensitive = idle && has && have_xorriso()
    for k in (:check, :scan, :add, :addalbum, :clear, :deject)
        W[k].sensitive = idle
    end
    W[:dcancel].visible = !idle
end

ddrive(app::App) = String(strip(app.data.w[:drive].text))

function draw_ring(app::App, ctx, w, h)
    p = app.palette; D = app.data
    set_hex(c, a = 1.0) = (r = hex2rgb(c); Cairo.set_source_rgba(ctx, r[1], r[2], r[3], a))
    cx, cy = w / 2, h / 2
    R = 0.47 * min(w, h); k = R / DISC_RADIUS_MM
    r0, r1 = 23.0 * k, 58.0 * k          # program area of a 120 mm disc
    set_hex(p["darker_background"]); Cairo.arc(ctx, cx, cy, R, 0, 2π); Cairo.fill(ctx)
    set_hex(p["muted"]); Cairo.set_line_width(ctx, 1); Cairo.arc(ctx, cx, cy, R, 0, 2π); Cairo.stroke(ctx)
    set_hex(p["background"]); Cairo.arc(ctx, cx, cy, r1, 0, 2π); Cairo.arc_negative(ctx, cx, cy, r0, 2π, 0); Cairo.fill(ctx)
    capsec = capacity(app)
    est = estimate_sectors(D.items)
    m = D.media
    used = (D.size_idx == 1 && !D.opts.blank && get(m, "appendable", false)) ? get(m, "readable", 0) : 0
    total = capsec + used
    # data is written inside-out at constant density, so the radius grows with sqrt(area)
    rad(f) = sqrt(r0^2 + clamp(f, 0, 1) * (r1^2 - r0^2))
    if total > 0
        fo = used / total; fn = (used + est) / total
        used > 0 && (set_hex(p["muted"]); Cairo.arc(ctx, cx, cy, rad(fo), 0, 2π); Cairo.arc_negative(ctx, cx, cy, r0, 2π, 0); Cairo.fill(ctx))
        if est > 0
            set_hex(fn > 1 ? p["bright_foreground"] : p["accent"], 0.85)
            Cairo.arc(ctx, cx, cy, rad(fn), 0, 2π); Cairo.arc_negative(ctx, cx, cy, rad(fo), 2π, 0); Cairo.fill(ctx)
        end
        if fn > 1   # overflow: hatch the rim
            set_hex(p["bright_foreground"]); Cairo.set_line_width(ctx, 3)
            for a in 0:0.12:2π-0.06
                Cairo.move_to(ctx, cx + r1 * sin(a), cy - r1 * cos(a)); Cairo.line_to(ctx, cx + R * sin(a + 0.05), cy - R * cos(a + 0.05))
            end
            Cairo.stroke(ctx)
        end
    elseif est > 0
        set_hex(p["accent"], 0.35); Cairo.arc(ctx, cx, cy, r1, 0, 2π); Cairo.arc_negative(ctx, cx, cy, r0, 2π, 0); Cairo.fill(ctx)
    end
    # tracks
    set_hex(p["darker_background"], 0.35); Cairo.set_line_width(ctx, 0.5)
    for r in range(r0, r1; length = 14); Cairo.arc(ctx, cx, cy, r, 0, 2π); Cairo.stroke(ctx); end
    # hub + hole
    set_hex(p["dark_background"]); Cairo.arc(ctx, cx, cy, HUB_RADIUS_MM * k * 0.95, 0, 2π); Cairo.fill(ctx)
    set_hex(p["background"]); Cairo.arc(ctx, cx, cy, HOLE_RADIUS_MM * k, 0, 2π); Cairo.fill(ctx)
    set_hex(p["muted"]); Cairo.arc(ctx, cx, cy, HOLE_RADIUS_MM * k, 0, 2π); Cairo.stroke(ctx)
    # percentage in the hub
    Cairo.select_font_face(ctx, "Liberation Mono", Cairo.FONT_SLANT_NORMAL, Cairo.FONT_WEIGHT_BOLD)
    txt = total > 0 ? "$(round(Int, 100 * (used + est) / total))%" : est > 0 ? "?" : "—"
    Cairo.set_font_size(ctx, 0.11 * R)
    ex = Cairo.text_extents(ctx, txt)
    set_hex(p["bright_foreground"]); Cairo.move_to(ctx, cx - ex[3] / 2 - ex[1], cy + HOLE_RADIUS_MM * k + 0.15R)
    Cairo.show_text(ctx, txt)
end

# ───────────────────────────── drive jobs ─────────────────────────────

function check_media!(app::App; quiet = false)
    D = app.data
    have_xorriso() || (dlog(app, "xorriso is not installed — run: sudo pacman -S libisoburn"); return)
    d = ddrive(app); isempty(d) && (dlog(app, "no drive selected"); return)
    app.proc === nothing || return
    out = IOBuffer()
    quiet || dlog(app, "checking the disc in $(d) …")
    D.w[:mediainfo].label = "CHECKING …"
    app.proc = spawn_lines(media_cmd(d), l -> println(out, l), ok -> later(app) do
        app.proc = nothing
        s = String(take!(out))
        D.media = parse_media(s); D.media_drive = d
        if isempty(D.media) || !haskey(D.media, "kind")
            D.media = Dict{String,Any}("none" => true)
            msg = something(match(r"(?m)^.*(FAILURE|SORRY).*$", s), match(r"(?m)^.+$", s * "?"))
            quiet || dlog(app, "could not read the drive: " * strip(msg.match))
        else
            quiet || dlog(app, join(filter(!isempty, [get(D.media, "drive", ""), get(D.media, "kind", ""),
                                                   get(D.media, "status", ""), get(D.media, "summary", "")]), " · "))
            haskey(D.media, "volid") && !get(D.media, "blank", true) && (quiet || dlog(app, "volume: $(D.media["volid"])"))
        end
        update_summary!(app)
    end)
end

"Run commands one after another; stop at the first failure."
function run_chain!(app::App, steps::Vector{Tuple{Cmd,String}}, title::String; on_ok = () -> nothing, on_fail = i -> nothing)
    D = app.data; W = D.w
    app.proc === nothing || return
    pb = W[:progress]
    set_status(app, title, "busy")
    app.started = time()
    D.adding = 0
    function step(i)
        if i > length(steps)
            app.proc = nothing
            el = round(Int, time() - app.started)
            set_status(app, "done", "ok"); pb.fraction = 1.0; pb.text = "COMPLETE · $(el ÷ 60)M $(el % 60)S"
            update_data_actions!(app); on_ok()
            return
        end
        cmd, label = steps[i]
        pb.fraction = 0.0; pb.text = uppercase(label)
        dlog(app, "\$ " * join(cmd.exec, " "))
        last = Ref(0.0)
        on_line = line -> later(app) do
            line = strip(line)
            if startswith(line, "Added to ISO image")
                D.adding += 1
                D.adding % 50 == 0 && (pb.text = "ADDING FILES · $(D.adding)"; Gtk4.G_.pulse(pb))
                return
            end
            pr = parse_progress(line)
            if pr !== nothing
                if pr.pct !== nothing
                    pb.fraction = pr.pct / 100
                    el = time() - app.started
                    pb.text = "$(uppercase(pr.stage)) $(round(pr.pct; digits = 1))%"
                elseif pr.bytes !== nothing && D.verify_total > 0
                    f = clamp(pr.bytes / D.verify_total, 0, 1); pb.fraction = f
                    pb.text = "VERIFYING $(round(Int, 100f))%"
                else
                    Gtk4.G_.pulse(pb); pb.text = uppercase(pr.stage) * " · DON'T EJECT"
                end
                # keep the log readable: one progress line per 10%
                pr.pct === nothing || (floor(pr.pct / 10) == floor(last[] / 10) && return)
                pr.pct === nothing || (last[] = pr.pct)
            end
            occursin(r"^xorriso : UPDATE :\s+\d+ (files added|nodes read)", line) && return
            occursin(r"^(Drive current|Media current|Media status|Media summary|Volume id)\s*:|^xorriso : NOTE : (Re-assessing|Loading ISO image tree)|^Written to medium|-volid text", line) && return
            occursin(r"^xorriso \d", line) && return
            dlog(app, line)
        end
        on_done = ok -> later(app) do
            if ok
                step(i + 1)
            else
                app.proc = nothing
                set_status(app, "failed", "idle"); pb.text = "FAILED / CANCELLED"
                dlog(app, "$(label) failed (see output above)")
                update_data_actions!(app); on_fail(i)
            end
        end
        try
            app.proc = spawn_lines(cmd, on_line, on_done)
        catch err
            app.proc = nothing
            dlog(app, "could not start xorriso: $(sprint(showerror, err))")
            set_status(app, "error", "idle"); update_data_actions!(app)
        end
        update_data_actions!(app)
    end
    step(1)
end

function prepare_map(app::App)
    D = app.data
    unique_names!(D.items)
    rebuild_list!(app)
    for it in D.items
        missing_ = [f[1] for f in it.files if !isfile(f[1])]
        isempty(missing_) || error("$(length(missing_)) file(s) of $(it.name) are gone, e.g. $(first(missing_))")
    end
    D.verify_total = total_bytes(D.items)
    write_map_file(filter(it -> !isempty(it.files), D.items), joinpath(CACHE_DIR, "datadisc-map.txt"))
end

function write_disc!(app::App)
    D = app.data
    d = ddrive(app)
    nf = total_files(D.items); est = estimate_sectors(D.items) * SECTOR
    m = D.media
    kind = get(m, "kind", "disc")
    o = D.opts
    lines = String["Write $(nf) files ($(human(est))) to the $(kind) in $(d)?", ""]
    push!(lines, "Disc name: $(volid_clean(o.volid))")
    if o.blank && get(m, "rewritable", false)
        push!(lines, "The rewritable disc will be ERASED first.")
    elseif get(m, "appendable", false) && !get(m, "blank", false)
        push!(lines, "The disc already has data: it is kept and these files are added as a new session.")
    end
    push!(lines, o.close ? "The disc will be finalized — nothing can be added later." :
                           "The disc stays open so more can be added later (needs a multisession-capable reader).")
    o.verify && push!(lines, "Every file is read back and checked afterwards.")
    get(m, "rewritable", false) || push!(lines, "", "Write-once media can't be undone if something goes wrong.")
    isempty(m) && push!(lines, "", "The disc hasn't been checked — xorriso will refuse if it can't write it.")
    ask_dialog(join(lines, "\n"), app.win; no_text = "Cancel", yes_text = "Write disc") do yes
        yes || return
        later(app) do
            mapf = prepare_map(app)
            steps = Tuple{Cmd,String}[(xorriso_write_cmd(d, mapf, o; mediakind = kind), o.blank ? "erasing + writing" : "writing")]
            o.verify && push!(steps, (xorriso_verify_cmd(d; eject = o.eject), "verifying"))
            run_chain!(app, steps, "writing disc"; on_ok = () -> begin
                dlog(app, "disc written: $(nf) files" * (o.verify ? ", all checksums match" : ""))
                o.eject || later(() -> check_media!(app; quiet = true), app)
                o.eject && (D.media = Dict{String,Any}(); update_summary!(app))
            end)
        end
    end
end

function write_iso!(app::App, path::AbstractString)
    path = endswith(lowercase(path), ".iso") ? path : path * ".iso"
    isfile(path) && rm(path)          # an existing image would otherwise get a new session appended
    mapf = prepare_map(app)
    o = app.data.opts
    steps = Tuple{Cmd,String}[(xorriso_write_cmd("stdio:" * path, mapf, o), "building image")]
    o.verify && push!(steps, (xorriso_verify_cmd(path), "verifying"))
    run_chain!(app, steps, "making iso"; on_ok = () -> dlog(app, "image saved: $(path) ($(human(filesize(path))))"),
               on_fail = i -> if i == 1
                   isfile(path) && (rm(path); dlog(app, "removed the incomplete image"))
               else
                   dlog(app, "the image was kept, but it did NOT verify — don't trust it")
               end)
end

function write_iso_dialog!(app::App)
    save_dialog("Save disc image", app.win, ("*.iso",)) do f
        (f isa AbstractString && !isempty(f)) && later(() -> write_iso!(app, f), app)
        nothing
    end
end

function eject_data!(app::App)
    d = ddrive(app); isempty(d) && return
    app.proc === nothing || return
    run(ignorestatus(`eject $d`); wait = false)
    app.data.media = Dict{String,Any}(); update_summary!(app)
    dlog(app, "eject $(d)")
end

# ───────────────────────────── page ─────────────────────────────

function add_dialog!(app::App; folders = false, system = false)
    (folders || system) || return later(() -> open_picker!(app), app)
    open_dialog(folders ? "Add album folders" : "Add photos", app.win,
                folders ? String[] : ("*.jpg, *.jpeg, *.png, *.heic, *.heif, *.webp, *.tif, *.tiff, *.gif, *.bmp, *.avif, *.dng, *.cr2, *.cr3, *.nef, *.arw, *.raf, *.orf, *.rw2, *.mp4, *.mov, *.m4v, *.JPG, *.JPEG, *.PNG, *.HEIC, *.MOV, *.MP4", "*");
                multiple = true, select_folder = folders) do fs
        fs === nothing && return nothing
        fs = fs isa AbstractString ? [fs] : collect(fs)
        filter!(f -> f isa AbstractString && !isempty(f), fs)
        isempty(fs) || later(() -> add_paths!(app, fs), app)
        nothing
    end
end

"Accept files and folders dropped from a file manager (GdkFileList)."
function setup_drop!(app::App, widget)
    gtype = ccall((:gdk_file_list_get_type, Gtk4.libgtk4), Gtk4.GLib.GType, ())
    target = GtkDropTarget(gtype, Gtk4.DragAction_COPY)
    push!(widget, target)
    app.data.w[:drop] = target
    # raw C callback: the GValue holding the file list isn't handled by Gtk4.jl's conversion
    signal_connect(target, "drop", Cint, (Ptr{Cvoid}, Cdouble, Cdouble)) do t, value, x, y, ud
        paths = String[]
        try
            fl = ccall((:g_value_get_boxed, Gtk4.GLib.libgobject), Ptr{Cvoid}, (Ptr{Cvoid},), value)
            lst = ccall((:gdk_file_list_get_files, Gtk4.libgtk4), Ptr{Gtk4.GLib._GSList{Ptr{Cvoid}}}, (Ptr{Cvoid},), fl)
            node = lst
            while node != C_NULL
                n = unsafe_load(node)
                cp = ccall((:g_file_get_path, Gtk4.GLib.libgio), Ptr{UInt8}, (Ptr{Cvoid},), n.data)
                cp == C_NULL || (push!(paths, unsafe_string(cp)); Gtk4.GLib.g_free(cp))
                node = n.next
            end
            ccall((:g_slist_free, Gtk4.GLib.libglib), Cvoid, (Ptr{Cvoid},), lst)
        catch
        end
        isempty(paths) || later(() -> add_paths!(app, paths), app)
        Cint(!isempty(paths))
    end
end

function build_data_page!(app::App)
    app.data = DataState()
    D = app.data; W = D.w
    page = GtkBox(:h; vexpand = true)

    # left: the compilation
    left = GtkBox(:v; hexpand = true, vexpand = true); add_css_class(left, "stage")
    addb = GtkButton("+ ADD PHOTOS…"); addb.tooltip_text = "Browse thumbnails and pick as many photos as you like (Ctrl+O)"
    albb = GtkButton("+ ADD ALBUM FOLDER…"); albb.tooltip_text = "Add whole folders; sub-folders are kept (Ctrl+Shift+O)"
    clrb = GtkButton("CLEAR"); add_css_class(clrb, "danger")
    W[:add] = addb; W[:addalbum] = albb; W[:clear] = clrb
    signal_connect(_ -> (add_dialog!(app); nothing), addb, "clicked")
    signal_connect(_ -> (add_dialog!(app; folders = true), nothing), albb, "clicked")
    signal_connect(clrb, "clicked") do _
        isempty(D.items) && return
        ask_dialog("Remove everything from the compilation?\n(Your files are not touched.)", app.win; no_text = "Cancel", yes_text = "Clear") do yes
            yes && later(() -> clear_items!(app), app)
        end
        nothing
    end
    title = GtkLabel("COMPILATION"); add_css_class(title, "section-title")
    hdr = hrow(title, GtkBox(:h; hexpand = true), addb, albb, clrb; spacing = 8)
    add_css_class(hdr, "listhdr")
    push!(left, hdr)
    lb = GtkListBox(; selection_mode = Gtk4.SelectionMode_NONE); add_css_class(lb, "disclist")
    W[:list] = lb
    empty_ = GtkLabel("ADD PHOTOS OR ALBUM FOLDERS\n\ndrop them here, or use the buttons above\nfolders keep their sub-folders on the disc";
                      justify = Gtk4.Justification_CENTER, vexpand = true, valign = Gtk4.Align_CENTER)
    add_css_class(empty_, "dim"); W[:empty] = empty_
    col = GtkBox(:v; vexpand = true); push!(col, lb, empty_)
    lsw = GtkScrolledWindow(; hscrollbar_policy = Gtk4.PolicyType_NEVER, vexpand = true)
    lsw[] = col
    push!(left, lsw)
    try setup_drop!(app, left) catch err; println("drag and drop unavailable: ", err) end
    push!(page, left)

    # right: disc, options, write
    side = GtkBox(:v; spacing = 0); add_css_class(side, "sidebar")
    sw = GtkScrolledWindow(; hscrollbar_policy = Gtk4.PolicyType_NEVER, vexpand = true)
    sw.width_request = 360; sw[] = side
    push!(page, sw)
    push!(side, GtkBox(:v; height_request = 10))

    s = section("01 · Disc")
    ring = GtkCanvas(200, 200; hexpand = true); W[:ring] = ring
    @guarded draw(ring) do w
        draw_ring(app, getgc(w), width(w), height(w))
    end
    sumL = GtkLabel(""; xalign = 0); add_css_class(sumL, "filename"); W[:sum] = sumL
    sizeL = GtkLabel(""; xalign = 0); add_css_class(sizeL, "doctitle"); W[:size] = sizeL
    fitL = GtkLabel(""; xalign = 0, wrap = true); add_css_class(fitL, "field-label"); W[:fit] = fitL
    push!(s, ring, sumL, sizeL, fitL)
    sizedd = dropdown(first.(DISC_SIZES), i -> later(() -> (D.size_idx = i; update_summary!(app)), app))
    push!(s, field_label("Capacity"), sizedd)
    medL = GtkLabel("NOT CHECKED"; xalign = 0, wrap = true); add_css_class(medL, "dim"); W[:mediainfo] = medL
    appendL = GtkLabel("Files already on this disc are kept; yours go in a new session."; xalign = 0, wrap = true)
    add_css_class(appendL, "field-label"); appendL.visible = false; W[:appendnote] = appendL
    push!(s, field_label("In the drive"), medL, appendL)
    push!(side, s)

    s = section("02 · Contents")
    push!(s, field_label("Disc name (max 32)"))
    vol = GtkEntry(; text = D.opts.volid, max_length = 32, hexpand = true); W[:volid] = vol
    signal_connect(e -> (D.opts.volid = Gtk4.G_.get_text(e); nothing), vol, "changed")
    push!(s, vol)
    fdd = dropdown(DATA_FILTER_LABELS, i -> later(() -> (D.filter = DATA_FILTERS[i]; rescan_all!(app)), app))
    fdd.tooltip_text = "What to take from album folders. Files you add one by one are always included."
    push!(s, field_label("From folders, include"), fdd)
    push!(side, s)

    s = section("03 · Write")
    push!(s, field_label("Drive"))
    de = GtkEntry(; hexpand = true, placeholder_text = "/dev/sr0"); W[:drive] = de
    signal_connect(_ -> (later(() -> update_data_actions!(app), app); nothing), de, "changed")
    scanb = GtkButton("SCAN"); W[:scan] = scanb
    signal_connect(scanb, "clicked") do _
        later(app) do
            ds = filter(f -> occursin(r"^/dev/sr\d+$", f), readdir("/dev"; join = true))
            isempty(ds) ? dlog(app, "no optical drives found") : (dlog(app, "drives: " * join(ds, ", ")); isempty(ddrive(app)) && (de.text = first(ds)))
        end
        nothing
    end
    push!(s, hrow(de, scanb))
    chk = GtkButton("CHECK DISC"); ej = GtkButton("EJECT"); W[:check] = chk; W[:deject] = ej
    signal_connect(_ -> (later(() -> check_media!(app), app); nothing), chk, "clicked")
    signal_connect(_ -> (later(() -> eject_data!(app), app); nothing), ej, "clicked")
    push!(s, hrow(chk, ej; homogeneous = true))
    spd = dropdown(["Max speed", "16×", "8×", "4×", "2×"], i -> (D.opts.speed = SPEEDS[i]))
    spd.tooltip_text = "Slower writes can be more reliable on cheap media"
    push!(s, field_label("Speed"), spd)
    for (k, label, tip) in ((:close, "Finalize disc", "Off = leave the disc open so more photos can be added later"),
                            (:verify, "Verify after writing", "Read every file back and compare its MD5 checksum"),
                            (:eject, "Eject when done", ""),
                            (:blank, "Erase rewritable disc first", "Only for RW media: wipe what's on it instead of adding to it"))
        c = GtkCheckButton(label; active = getfield(D.opts, k))
        isempty(tip) || (c.tooltip_text = tip)
        signal_connect(c, "toggled") do w
            setfield!(D.opts, k, w.active)
            k == :blank && later(() -> update_summary!(app), app)
            nothing
        end
        W[Symbol(:opt_, k)] = c
        push!(s, c)
    end
    wb = GtkButton("WRITE DISC"); add_css_class(wb, "primary"); W[:write] = wb
    ib = GtkButton("SAVE AS ISO IMAGE…"); W[:iso] = ib
    ib.tooltip_text = "Make a disc image instead (burn it later, or keep it as a backup)"
    signal_connect(_ -> (write_disc!(app); nothing), wb, "clicked")
    signal_connect(_ -> (write_iso_dialog!(app); nothing), ib, "clicked")
    pb = GtkProgressBar(; show_text = true, text = "READY"); W[:progress] = pb
    cb = GtkButton("ABORT"); add_css_class(cb, "danger"); cb.visible = false; W[:dcancel] = cb
    signal_connect(cb, "clicked") do _
        app.proc === nothing && return
        dlog(app, "abort requested — xorriso will stop at the next safe point")
        cli_interrupt(app.proc); nothing
    end
    push!(s, wb, ib, pb, cb)
    if !have_xorriso()
        warn = GtkLabel("xorriso is not installed. Install it with:\n  sudo pacman -S libisoburn"; xalign = 0, wrap = true, selectable = true)
        add_css_class(warn, "warn"); W[:nox] = warn
        push!(s, warn)
    end
    push!(side, s)

    s = section("04 · Output")
    buf = GtkTextBuffer()
    tv = GtkTextView(; buffer = buf, editable = false, cursor_visible = false, monospace = true,
                     wrap_mode = Gtk4.WrapMode_WORD_CHAR, left_margin = 6, top_margin = 4)
    osw = GtkScrolledWindow(; height_request = 150); osw[] = tv; add_css_class(osw, "log")
    W[:logbuf] = buf; W[:logview] = tv
    push!(s, osw)
    push!(side, s)

    have_xorriso() ? dlog(app, "xorriso: $(xorriso_path())") : dlog(app, "xorriso not found — sudo pacman -S libisoburn")
    update_summary!(app)
    page
end

"Called when the DATA DISC page is shown."
function data_page_shown!(app::App)
    D = app.data
    if isempty(ddrive(app))
        ds = filter(f -> occursin(r"^/dev/sr\d+$", f), readdir("/dev"; join = true))
        isempty(ds) || (D.w[:drive].text = first(ds))
    end
    isempty(D.media) && have_xorriso() && !isempty(ddrive(app)) && app.proc === nothing && check_media!(app)
end
