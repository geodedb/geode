// CANARY: REQ=REQ-SONNY-CAPABILITY-PROFILE-002; FEATURE="SonnyCapabilityProfile"; ASPECT=ProcessRefusal; STATUS=IMPL; TEST=tests/test_capability_gate_startup.zig; OWNER=server; UPDATED=2026-09-08
// Linux process acceptance uses the real geode this build emitted (argv[2],
// SONNY-2697) and native syscall tracing.
// Python orchestrates bounded children/fixtures; it never supplies engine rows.
const std = @import("std");
const build_options = @import("build_options");
const geode_test_bin = @import("geode_test_bin");

// The live refusal reason for a canonical profile is version-relative: below the
// engine floor the gate stops at the version check, at or above it the still-false
// mandatory capability rows decide. The harness never guesses it; Zig computes it
// from the build version and hands it over as argv[1].
fn expectedCanonicalReason() ![]const u8 {
    const label = build_options.version;
    const running = try std.SemanticVersion.parse(if (std.mem.startsWith(u8, label, "v")) label[1..] else label);
    const floor: std.SemanticVersion = .{ .major = 0, .minor = 8, .patch = 14 };
    return if (running.order(floor) == .lt) "IncompatibleEngineVersion" else "MandatoryCapabilityUnsupported";
}

test "real startup gate refuses before every listener and releases its lock" {
    // The native observation (process-tree and listener scan) is Linux-only.
    // SONNY-6770: the step runs in the aggregate on every OS (SONNY-2772),
    // so off Linux it skips; failing there broke test-macos-unit.
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const expected_reason = try expectedCanonicalReason();
    const result = try std.process.run(std.testing.allocator, threaded.io(), .{
        .argv = &.{ "/usr/bin/python3", "-c", process_test ++ "\n" ++ growth_test, expected_reason, geode_test_bin.geode_exe },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
}

const process_test =
    \\import ctypes, datetime, fcntl, hashlib, json, os, pathlib, re, signal, socket, stat, subprocess, sys, tempfile, time
    \\canonical_reason = sys.argv[1]
    \\assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0, 'subreaper unavailable'
    \\work = pathlib.Path.cwd()
    \\binary = pathlib.Path(sys.argv[2])
    \\manifest = work / 'release/sonny_capability_profile.json'
    \\(work/'.superpowers'/'sdd').mkdir(parents=True, exist_ok=True)
    \\root = pathlib.Path(tempfile.mkdtemp(prefix='geode-capability-startup-', dir=str(work/'.superpowers'/'sdd')))
    \\print('startup evidence: ' + str(root), flush=True)
    \\def sha(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    \\identities = {str(p): sha(p) for p in (binary, manifest, '/usr/bin/strace', '/usr/bin/python3', '/usr/bin/openssl', work / 'tests/test_capability_gate_startup.zig')}
    \\(root / 'identities.json').write_text(json.dumps(identities, indent=2))
    \\def port():
    \\    with socket.socket() as s:
    \\        s.bind(('127.0.0.1', 0))
    \\        return s.getsockname()[1]
    \\def case(mode, profile_kind=None):
    \\    d = root / (mode + '-' + (profile_kind or 'ordinary'))
    \\    d.mkdir()
    \\    for child in ('data', 'home', 'certs', 'tmp'): (d / child).mkdir(mode=0o700)
    \\    q, g, m, l, c = [port() for _ in range(5)]
    \\    env = {'PATH':'/usr/bin:/bin', 'HOME':str(d/'home'), 'TMPDIR':str(d/'tmp'), 'LANG':'C', 'TZ':'UTC',
    \\           'GEODE_DATA_DIR':str(d/'data'), 'GEODE_CERT_DIR':str(d/'certs'), 'GEODE_AUDIT_LOG_PATH':str(d/'audit.jsonl'),
    \\           'GEODE_METRICS_BIND':'127.0.0.1', 'GEODE_METRICS_PORT':str(m), 'GEODE_DATA_DIR_LOCK_TIMEOUT_MS':'0'}
    \\    argv = [str(binary), 'serve', '--data-dir', str(d/'data'), '--log-level', 'info', '--lsp-port='+str(l if mode=='lsp' else 0)]
    \\    expected = [m]
    \\    if mode != 'grpc':
    \\        argv += ['--listen', '127.0.0.1:'+str(q)]
    \\        expected += [q]
    \\    if mode in ('grpc', 'combined'):
    \\        argv += ['--listen-grpc', '127.0.0.1:'+str(g)]
    \\        expected += [g]
    \\    if mode == 'lsp': expected += [l]
    \\    if mode == 'cluster':
    \\        env.update(GEODE_NODE_ID='1', GEODE_CLUSTER_TOKEN='task2-owned-local-cluster-token', GEODE_CLUSTER_LISTEN_ADDRESS='127.0.0.1', GEODE_CLUSTER_PORT=str(c))
    \\        expected += [c]
    \\    reason = canonical_reason
    \\    if profile_kind:
    \\        path = d/'profile.json'
    \\        data = manifest.read_bytes()
    \\        if profile_kind == 'missing': reason = 'FileNotFound'
    \\        elif profile_kind == 'directory':
    \\            path.mkdir()
    \\            reason = 'InvalidCapabilityProfileFileType'
    \\        elif profile_kind == 'fifo':
    \\            os.mkfifo(path)
    \\            reason = 'InvalidCapabilityProfileFileType'
    \\        elif profile_kind == 'oversize':
    \\            path.write_bytes(data + b' ' * ((1<<20)+1-len(data)))
    \\            reason = 'StreamTooLong'
    \\        elif profile_kind == 'exact-size': path.write_bytes(data + b' ' * ((1<<20)-len(data)))
    \\        elif profile_kind == 'symlink': path.symlink_to(manifest)
    \\        elif profile_kind == 'unreadable':
    \\            assert os.geteuid() != 0, 'unreadable fixture requires non-root uid'
    \\            path.write_bytes(data)
    \\            path.chmod(0)
    \\            reason = 'AccessDenied'
    \\        elif profile_kind == 'malformed':
    \\            path.write_text('{}')
    \\            reason = 'MalformedCapabilityProfile'
    \\        else: path.write_bytes(data)
    \\        if mode == 'env': env['GEODE_REQUIRE_CAPABILITY_PROFILE'] = 'profile.json'
    \\        elif mode == 'file':
    \\            config = d/'config.json'
    \\            config.write_text(json.dumps({'require_capability_profile':'profile.json'}))
    \\            argv += ['--config',str(config)]
    \\        elif mode == 'discovery':
    \\            (d/'.geode').mkdir()
    \\            (d/'.geode'/'config.json').write_text(json.dumps({'require_capability_profile':'profile.json'}))
    \\        else: argv += ['--require-capability-profile', str(path)]
    \\        if profile_kind == 'bad-config':
    \\            reason = 'ParseError'
    \\            if mode == 'file': (d/'config.json').write_text('{broken')
    \\            else: (d/'.geode'/'config.json').write_text('{broken')
    \\        elif profile_kind == 'empty-path':
    \\            env['GEODE_REQUIRE_CAPABILITY_PROFILE'] = ''
    \\            reason = 'InvalidCapabilityProfilePath'
    \\    elif mode == 'file':
    \\        (d/'config.json').write_text('{}')
    \\        argv += ['--config',str(d/'config.json')]
    \\    elif mode == 'discovery':
    \\        (d/'.geode').mkdir()
    \\        (d/'.geode'/'config.json').write_text('{}')
    \\    trace = d/'network.trace'
    \\    cmd = ['/usr/bin/strace','-f','-qq','-e','trace=bind,listen,connect','-o',str(trace),*argv]
    \\    receipt = {'argv':argv, 'command':cmd, 'env':env, 'env_sha256':hashlib.sha256(json.dumps(env,sort_keys=True).encode()).hexdigest(), 'binary_sha256':identities[str(binary)], 'started':datetime.datetime.now(datetime.timezone.utc).isoformat(), 'expected_ports':expected}
    \\    (d/'entry.json').write_text(json.dumps(receipt,indent=2))
    \\    with (d/'output.log').open('wb') as log:
    \\        p = subprocess.Popen(cmd,cwd=d,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    \\        reached = False
    \\        deadline = time.monotonic()+60
    \\        try:
    \\            while p.poll() is None and time.monotonic()<deadline:
    \\                text = trace.read_text() if trace.exists() else ''
    \\                reached = all(re.search(r'bind\(.*htons\('+str(n)+r'\).* = 0',text) for n in expected)
    \\                if reached: break
    \\                time.sleep(.05)
    \\        finally:
    \\            natural_rc = p.poll()
    \\            if natural_rc is None:
    \\                os.killpg(p.pid,signal.SIGTERM)
    \\                try: p.wait(timeout=5)
    \\                except subprocess.TimeoutExpired:
    \\                    os.killpg(p.pid,signal.SIGKILL)
    \\                    p.wait(timeout=5)
    \\            try: os.killpg(p.pid,signal.SIGKILL)
    \\            except ProcessLookupError: pass
    \\            while True:
    \\                try: os.waitpid(-p.pid,0)
    \\                except ChildProcessError: break
    \\    lock = d/'data'/'.geode.lock'
    \\    if profile_kind in ('bad-config','empty-path'): assert not lock.exists(), 'invalid config reached storage initialization'
    \\    else:
    \\        with lock.open('r+') as f:
    \\            fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
    \\            fcntl.flock(f,fcntl.LOCK_UN)
    \\    text = trace.read_text()
    \\    output = (d/'output.log').read_text(errors='replace')
    \\    binds = [line for line in text.splitlines() if 'bind(' in line]
    \\    receipt.update(ended=datetime.datetime.now(datetime.timezone.utc).isoformat(), natural_rc=natural_rc, reaped_rc=p.returncode, reached=reached, binds=binds, lock_released=True)
    \\    (d/'receipt.json').write_text(json.dumps(receipt,indent=2))
    \\    if profile_kind:
    \\        assert natural_rc is not None and natural_rc != 0, 'gate did not refuse: '+str(d)
    \\        assert not binds, 'transient bind before refusal: '+str(d)
    \\        assert reason in output, 'wrong refusal: '+str(d)
    \\        if profile_kind not in ('bad-config','empty-path'): assert 'capability profile' in output and 'refusing to start' in output, 'missing refusal diagnostic'
    \\        assert '[startup] server ready' not in output and 'status":"listening' not in output, 'premature readiness'
    \\    else: assert reached, 'ordinary listener prerequisite failed: '+str(d)
    \\    if profile_kind == 'fifo' and path.is_fifo(): path.unlink()
    \\    print('PASS '+d.name,flush=True)
    \\def sweep_fifos():
    \\    for p in root.rglob('*'):
    \\        try:
    \\            if stat.S_ISFIFO(p.lstat().st_mode): p.unlink()
    \\        except OSError: pass
    \\try:
    \\    for mode in ('quic','grpc','combined','metrics','lsp','cluster','env','file','discovery'):
    \\        case(mode)
    \\        case(mode,'canonical')
    \\    for kind in ('missing','directory','fifo','oversize','exact-size','symlink','unreadable','malformed'): case('quic',kind)
    \\    case('file','bad-config')
    \\    case('discovery','bad-config')
    \\    case('env','empty-path')
    \\finally:
    \\    sweep_fifos()
;

// Stop the real process on the successful same-descriptor stat syscall exit,
// append bytes before it can read, and then resume. No engine/syscall result is
// replaced. This proves a real growth race cannot evade the bounded reader.
const growth_test =
    \\import platform
    \\assert platform.machine() == 'x86_64', 'growth observer requires Linux x86_64 syscall ABI'
    \\libc = ctypes.CDLL(None, use_errno=True)
    \\libc.ptrace.restype = ctypes.c_long
    \\class Regs(ctypes.Structure):
    \\    _fields_ = [(n,ctypes.c_ulonglong) for n in 'r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi orig_rax rip cs eflags rsp ss fs_base gs_base ds es fs gs'.split()]
    \\def ptrace(op,pid,addr=0,data=0):
    \\    result = libc.ptrace(op,pid,ctypes.c_void_p(addr),data)
    \\    assert result != -1, 'ptrace failure: '+str(ctypes.get_errno())
    \\    return result
    \\d = root/'growing-file'
    \\d.mkdir()
    \\for child in ('data','home','certs','tmp'): (d/child).mkdir(mode=0o700)
    \\path = d/'profile.json'
    \\original = manifest.read_bytes()
    \\path.write_bytes(original)
    \\env = {'PATH':'/usr/bin:/bin','HOME':str(d/'home'),'TMPDIR':str(d/'tmp'),'GEODE_CERT_DIR':str(d/'certs'), 'GEODE_DATA_DIR':str(d/'data'), 'GEODE_AUDIT_LOG_PATH':str(d/'audit.jsonl'),'GEODE_METRICS_BIND':'127.0.0.1','GEODE_METRICS_PORT':str(port()),'LANG':'C','TZ':'UTC'}
    \\argv = [str(binary),'serve','--data-dir',str(d/'data'),'--listen','127.0.0.1:'+str(port()),'--lsp-port=0','--require-capability-profile',str(path)]
    \\receipt = {'argv':argv,'env':env,'binary_sha256':identities[str(binary)],'started':datetime.datetime.now(datetime.timezone.utc).isoformat(),'original_size':len(original)}
    \\(d/'entry.json').write_text(json.dumps(receipt,indent=2))
    \\def traced_child(): ptrace(0,0)
    \\with (d/'output.log').open('wb') as log:
    \\    p = subprocess.Popen(argv,cwd=d,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,preexec_fn=traced_child)
    \\    deadline = time.monotonic()+60
    \\    entering, grew, binds, exited = True, False, 0, False
    \\    def wait_stop():
    \\        while time.monotonic()<deadline:
    \\            pid,status = os.waitpid(p.pid,os.WNOHANG)
    \\            if pid: return status
    \\            time.sleep(.0005)
    \\        raise AssertionError('growth observer deadline')
    \\    try:
    \\        status = wait_stop()
    \\        assert os.WIFSTOPPED(status), 'missing initial ptrace stop'
    \\        ptrace(0x4200,p.pid,0,0x100001) # SETOPTIONS: EXITKILL | TRACESYSGOOD
    \\        while True:
    \\            ptrace(24,p.pid) # PTRACE_SYSCALL
    \\            status = wait_stop()
    \\            if os.WIFEXITED(status) or os.WIFSIGNALED(status):
    \\                p.returncode = os.waitstatus_to_exitcode(status)
    \\                exited = True
    \\                break
    \\            sig = os.WSTOPSIG(status)
    \\            if sig != (signal.SIGTRAP|0x80):
    \\                assert sig in (signal.SIGCHLD, signal.SIGTRAP), 'unexpected trace signal '+str(sig)
    \\                continue
    \\            regs = Regs()
    \\            ptrace(12,p.pid,0,ctypes.byref(regs)) # GETREGS
    \\            if entering and regs.orig_rax == 49: binds += 1
    \\            if not entering and regs.orig_rax in (5,332) and regs.rax == 0 and not grew:
    \\                try: target = os.readlink('/proc/'+str(p.pid)+'/fd/'+str(regs.rdi))
    \\                except OSError: target = None
    \\                if target == str(path):
    \\                    info = pathlib.Path('/proc/'+str(p.pid)+'/fdinfo/'+str(regs.rdi)).read_text()
    \\                    flags = int(re.search(r'flags:\s*([0-7]+)',info).group(1),8)
    \\                    assert flags & os.O_NONBLOCK and flags & os.O_CLOEXEC, 'profile descriptor flags'
    \\                    with path.open('ab') as f: f.write(b' '*((1<<20)+1-len(original)))
    \\                    receipt.update(stat_syscall=regs.orig_rax,profile_fd=regs.rdi,flags=oct(flags),grown_size=path.stat().st_size)
    \\                    grew = True
    \\            entering = not entering
    \\    finally:
    \\        try: os.killpg(p.pid,signal.SIGKILL)
    \\        except ProcessLookupError: pass
    \\        if not exited: p.wait(timeout=5)
    \\        while True:
    \\            try: os.waitpid(-p.pid,0)
    \\            except ChildProcessError: break
    \\output = (d/'output.log').read_text(errors='replace')
    \\with (d/'data'/'.geode.lock').open('r+') as lock:
    \\    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    \\    fcntl.flock(lock,fcntl.LOCK_UN)
    \\receipt.update(ended=datetime.datetime.now(datetime.timezone.utc).isoformat(),rc=p.returncode,grew=grew,binds=binds,lock_released=True)
    \\(d/'receipt.json').write_text(json.dumps(receipt,indent=2))
    \\assert grew and p.returncode != 0 and binds == 0 and 'StreamTooLong' in output, 'growth was not refused'
    \\print('PASS growing-file after same-descriptor stat',flush=True)
;
