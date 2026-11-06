# Data discs: collect photos / album folders and write them to CD/DVD/BD (or an ISO) with xorriso.
# No GTK in here — the UI lives in datagui.jl.

# read at run time (a const would be frozen into the precompile cache)
xorriso_name() = get(ENV, "LIGHTSCRIBE_XORRISO", "xorriso")
const SECTOR = 2048

const PHOTO_EXTS = Set(split("jpg jpeg jpe jfif png gif bmp tif tiff webp heic heif avif jxl svg " *
                             "raw dng cr2 cr3 crw nef nrw arw srf sr2 orf rw2 raf srw pef x3f 3fr erf kdc mos mrw rwl iiq"))
const VIDEO_EXTS = Set(split("mp4 m4v mov avi mkv mts m2ts mpg mpeg 3gp 3g2 wmv webm"))
const SIDECAR_EXTS = Set(split("xmp aae thm"))   # edit/metadata sidecars that belong with photos
const JUNK_NAMES = Set(["Thumbs.db", "desktop.ini", ".DS_Store", ".directory", ".picasa.ini", "Picasa.ini"])

"What to take from folders: photos only, photos + videos (+ sidecars), or everything."
const DATA_FILTERS = ["media", "photos", "all"]
const DATA_FILTER_LABELS = ["Photos & videos", "Photos only", "All files"]

"Preset capacities in 2048-byte sectors (first entry = ask the drive)."
const DISC_SIZES = [("Disc in drive", 0), ("CD · 700 MB", 359_846), ("DVD · 4.7 GB", 2_295_104),
                    ("DVD DL · 8.5 GB", 4_173_824), ("BD · 25 GB", 12_219_392)]
const SPEEDS = ["max", "16", "8", "4", "2"]

ext(p) = lowercase(lstrip(splitext(p)[2], '.'))
is_photo(p) = ext(p) in PHOTO_EXTS
thumbable(p) = ext(p) in ("jpg", "jpeg", "jpe", "jfif", "png", "gif", "bmp", "tif", "tiff", "webp", "avif", "heic", "heif", "svg")

function wanted(path::AbstractString, filter::AbstractString)
    b = basename(path)
    (startswith(b, ".") || b in JUNK_NAMES) && return false
    filter == "all" && return true
    e = ext(path)
    filter == "photos" && return e in PHOTO_EXTS
    e in PHOTO_EXTS || e in VIDEO_EXTS || e in SIDECAR_EXTS
end

"One thing the user added: a single file, or a folder (album) copied with its sub-folders."
Base.@kwdef mutable struct DiscItem
    path::String                       # absolute source path
    name::String                       # name on the disc (top level)
    isdir::Bool = false
    files::Vector{Tuple{String,String,Int}} = Tuple{String,String,Int}[]   # (source, path inside item, bytes)
    dirs::Int = 0
    bytes::Int = 0
    thumb::String = ""                 # a photo to show for this item
    photos::Int = 0
    videos::Int = 0
end

"(Re)collect the files of an item. Explicitly added single files are always kept."
function scan_item!(it::DiscItem, filter::AbstractString)
    empty!(it.files); it.dirs = 0; it.bytes = 0; it.photos = 0; it.videos = 0
    if !it.isdir
        sz = isfile(it.path) ? filesize(it.path) : 0
        push!(it.files, (it.path, "", sz))
    else
        for (root, dirs, files) in walkdir(it.path; onerror = e -> nothing)
            filter!(d -> !startswith(d, ".") && d != "@eaDir", dirs)   # hidden + Synology thumbnail dirs
            sort!(dirs; by = lowercase)
            rel = relpath(root, it.path)
            got = false
            for f in sort(files; by = lowercase)
                p = joinpath(root, f)
                (isfile(p) && wanted(p, filter)) || continue
                push!(it.files, (p, rel == "." ? f : joinpath(rel, f), filesize(p)))
                got = true
            end
            got && rel != "." && (it.dirs += 1)
        end
    end
    for (p, _, sz) in it.files
        it.bytes += sz
        e = ext(p)
        e in PHOTO_EXTS && (it.photos += 1)
        e in VIDEO_EXTS && (it.videos += 1)
        isempty(it.thumb) && thumbable(p) && (it.thumb = p)
    end
    it
end

function new_item(path::AbstractString, filter::AbstractString)
    p = rstrip(abspath(path), '/')
    scan_item!(DiscItem(path = p, name = basename(p), isdir = isdir(p)), filter)
end

"Make top-level names valid and unique (case-insensitively, so they also work on Windows)."
function unique_names!(items::Vector{DiscItem})
    seen = Set{String}()
    for it in items
        n = strip(replace(it.name, r"[/\x00]" => "_"))
        isempty(n) && (n = basename(it.path))
        base, e = it.isdir ? (n, "") : splitext(n)
        k = 2; cand = n
        while lowercase(cand) in seen
            cand = "$(base) ($(k))$(e)"; k += 1
        end
        push!(seen, lowercase(cand))
        it.name = cand
    end
    items
end

"Conservative size estimate of the ISO-9660 + Rock Ridge + Joliet image, in sectors."
function estimate_sectors(items::Vector{DiscItem})
    nfiles = sum(it -> length(it.files), items; init = 0)
    ndirs = sum(it -> it.dirs + it.isdir, items; init = 0)
    data = sum(it -> sum(f -> cld(f[3], SECTOR), it.files; init = 0), items; init = 0)
    # system area + volume descriptors + path tables, ~3 directory records per file per tree, MD5 array
    data + 400 + cld(nfiles * 3 * 120, SECTOR) * 2 + ndirs * 4 + cld(nfiles * 16, SECTOR)
end

total_bytes(items) = sum(it -> it.bytes, items; init = 0)
total_files(items) = sum(it -> length(it.files), items; init = 0)

function human(bytes::Real)
    bytes < 1024 && return "$(round(Int, bytes)) B"
    for (u, d) in (("KB", 1024.0), ("MB", 1024.0^2), ("GB", 1024.0^3), ("TB", 1024.0^4))
        v = bytes / d
        v < 1024 && return (v < 10 ? string(round(v; digits = 2)) : v < 100 ? string(round(v; digits = 1)) : string(round(Int, v))) * " " * u
    end
end

# ───────────────────────────── xorriso ─────────────────────────────

xorriso_path() = Sys.which(xorriso_name())
have_xorriso() = xorriso_path() !== nothing

"Quote one word for xorriso's -options_from_file parser (quoted parts concatenate, like sh)."
xq(s::AbstractString) = "'" * replace(s, "'" => "'\"'\"'") * "'"

"Write the -map list for all items; returns the file path."
function write_map_file(items::Vector{DiscItem}, path::AbstractString)
    mkpath(dirname(path))
    open(path, "w") do io
        for it in items, (src, rel, _) in it.files
            dst = "/" * (isempty(rel) ? it.name : it.name * "/" * rel)
            println(io, "-map ", xq(src), " ", xq(dst))
        end
    end
    path
end

Base.@kwdef mutable struct BurnOptions
    volid::String = "PHOTOS"
    close::Bool = true        # finalize: no further sessions
    blank::Bool = false       # erase rewritable media first
    verify::Bool = true
    eject::Bool = true
    speed::String = "max"
end

"Valid volume label: ≤32 characters, no slashes."
volid_clean(s) = (v = strip(replace(s, r"[/\\\x00-\x1f]" => "_")); first(isempty(v) ? "PHOTOS" : v, 32))

"""
Command that writes `items` to `target` (a drive, or `stdio:/path.iso`). Appendable discs get a
new session holding the old files plus the new ones (multisession), unless `blank` is set.
"""
function xorriso_write_cmd(target::AbstractString, mapfile::AbstractString, o::BurnOptions; mediakind = "")
    iso = startswith(target, "stdio:")
    args = String["-abort_on", "FAILURE", "-report_about", "UPDATE", "-pkt_output", "off"]
    if o.blank && !iso
        append!(args, ["-outdev", target, "-blank", "as_needed"])
    else
        append!(args, [iso ? "-outdev" : "-dev", target])
    end
    o.speed == "max" || iso || append!(args, ["-speed", o.speed * (occursin("CD", mediakind) ? "c" : occursin("BD", mediakind) ? "b" : "d")])
    append!(args, ["-volid", volid_clean(o.volid), "-joliet", "on", "-rockridge", "on",
                   "-compliance", "joliet_long_names", "-md5", "on",
                   "-options_from_file", mapfile])
    iso || append!(args, ["-close", o.close ? "on" : "off"])
    # libburn writes blank DVD-R in DAO mode by default, which always closes the disc;
    # incremental (TAO) recording is what keeps it open for more sessions
    (!iso && !o.close) && append!(args, ["-write_type", "tao"])
    push!(args, "-commit")
    (o.eject && !o.verify && !iso) && append!(args, ["-eject", "all"])
    `$(xorriso_path()) $args`
end

"Re-read every file and compare it with the MD5 recorded while writing."
function xorriso_verify_cmd(target::AbstractString; eject = false)
    args = String["-abort_on", "FAILURE", "-report_about", "UPDATE", "-md5", "on", "-indev", target,
                  "-check_md5_r", "SORRY", "/", "--"]
    eject && append!(args, ["-eject", "all"])
    `$(xorriso_path()) $args`
end

media_cmd(drive) = `$(xorriso_path()) -report_about WARNING -outdev $drive -toc`

"Pull the interesting fields out of `xorriso -toc` output."
function parse_media(out::AbstractString)
    d = Dict{String,Any}()
    m = match(r"Media current:\s*(.+)", out); m === nothing || (d["kind"] = strip(m[1]))
    m = match(r"Media status\s*:\s*(.+)", out); m === nothing || (d["status"] = strip(m[1]))
    m = match(r"Media summary:\s*(.+)", out); m === nothing || (d["summary"] = strip(m[1]))
    m = match(r"Media blocks\s*:\s*(\d+) readable\s*,\s*(\d+) writable\s*,\s*(\d+) overall", out)
    if m !== nothing
        d["readable"] = parse(Int, m[1]); d["writable"] = parse(Int, m[2]); d["overall"] = parse(Int, m[3])
    end
    m = match(r"Drive type\s*:\s*vendor '([^']*)' product '([^']*)'", out)
    m === nothing || (d["drive"] = strip(strip(m[1]) * " " * strip(m[2])))
    m = match(r"Volume id\s*:\s*'([^']*)'", out); m === nothing || (d["volid"] = m[1])
    st = get(d, "status", "")
    d["blank"] = occursin("is blank", st)
    d["appendable"] = occursin("appendable", st)
    d["closed"] = occursin("is closed", st)
    d["rewritable"] = occursin(r"RW|RE|RAM|overwriteable", get(d, "kind", ""))
    d["none"] = occursin("is not present", st) || occursin(r"No media|none", get(d, "kind", ""))
    d
end

"""
Spawn any command, merging stderr into stdout, calling `on_line` per line (split on CR/LF)
and `on_done(ok)` at the end, from an async task. Returns the Process.
"""
function spawn_lines(cmd::Cmd, on_line::Function, on_done::Function)
    proc = open(`bash -c 'exec "$@" 2>&1' _ $(cmd.exec)`, "r")
    @async begin
        buf = IOBuffer()
        try
            while !eof(proc)
                for b in readavailable(proc)
                    if b == UInt8('\n') || b == UInt8('\r')
                        line = String(take!(buf))
                        isempty(strip(line)) || on_line(line)
                    else
                        write(buf, b)
                    end
                end
            end
            rest = String(take!(buf)); isempty(strip(rest)) || on_line(rest)
        catch err
            on_line("error: $(sprint(showerror, err))")
        end
        wait(proc)
        on_done(success(proc))
    end
    proc
end

"Stage, percent and/or bytes processed from an xorriso UPDATE line, or nothing."
function parse_progress(line::AbstractString)
    m = match(r"Writing:\s+\d+s\s+(\d+(?:\.\d+)?)%", line)
    m === nothing || return (stage = "Writing", pct = parse(Float64, m[1]), bytes = nothing)
    m = match(r"(\d+(?:\.\d+)?)% done", line)
    m === nothing || return (stage = "Writing", pct = parse(Float64, m[1]), bytes = nothing)
    m = match(r"[Bb]lanking.*?(\d+(?:\.\d+)?)%", line)
    m === nothing || return (stage = "Erasing", pct = parse(Float64, m[1]), bytes = nothing)
    occursin(r"[Cc]losing (track|session)|[Ff]ixating|[Ff]ormatting", line) &&
        return (stage = "Closing", pct = nothing, bytes = nothing)
    m = match(r"(\d+(?:\.\d+)?)\s*([kmgKMG]?)\s+content bytes read", line)
    if m !== nothing
        mult = Dict("" => 1.0, "k" => 1024.0, "m" => 1024.0^2, "g" => 1024.0^3)[lowercase(m[2])]
        return (stage = "Verifying", pct = nothing, bytes = parse(Float64, m[1]) * mult)
    end
    nothing
end
