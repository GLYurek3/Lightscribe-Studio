module LightScribeStudio

using Gtk4, Cairo, TOML
using Gtk4.GdkPixbufLib: GdkPixbuf

include("imaging.jl")
include("theme.jl")
include("text.jl")
include("cli.jl")
include("datadisc.jl")
include("gui.jl")
include("document.jl")
include("datagui.jl")
include("picker.jl")

export main

end
