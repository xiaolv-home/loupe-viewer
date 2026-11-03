# Sourced by the build and test scripts. A Command Line Tools update can ship an SDK whose
# SwiftUI needs a macro plugin the CLT toolchain lacks (CLT 27.2: "plugin for module
# 'SwiftUIMacros' not found"). Then build against the newest installed SDK that still works.
DEV="$(xcode-select -p)"
if [[ -z "${SDKROOT:-}" && ! -d "$DEV/Platforms" ]]; then
  probe_dir="$(mktemp -d)"
  printf 'import SwiftUI\nstruct V: View { @State var x = 0; var body: some View { Text("") } }\n' > "$probe_dir/p.swift"
  if ! swiftc -typecheck "$probe_dir/p.swift" >/dev/null 2>&1; then
    for sdk in $(ls -d "$DEV"/SDKs/MacOSX[0-9]*.sdk | sort -rV); do
      [[ -L "$sdk" ]] && continue
      if SDKROOT="$sdk" swiftc -typecheck "$probe_dir/p.swift" >/dev/null 2>&1; then
        export SDKROOT="$sdk"
        echo "默认 SDK 编译不了 SwiftUI，改用 $(basename "$sdk")" >&2
        break
      fi
    done
  fi
  rm -rf "$probe_dir"
fi
