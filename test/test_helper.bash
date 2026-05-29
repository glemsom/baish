#!/usr/bin/env bash

repo_root() {
  cd -- "$(dirname -- "${BATS_TEST_FILENAME}")/.." && pwd
}

make_stub_command() {
  local directory="$1"
  local name="$2"
  local body="$3"

  mkdir -p "$directory"
  cat >"$directory/$name" <<EOF
#!/usr/bin/env bash
$body
EOF
  chmod +x "$directory/$name"
}
