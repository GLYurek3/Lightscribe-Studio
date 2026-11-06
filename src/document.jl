# Label documents: snapshots, undo/redo history, save/open (.lslabel, TOML), export.

const LABEL_EXT = ".lslabel"
const LABEL_FILTER = "*.lslabel"
const HISTORY_LIMIT = 200
const COMMIT_DELAY_MS = 450   # edits closer together than this become one undo step

# ───────────────────────────── snapshots ─────────────────────────────

"Everything that defines the printed label (not view settings, drive, or which text is selected)."
function snapshot(app::App)
    Dict{String,Any}(
        "version" => 1,
        "image"   => app.srcpath,
        "mode"    => app.mode,
        "adjust"  => Dict{String,Any}(string(k) => getfield(app.adj, k) for k in fieldnames(Adjustments)),
        "text"    => [Dict{String,Any}(string(k) => getfield(L, k) for k in fieldnames(TextLayer)) for L in app.texts],
    )
end

blank_snapshot() = Dict{String,Any}(
    "version" => 1, "image" => "", "mode" => "full",
    "adjust" => Dict{String,Any}(string(k) => getfield(Adjustments(), k) for k in fieldnames(Adjustments)),
    "text" => Dict{String,Any}[])

"Copy known keys from a Dict onto a mutable struct, converting types; unknown/missing keys are ignored."
function fill_struct!(obj, d::AbstractDict)
    for k in fieldnames(typeof(obj))
        v = get(d, string(k), nothing)
        v === nothing && continue
        T = fieldtype(typeof(obj), k)
        try
            setfield!(obj, k, T <: AbstractString ? string(v) : convert(T, v))
        catch
        end
    end
    obj
end

function set_image!(app::App, path::AbstractString)
    W = app.widgets
    if isempty(path)
        app.src_full = nothing; app.src_prev = nothing; app.srcpath = ""
        W[:filename].label = "—"; W[:imginfo].label = ""
        return true
    end
    cached = get(app.image_cache, path, nothing)
    if cached === nothing
        isfile(path) || (logline(app, "image not found: $(path)"); return false)
        full = load_image(path)
        length(app.image_cache) >= 4 && empty!(app.image_cache)
        cached = app.image_cache[path] = (full, downscale(full, 1400))
    end
    app.src_full, app.src_prev = cached
    app.srcpath = path
    h, w = size(app.src_full)
    W[:filename].label = basename(path); W[:imginfo].label = "$(w) × $(h) PX"
    true
end

"Make the app match a snapshot. Widgets are updated on idle (never inside a signal)."
function restore!(app::App, snap::AbstractDict)
    app.restoring = true
    try
        fill_struct!(app.adj, get(snap, "adjust", Dict()))
        app.texts = [fill_struct!(TextLayer(), d) for d in get(snap, "text", [])]
        app.sel = isempty(app.texts) ? 0 : clamp(app.sel, 1, length(app.texts))
        isempty(app.texts) && (app.drag_text = false)
        m = string(get(snap, "mode", "full")); app.mode = m in MODES ? m : "full"
        img = string(get(snap, "image", ""))
        img == app.srcpath || set_image!(app, img) || set_image!(app, "")
        app.show_drive_preview = false
        recompute!(app)
    finally
        app.restoring = false
    end
    sync_widgets!(app); sync_text_widgets!(app); sync_mode!(app)
    update_actions!(app); update_title!(app)
end

function sync_mode!(app::App)
    Gtk4.GLib.g_idle_add() do
        app.syncing = true
        try Gtk4.G_.set_selected(app.widgets[:mode], findfirst(==(app.mode), MODES) - 1) finally app.syncing = false end
        false
    end
end

# ───────────────────────────── history ─────────────────────────────

"Note that the label changed; a burst of changes is committed as one undo step."
function touch!(app::App)
    app.restoring && return
    update_title!(app)
    app.commit_pending && return
    app.commit_pending = true
    Gtk4.GLib.g_timeout_add(COMMIT_DELAY_MS) do
        app.commit_pending = false
        commit!(app)
        false
    end
    nothing
end

function commit!(app::App)
    cur = snapshot(app)
    cur == app.committed && return false
    push!(app.undo, app.committed)
    length(app.undo) > HISTORY_LIMIT && popfirst!(app.undo)
    app.committed = cur
    empty!(app.redo)
    update_title!(app)
    true
end

function undo!(app::App)
    commit!(app)                       # pending edits become the step we are undoing
    isempty(app.undo) && return
    push!(app.redo, app.committed)
    app.committed = pop!(app.undo)
    restore!(app, app.committed)
    logline(app, "undo  ($(length(app.undo)) more)")
end

function redo!(app::App)
    commit!(app)
    isempty(app.redo) && return
    push!(app.undo, app.committed)
    app.committed = pop!(app.redo)
    restore!(app, app.committed)
    logline(app, "redo  ($(length(app.redo)) more)")
end

"Start a fresh history from the current state (after New / Open)."
function reset_history!(app::App; saved = true)
    empty!(app.undo); empty!(app.redo)
    app.committed = snapshot(app)
    app.saved_snap = saved ? app.committed : nothing
    update_title!(app)
end

is_dirty(app::App) = app.saved_snap === nothing || snapshot(app) != app.saved_snap

function update_title!(app::App)
    W = app.widgets
    haskey(W, :doctitle) || return
    name = isempty(app.docpath) ? "UNTITLED" : uppercase(basename(app.docpath))
    dirty = is_dirty(app) && !(isempty(app.docpath) && snapshot(app) == blank_snapshot())
    W[:doctitle].label = dirty ? name * " •" : name
    app.win.title = (dirty ? "• " : "") * (isempty(app.docpath) ? "Untitled" : basename(app.docpath)) * " — LightScribe Studio"
    haskey(W, :undo) && (W[:undo].sensitive = !isempty(app.undo) || snapshot(app) != app.committed)
    haskey(W, :redo) && (W[:redo].sensitive = !isempty(app.redo))
end

# ───────────────────────────── files ─────────────────────────────

function save_label!(app::App, path::AbstractString)
    endswith(lowercase(path), LABEL_EXT) || (path *= LABEL_EXT)
    commit!(app)
    snap = snapshot(app)
    out = deepcopy(snap)
    if !isempty(app.srcpath)
        out["image"] = abspath(app.srcpath)
        out["image_relative"] = relpath(abspath(app.srcpath), dirname(abspath(path)))
    end
    out["saved_with"] = "LightScribe Studio"
    tmp = path * ".tmp"
    open(tmp, "w") do io
        println(io, "# LightScribe Studio label — the image is referenced, not embedded")
        TOML.print(io, out; sorted = true)
    end
    mv(tmp, path; force = true)
    app.docpath = path
    app.saved_snap = snap
    update_title!(app)
    logline(app, "saved $(path)")
end

function open_label!(app::App, path::AbstractString)
    d = try
        TOML.parsefile(path)
    catch err
        logline(app, "could not read $(path): $(sprint(showerror, err))"); return
    end
    get(d, "version", 0) == 1 || logline(app, "warning: unknown label version $(get(d, "version", "?")), loading anyway")
    # find the image: next to the label first (survives moving both together), then the absolute path
    img = ""
    rel = get(d, "image_relative", ""); ab = get(d, "image", "")
    if !isempty(rel) && isfile(joinpath(dirname(abspath(path)), rel))
        img = normpath(joinpath(dirname(abspath(path)), rel))
    elseif !isempty(ab) && isfile(ab)
        img = ab
    elseif !isempty(ab)
        logline(app, "image $(ab) is missing — opening the text and settings only")
    end
    d["image"] = img
    app.sel = 1
    restore!(app, d)
    app.docpath = path
    reset_history!(app; saved = isempty(ab) || !isempty(img))
    logline(app, "opened $(path)")
end

function new_label!(app::App)
    app.sel = 0
    restore!(app, blank_snapshot())
    app.docpath = ""
    reset_history!(app)
    logline(app, "new label")
end

"Run `f` now, or after the user agrees to drop unsaved changes."
function confirm_discard(f::Function, app::App, what::AbstractString)
    if !is_dirty(app) || (isempty(app.docpath) && snapshot(app) == blank_snapshot())
        later(f, app); return
    end
    ask_dialog("Discard unsaved changes and $(what)?", app.win; no_text = "Cancel", yes_text = "Discard") do yes
        yes && later(f, app)
    end
    nothing
end

function save_as_dialog!(app::App)
    save_dialog("Save label", app.win, (LABEL_FILTER,)) do f
        (f isa AbstractString && !isempty(f)) && later(() -> save_label!(app, f), app)
        nothing
    end
    nothing
end

save_or_ask!(app::App) = isempty(app.docpath) ? save_as_dialog!(app) : later(() -> save_label!(app, app.docpath), app)

"Open dialog for both label files and images; dispatch on extension."
function open_any_dialog!(app::App)
    filt = "$(LABEL_FILTER), " * IMAGE_FILTER
    open_dialog("Open label or image", app.win, (filt, LABEL_FILTER, IMAGE_FILTER)) do f
        (f isa AbstractString && !isempty(f)) || return nothing
        if endswith(lowercase(f), LABEL_EXT)
            confirm_discard(() -> open_label!(app, f), app, "open $(basename(f))")
        else
            later(() -> open_image!(app, f), app)
        end
        nothing
    end
    nothing
end

function export_image!(app::App, path::AbstractString)
    has_content(app) || (logline(app, "nothing to export"); return)
    lower = lowercase(path)
    (endswith(lower, ".png") || endswith(lower, ".bmp")) || (path *= ".png")
    img = compose(app, app.src_full, BURN_N)
    if endswith(lowercase(path), ".bmp")
        write_bmp(path, img)
    else
        data = Matrix{UInt32}(undef, size(img))
        @inbounds for i in eachindex(img)
            v = round(UInt32, clamp(img[i], 0f0, 1f0) * 255)
            data[i] = 0xff000000 | (v << 16) | (v << 8) | v
        end
        Cairo.write_to_png(Cairo.CairoImageSurface(data, Cairo.FORMAT_RGB24), path)
    end
    logline(app, "exported $(BURN_N)×$(BURN_N) ($(BURN_DPI) dpi, 120 mm) → $(path)")
end

function export_dialog!(app::App)
    save_dialog("Export label image", app.win, ("*.png", "*.bmp")) do f
        (f isa AbstractString && !isempty(f)) && later(() -> export_image!(app, f), app)
        nothing
    end
    nothing
end
