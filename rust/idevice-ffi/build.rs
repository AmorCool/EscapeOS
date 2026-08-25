// Trivial build script: header generation is done out-of-band (the pre-generated
// `EscapeOS/Tunnel/idevice.h` shipped with the app is used as-is). Keeping this
// empty avoids pulling in cbindgen + a local plist.h during the iOS build.
fn main() {}
