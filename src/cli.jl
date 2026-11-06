# Thin wrapper around /opt/4L/4L-cli.bin

const CLI_BIN = get(ENV, "LIGHTSCRIBE_CLI", "/opt/4L/4L-cli.bin")
const CLI_LIBDIR = get(ENV, "LIGHTSCRIBE_LIBDIR", "/usr/lib32/lightscribe")
const ELEVATOR = get(ENV, "LIGHTSCRIBE_SUDO", "pkexec")

is_root() = ccall(:geteuid, Cuint, ()) == 0

"Build the command line; `elevate` wraps it in pkexec (4L needs root for drive I/O)."
function cli_cmd(args::Vector{String}; elevate::Bool = true)
    inner = `env LD_LIBRARY_PATH=$CLI_LIBDIR $CLI_BIN $args`
    (elevate && !is_root()) ? `$ELEVATOR $inner` : inner
end

"Run a short CLI command synchronously, returning (ok, combined output)."
function cli_run(args::Vector{String}; elevate::Bool = true)
    out = IOBuffer()
    p = run(pipeline(ignorestatus(cli_cmd(args; elevate)); stdout = out, stderr = out); wait = true)
    s = String(take!(out))
    s = replace(s, r"^Using /etc/lightscribe\.rc\s*"m => "")
    (success(p), strip(s))
end

"Find LightScribe drives: parse `enumerate`, fall back to optical device nodes."
function find_drives(; elevate::Bool = false)
    drives = String[]
    try
        ok, out = cli_run(["enumerate"]; elevate)
        for m in eachmatch(r"Drive path:\s*(\S+)", out)
            push!(drives, m.captures[1])
        end
    catch err
        @warn "enumerate failed" err
    end
    if isempty(drives)
        for f in readdir("/dev"; join = true)
            occursin(r"^/dev/sr\d+$", f) && push!(drives, f)
        end
    end
    unique(drives)
end

"Parse 'Key: value' lines into a Dict."
parse_kv(s) = Dict(strip(m[1]) => strip(m[2]) for m in eachmatch(r"^([^:\n]+):\s*(.*)$"m, s))

"""
Run a long CLI job (print/preview) asynchronously. `on_line(line)` is called for every
line/carriage-return-delimited chunk; `on_done(ok)` at the end. Returns the Process.
"""
function cli_spawn(args::Vector{String}, on_line::Function, on_done::Function; elevate::Bool = true)
    cmd = cli_cmd(args; elevate)
    # merge stderr into stdout so progress lines arrive in order
    proc = open(`bash -c 'exec "$@" 2>&1' _ $(cmd.exec)`, "r")
    @async begin
        buf = IOBuffer()
        try
            while !eof(proc)
                data = readavailable(proc)
                for b in data
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

"Ask the running (root) 4L-cli process to abort gracefully with SIGINT."
function cli_interrupt(proc)
    pid = getpid(proc)
    if is_root() || !occursin(ELEVATOR, string(proc.cmd))
        kill(proc, Base.SIGINT)
    else
        run(ignorestatus(`$ELEVATOR kill -INT $pid`); wait = false)
    end
end
