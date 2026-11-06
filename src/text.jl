# Text layers, rendered with Cairo straight into the label raster (same pixels for preview and burn).

const TEXT_PATHS = ["straight", "arc_top", "arc_bottom"]

Base.@kwdef mutable struct TextLayer
    text::String      = "LABEL TEXT"
    font::String      = "Liberation Sans"
    size::Float64     = 6.0      # cap-ish height in mm (font size)
    bold::Bool        = true
    italic::Bool      = false
    path::String      = "arc_top"  # straight | arc_top | arc_bottom
    x::Float64        = 0.0      # mm from centre (straight)
    y::Float64        = -42.0
    angle::Float64    = 0.0      # straight: rotation; arc: position on the ring (0 = top, clockwise)
    radius::Float64   = 50.0     # arc: radius of the text band centre, mm
    spacing::Float64  = 0.0      # extra letter spacing, mm
    clear::Bool       = false    # true = knock out (unburned) instead of burn
end

"Default layer for the n-th added text, laid out so successive layers don't stack."
function default_layer(n::Int)
    n == 1 && return TextLayer(text = "TITLE", path = "arc_top", radius = 50.0, size = 7.0)
    n == 2 && return TextLayer(text = "subtitle", path = "arc_bottom", radius = 50.0, angle = 180.0, size = 5.0, bold = false)
    TextLayer(text = "TEXT", path = "straight", x = 0.0, y = 30.0, size = 5.0)  # just below the hub
end

function setup_font!(ctx, L::TextLayer, pxmm)
    Cairo.select_font_face(ctx, L.font,
        L.italic ? Cairo.FONT_SLANT_ITALIC : Cairo.FONT_SLANT_NORMAL,
        L.bold ? Cairo.FONT_WEIGHT_BOLD : Cairo.FONT_WEIGHT_NORMAL)
    Cairo.set_font_size(ctx, L.size * pxmm)
end

advance(ctx, s) = Cairo.text_extents(ctx, s)[5]

"Draw one layer onto `ctx` whose origin is the disc centre and units are pixels."
function draw_layer!(ctx, L::TextLayer, pxmm)
    isempty(strip(L.text)) && return
    setup_font!(ctx, L, pxmm)
    h = L.size * pxmm * 0.72          # approximate cap height
    sp = L.spacing * pxmm
    if L.path == "straight"
        lines = split(L.text, '\n')
        lh = L.size * pxmm * 1.2
        Cairo.save(ctx)
        Cairo.translate(ctx, L.x * pxmm, L.y * pxmm)
        Cairo.rotate(ctx, deg2rad(L.angle))
        y0 = -lh * (length(lines) - 1) / 2 + h / 2
        for (i, line) in enumerate(lines)
            chars = collect(graphemes_or_chars(line))
            w = sum(advance(ctx, c) for c in chars; init = 0.0) + sp * max(length(chars) - 1, 0)
            x = -w / 2
            for c in chars
                Cairo.move_to(ctx, x, y0 + (i - 1) * lh)
                Cairo.show_text(ctx, c)
                x += advance(ctx, c) + sp
            end
        end
        Cairo.restore(ctx)
    else
        text = replace(L.text, '\n' => ' ')
        chars = collect(graphemes_or_chars(text))
        widths = [advance(ctx, c) for c in chars]
        total = sum(widths; init = 0.0) + sp * max(length(chars) - 1, 0)
        top = L.path == "arc_top"
        # baseline radius: glyphs grow outward on top arcs and inward on bottom arcs
        r = max(L.radius * pxmm + (top ? -h / 2 : h / 2), 1.0)
        span = total / r
        θc = deg2rad(L.angle)
        cum = 0.0
        for (c, w) in zip(chars, widths)
            mid = (cum + w / 2) / r
            a = top ? θc - span / 2 + mid : θc + span / 2 - mid   # angle from top, clockwise
            Cairo.save(ctx)
            Cairo.translate(ctx, r * sin(a), -r * cos(a))
            Cairo.rotate(ctx, top ? a : a + π)
            Cairo.move_to(ctx, -w / 2, 0)
            Cairo.show_text(ctx, c)
            Cairo.restore(ctx)
            cum += w + sp
        end
    end
end

# Unicode-aware enough for labels: split into grapheme clusters so accents stay attached.
graphemes_or_chars(s) = (string(g) for g in Base.Unicode.graphemes(s))

"""
Composite text layers onto `img` (N×N, covers the 120 mm disc). Burn layers darken,
clear layers lighten, applied in order.
"""
function draw_text!(img::Matrix{Float32}, layers::Vector{TextLayer})
    isempty(layers) && return img
    N = size(img, 1)
    pxmm = N / (2 * DISC_RADIUS_MM)
    surf = Cairo.CairoARGBSurface(N, N)
    ctx = Cairo.CairoContext(surf)
    for L in layers
        isempty(strip(L.text)) && continue
        Cairo.save(ctx)
        Cairo.set_operator(ctx, Cairo.OPERATOR_CLEAR); Cairo.paint(ctx)
        Cairo.restore(ctx)
        Cairo.save(ctx)
        Cairo.translate(ctx, N / 2, N / 2)
        Cairo.set_source_rgba(ctx, 0, 0, 0, 1)
        draw_layer!(ctx, L, pxmm)
        Cairo.restore(ctx)
        Cairo.flush(surf)
        stride = Cairo.format_stride_for_width(Cairo.FORMAT_ARGB32, N) ÷ 4
        ink = L.clear ? 1f0 : 0f0
        GC.@preserve surf begin
            data = unsafe_wrap(Array, Cairo.image_surface_get_data(surf), (stride, N))
            @inbounds for i in 1:N, j in 1:N   # data is (x, y), img is (row=y, col=x)
                a = Float32((data[j, i] >> 24) & 0xff) / 255f0
                a > 0 && (img[i, j] = img[i, j] * (1 - a) + ink * a)
            end
        end
    end
    Cairo.finish(surf)
    img
end

"Anchor point of a layer in mm relative to the disc centre (for the on-disc marker)."
function layer_anchor(L::TextLayer)
    L.path == "straight" && return (L.x, L.y)
    a = deg2rad(L.angle)
    (L.radius * sin(a), -L.radius * cos(a))
end

"Installed font families (fontconfig), favourites first, script-specific Noto variants dropped."
function font_families()
    fams = String[]
    try
        for line in eachline(`fc-list : family`)
            for f in split(line, ',')
                f = strip(f); isempty(f) || push!(fams, f)
            end
        end
    catch
    end
    keep(f) = !occursin(r"^Noto (Sans|Serif|Kufi|Naskh|Nastaliq|Rashi|Fangsong|Music|Color|Znamenny|Traditional) ?\S", f) ||
              f in ("Noto Sans Mono", "Noto Serif Display")
    fams = sort!(unique(filter(keep, fams)); by = lowercase)
    favs = ["Liberation Sans", "Liberation Serif", "Liberation Mono", "Noto Sans", "Noto Serif", "Fira Sans",
            "Iosevka Nerd Font", "JetBrainsMono Nerd Font", "Nimbus Sans", "Nimbus Roman", "C059"]
    favs = filter(in(fams), favs)
    isempty(fams) && return ["Sans", "Serif", "Monospace"]
    vcat(favs, filter(!in(favs), fams))
end
