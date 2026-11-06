# Omarchy theme integration: read the active palette and turn it into GTK CSS.

const THEME_DIR = joinpath(homedir(), ".local", "state", "omarchy", "current", "theme")

const LUMON = Dict(
    "accent" => "#8bc9eb", "selection" => "#243d56", "muted" => "#304860",
    "background" => "#16242d", "dark_background" => "#101b21",
    "darker_background" => "#0b1216", "lighter_background" => "#1b2d40",
    "foreground" => "#d6e2ee", "dark_foreground" => "#4d86b0",
    "bright_foreground" => "#f2fcff", "red" => "#4d86b0", "cyan" => "#b4e4f6",
    "blue" => "#6fb8e3", "brown" => "#456475",
)

struct Palette
    c::Dict{String,String}
    name::String
end
Base.getindex(p::Palette, k::AbstractString) = get(p.c, k, get(LUMON, k, "#ff00ff"))

function load_palette()
    c = copy(LUMON); name = "lumon"
    f = joinpath(THEME_DIR, "colors.toml")
    try
        isfile(f) && merge!(c, Dict(k => string(v) for (k, v) in TOML.parsefile(f) if v isa AbstractString))
        nf = joinpath(dirname(THEME_DIR), "theme.name")
        isfile(nf) && (name = strip(read(nf, String)))
    catch err
        @warn "Could not read Omarchy theme, using Lumon defaults" err
    end
    Palette(c, name)
end

theme_stamp() = (f = joinpath(dirname(THEME_DIR), "theme.name"); isfile(f) ? mtime(f) : 0.0)

function hex2rgb(h::AbstractString)
    h = lstrip(h, '#')
    (parse(Int, h[1:2]; base=16) / 255, parse(Int, h[3:4]; base=16) / 255, parse(Int, h[5:6]; base=16) / 255)
end
rgba(h, a) = (c = hex2rgb(h); "rgba($(round(Int,255c[1])),$(round(Int,255c[2])),$(round(Int,255c[3])),$a)")

function theme_css(p::Palette; font = "Liberation Mono")
    bg, bgd, bgdd, bgl = p["background"], p["dark_background"], p["darker_background"], p["lighter_background"]
    fg, fgd, fgb = p["foreground"], p["dark_foreground"], p["bright_foreground"]
    acc, sel, mut = p["accent"], p["selection"], p["muted"]
    """
    * { font-family: "$font", monospace; font-size: 10.5pt; }
    window, window.background { background: $bg; color: $fg; }
    .topbar { background: $bgdd; border-bottom: 1px solid $mut; padding: 6px 14px; }
    .brand { color: $acc; font-weight: bold; letter-spacing: 3px; }
    .brand-sub { color: $fgd; letter-spacing: 2px; }
    .doctitle { color: $fgb; letter-spacing: 1px; }
    button.tool { padding: 1px 8px; min-height: 18px; font-size: 9pt; letter-spacing: 1px; background: $bgd; }
    button.tool:hover { background: $sel; }
    stackswitcher.pages button { padding: 1px 12px; min-height: 18px; font-size: 9pt; letter-spacing: 2px; background: $bgd; }
    stackswitcher.pages button:checked { background: $acc; color: $bgdd; border-color: $acc; }
    .listhdr { background: $bgdd; border-bottom: 1px solid $mut; padding: 8px 14px; }
    list.disclist { background: transparent; }
    list.disclist row { border-bottom: 1px solid $bgl; padding: 8px 14px; }
    list.disclist row:hover { background: $bgl; }
    .thumb { background: $bgdd; border: 1px solid $mut; }
    .thumb-icon { color: $fgb; font-size: 12pt; margin: 2px 4px; text-shadow: 0 0 3px $bgdd; }
    label.small { font-size: 8.5pt; }
    entry.flat { background: transparent; border-color: transparent; color: $fgb; padding-left: 0; }
    entry.flat:focus-within { background: $bgdd; border-color: $acc; padding-left: 4px; }
    .warn { color: $bgdd; background: $fgb; padding: 4px 6px; }
    label.ok { color: $acc; }
    flowbox.pickgrid { padding: 14px; }
    flowboxchild.photo-tile, flowboxchild.folder-tile { padding: 6px; border: 1px solid transparent; background: transparent; }
    flowboxchild.photo-tile:hover, flowboxchild.folder-tile:hover { background: $bgl; border-color: $mut; }
    flowboxchild.picked, flowboxchild.picked:hover { background: $sel; border-color: $acc; }
    flowboxchild.picked .thumb { border-color: $acc; }
    .tick { color: transparent; background: transparent; margin: 4px; padding: 0 5px; font-weight: bold; }
    flowboxchild.photo-tile:hover .tick { color: $fgd; background: rgba(11,18,22,0.6); border: 1px solid $mut; }
    flowboxchild.picked .tick, flowboxchild.picked:hover .tick { color: $bgdd; background: $acc; border: 1px solid $acc; }
    .badge { color: $bgdd; background: $fgd; font-size: 8pt; letter-spacing: 1px; padding: 0 4px; margin: 4px; }
    .folder-glyph { color: $acc; font-size: 22pt; text-shadow: 0 0 6px $bgdd; }
    .pickbar { background: $bgdd; border-top: 1px solid $mut; padding: 8px 14px; }
    .topbar separator { background: $mut; min-width: 1px; margin: 3px 4px; }
    .status-pill { color: $bgdd; background: $acc; padding: 1px 8px; font-weight: bold; letter-spacing: 1px; }
    .status-pill.idle { background: $mut; color: $fg; }
    .status-pill.busy { background: $fgb; color: $bgdd; }
    .stage { background: $bgd; }
    .sidebar { background: $bg; border-left: 1px solid $mut; }
    .section { border: 1px solid $mut; background: $bgd; padding: 10px 12px 12px 12px; margin: 0 10px 10px 10px; }
    .section-title { color: $acc; font-weight: bold; letter-spacing: 3px; font-size: 9.5pt; margin-bottom: 4px; }
    .field-label { color: $fgd; font-size: 9pt; letter-spacing: 1px; }
    .dim { color: $fgd; }
    .filename { color: $fgb; }
    button {
        background: $bgl; color: $fg; border: 1px solid $mut; border-radius: 0;
        box-shadow: none; padding: 4px 10px; min-height: 22px; text-shadow: none;
    }
    button:hover { background: $sel; border-color: $acc; color: $fgb; }
    button:active, button:checked { background: $acc; color: $bgdd; border-color: $acc; }
    button:disabled { color: $mut; border-color: $bgl; background: $bgd; }
    button.primary { background: $acc; color: $bgdd; border-color: $acc; font-weight: bold; letter-spacing: 2px; }
    button.primary:hover { background: $fgb; border-color: $fgb; }
    button.primary:disabled { background: $mut; color: $bgd; border-color: $mut; }
    button.danger { border-color: $fgd; }
    scale { padding: 2px 0; min-height: 18px; }
    scale trough { background: $bgdd; border: 1px solid $mut; border-radius: 0; min-height: 4px; }
    scale highlight { background: $acc; border-radius: 0; }
    scale slider { background: $fgb; border: 1px solid $acc; border-radius: 0; min-width: 8px; min-height: 14px; margin: -6px 0; box-shadow: none; }
    scale slider:hover { background: $acc; }
    scale value { color: $fgb; font-size: 9pt; min-width: 48px; }
    checkbutton { color: $fg; }
    checkbutton check { background: $bgdd; border: 1px solid $mut; border-radius: 0; min-width: 12px; min-height: 12px; }
    checkbutton check:checked { background: $acc; border-color: $acc; color: $bgdd; }
    checkbutton:hover check { border-color: $acc; }
    dropdown > button { padding: 2px 8px; }
    popover > contents, popover.menu > contents { background: $bgdd; border: 1px solid $acc; border-radius: 0; color: $fg; padding: 2px; }
    popover listview, popover list { background: transparent; }
    popover row:hover, popover row:selected { background: $sel; }
    entry { background: $bgdd; color: $fgb; border: 1px solid $mut; border-radius: 0; box-shadow: none; caret-color: $acc; min-height: 22px; }
    entry:focus-within { border-color: $acc; outline: none; }
    textview, textview text { background: $bgdd; color: $fg; font-size: 9pt; }
    .log { border: 1px solid $mut; }
    progressbar trough { background: $bgdd; border: 1px solid $mut; border-radius: 0; min-height: 8px; }
    progressbar progress { background: $acc; border-radius: 0; min-height: 8px; }
    progressbar text { color: $fgd; font-size: 9pt; }
    scrolledwindow, viewport { background: transparent; }
    scrollbar { background: transparent; }
    scrollbar slider { background: $mut; border-radius: 0; min-width: 4px; }
    scrollbar slider:hover { background: $acc; }
    separator { background: $mut; min-height: 1px; }
    tooltip, tooltip.background { background: $bgdd; color: $fgb; border: 1px solid $acc; border-radius: 0; }
    window.dialog, messagedialog, .message-dialog { background: $bg; color: $fg; border: 1px solid $acc; border-radius: 0; }
    """
end
