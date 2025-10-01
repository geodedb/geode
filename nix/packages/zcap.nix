# Legacy zcap package (for compatibility)
# This creates a wrapper that points to the main geode binary
{ lib, stdenv, zig, optimize ? "ReleaseFast", enableXdp ? false }:

stdenv.mkDerivation rec {
  pname = "zcap";
  version = "0.18.0";
  
  src = ./../..;
  
  buildCommand = ''
    mkdir -p $out/bin
    # Create a compatibility wrapper
    cat > $out/bin/zcap << 'EOF'
#!/bin/sh
# zcap compatibility wrapper - redirects to geode
exec geode "$@"
EOF
    chmod +x $out/bin/zcap
    
    # Create a note about the migration
    mkdir -p $out/share/doc/zcap
    cat > $out/share/doc/zcap/README << 'EOF'
ZCAP → Geode Migration Notice
============================

This is a compatibility wrapper for the legacy 'zcap' command.
The project has been renamed to 'Geode'.

Please update your scripts to use 'geode' instead of 'zcap'.

For more information, see the Geode documentation.
EOF
  '';
  
  meta = with lib; {
    description = "Legacy compatibility wrapper for Geode (formerly zcap)";
    homepage = "https://github.com/spyderorg/geode";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "zcap";
  };
}