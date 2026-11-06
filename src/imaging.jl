# Pure-Julia image pipeline: grayscale float matrices, 1.0 = white (unburned), 0.0 = black (burned).

"Disc geometry in mm (radius), measured from the 4L templates in /opt/4L/templates."
const DISC_RADIUS_MM = 60.0
const HOLE_RADIUS_MM = 7.5
const HUB_RADIUS_MM  = 22.8
const LABEL_AREAS = Dict(
    "full"    => (24.3, 59.5),
    "content" => (25.3, 37.6),
    "title"   => (31.8, 37.6),
)

Base.@kwdef mutable struct Adjustments
    zoom::Float64       = 1.0     # 1 = image's short side spans the disc
    rotate::Float64     = 0.0     # degrees
    offset_x::Float64   = 0.0     # fraction of disc diameter
    offset_y::Float64   = 0.0
    flip::Bool          = false
    brightness::Float64 = 0.0     # -1 .. 1
    contrast::Float64   = 0.0     # -1 .. 1
    gamma::Float64      = 1.0     # 0.2 .. 3
    sharpen::Float64    = 0.0     # 0 .. 3
    invert::Bool        = false
    threshold::Bool     = false
    threshold_level::Float64 = 0.5
    dither::Bool        = false
    background_white::Bool = true # fill outside the image as unburned
    black_point::Float64 = 0.0    # set by auto-levels
    white_point::Float64 = 1.0
end

"Convert interleaved 8-bit RGB(A) rows into a Float32 luma matrix (rows × cols)."
function luma_from_bytes(bytes::AbstractVector{UInt8}, w::Int, h::Int, rowstride::Int, nchan::Int)
    out = Matrix{Float32}(undef, h, w)
    @inbounds for y in 1:h
        base = (y - 1) * rowstride
        for x in 1:w
            i = base + (x - 1) * nchan
            r = bytes[i+1]; g = bytes[i+2]; b = bytes[i+3]
            v = (0.2126f0 * r + 0.7152f0 * g + 0.0722f0 * b) / 255f0
            if nchan == 4  # composite transparency onto white (unburned)
                a = bytes[i+4] / 255f0
                v = v * a + (1f0 - a)
            end
            out[y, x] = v
        end
    end
    out
end

"Box-filter downscale so the longest side is at most `maxside`."
function downscale(img::Matrix{Float32}, maxside::Int)
    h, w = size(img)
    f = max(h, w) / maxside
    f <= 1 && return copy(img)
    nh, nw = max(1, floor(Int, h / f)), max(1, floor(Int, w / f))
    out = zeros(Float32, nh, nw)
    cnt = zeros(Float32, nh, nw)
    @inbounds for x in 1:w, y in 1:h
        ny = min(nh, 1 + floor(Int, (y - 1) / f))
        nx = min(nw, 1 + floor(Int, (x - 1) / f))
        out[ny, nx] += img[y, x]; cnt[ny, nx] += 1
    end
    out ./= max.(cnt, 1f0)
    out
end

@inline function bilinear(img::Matrix{Float32}, y::Float64, x::Float64, bg::Float32)
    h, w = size(img)
    (y < 0.5 || x < 0.5 || y > h + 0.5 || x > w + 0.5) && return bg
    y = clamp(y, 1.0, Float64(h)); x = clamp(x, 1.0, Float64(w))
    y0 = min(floor(Int, y), h - 1 + (h == 1)); x0 = min(floor(Int, x), w - 1 + (w == 1))
    y1 = min(y0 + 1, h); x1 = min(x0 + 1, w)
    fy = Float32(y - y0); fx = Float32(x - x0)
    @inbounds a = img[y0, x0] * (1 - fx) + img[y0, x1] * fx
    @inbounds b = img[y1, x0] * (1 - fx) + img[y1, x1] * fx
    a * (1 - fy) + b * fy
end

"Resample `src` onto an N×N canvas that represents the full 120 mm disc."
function place(src::Matrix{Float32}, N::Int, a::Adjustments)
    h, w = size(src)
    bg = a.background_white ? 1f0 : 0f0
    # pixels of source per canvas pixel: short side spans the canvas at zoom 1 (cover)
    s = min(h, w) / (N * a.zoom)
    θ = deg2rad(a.rotate); c, sn = cos(θ), sin(θ)
    cx = cy = (N + 1) / 2
    ox, oy = a.offset_x * N, a.offset_y * N
    out = Matrix{Float32}(undef, N, N)
    for j in 1:N
        @inbounds for i in 1:N
            dx = j - cx - ox; dy = i - cy - oy
            rx = c * dx + sn * dy
            ry = -sn * dx + c * dy
            a.flip && (rx = -rx)
            out[i, j] = bilinear(src, (h + 1) / 2 + ry * s, (w + 1) / 2 + rx * s, bg)
        end
    end
    out
end

function box_blur(img::Matrix{Float32}, r::Int)
    h, w = size(img)
    tmp = similar(img); out = similar(img)
    @inbounds for i in 1:h
        acc = 0f0
        for j in -r:r; acc += img[i, clamp(1 + j, 1, w)]; end
        for j in 1:w
            tmp[i, j] = acc / (2r + 1)
            acc += img[i, clamp(j + r + 1, 1, w)] - img[i, clamp(j - r, 1, w)]
        end
    end
    @inbounds for j in 1:w
        acc = 0f0
        for i in -r:r; acc += tmp[clamp(1 + i, 1, h), j]; end
        for i in 1:h
            out[i, j] = acc / (2r + 1)
            acc += tmp[clamp(i + r + 1, 1, h), j] - tmp[clamp(i - r, 1, h), j]
        end
    end
    out
end

function floyd_steinberg!(img::Matrix{Float32})
    h, w = size(img)
    @inbounds for i in 1:h, j in 1:w
        old = img[i, j]; new = old < 0.5f0 ? 0f0 : 1f0
        img[i, j] = new; e = old - new
        j < w && (img[i, j+1] += e * 7f0 / 16)
        if i < h
            j > 1 && (img[i+1, j-1] += e * 3f0 / 16)
            img[i+1, j] += e * 5f0 / 16
            j < w && (img[i+1, j+1] += e * 1f0 / 16)
        end
    end
    img
end

"Apply tonal adjustments in place-free fashion; returns a new matrix."
function adjust(img::Matrix{Float32}, a::Adjustments)
    bp, wp = Float32(a.black_point), Float32(max(a.white_point, a.black_point + 1e-3))
    b = Float32(a.brightness)
    # contrast slider -1..1 mapped to a multiplicative factor 0..~5
    k = Float32(a.contrast >= 0 ? 1 + 4 * a.contrast^1.5 : 1 + a.contrast)
    g = Float32(1 / a.gamma)
    out = similar(img)
    @inbounds for i in eachindex(img)
        v = (img[i] - bp) / (wp - bp)
        v = clamp(v, 0f0, 1f0)^g
        v = (v - 0.5f0) * k + 0.5f0 + b
        out[i] = clamp(v, 0f0, 1f0)
    end
    if a.sharpen > 0
        r = max(1, round(Int, size(img, 1) / 400))
        bl = box_blur(out, r)
        s = Float32(a.sharpen)
        @inbounds for i in eachindex(out)
            out[i] = clamp(out[i] + s * (out[i] - bl[i]), 0f0, 1f0)
        end
    end
    a.invert && (out .= 1f0 .- out)
    if a.threshold
        t = Float32(a.threshold_level)
        out .= ifelse.(out .< t, 0f0, 1f0)
    elseif a.dither
        floyd_steinberg!(out)
        clamp!(out, 0f0, 1f0)
    end
    out
end

"Full pipeline for a square N×N label image."
render_label(src::Matrix{Float32}, N::Int, a::Adjustments) = adjust(place(src, N, a), a)

"Percentile-based black/white points (ignores the outer 0.5% tails)."
function auto_levels(src::Matrix{Float32})
    v = sort!(vec(copy(src)))
    n = length(v)
    lo = v[clamp(round(Int, 0.005n), 1, n)]
    hi = v[clamp(round(Int, 0.995n), 1, n)]
    hi - lo < 0.02 ? (0.0, 1.0) : (Float64(lo), Float64(hi))
end

"Write an 8-bit grayscale image as a 24-bit BMP (what 4L-cli is happiest with)."
function write_bmp(path::AbstractString, img::Matrix{Float32})
    h, w = size(img)
    rowbytes = 3w; pad = (4 - rowbytes % 4) % 4
    datasize = (rowbytes + pad) * h
    open(path, "w") do io
        write(io, UInt8('B'), UInt8('M'), UInt32(54 + datasize), UInt32(0), UInt32(54))
        write(io, UInt32(40), Int32(w), Int32(h), UInt16(1), UInt16(24), UInt32(0),
              UInt32(datasize), Int32(23622), Int32(23622), UInt32(0), UInt32(0)) # 600 dpi
        row = Vector{UInt8}(undef, rowbytes + pad); fill!(row, 0x00)
        for y in h:-1:1  # bottom-up
            @inbounds for x in 1:w
                v = round(UInt8, clamp(img[y, x], 0f0, 1f0) * 255)
                row[3x-2] = v; row[3x-1] = v; row[3x] = v
            end
            write(io, row)
        end
    end
    path
end

"Read a 24/32-bit uncompressed BMP (used for 4L-cli preview output) into a luma matrix."
function read_bmp(path::AbstractString)
    d = read(path)
    off = Int(reinterpret(UInt32, d[11:14])[1])
    w = Int(reinterpret(Int32, d[19:22])[1]); hraw = Int(reinterpret(Int32, d[23:26])[1])
    bpp = Int(reinterpret(UInt16, d[29:30])[1])
    bpp in (24, 32) || error("unsupported BMP depth $bpp")
    h = abs(hraw); nch = bpp ÷ 8
    stride = ((w * nch + 3) ÷ 4) * 4
    out = Matrix{Float32}(undef, h, w)
    for r in 1:h
        y = hraw > 0 ? h - r + 1 : r
        base = off + (r - 1) * stride
        @inbounds for x in 1:w
            i = base + (x - 1) * nch
            b, g, rr = d[i+1], d[i+2], d[i+3]
            out[y, x] = (0.2126f0 * rr + 0.7152f0 * g + 0.0722f0 * b) / 255f0
        end
    end
    out
end
